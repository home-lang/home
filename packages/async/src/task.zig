const std = @import("std");
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const Context = future_mod.Context;
const Waker = future_mod.Waker;

/// Unique identifier for a task
pub const TaskId = struct {
    id: u64,

    var next_id = std.atomic.Value(u64).init(1);

    pub fn generate() TaskId {
        return .{ .id = next_id.fetchAdd(1, .monotonic) };
    }
};

/// Task state
const job_state = @import("job_state.zig");
pub const TaskState = job_state.State;

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
        state: std.atomic.Value(TaskState),
        future: Future(T),
        result: ?T,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, fut: Future(T)) !*Self {
            const task = try allocator.create(Self);
            task.* = .{
                .id = TaskId.generate(),
                .state = std.atomic.Value(TaskState).init(.Pending),
                .future = fut,
                .result = null,
                .allocator = allocator,
            };
            return task;
        }

        /// Call only after the poll owner/executor has quiesced. Cancellation
        /// marks an outcome; it does not stop a currently executing poll.
        pub fn deinit(self: *Self) void {
            self.future.deinit();
            self.allocator.destroy(self);
        }

        /// Poll the task's future
        ///
        /// Returns true if the task completed, false if still pending
        pub fn poll(self: *Self, ctx: *Context) bool {
            // Only transition Pending → Running. If the task is already
            // Running or Completed, skip the poll entirely.
            const current = self.state.load(.acquire);
            if (current == .Completed or current == .Failed or current == .Cancelled) return true;
            if (current == .Running) return false;

            if (self.state.cmpxchgStrong(
                .Pending,
                .Running,
                .acquire,
                .monotonic,
            ) != null) {
                // Another thread already transitioned the state.
                return false;
            }

            const result = self.future.poll(ctx);

            switch (result) {
                .Ready => |value| {
                    self.result = value;
                    return job_state.finishPoll(&self.state, true);
                },
                .Pending => {
                    return job_state.finishPoll(&self.state, false);
                },
            }
        }

        /// Cancel the task
        pub fn cancel(self: *Self) void {
            _ = job_state.cancel(&self.state);
        }

        /// Check if task is completed
        pub fn isCompleted(self: *Self) bool {
            return self.state.load(.acquire) == .Completed;
        }

        /// Check if task is cancelled
        pub fn isCancelled(self: *Self) bool {
            return self.state.load(.acquire) == .Cancelled;
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

        /// Release the completed task and its type-erased future state.
        pub fn deinit(self: Self) void {
            const state = self.task.state.load(.acquire);
            std.debug.assert(state == .Completed or state == .Failed);
            self.task.deinit();
        }

        /// Wait for the task to complete and get the result
        ///
        /// This will block the current thread until the task finishes.
        /// Only use this from non-async code or the runtime's block_on.
        pub fn await(self: Self) !T {
            while (!self.task.isCompleted()) {
                const state = self.task.state.load(.acquire);
                if (state == .Cancelled) return error.TaskCancelled;
                if (state == .Failed) return error.TaskFailed;

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
            const state = self.task.state.load(.acquire);
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
    const fut = try future_mod.ready(i32, 42, allocator);
    const task = try Task(i32).init(allocator, fut);
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

    const fut = try future_mod.pending(i32, allocator);
    const task = try Task(i32).init(allocator, fut);
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

    const fut = try future_mod.pending(i32, allocator);
    const task = try Task(i32).init(allocator, fut);
    defer task.deinit();

    try testing.expect(!task.isCancelled());

    task.cancel();

    try testing.expect(task.isCancelled());
}

test "JoinHandle - await ready task" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const fut = try future_mod.ready(i32, 100, allocator);
    const task = try Task(i32).init(allocator, fut);
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

    const fut = try future_mod.ready(i32, 77, allocator);
    const task = try Task(i32).init(allocator, fut);
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

fn regressionContext() Context {
    const Noop = struct {
        fn wake(_: *anyopaque) void {}
        fn clone(ptr: *anyopaque) *anyopaque {
            return ptr;
        }
    };
    return Context.init(.{ .data = undefined, .vtable = &.{ .wake = Noop.wake, .wake_by_ref = Noop.wake, .clone = Noop.clone, .drop = Noop.wake } });
}
test "cancel during a future poll survives both Ready and Pending returns" {
    const Poller = struct {
        task: *Task(u32) = undefined,
        ready: bool,
        fn poll(ptr: *anyopaque, _: *Context) future_mod.PollResult(u32) {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.task.cancel();
            return if (self.ready) .{ .Ready = 42 } else .Pending;
        }
    };
    for ([_]bool{ false, true }) |ready| {
        var poller: Poller = .{ .ready = ready };
        const task = try Task(u32).init(std.testing.allocator, .{ .state = &poller, .poll_fn = Poller.poll });
        defer task.deinit();
        poller.task = task;
        var ctx = regressionContext();
        try std.testing.expect(task.poll(&ctx));
        try std.testing.expect(task.isCancelled());
        try std.testing.expect(!task.isCompleted());
        const handle: JoinHandle(u32) = .{ .task = task };
        try std.testing.expectError(error.TaskCancelled, handle.await());
    }
}
test "completed tasks resist late cancellation and failed joins return immediately" {
    const task = try Task(u32).init(std.testing.allocator, try future_mod.ready(u32, 42, std.testing.allocator));
    defer task.deinit();
    var ctx = regressionContext();
    try std.testing.expect(task.poll(&ctx));
    task.cancel();
    const handle: JoinHandle(u32) = .{ .task = task };
    try std.testing.expectEqual(@as(u32, 42), try handle.await());
    task.state.store(.Failed, .release);
    try std.testing.expectError(error.TaskFailed, handle.await());
}
