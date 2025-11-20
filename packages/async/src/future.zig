const std = @import("std");

/// Result of polling a Future
pub fn PollResult(comptime T: type) type {
    return union(enum) {
        /// Future completed with a value
        Ready: T,
        /// Future is not yet ready
        Pending: void,

        pub fn isReady(self: @This()) bool {
            return switch (self) {
                .Ready => true,
                .Pending => false,
            };
        }

        pub fn isPending(self: @This()) bool {
            return !self.isReady();
        }
    };
}

/// Context passed to Future.poll()
///
/// Contains the waker that should be called when the Future can make progress.
pub const Context = struct {
    waker: Waker,

    pub fn init(waker: Waker) Context {
        return .{ .waker = waker };
    }

    pub fn waker(self: *const Context) *const Waker {
        return &self.waker;
    }
};

/// Waker for notifying when a Future can make progress
///
/// This is the core mechanism for async/await. When a Future returns Pending,
/// it stores the Waker and calls it when it's ready to be polled again.
pub const Waker = struct {
    data: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Wake the task associated with this waker
        wake: *const fn (*anyopaque) void,
        /// Wake by reference (doesn't consume waker)
        wake_by_ref: *const fn (*anyopaque) void,
        /// Clone the waker
        clone: *const fn (*anyopaque) *anyopaque,
        /// Drop the waker (cleanup)
        drop: *const fn (*anyopaque) void,
    };

    pub fn wake(self: Waker) void {
        self.vtable.wake(self.data);
    }

    pub fn wakeByRef(self: *const Waker) void {
        self.vtable.wake_by_ref(self.data);
    }

    pub fn clone(self: *const Waker) Waker {
        const new_data = self.vtable.clone(self.data);
        return Waker{
            .data = new_data,
            .vtable = self.vtable,
        };
    }

    pub fn drop(self: *const Waker) void {
        self.vtable.drop(self.data);
    }
};

/// Future trait - represents an asynchronous computation
///
/// Futures are lazy - they don't do anything until polled.
/// The poll method is called repeatedly by the executor until
/// the Future completes.
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Function pointer for polling this future
        poll_fn: *const fn (*anyopaque, *Context) PollResult(T),
        /// Type-erased state
        state: *anyopaque,

        pub fn poll(self: *Self, ctx: *Context) PollResult(T) {
            return self.poll_fn(self.state, ctx);
        }

        /// Map the output of this Future
        pub fn map(self: *Self, allocator: std.mem.Allocator, comptime U: type, f: *const fn (T) U) !Future(U) {
            const State = struct {
                inner: Future(T),
                f: *const fn (T) U,
            };

            const state = try allocator.create(State);
            state.* = .{
                .inner = self.*,
                .f = f,
            };

            const poll_fn = struct {
                fn poll(ptr: *anyopaque, ctx: *Context) PollResult(U) {
                    const s = @as(*State, @ptrCast(@alignCast(ptr)));
                    const result = s.inner.poll(ctx);
                    return switch (result) {
                        .Ready => |val| .{ .Ready = s.f(val) },
                        .Pending => .Pending,
                    };
                }
            }.poll;

            return Future(U){
                .poll_fn = poll_fn,
                .state = @ptrCast(state),
            };
        }

        /// Chain this Future with another
        pub fn andThen(
            self: *Self,
            allocator: std.mem.Allocator,
            comptime U: type,
            f: *const fn (T) Future(U),
        ) !Future(U) {
            const State = struct {
                inner: Future(T),
                f: *const fn (T) Future(U),
                next: ?Future(U),
                inner_done: bool,
            };

            const state = try allocator.create(State);
            state.* = .{
                .inner = self.*,
                .f = f,
                .next = null,
                .inner_done = false,
            };

            const poll_fn = struct {
                fn poll(ptr: *anyopaque, ctx: *Context) PollResult(U) {
                    const s = @as(*State, @ptrCast(@alignCast(ptr)));

                    if (!s.inner_done) {
                        const result = s.inner.poll(ctx);
                        switch (result) {
                            .Ready => |val| {
                                s.next = s.f(val);
                                s.inner_done = true;
                            },
                            .Pending => return .Pending,
                        }
                    }

                    if (s.next) |*next| {
                        return next.poll(ctx);
                    }

                    unreachable;
                }
            }.poll;

            return Future(U){
                .poll_fn = poll_fn,
                .state = @ptrCast(state),
            };
        }
    };
}

