const std = @import("std");
const WorkStealingDeque = @import("work_stealing_deque.zig").WorkStealingDeque;
const ConcurrentQueue = @import("concurrent_queue.zig").ConcurrentQueue;
const Parker = @import("parker.zig").Parker;
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const Context = future_mod.Context;
const Waker = future_mod.Waker;
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const RawTask = task_mod.RawTask;
const JoinHandle = task_mod.JoinHandle;

/// Worker thread for executing tasks
const Worker = struct {
    id: usize,
    local_queue: WorkStealingDeque(RawTask),
    runtime: ?*Runtime,
    thread: ?std.Thread,
    parker: Parker,
    prng: std.Random.DefaultPrng,

    fn init(id: usize, allocator: std.mem.Allocator) !Worker {
        return .{
            .id = id,
            .local_queue = try WorkStealingDeque(RawTask).init(allocator),
            .runtime = null,
            .thread = null,
            .parker = Parker.init(),
            .prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15 ^ @as(u64, @intCast(id))),
        };
    }

    fn deinit(self: *Worker) void {
        self.local_queue.deinit();
    }

    /// Main worker loop
    fn run(self: *Worker) void {
        current_worker = self;
        defer current_worker = null;

        const runtime = self.runtime.?;
        while (!runtime.shutdown.load(.acquire)) {
            if (self.findTask()) |task| {
                self.runTask(task);
            } else {
                self.parker.park();
            }
        }
    }

    /// Find a task to execute
    fn findTask(self: *Worker) ?RawTask {
        // Try local queue first (LIFO for cache locality)
        if (self.local_queue.pop()) |task| {
            return task;
        }

        // Try global queue
        const runtime = self.runtime.?;
        if (runtime.global_queue.pop()) |task| {
            return task;
        }

        // Try stealing from other workers
        return self.steal();
    }

    /// Steal work from other workers
    fn steal(self: *Worker) ?RawTask {
        // Randomize starting point to avoid hot-spots
        const runtime = self.runtime.?;
        if (runtime.workers.len <= 1) return null;
        const start = self.prng.random().intRangeLessThan(usize, 0, runtime.workers.len);

        var i: usize = 0;
        while (i < runtime.workers.len) : (i += 1) {
            const victim_idx = (start + i) % runtime.workers.len;

            if (victim_idx == self.id) continue; // Don't steal from ourselves

            const victim = &runtime.workers[victim_idx];

            if (victim.local_queue.steal()) |task| {
                return task;
            }
        }

        return null;
    }

    /// Execute a task
    fn runTask(self: *Worker, raw_task: RawTask) void {
        const runtime = self.runtime.?;
        var waker_data = WakerData{
            .task = raw_task,
            .runtime = runtime,
            .owned = false,
        };

        const waker = Waker{
            .data = @ptrCast(&waker_data),
            .vtable = &WakerData.vtable,
        };
        defer waker.drop();

        var ctx = Context.init(waker);
        var task_copy = raw_task;
        _ = task_copy.poll(&ctx);
    }

    /// Unpark this worker
    fn unpark(self: *Worker) void {
        self.parker.unpark();
    }

    /// Spawn a task on this worker's local queue
    fn spawnLocal(self: *Worker, task: RawTask) !void {
        try self.local_queue.push(task);
        self.runtime.?.unparkPeer(self.id);
    }
};

threadlocal var current_worker: ?*Worker = null;

