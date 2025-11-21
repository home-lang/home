const std = @import("std");

/// State of an asynchronous task during its lifecycle.
///
/// Tasks transition through these states:
/// Pending -> Running -> Completed/Failed
pub const TaskState = enum {
    /// Task created but not yet executed
    Pending,
    /// Task is currently executing
    Running,
    /// Task finished successfully
    Completed,
    /// Task failed with an error
    Failed,
};

/// Generic Future type for async computations.
///
/// A Future represents a value that will be available in the future,
/// similar to JavaScript Promises or Rust Futures. Futures are:
/// - Lazy: Don't start until polled
/// - Composable: Can be chained and combined
/// - Type-safe: Generic over result type T
///
/// Futures use a polling model where the executor repeatedly calls
/// poll() until the Future completes. When a Future isn't ready,
/// it registers a Waker to be notified when it can make progress.
///
/// Example:
/// ```zig
/// var future = Future(i32).init();
/// // ... later, when value is ready ...
/// future.complete(42);
/// const result = try future.poll(); // returns 42
/// ```
///
/// Parameters:
///   - T: The type of value this Future will eventually produce
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Current state of this Future
        state: TaskState,
        /// Result value (set when state is Completed)
        result: ?T,
        /// Error value (set when state is Failed)
        error_value: ?anyerror,
        /// Waker to notify when Future becomes ready
        waker: ?*Waker,

        /// Create a new Future in Pending state.
        ///
        /// Returns: Initialized Future
        pub fn init() Self {
            return .{
                .state = .Pending,
                .result = null,
                .error_value = null,
                .waker = null,
            };
        }

        /// Poll the Future to check if it's ready.
        ///
        /// This is the core operation of the Future trait. The executor
        /// calls poll() repeatedly until the Future completes.
        ///
        /// Returns:
        /// - Some(T) if the Future completed successfully
        /// - Error if the Future failed
        /// - null if the Future is still pending
        pub fn poll(self: *Self) !?T {
            return switch (self.state) {
                .Completed => self.result,
                .Failed => if (self.error_value) |err| err else error.UnknownError,
                else => null,
            };
        }

        /// Mark the Future as completed with a successful value.
        ///
        /// Transitions state to Completed, stores the result, and
        /// wakes any waiting executor.
        ///
        /// Parameters:
        ///   - value: The successful result value
        pub fn complete(self: *Self, value: T) void {
            self.result = value;
            self.state = .Completed;
            if (self.waker) |waker| {
                waker.wake();
            }
        }

        /// Mark the Future as failed with an error.
        ///
        /// Transitions state to Failed, stores the error, and
        /// wakes any waiting executor.
        ///
        /// Parameters:
        ///   - err: The error that caused the failure
        pub fn fail(self: *Self, err: anyerror) void {
            self.error_value = err;
            self.state = .Failed;
            if (self.waker) |waker| {
                waker.wake();
            }
        }
    };
}

/// Waker for notifying executors when a Future can make progress.
///
/// When a Future is polled but not ready, it registers a Waker
/// that will be called when the Future becomes ready (e.g., when
/// I/O completes, a timer fires, or data arrives).
///
/// This implements the wake-up mechanism for async/await, allowing
/// efficient scheduling without busy-waiting.
pub const Waker = struct {
    /// Function to call when waking
    wake_fn: *const fn (*Waker) void,
    /// Optional context data for the waker
    data: ?*anyopaque,

    /// Wake the associated Future.
    ///
    /// Calls the wake function, which typically notifies the executor
    /// to re-poll this Future.
    pub fn wake(self: *Waker) void {
        self.wake_fn(self);
    }
};

/// Asynchronous task managed by the runtime.
///
/// A Task is a unit of async work that can be scheduled and executed
/// by the async runtime. Each task has:
/// - A unique ID for tracking
/// - State tracking (Pending/Running/Completed/Failed)
/// - A poll function that drives execution
/// - Optional data for task-specific state
///
/// Tasks are the bridge between user async functions and the runtime
/// executor.
pub const Task = struct {
    /// Unique task identifier
    id: u64,
    /// Current task state
    state: TaskState,
    /// Function to poll this task
    poll_fn: *const fn (*Task) anyerror!void,
    /// Optional task-specific data
    data: ?*anyopaque,

    /// Poll the task to make progress.
    ///
    /// Calls the task's poll function to execute one step. The poll
    /// function should return quickly, yielding if it would block.
    ///
    /// Errors: Returns any error from the poll function
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
            std.posix.nanosleep(0, 1_000_000); // 1ms
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

            std.posix.nanosleep(0, 1_000_000); // 1ms
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
    std.posix.nanosleep(0, duration_ns);
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
            std.posix.nanosleep(0, 100_000); // 0.1ms
        }
    }

    return results.toOwnedSlice();
}
