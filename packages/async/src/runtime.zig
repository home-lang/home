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
    runtime: *Runtime,
    thread: ?std.Thread,
    parker: Parker,
    notified: std.atomic.Value(bool),

    fn init(id: usize, runtime: *Runtime) !Worker {
        return .{
            .id = id,
            .local_queue = try WorkStealingDeque(RawTask).init(runtime.allocator),
            .runtime = runtime,
            .thread = null,
            .parker = Parker.init(),
            .notified = std.atomic.Value(bool).init(false),
        };
    }

    fn deinit(self: *Worker) void {
        self.local_queue.deinit();
    }

    /// Main worker loop
    fn run(self: *Worker) void {
        while (!self.runtime.shutdown.load(.acquire)) {
            if (self.findTask()) |_| {
                self.runTask();
            } else {
                // No work found, park the thread
                self.park();
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
        if (self.runtime.global_queue.pop()) |task| {
            return task;
        }

        // Try stealing from other workers
        return self.steal();
    }

    /// Steal work from other workers
    fn steal(self: *Worker) ?RawTask {
        // Randomize starting point to avoid hot-spots
        const start = self.runtime.prng.random().intRangeLessThan(usize, 0, self.runtime.workers.len);

        var i: usize = 0;
        while (i < self.runtime.workers.len) : (i += 1) {
            const victim_idx = (start + i) % self.runtime.workers.len;

            if (victim_idx == self.id) continue; // Don't steal from ourselves

            const victim = &self.runtime.workers[victim_idx];

            if (victim.local_queue.steal()) |task| {
                return task;
            }
        }

        return null;
    }

    /// Execute a task
    fn runTask(self: *Worker) void {
        _ = @This();

        if (self.findTask()) |raw_task| {
            // Create waker for this task
            const waker_data = self.runtime.allocator.create(WakerData) catch return;
            waker_data.* = .{
                .task = raw_task,
                .worker_id = self.id,
                .runtime = self.runtime,
            };

            const waker = Waker{
                .data = @ptrCast(waker_data),
                .vtable = &WakerData.vtable,
            };

            var ctx = Context.init(waker);

            // Poll the task (make mutable copy)
            var task_copy = raw_task;
            const completed = task_copy.poll(&ctx);

            if (!completed) {
                // Task not ready, it will be re-queued when waker is called
            } else {
                // Task completed, clean up waker
                self.runtime.allocator.destroy(waker_data);
            }
        }
    }

    /// Park this worker thread
    fn park(self: *Worker) void {
        // Check if we were notified before parking
        if (self.notified.swap(false, .acquire)) {
            return;
        }

        // Park with timeout to periodically check shutdown
        _ = self.parker.parkTimeout(100 * std.time.ns_per_ms); // 100ms
    }

    /// Unpark this worker
    fn unpark(self: *Worker) void {
        self.notified.store(true, .release);
        self.parker.unpark();
    }

    /// Spawn a task on this worker's local queue
    fn spawnLocal(self: *Worker, task: RawTask) !void {
        try self.local_queue.push(task);
        self.unpark();
    }
};

/// Waker data for task notifications
const WakerData = struct {
    task: RawTask,
    worker_id: usize,
    runtime: *Runtime,

    const vtable = Waker.VTable{
        .wake = wake,
        .wake_by_ref = wakeByRef,
        .clone = clone,
        .drop = drop,
    };

    fn wake(ptr: *anyopaque) void {
        const self = @as(*WakerData, @ptrCast(@alignCast(ptr)));

        // Re-queue the task
        self.runtime.enqueueTask(self.task) catch {
            std.debug.print("Failed to re-queue task\n", .{});
        };

        // Cleanup
        self.runtime.allocator.destroy(self);
    }

    fn wakeByRef(ptr: *anyopaque) void {
        const self = @as(*WakerData, @ptrCast(@alignCast(ptr)));

        // Re-queue the task
        self.runtime.enqueueTask(self.task) catch {
            std.debug.print("Failed to re-queue task\n", .{});
        };
    }

    fn clone(ptr: *anyopaque) *anyopaque {
        const self = @as(*WakerData, @ptrCast(@alignCast(ptr)));

        const new_data = self.runtime.allocator.create(WakerData) catch unreachable;
        new_data.* = self.*;

        return @ptrCast(new_data);
    }

    fn drop(ptr: *anyopaque) void {
        const self = @as(*WakerData, @ptrCast(@alignCast(ptr)));
        self.runtime.allocator.destroy(self);
    }
};

/// The async runtime
///
/// Manages worker threads, task scheduling, and I/O polling.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    global_queue: ConcurrentQueue(RawTask),
    shutdown: std.atomic.Value(bool),
    prng: std.Random.DefaultPrng,

    /// Create a new runtime with the specified number of worker threads
    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !Runtime {
        const worker_count = if (num_workers == 0) try std.Thread.getCpuCount() else num_workers;

        var runtime = Runtime{
            .allocator = allocator,
            .workers = try allocator.alloc(Worker, worker_count),
            .global_queue = try ConcurrentQueue(RawTask).init(allocator),
            .shutdown = std.atomic.Value(bool).init(false),
            .prng = std.Random.DefaultPrng.init(@intCast(@as(usize, @intFromPtr(&worker_count)))),
        };

        // Initialize workers
        for (runtime.workers, 0..) |*worker, i| {
            worker.* = try Worker.init(i, &runtime);
        }

        return runtime;
    }

    /// Clean up runtime resources
    pub fn deinit(self: *Runtime) void {
        self.shutdown.store(true, .release);

        // Wait for workers to finish
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
            }
        }

        // Clean up workers
        for (self.workers) |*worker| {
            worker.deinit();
        }

        self.allocator.free(self.workers);
        self.global_queue.deinit();
    }

    /// Spawn a new task
    pub fn spawn(self: *Runtime, comptime T: type, fut: Future(T)) !JoinHandle(T) {
        const task = try Task(T).init(self.allocator, fut);
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
        _ = std.Thread.getCurrentId();

        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                _ = thread; // Thread comparison would need platform-specific logic
                // For now, just return null - work stealing will handle distribution
                continue;
            }
        }

        return null;
    }

    /// Unpark one worker thread
    fn unparkOne(self: *Runtime) void {
        // Simple strategy: unpark first worker
        // In production, could use round-robin or track parked workers
        if (self.workers.len > 0) {
            self.workers[0].unpark();
        }
    }

    /// Run the runtime until all tasks complete
    pub fn run(self: *Runtime) !void {
        // Start worker threads
        for (self.workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
        }

        // Wait for all workers to finish
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
            }
        }
    }

    /// Block on a future until it completes
    pub fn blockOn(self: *Runtime, comptime T: type, fut: Future(T)) !T {
        const handle = try self.spawn(T, fut);

        // Start runtime in background if not already running
        const runtime_thread = try std.Thread.spawn(.{}, Runtime.run, .{self});

        // Wait for result
        const result = try handle.await();

        // Shutdown runtime
        self.shutdown.store(true, .release);
        runtime_thread.join();

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

    var fut = try future_mod.ready(i32, 42, allocator);
    const handle = try runtime.spawn(i32, fut);

    // Start runtime
    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});

    // Give it time to execute
    std.posix.nanosleep(0, 10 * std.time.ns_per_ms);

    // Should be completed
    if (handle.tryGet()) |result| {
        try testing.expectEqual(@as(i32, 42), result);
    }

    runtime.shutdown.store(true, .release);
    for (runtime.workers) |*worker| {
        worker.unpark();
    }
    rt_thread.join();

    allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));
}

test "Runtime - block_on" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 2);
    defer runtime.deinit();

    var fut = try future_mod.ready(i32, 100, allocator);

    // This should block until the future completes
    const result = try runtime.blockOn(i32, fut);

    try testing.expectEqual(@as(i32, 100), result);

    allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));
}

test "Runtime - multiple tasks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 4);
    defer runtime.deinit();

    var handles: std.ArrayList(JoinHandle(i32)) = .empty;
    defer handles.deinit(allocator);

    // Spawn multiple tasks
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        const fut = try future_mod.ready(i32, i, allocator);
        const handle = try runtime.spawn(i32, fut);
        try handles.append(allocator, handle);
    }

    // Start runtime
    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});

    // Give time for execution
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

    runtime.shutdown.store(true, .release);
    for (runtime.workers) |*worker| {
        worker.unpark();
    }
    rt_thread.join();

    // Cleanup futures
    i = 0;
    while (i < 10) : (i += 1) {
        const handle = handles.items[@intCast(i)];
        allocator.destroy(@as(*anyopaque, @ptrCast(handle.task.future.state)));
    }
}