/// Waker data for task notifications
const WakerData = struct {
    task: RawTask,
    runtime: *Runtime,
    /// The root waker lives on Worker.runTask's stack. Only clones can outlive
    /// that poll and therefore need allocator-backed ownership.
    owned: bool,

    const vtable = Waker.VTable{
        .wake = wake,
        .wake_by_ref = wakeByRef,
        .clone = clone,
        .drop = drop,
    };

    fn wake(ptr: *anyopaque) void {
        const self = @as(*WakerData, @ptrCast(@alignCast(ptr)));
        const task = self.task;
        const runtime = self.runtime;
        defer if (self.owned) runtime.task_allocator.destroy(self);

        // Re-queue the task
        runtime.enqueueTask(task) catch {
            std.log.err("Failed to re-queue task", .{});
        };
    }

    fn wakeByRef(ptr: *anyopaque) void {
        const self = @as(*WakerData, @ptrCast(@alignCast(ptr)));

        // Re-queue the task
        self.runtime.enqueueTask(self.task) catch {
            std.log.err("Failed to re-queue task", .{});
        };
    }

    fn clone(ptr: *anyopaque) *anyopaque {
        const self = @as(*WakerData, @ptrCast(@alignCast(ptr)));

        const new_data = self.runtime.task_allocator.create(WakerData) catch @panic("OOM cloning WakerData");
        new_data.* = self.*;
        new_data.owned = true;

        return @ptrCast(new_data);
    }

    fn drop(ptr: *anyopaque) void {
        const self = @as(*WakerData, @ptrCast(@alignCast(ptr)));
        if (self.owned) self.runtime.task_allocator.destroy(self);
    }
};

/// The async runtime
///
/// Manages worker threads, task scheduling, and I/O polling.
pub const Runtime = struct {
    /// Owns workers and long-lived queue storage.
    allocator: std.mem.Allocator,
    /// Owns tasks and cloned wakers. High-throughput callers may provide a
    /// bounded pool while keeping runtime storage on a general allocator.
    task_allocator: std.mem.Allocator,
    workers: []Worker,
    global_queue: ConcurrentQueue(RawTask),
    shutdown: std.atomic.Value(bool),
    next_worker: std.atomic.Value(usize),

    /// Create a new runtime with the specified number of worker threads
    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !Runtime {
        return initWithTaskAllocator(allocator, allocator, num_workers);
    }

    /// Create a runtime with separate allocators for long-lived runtime state
    /// and short-lived tasks/waker clones.
    pub fn initWithTaskAllocator(
        allocator: std.mem.Allocator,
        task_allocator: std.mem.Allocator,
        num_workers: usize,
    ) !Runtime {
        const worker_count = if (num_workers == 0) try std.Thread.getCpuCount() else num_workers;
        if (worker_count == 0) return error.InvalidWorkerCount;

        const workers = try allocator.alloc(Worker, worker_count);
        errdefer allocator.free(workers);

        var global_queue = try ConcurrentQueue(RawTask).init(allocator);
        errdefer global_queue.deinit();

        var initialized: usize = 0;
        errdefer for (workers[0..initialized]) |*worker| worker.deinit();
        for (workers, 0..) |*worker, i| {
            worker.* = try Worker.init(i, allocator);
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .task_allocator = task_allocator,
            .workers = workers,
            .global_queue = global_queue,
            .shutdown = std.atomic.Value(bool).init(false),
            .next_worker = std.atomic.Value(usize).init(0),
        };
    }

    /// Clean up runtime resources
    pub fn deinit(self: *Runtime) void {
        self.requestShutdown();
        self.joinWorkers();

        // Clean up workers
        for (self.workers) |*worker| {
            worker.deinit();
        }

        self.allocator.free(self.workers);
        self.global_queue.deinit();
    }

    /// Spawn a new task
    pub fn spawn(self: *Runtime, comptime T: type, fut: Future(T)) !JoinHandle(T) {
        const task = try Task(T).init(self.task_allocator, fut);
        errdefer task.deinit();
        const raw = RawTask.fromTask(T, task);

        try self.enqueueTask(raw);

        return JoinHandle(T){ .task = task };
    }

    /// Enqueue a task for execution
    fn enqueueTask(self: *Runtime, task: RawTask) !void {
        // Try to push to current worker's local queue if we're on a worker
        if (getCurrentWorker(self)) |worker| {
            try worker.spawnLocal(task);
            return;
        }

        // Otherwise, push to global queue
        try self.global_queue.push(task);

        // Wake a worker
        self.unparkOne();
    }

    /// Get the current worker (if running on a worker thread)
    fn getCurrentWorker(self: *Runtime) ?*Worker {
        if (current_worker) |worker| {
            if (worker.runtime == self) return worker;
        }
        return null;
    }

    /// Number of worker threads owned by this runtime.
    pub fn workerCount(self: *const Runtime) usize {
        return self.workers.len;
    }

    /// Index of the worker currently polling this task, or null outside this
    /// runtime's worker threads. This lets executor-aware futures shard work
    /// and expose scheduling telemetry without leaking the private Worker type.
    pub fn currentWorkerIndex(self: *Runtime) ?usize {
        const worker = self.getCurrentWorker() orelse return null;
        return worker.id;
    }

    /// Unpark one worker thread
    fn unparkOne(self: *Runtime) void {
        if (self.workers.len > 0) {
            const index = self.next_worker.fetchAdd(1, .monotonic) % self.workers.len;
            self.workers[index].unpark();
        }
    }

    /// Wake a worker other than the one that just added local work, allowing
    /// parked peers to steal nested tasks immediately.
    fn unparkPeer(self: *Runtime, excluded_index: usize) void {
        if (self.workers.len <= 1) {
            self.workers[0].unpark();
            return;
        }

        const candidate = self.next_worker.fetchAdd(1, .monotonic) % (self.workers.len - 1);
        const index = if (candidate >= excluded_index) candidate + 1 else candidate;
        self.workers[index].unpark();
    }

    fn unparkAll(self: *Runtime) void {
        for (self.workers) |*worker| worker.unpark();
    }

    fn joinWorkers(self: *Runtime) void {
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }
    }

    pub fn requestShutdown(self: *Runtime) void {
        self.shutdown.store(true, .release);
        self.unparkAll();
    }

    /// Run the runtime until all tasks complete
    pub fn run(self: *Runtime) !void {
        if (self.shutdown.load(.acquire)) return error.RuntimeShuttingDown;

        for (self.workers) |*worker| worker.runtime = self;

        var started: usize = 0;
        errdefer {
            self.requestShutdown();
            for (self.workers[0..started]) |*worker| {
                worker.thread.?.join();
                worker.thread = null;
            }
        }

        for (self.workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
            started += 1;
        }

        self.joinWorkers();
    }

    /// Block on a future until it completes
    pub fn blockOn(self: *Runtime, comptime T: type, fut: Future(T)) !T {
        const handle = try self.spawn(T, fut);
        const runtime_thread = try std.Thread.spawn(.{}, Runtime.run, .{self});
        const result = handle.await() catch |err| {
            self.requestShutdown();
            runtime_thread.join();
            return err;
        };

        self.requestShutdown();
        runtime_thread.join();
        handle.deinit();

        return result;
    }
};