/// A Future that is immediately ready
pub fn ready(comptime T: type, value: T, allocator: std.mem.Allocator) !Future(T) {
    const State = struct {
        value: T,
        consumed: bool,
    };

    const state = try allocator.create(State);
    state.* = .{ .value = value, .consumed = false };

    const poll_fn = struct {
        fn poll(ptr: *anyopaque, _: *Context) PollResult(T) {
            const s = @as(*State, @ptrCast(@alignCast(ptr)));
            if (s.consumed) {
                // Future polled after completion - shouldn't happen
                // but we handle it gracefully
                unreachable;
            }
            s.consumed = true;
            return .{ .Ready = s.value };
        }
    }.poll;

    return Future(T){
        .poll_fn = poll_fn,
        .state = @ptrCast(state),
    };
}

/// A Future that is always pending (never completes)
pub fn pending(comptime T: type, allocator: std.mem.Allocator) !Future(T) {
    const State = struct {};

    const state = try allocator.create(State);

    const poll_fn = struct {
        fn poll(_: *anyopaque, _: *Context) PollResult(T) {
            return .Pending;
        }
    }.poll;

    return Future(T){
        .poll_fn = poll_fn,
        .state = @ptrCast(state),
    };
}

/// Join two futures, returning both results when both complete
pub fn join(
    comptime T: type,
    comptime U: type,
    allocator: std.mem.Allocator,
    fut1: Future(T),
    fut2: Future(U),
) !Future(struct { T, U }) {
    const Result = struct { T, U };
    const State = struct {
        fut1: Future(T),
        fut2: Future(U),
        result1: ?T,
        result2: ?U,
    };

    const state = try allocator.create(State);
    state.* = .{
        .fut1 = fut1,
        .fut2 = fut2,
        .result1 = null,
        .result2 = null,
    };

    const poll_fn = struct {
        fn poll(ptr: *anyopaque, ctx: *Context) PollResult(Result) {
            const s = @as(*State, @ptrCast(@alignCast(ptr)));

            // Poll first future if not done
            if (s.result1 == null) {
                const r1 = s.fut1.poll(ctx);
                switch (r1) {
                    .Ready => |val| s.result1 = val,
                    .Pending => {},
                }
            }

            // Poll second future if not done
            if (s.result2 == null) {
                const r2 = s.fut2.poll(ctx);
                switch (r2) {
                    .Ready => |val| s.result2 = val,
                    .Pending => {},
                }
            }

            // Both done?
            if (s.result1 != null and s.result2 != null) {
                return .{ .Ready = .{ s.result1.?, s.result2.? } };
            }

            return .Pending;
        }
    }.poll;

    return Future(Result){
        .poll_fn = poll_fn,
        .state = @ptrCast(state),
    };
}

/// Select the first of two futures to complete
pub fn select(
    comptime T: type,
    comptime U: type,
    allocator: std.mem.Allocator,
    fut1: Future(T),
    fut2: Future(U),
) !Future(union(enum) { First: T, Second: U }) {
    const Result = union(enum) { First: T, Second: U };
    const State = struct {
        fut1: Future(T),
        fut2: Future(U),
    };

    const state = try allocator.create(State);
    state.* = .{
        .fut1 = fut1,
        .fut2 = fut2,
    };

    const poll_fn = struct {
        fn poll(ptr: *anyopaque, ctx: *Context) PollResult(Result) {
            const s = @as(*State, @ptrCast(@alignCast(ptr)));

            // Try first future
            const r1 = s.fut1.poll(ctx);
            if (r1.isReady()) {
                return .{ .Ready = .{ .First = r1.Ready } };
            }

            // Try second future
            const r2 = s.fut2.poll(ctx);
            if (r2.isReady()) {
                return .{ .Ready = .{ .Second = r2.Ready } };
            }

            return .Pending;
        }
    }.poll;

    return Future(Result){
        .poll_fn = poll_fn,
        .state = @ptrCast(state),
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "Future - ready" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var fut = try ready(i32, 42, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));

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
    const result = fut.poll(&ctx);

    try testing.expect(result.isReady());
    try testing.expectEqual(@as(i32, 42), result.Ready);
}

test "Future - pending" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var fut = try pending(i32, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));

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
    const result = fut.poll(&ctx);

    try testing.expect(result.isPending());
}

test "Future - join" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var fut1 = try ready(i32, 10, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut1.state)));

    var fut2 = try ready(i32, 20, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut2.state)));

    var joined = try join(i32, i32, allocator, fut1, fut2);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(joined.state)));

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
    const result = joined.poll(&ctx);

    try testing.expect(result.isReady());
    try testing.expectEqual(@as(i32, 10), result.Ready[0]);
    try testing.expectEqual(@as(i32, 20), result.Ready[1]);
}

test "Future - select first" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var fut1 = try ready(i32, 42, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut1.state)));

    var fut2 = try pending(i32, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut2.state)));

    var selected = try select(i32, i32, allocator, fut1, fut2);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(selected.state)));

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
    const result = selected.poll(&ctx);

    try testing.expect(result.isReady());
    try testing.expectEqual(@as(i32, 42), result.Ready.First);
}
