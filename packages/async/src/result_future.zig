const std = @import("std");
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const PollResult = future_mod.PollResult;
const Context = future_mod.Context;

/// Result type for async functions with error handling
///
/// This integrates Rust-style Result types with Home's async system,
/// enabling seamless error propagation with the ? operator.
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,

        const Self = @This();

        pub fn ok_value(value: T) Self {
            return .{ .ok = value };
        }

        pub fn err_value(err_val: E) Self {
            return .{ .err = err_val };
        }

        pub fn isOk(self: Self) bool {
            return switch (self) {
                .ok => true,
                .err => false,
            };
        }

        pub fn isErr(self: Self) bool {
            return !self.isOk();
        }

        /// Unwrap the Ok value or panic
        /// For error propagation, use the ? operator
        pub fn unwrap(self: Self) !T {
            return switch (self) {
                .ok => |v| v,
                .err => error.ResultUnwrapError,
            };
        }

        /// Get error value (panics if Ok)
        pub fn unwrapErr(self: Self) E {
            return switch (self) {
                .ok => unreachable,
                .err => |e| e,
            };
        }

        /// Map the Ok value to a different type
        pub fn map(self: Self, comptime U: type, f: *const fn (T) U) Result(U, E) {
            return switch (self) {
                .ok => |v| Result(U, E).ok_value(f(v)),
                .err => |e| Result(U, E).err_value(e),
            };
        }

        /// Map the Err value to a different error type
        pub fn mapErr(self: Self, comptime F: type, f: *const fn (E) F) Result(T, F) {
            return switch (self) {
                .ok => |v| Result(T, F).ok_value(v),
                .err => |e| Result(T, F).err_value(f(e)),
            };
        }

        /// Chain Result-returning operations (flatMap)
        pub fn andThen(self: Self, comptime U: type, f: *const fn (T) Result(U, E)) Result(U, E) {
            return switch (self) {
                .ok => |v| f(v),
                .err => |e| Result(U, E).err_value(e),
            };
        }

        /// Provide default value on error
        pub fn unwrapOr(self: Self, default: T) T {
            return switch (self) {
                .ok => |v| v,
                .err => default,
            };
        }

        /// Convert Result to Future
        pub fn toFuture(self: Self, allocator: std.mem.Allocator) !Future(Self) {
            return future_mod.ready(Self, self, allocator);
        }
    };
}

/// Future that resolves to a Result
///
/// This enables async functions to return Result types and use
/// the ? operator for error propagation within async contexts.
pub fn ResultFuture(comptime T: type, comptime E: type) type {
    return struct {
        const Self = @This();
        const ResultType = Result(T, E);

        inner: Future(ResultType),

        pub fn poll(self: *Self, ctx: *Context) PollResult(ResultType) {
            return self.inner.poll(ctx);
        }

        /// Map the Ok value if the future completes successfully
        pub fn map(
            self: *Self,
            allocator: std.mem.Allocator,
            comptime U: type,
            f: *const fn (T) U,
        ) !ResultFuture(U, E) {
            const MapState = struct {
                fut: Future(ResultType),
                map_fn: *const fn (T) U,

                fn mapPoll(state: *anyopaque, ctx: *Context) PollResult(Result(U, E)) {
                    const s = @as(*@This(), @ptrCast(@alignCast(state)));
                    switch (s.fut.poll(ctx)) {
                        .Ready => |result| {
                            const mapped = result.map(U, s.map_fn);
                            return .{ .Ready = mapped };
                        },
                        .Pending => return .Pending,
                    }
                }
            };

            const state = try allocator.create(MapState);
            state.* = .{
                .fut = self.inner,
                .map_fn = f,
            };

            return ResultFuture(U, E){
                .inner = Future(Result(U, E)){
                    .poll_fn = MapState.mapPoll,
                    .state = state,
                },
            };
        }

        /// Chain Result-returning async operations
        pub fn andThen(
            self: *Self,
            allocator: std.mem.Allocator,
            comptime U: type,
            f: *const fn (T) Future(Result(U, E)),
        ) !ResultFuture(U, E) {
            const AndThenState = struct {
                fut: Future(ResultType),
                next_fn: *const fn (T) Future(Result(U, E)),
                next_fut: ?Future(Result(U, E)),
                state: enum { First, Second } = .First,

                fn andThenPoll(state: *anyopaque, ctx: *Context) PollResult(Result(U, E)) {
                    const s = @as(*@This(), @ptrCast(@alignCast(state)));

                    while (true) {
                        switch (s.state) {
                            .First => {
                                switch (s.fut.poll(ctx)) {
                                    .Ready => |result| {
                                        switch (result) {
                                            .ok => |v| {
                                                s.next_fut = s.next_fn(v);
                                                s.state = .Second;
                                                continue;
                                            },
                                            .err => |e| {
                                                return .{ .Ready = Result(U, E).err_value(e) };
                                            },
                                        }
                                    },
                                    .Pending => return .Pending,
                                }
                            },
                            .Second => {
                                return s.next_fut.?.poll(ctx);
                            },
                        }
                    }
                }
            };

            const state = try allocator.create(AndThenState);
            state.* = .{
                .fut = self.inner,
                .next_fn = f,
                .next_fut = null,
            };

            return ResultFuture(U, E){
                .inner = Future(Result(U, E)){
                    .poll_fn = AndThenState.andThenPoll,
                    .state = state,
                },
            };
        }
    };
}

