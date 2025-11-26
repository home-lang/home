const std = @import("std");
const Task = @import("task.zig").Task;
const Future = @import("future.zig").Future;

/// Event loop for async runtime
/// Handles I/O events, timers, and task scheduling
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(*Task),
    ready_queue: std.ArrayList(*Task),
    timers: std.ArrayList(Timer),
    running: bool = false,
    epoll_fd: ?std.os.fd_t = null,

    pub const Timer = struct {
        task: *Task,
        deadline: i64, // Unix timestamp in milliseconds
        interval: ?i64 = null, // For repeating timers
    };

    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        const epoll_fd = if (std.os.linux.epoll_create1(0)) |fd| fd else |_| null;

        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(*Task).init(allocator),
            .ready_queue = std.ArrayList(*Task).init(allocator),
            .timers = std.ArrayList(Timer).init(allocator),
            .epoll_fd = epoll_fd,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.tasks.deinit();
        self.ready_queue.deinit();
        self.timers.deinit();

        if (self.epoll_fd) |fd| {
            std.os.close(fd);
        }
    }

    /// Spawn a new task
    pub fn spawn(self: *EventLoop, task: *Task) !void {
        try self.tasks.append(task);
        try self.ready_queue.append(task);
    }

    /// Add timer
    pub fn addTimer(self: *EventLoop, task: *Task, delay_ms: i64, interval: ?i64) !void {
        const now = std.time.milliTimestamp();
        try self.timers.append(.{
            .task = task,
            .deadline = now + delay_ms,
            .interval = interval,
        });
    }

    /// Main event loop
    pub fn run(self: *EventLoop) !void {
        self.running = true;

        while (self.running) {
            // Process ready tasks
            while (self.ready_queue.items.len > 0) {
                const task = self.ready_queue.orderedRemove(0);
                try self.pollTask(task);
            }

            // Check timers
            try self.processTimers();

            // Poll I/O events
            if (self.epoll_fd) |epoll| {
                try self.pollIO(epoll);
            }

            // If no work, sleep briefly
            if (self.ready_queue.items.len == 0 and self.tasks.items.len == 0) {
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    /// Poll a single task
    fn pollTask(self: *EventLoop, task: *Task) !void {
        const result = task.poll() catch |err| {
            std.debug.print("Task error: {}\n", .{err});
            return;
        };

        switch (result) {
            .Ready => {
                // Task complete, remove from tasks list
                for (self.tasks.items, 0..) |t, i| {
                    if (t == task) {
                        _ = self.tasks.orderedRemove(i);
                        break;
                    }
                }
            },
            .Pending => {
                // Task not ready, will be polled again later
            },
        }
    }

    /// Process expired timers
    fn processTimers(self: *EventLoop) !void {
        const now = std.time.milliTimestamp();
        var i: usize = 0;

        while (i < self.timers.items.len) {
            const timer = &self.timers.items[i];

            if (now >= timer.deadline) {
                // Timer expired, wake task
                try self.ready_queue.append(timer.task);

                if (timer.interval) |interval| {
                    // Repeating timer, reschedule
                    timer.deadline = now + interval;
                    i += 1;
                } else {
                    // One-shot timer, remove
                    _ = self.timers.orderedRemove(i);
                }
            } else {
                i += 1;
            }
        }
    }

    /// Poll I/O events using epoll (Linux) or kqueue (macOS/BSD)
    fn pollIO(self: *EventLoop, epoll: std.os.fd_t) !void {
        _ = self;
        var events: [32]std.os.linux.epoll_event = undefined;

        const timeout_ms = 10; // 10ms timeout
        const n = std.os.linux.epoll_wait(epoll, &events, timeout_ms);

        if (n < 0) return;

        for (events[0..@intCast(n)]) |event| {
            _ = event;
            // Wake associated task based on event data
            // This would be connected to actual I/O operations
        }
    }

    /// Stop the event loop
    pub fn stop(self: *EventLoop) void {
        self.running = false;
    }
};

/// Work-stealing scheduler for multi-threaded async
pub const WorkStealingScheduler = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    global_queue: std.ArrayList(*Task),
    queue_mutex: std.Thread.Mutex = .{},

    pub const Worker = struct {
        id: usize,
        local_queue: std.ArrayList(*Task),
        thread: std.Thread,
        scheduler: *WorkStealingScheduler,
        running: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !WorkStealingScheduler {
        const workers = try allocator.alloc(Worker, num_workers);

        return .{
            .allocator = allocator,
            .workers = workers,
            .global_queue = std.ArrayList(*Task).init(allocator),
        };
    }

    pub fn deinit(self: *WorkStealingScheduler) void {
        for (self.workers) |*worker| {
            worker.local_queue.deinit();
        }
        self.allocator.free(self.workers);
        self.global_queue.deinit();
    }

    /// Start all workers
    pub fn start(self: *WorkStealingScheduler) !void {
        for (self.workers, 0..) |*worker, i| {
            worker.* = .{
                .id = i,
                .local_queue = std.ArrayList(*Task).init(self.allocator),
                .thread = undefined,
                .scheduler = self,
            };

            worker.thread = try std.Thread.spawn(.{}, workerRun, .{worker});
        }
    }

    /// Worker thread function
    fn workerRun(worker: *Worker) void {
        while (worker.running) {
            // Try to get task from local queue
            const task = worker.local_queue.popOrNull() orelse blk: {
                // Try to steal from global queue
                worker.scheduler.queue_mutex.lock();
                defer worker.scheduler.queue_mutex.unlock();

                if (worker.scheduler.global_queue.popOrNull()) |t| {
                    break :blk t;
                }

                // Try to steal from other workers
                break :blk worker.scheduler.steal(worker.id) orelse {
                    // No work available, sleep briefly
                    std.time.sleep(1 * std.time.ns_per_ms);
                    continue;
                };
            };

            // Execute task
            _ = task.poll() catch continue;
        }
    }

    /// Steal task from another worker
    fn steal(self: *WorkStealingScheduler, excluding_id: usize) ?*Task {
        for (self.workers, 0..) |*worker, i| {
            if (i == excluding_id) continue;

            if (worker.local_queue.items.len > 1) {
                // Steal from the front (oldest task)
                return worker.local_queue.orderedRemove(0);
            }
        }

        return null;
    }

    /// Submit task to scheduler
    pub fn submit(self: *WorkStealingScheduler, task: *Task) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        try self.global_queue.append(task);
    }

    /// Stop all workers
    pub fn stop(self: *WorkStealingScheduler) void {
        for (self.workers) |*worker| {
            worker.running = false;
        }

        for (self.workers) |*worker| {
            worker.thread.join();
        }
    }
};

test "EventLoop basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var loop = try EventLoop.init(allocator);
    defer loop.deinit();

    // Test would create tasks and run event loop
}
