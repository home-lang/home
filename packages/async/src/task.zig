const std = @import("std");
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const PollResult = future_mod.PollResult;
const Context = future_mod.Context;
const Waker = future_mod.Waker;

/// Unique identifier for a task
pub const TaskId = struct {
    id: u64,

    var next_id = std.atomic.Atomic(u64).init(1);

    pub fn generate() TaskId {
        return .{ .id = next_id.fetchAdd(1, .Monotonic) };
    }
};

/// Task state
pub const TaskState = enum {
    /// Task is ready to run
    Pending,
    /// Task is currently running
    Running,
    /// Task completed successfully
    Completed,
    /// Task failed with an error
    Failed,
    /// Task was cancelled
    Cancelled,
};

/// A spawned task that can be awaited
///
/// This represents a top-level async task managed by the runtime.
/// It wraps a Future and provides:
/// - Unique ID for tracking
/// - Waker for notifications
/// - Join handle for awaiting completion
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        id: TaskId,
        state: std.atomic.Atomic(TaskState),
        future: Future(T),
        result: ?T,
        waker: ?*Waker,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, fut: Future(T)) !*Self {
            const task = try allocator.create(Self);
            task.* = .{
                .id = TaskId.generate(),
                .state = std.atomic.Atomic(TaskState).init(.Pending),
                .future = fut,
                .result = null,
                .waker = null,
                .allocator = allocator,
            };
            return task;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        /// Poll the task's future
        ///
        /// Returns true if the task completed, false if still pending
        pub fn poll(self: *Self, ctx: *Context) bool {
            // Set state to running
            _ = self.state.cmpxchgStrong(
                .Pending,
                .Running,
                .Acquire,
                .Monotonic,
            );

            const result = self.future.poll(ctx);

            switch (result) {
                .Ready => |value| {
                    self.result = value;
                    self.state.store(.Completed, .Release);
                    return true;
                },
                .Pending => {
                    self.state.store(.Pending, .Release);
                    return false;
                },
            }
        }

        /// Cancel the task
        pub fn cancel(self: *Self) void {
            self.state.store(.Cancelled, .Release);
        }

        /// Check if task is completed
        pub fn isCompleted(self: *Self) bool {
            return self.state.load(.Acquire) == .Completed;
        }

        /// Check if task is cancelled
        pub fn isCancelled(self: *Self) bool {
            return self.state.load(.Acquire) == .Cancelled;
        }
    };
}

/// Join handle for awaiting task completion
///
/// Returned when spawning a task, can be used to await the result.
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();

        task: *Task(T),

        /// Wait for the task to complete and get the result
        ///
        /// This will block the current thread until the task finishes.
        /// Only use this from non-async code or the runtime's block_on.
        pub fn await(self: Self) !T {
            while (!self.task.isCompleted()) {
                if (self.task.isCancelled()) {
                    return error.TaskCancelled;
                }

                // Spin or yield
                std.Thread.yield() catch {};
            }

            return self.task.result orelse error.TaskFailed;
        }

        /// Try to get the result without blocking
        pub fn tryGet(self: Self) ?T {
            if (self.task.isCompleted()) {
                return self.task.result;
            }
            return null;
        }

        /// Cancel the task
        pub fn cancel(self: Self) void {
            self.task.cancel();
        }

        /// Check if the task is done (completed or cancelled)
        pub fn isDone(self: Self) bool {
            const state = self.task.state.load(.Acquire);
            return state == .Completed or state == .Cancelled or state == .Failed;
        }
    };
}

/// RawTask - Type-erased task for storage in queues
///
/// This allows storing tasks of different types in the same queue.
pub const RawTask = struct {
    poll_fn: *const fn (*RawTask, *Context) bool,
    data: *anyopaque,
    id: TaskId,

    pub fn fromTask(comptime T: type, task: *Task(T)) RawTask {
        const poll_fn = struct {
            fn poll(raw: *RawTask, ctx: *Context) bool {
                const t = @as(*Task(T), @ptrCast(@alignCast(raw.data)));
                return t.poll(ctx);
            }
        }.poll;

        return .{
            .poll_fn = poll_fn,
            .data = @ptrCast(task),
            .id = task.id,
        };
    }

    pub fn poll(self: *RawTask, ctx: *Context) bool {
        return self.poll_fn(self, ctx);
    }
};

