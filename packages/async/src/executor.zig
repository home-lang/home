const std = @import("std");
const async_runtime = @import("async_runtime.zig");

/// Multi-threaded async executor with work-stealing
pub const Executor = struct {
    allocator: std.mem.Allocator,
    worker_threads: []std.Thread,
    task_queues: []TaskQueue,
    global_queue: TaskQueue,
    num_workers: usize,
    running: std.atomic.Value(bool),
    parker: Parker,

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !Executor {
        const actual_workers = if (num_workers == 0)
            try std.Thread.getCpuCount()
        else
            num_workers;

        const worker_threads = try allocator.alloc(std.Thread, actual_workers);
        const task_queues = try allocator.alloc(TaskQueue, actual_workers);

        for (task_queues) |*queue| {
            queue.* = TaskQueue.init(allocator);
        }

        return .{
            .allocator = allocator,
            .worker_threads = worker_threads,
            .task_queues = task_queues,
            .global_queue = TaskQueue.init(allocator),
            .num_workers = actual_workers,
            .running = std.atomic.Value(bool).init(false),
            .parker = Parker.init(),
        };
    }

    pub fn deinit(self: *Executor) void {
        self.running.store(false, .release);

        // Wait for all workers to finish
        for (self.worker_threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.worker_threads);

        for (self.task_queues) |*queue| {
            queue.deinit();
        }
        self.allocator.free(self.task_queues);

        self.global_queue.deinit();
        self.parker.deinit();
    }

    /// Spawn a new async task
    pub fn spawn(self: *Executor, comptime F: type, func: F, args: anytype) !void {
        const task = try self.allocator.create(async_runtime.Task);
        task.* = async_runtime.Task{
            .id = @atomicRmw(u64, &task_id_counter, .Add, 1, .monotonic),
            .state = .Pending,
            .poll_fn = wrapFunction(F, func, args),
            .data = null,
        };

        // Add to global queue
        try self.global_queue.push(task);
        self.parker.unpark();
    }

    /// Start the executor
    pub fn run(self: *Executor) !void {
        self.running.store(true, .release);

        // Spawn worker threads
        for (self.worker_threads, 0..) |*thread, i| {
            const worker_id = i;
            thread.* = try std.Thread.spawn(.{}, workerLoop, .{ self, worker_id });
        }

        // Main thread also participates in work
        try self.workerLoop(0);
    }

    /// Worker thread loop
    fn workerLoop(self: *Executor, worker_id: usize) !void {
        const local_queue = &self.task_queues[worker_id];

        while (self.running.load(.acquire)) {
            // Try to get task from local queue
            if (local_queue.pop()) |task| {
                try self.executeTask(task);
                continue;
            }

            // Try to steal from global queue
            if (self.global_queue.pop()) |task| {
                try self.executeTask(task);
                continue;
            }

            // Try to steal from other workers
            var stolen = false;
            for (self.task_queues, 0..) |*other_queue, i| {
                if (i == worker_id) continue;

                if (other_queue.steal()) |task| {
                    try self.executeTask(task);
                    stolen = true;
                    break;
                }
            }

            if (stolen) continue;

            // No work available, park the thread
            self.parker.park();
        }
    }

    /// Execute a single task
    fn executeTask(self: *Executor, task: *async_runtime.Task) !void {
        _ = self;

        if (task.state == .Completed or task.state == .Failed) {
            return;
        }

        task.poll() catch |err| {
            task.state = .Failed;
            std.debug.print("Task {} failed: {}\n", .{ task.id, err });
        };
    }

    fn wrapFunction(comptime F: type, func: F, args: anytype) *const fn (*async_runtime.Task) anyerror!void {
        _ = func;
        _ = args;
        // This would need to be implemented with comptime magic to wrap arbitrary functions
        // For now, return a placeholder
        return struct {
            fn poll(task: *async_runtime.Task) anyerror!void {
                _ = task;
                // Function execution happens here
            }
        }.poll;
    }
};

var task_id_counter: u64 = 0;