/// Create a Future that immediately resolves to Ok(value)
pub fn ok(comptime T: type, comptime E: type, value: T, allocator: std.mem.Allocator) !Future(Result(T, E)) {
    return future_mod.ready(Result(T, E), Result(T, E).ok_value(value), allocator);
}

/// Create a Future that immediately resolves to Err(error)
pub fn err(comptime T: type, comptime E: type, error_value: E, allocator: std.mem.Allocator) !Future(Result(T, E)) {
    return future_mod.ready(Result(T, E), Result(T, E).err_value(error_value), allocator);
}

/// Async function helper for ? operator
///
/// When an async function encounters `await expr?`, this helper:
/// 1. Polls the future
/// 2. If Ready and Ok: extracts value
/// 3. If Ready and Err: returns early with error
/// 4. If Pending: returns Pending
pub fn tryAwait(
    comptime T: type,
    comptime E: type,
    fut: *Future(Result(T, E)),
    ctx: *Context,
) PollResult(T) {
    switch (fut.poll(ctx)) {
        .Ready => |result| {
            switch (result) {
                .ok => |value| return .{ .Ready = value },
                .err => |e| {
                    // In the actual state machine, this would trigger
                    // an early return with the error wrapped in Result
                    _ = e;
                    return .Pending; // Placeholder
                },
            }
        },
        .Pending => return .Pending,
    }
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "Result - basic ok and err" {
    const testing = std.testing;

    const result_ok = Result(i32, []const u8).ok_value(42);
    try testing.expect(result_ok.isOk());
    try testing.expectEqual(@as(i32, 42), (try result_ok.unwrap()));

    const result_err = Result(i32, []const u8).err_value("error");
    try testing.expect(result_err.isErr());
}

test "Result - map" {
    const testing = std.testing;

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const result_ok = Result(i32, []const u8).ok_value(21);
    const mapped = result_ok.map(i32, double);
    try testing.expect(mapped.isOk());
    try testing.expectEqual(@as(i32, 42), (try mapped.unwrap()));

    const result_err = Result(i32, []const u8).err_value("error");
    const mapped_err = result_err.map(i32, double);
    try testing.expect(mapped_err.isErr());
}

test "Result - andThen" {
    const testing = std.testing;

    const toStr = struct {
        fn f(x: i32) Result([]const u8, []const u8) {
            if (x < 0) {
                return Result([]const u8, []const u8).err_value("negative");
            }
            return Result([]const u8, []const u8).ok_value("positive");
        }
    }.f;

    const result_ok = Result(i32, []const u8).ok_value(42);
    const chained = result_ok.andThen([]const u8, toStr);
    try testing.expect(chained.isOk());

    const result_neg = Result(i32, []const u8).ok_value(-1);
    const chained_err = result_neg.andThen([]const u8, toStr);
    try testing.expect(chained_err.isErr());
}

test "Result - unwrapOr" {
    const testing = std.testing;

    const result_ok = Result(i32, []const u8).ok_value(42);
    try testing.expectEqual(@as(i32, 42), result_ok.unwrapOr(0));

    const result_err = Result(i32, []const u8).err_value("error");
    try testing.expectEqual(@as(i32, 0), result_err.unwrapOr(0));
}

// ResultFuture integration tests require full runtime setup
// See packages/async/tests/result_future_test.zig for comprehensive tests