// =================================================================================
//                                    TESTS
// =================================================================================

test "Runtime - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 4);
    defer runtime.deinit();

    try testing.expectEqual(@as(usize, 4), runtime.workers.len);
}

test "Runtime - spawn ready future" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 2);
    defer runtime.deinit();

    const fut = try future_mod.ready(i32, 42, allocator);
    const handle = try runtime.spawn(i32, fut);

    // Start runtime
    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});

    const result = try handle.await();
    runtime.requestShutdown();
    rt_thread.join();
    defer handle.deinit();

    try testing.expectEqual(@as(i32, 42), result);
}

test "Runtime - block_on" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 2);
    defer runtime.deinit();

    const fut = try future_mod.ready(i32, 100, allocator);

    // This should block until the future completes
    const result = try runtime.blockOn(i32, fut);

    try testing.expectEqual(@as(i32, 100), result);
}

test "Runtime - multiple tasks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 4);
    defer runtime.deinit();

    const task_count = 10_000;
    var handles: std.ArrayList(JoinHandle(usize)) = .empty;
    defer handles.deinit(allocator);

    for (0..task_count) |i| {
        const fut = try future_mod.ready(usize, i, allocator);
        const handle = try runtime.spawn(usize, fut);
        try handles.append(allocator, handle);
    }

    // Start runtime
    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});

    var sum: usize = 0;
    for (handles.items) |handle| {
        sum += try handle.await();
    }

    runtime.requestShutdown();
    rt_thread.join();

    try testing.expectEqual(task_count * (task_count - 1) / 2, sum);
    for (handles.items) |handle| handle.deinit();
}