/// Lock-free task queue using Chase-Lev deque
pub const TaskQueue = struct {
    allocator: std.mem.Allocator,
    buffer: []?*async_runtime.Task,
    capacity: usize,
    top: std.atomic.Value(usize),
    bottom: std.atomic.Value(usize),
    mutex: std.Thread.Mutex,

    const INITIAL_CAPACITY = 256;

    pub fn init(allocator: std.mem.Allocator) TaskQueue {
        const buffer = allocator.alloc(?*async_runtime.Task, INITIAL_CAPACITY) catch unreachable;
        @memset(buffer, null);

        return .{
            .allocator = allocator,
            .buffer = buffer,
            .capacity = INITIAL_CAPACITY,
            .top = std.atomic.Value(usize).init(0),
            .bottom = std.atomic.Value(usize).init(0),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *TaskQueue) void {
        self.allocator.free(self.buffer);
    }

    /// Push task to bottom (owner thread only)
    pub fn push(self: *TaskQueue, task: *async_runtime.Task) !void {
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.acquire);

        if (b - t >= self.capacity) {
            try self.grow();
        }

        const idx = b % self.capacity;
        self.buffer[idx] = task;
        self.bottom.store(b + 1, .release);
    }

    /// Pop task from bottom (owner thread only)
    pub fn pop(self: *TaskQueue) ?*async_runtime.Task {
        var b = self.bottom.load(.monotonic);
        if (b == 0) return null;

        b -= 1;
        self.bottom.store(b, .monotonic);
        @atomicFence(.seq_cst);

        const t = self.top.load(.monotonic);
        const idx = b % self.capacity;
        const task = self.buffer[idx];

        if (t > b) {
            // Queue is empty
            self.bottom.store(t, .monotonic);
            return null;
        }

        if (t == b) {
            // Last element, race with steal
            if (!self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic)) |_| {
                // Lost race
                self.bottom.store(t + 1, .monotonic);
                return null;
            }
        }

        return task;
    }

    /// Steal task from top (thief threads)
    pub fn steal(self: *TaskQueue) ?*async_runtime.Task {
        while (true) {
            const t = self.top.load(.acquire);
            @atomicFence(.seq_cst);
            const b = self.bottom.load(.acquire);

            if (t >= b) {
                return null; // Empty
            }

            const idx = t % self.capacity;
            const task = self.buffer[idx];

            if (self.top.cmpxchgWeak(t, t + 1, .seq_cst, .monotonic)) |_| {
                // CAS failed, retry
                continue;
            }

            return task;
        }
    }

    fn grow(self: *TaskQueue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const new_capacity = self.capacity * 2;
        const new_buffer = try self.allocator.alloc(?*async_runtime.Task, new_capacity);
        @memset(new_buffer, null);

        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.monotonic);

        for (t..b) |i| {
            const old_idx = i % self.capacity;
            const new_idx = i % new_capacity;
            new_buffer[new_idx] = self.buffer[old_idx];
        }

        self.allocator.free(self.buffer);
        self.buffer = new_buffer;
        self.capacity = new_capacity;
    }
};

/// Parker for thread parking/unparking
pub const Parker = struct {
    mutex: std.Thread.Mutex,
    condvar: std.Thread.Condition,
    parked_count: std.atomic.Value(usize),

    pub fn init() Parker {
        return .{
            .mutex = std.Thread.Mutex{},
            .condvar = std.Thread.Condition{},
            .parked_count = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *Parker) void {
        _ = self;
    }

    pub fn park(self: *Parker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.parked_count.fetchAdd(1, .monotonic);
        self.condvar.wait(&self.mutex);
        _ = self.parked_count.fetchSub(1, .monotonic);
    }

    pub fn unpark(self: *Parker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.parked_count.load(.monotonic) > 0) {
            self.condvar.signal();
        }
    }

    pub fn unpark_all(self: *Parker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.parked_count.load(.monotonic) > 0) {
            self.condvar.broadcast();
        }
    }
};

/// Async channel for communication between tasks
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: std.ArrayList(T),
        senders: usize,
        receivers: usize,
        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        not_full: std.Thread.Condition,
        capacity: usize,
        closed: bool,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
            return .{
                .allocator = allocator,
                .buffer = std.ArrayList(T).init(allocator),
                .senders = 0,
                .receivers = 0,
                .mutex = std.Thread.Mutex{},
                .not_empty = std.Thread.Condition{},
                .not_full = std.Thread.Condition{},
                .capacity = capacity,
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
        }

        pub fn send(self: *Self, value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.buffer.items.len >= self.capacity and !self.closed) {
                self.not_full.wait(&self.mutex);
            }

            if (self.closed) {
                return error.ChannelClosed;
            }

            try self.buffer.append(value);
            self.not_empty.signal();
        }

        pub fn recv(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.buffer.items.len == 0 and !self.closed) {
                self.not_empty.wait(&self.mutex);
            }

            if (self.buffer.items.len == 0 and self.closed) {
                return error.ChannelClosed;
            }

            const value = self.buffer.orderedRemove(0);
            self.not_full.signal();
            return value;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }
    };
}