// =================================================================================
//                                    TESTS
// =================================================================================

test "TaskId - unique generation" {
    const testing = std.testing;

    const id1 = TaskId.generate();
    const id2 = TaskId.generate();
    const id3 = TaskId.generate();

    try testing.expect(id1.id != id2.id);
    try testing.expect(id2.id != id3.id);
    try testing.expect(id1.id < id2.id);
    try testing.expect(id2.id < id3.id);
}

test "Task - basic lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a ready future
    var fut = try future_mod.ready(i32, 42, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));

    var task = try Task(i32).init(allocator, fut);
    defer task.deinit();

    try testing.expect(!task.isCompleted());

    // Create a dummy waker
    const waker = Waker{
        .data = undefined,
        .vtable = &.{
            .wake = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .wake_by_ref = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .clone = struct {
                fn clone(ptr: *anyopaque) *anyopaque {
                    return ptr;
                }
            }.clone,
            .drop = struct {
                fn drop(_: *anyopaque) void {}
            }.drop,
        },
    };

    var ctx = Context.init(waker);

    // Poll the task
    const completed = task.poll(&ctx);
    try testing.expect(completed);
    try testing.expect(task.isCompleted());
    try testing.expectEqual(@as(i32, 42), task.result.?);
}

test "Task - pending future" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var fut = try future_mod.pending(i32, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));

    var task = try Task(i32).init(allocator, fut);
    defer task.deinit();

    const waker = Waker{
        .data = undefined,
        .vtable = &.{
            .wake = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .wake_by_ref = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .clone = struct {
                fn clone(ptr: *anyopaque) *anyopaque {
                    return ptr;
                }
            }.clone,
            .drop = struct {
                fn drop(_: *anyopaque) void {}
            }.drop,
        },
    };

    var ctx = Context.init(waker);

    // Poll - should remain pending
    const completed = task.poll(&ctx);
    try testing.expect(!completed);
    try testing.expect(!task.isCompleted());
}

test "Task - cancellation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var fut = try future_mod.pending(i32, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));

    var task = try Task(i32).init(allocator, fut);
    defer task.deinit();

    try testing.expect(!task.isCancelled());

    task.cancel();

    try testing.expect(task.isCancelled());
}

test "JoinHandle - await ready task" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var fut = try future_mod.ready(i32, 100, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));

    var task = try Task(i32).init(allocator, fut);
    defer task.deinit();

    // Poll to complete
    const waker = Waker{
        .data = undefined,
        .vtable = &.{
            .wake = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .wake_by_ref = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .clone = struct {
                fn clone(ptr: *anyopaque) *anyopaque {
                    return ptr;
                }
            }.clone,
            .drop = struct {
                fn drop(_: *anyopaque) void {}
            }.drop,
        },
    };

    var ctx = Context.init(waker);
    _ = task.poll(&ctx);

    const handle = JoinHandle(i32){ .task = task };
    const result = try handle.await();

    try testing.expectEqual(@as(i32, 100), result);
}

test "RawTask - type erasure" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var fut = try future_mod.ready(i32, 77, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));

    var task = try Task(i32).init(allocator, fut);
    defer task.deinit();

    var raw = RawTask.fromTask(i32, task);

    const waker = Waker{
        .data = undefined,
        .vtable = &.{
            .wake = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .wake_by_ref = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .clone = struct {
                fn clone(ptr: *anyopaque) *anyopaque {
                    return ptr;
                }
            }.clone,
            .drop = struct {
                fn drop(_: *anyopaque) void {}
            }.drop,
        },
    };

    var ctx = Context.init(waker);

    // Poll through type-erased interface
    const completed = raw.poll(&ctx);
    try testing.expect(completed);
    try testing.expectEqual(@as(i32, 77), task.result.?);
}
