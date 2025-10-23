const std = @import("std");

/// Async task state
pub const TaskState = enum {
    Pending,
    Running,
    Completed,
    Failed,
};

/// Future represents an async computation
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        state: TaskState,
        result: ?T,
        error_value: ?anyerror,
        waker: ?*Waker,

        pub fn init() Self {
            return .{
                .state = .Pending,
                .result = null,
                .error_value = null,
                .waker = null,
            };
        }

        pub fn poll(self: *Self) !?T {
            return switch (self.state) {
                .Completed => self.result,
                .Failed => if (self.error_value) |err| err else error.UnknownError,
                else => null,
            };
        }

        pub fn complete(self: *Self, value: T) void {
            self.result = value;
            self.state = .Completed;
            if (self.waker) |waker| {
                waker.wake();
            }
        }

        pub fn fail(self: *Self, err: anyerror) void {
            self.error_value = err;
            self.state = .Failed;
            if (self.waker) |waker| {
                waker.wake();
            }
        }
    };
}

/// Waker to notify when a future is ready
pub const Waker = struct {
    wake_fn: *const fn (*Waker) void,
    data: ?*anyopaque,

    pub fn wake(self: *Waker) void {
        self.wake_fn(self);
    }
};

/// Async task
pub const Task = struct {
    id: u64,
    state: TaskState,
    poll_fn: *const fn (*Task) anyerror!void,
    data: ?*anyopaque,

    pub fn poll(self: *Task) !void {
        if (self.state == .Completed or self.state == .Failed) return;
        self.state = .Running;
        try self.poll_fn(self);
    }
};

/// Simple async runtime
pub const AsyncRuntime = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(*Task),
    next_task_id: u64,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) AsyncRuntime {
        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(*Task).init(allocator),
            .next_task_id = 0,
            .running = false,
        };
    }

    pub fn deinit(self: *AsyncRuntime) void {
        for (self.tasks.items) |task| {
            self.allocator.destroy(task);
        }
        self.tasks.deinit();
    }

    /// Spawn a new async task
    pub fn spawn(
        self: *AsyncRuntime,
        poll_fn: *const fn (*Task) anyerror!void,
        data: ?*anyopaque,
    ) !*Task {
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);
        task.* = .{
            .id = self.next_task_id,
            .state = .Pending,
            .poll_fn = poll_fn,
            .data = data,
        };
        self.next_task_id += 1;

        try self.tasks.append(self.allocator, task);
        return task;
    }

    /// Run the async runtime until all tasks complete
    pub fn run(self: *AsyncRuntime) !void {
        self.running = true;
        defer self.running = false;

        while (self.hasPendingTasks()) {
            var i: usize = 0;
            while (i < self.tasks.items.len) {
                const task = self.tasks.items[i];
                if (task.state == .Pending or task.state == .Running) {
                    task.poll() catch |err| {
                        task.state = .Failed;
                        std.debug.print("Task {d} failed: {}\n", .{ task.id, err });
                    };
                }
                i += 1;
            }

            // Small yield to prevent busy loop
            std.time.sleep(1_000_000); // 1ms
        }
    }

    /// Block on a future until it completes
    pub fn block_on(self: *AsyncRuntime, comptime T: type, future: *Future(T)) !T {
        while (true) {
            if (try future.poll()) |value| {
                return value;
            }

            // Poll all tasks
            var i: usize = 0;
            while (i < self.tasks.items.len) {
                const task = self.tasks.items[i];
                if (task.state == .Pending or task.state == .Running) {
                    task.poll() catch |err| {
                        task.state = .Failed;
                        return err;
                    };
                }
                i += 1;
            }

            std.time.sleep(1_000_000); // 1ms
        }
    }

    fn hasPendingTasks(self: *AsyncRuntime) bool {
        for (self.tasks.items) |task| {
            if (task.state == .Pending or task.state == .Running) {
                return true;
            }
        }
        return false;
    }
};

/// Async sleep function
pub fn sleep(duration_ns: u64) Future(void) {
    var future = Future(void).init();

    // In a real implementation, this would register with the runtime
    // For now, just complete after sleeping
    std.time.sleep(duration_ns);
    future.complete({});

    return future;
}

/// Join multiple futures
pub fn join(allocator: std.mem.Allocator, comptime T: type, futures: []Future(T)) ![]T {
    var results = std.ArrayList(T).init(allocator);
    defer results.deinit();

    for (futures) |*future| {
        while (true) {
            if (try future.poll()) |value| {
                try results.append(value);
                break;
            }
            std.time.sleep(100_000); // 0.1ms
        }
    }

    return results.toOwnedSlice();
}
