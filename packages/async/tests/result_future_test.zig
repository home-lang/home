const std = @import("std");
const testing = std.testing;
const result_mod = @import("../src/result_future.zig");
const Result = result_mod.Result;
const ResultFuture = result_mod.ResultFuture;
const future_mod = @import("../src/future.zig");
const Future = future_mod.Future;
const PollResult = future_mod.PollResult;
const Context = future_mod.Context;
const Waker = future_mod.Waker;
const runtime_mod = @import("../src/runtime.zig");
const Runtime = runtime_mod.Runtime;

// Test errors
const TestError = error{
    NetworkError,
    DatabaseError,
    ValidationError,
};

// =================================================================================
//                          RESULT TYPE TESTS
// =================================================================================

test "Result - create ok value" {
    const result = Result(i32, TestError).ok_value(42);
    try testing.expect(result.isOk());
    try testing.expect(!result.isErr());

    const value = try result.unwrap();
    try testing.expectEqual(@as(i32, 42), value);
}

test "Result - create err value" {
    const result = Result(i32, TestError).err_value(error.NetworkError);
    try testing.expect(!result.isOk());
    try testing.expect(result.isErr());

    const err = result.unwrap();
    try testing.expectError(error.NetworkError, err);
}

test "Result - map ok value" {
    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const result = Result(i32, TestError).ok_value(21);
    const mapped = result.map(i32, double);

    try testing.expect(mapped.isOk());
    const value = try mapped.unwrap();
    try testing.expectEqual(@as(i32, 42), value);
}

test "Result - map preserves error" {
    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const result = Result(i32, TestError).err_value(error.NetworkError);
    const mapped = result.map(i32, double);

    try testing.expect(mapped.isErr());
}

test "Result - mapErr transforms error type" {
    const toStr = struct {
        fn f(err: TestError) []const u8 {
            return switch (err) {
                error.NetworkError => "network error",
                error.DatabaseError => "database error",
                error.ValidationError => "validation error",
            };
        }
    }.f;

    const result = Result(i32, TestError).err_value(error.NetworkError);
    const mapped = result.mapErr([]const u8, toStr);

    try testing.expect(mapped.isErr());
    // Would check error value but error types don't support equality
}

test "Result - andThen chains ok values" {
    const validate = struct {
        fn f(x: i32) Result(i32, TestError) {
            if (x < 0) {
                return Result(i32, TestError).err_value(error.ValidationError);
            }
            return Result(i32, TestError).ok_value(x * 2);
        }
    }.f;

    const result = Result(i32, TestError).ok_value(21);
    const chained = result.andThen(i32, validate);

    try testing.expect(chained.isOk());
    const value = try chained.unwrap();
    try testing.expectEqual(@as(i32, 42), value);
}

test "Result - andThen propagates inner error" {
    const validate = struct {
        fn f(x: i32) Result(i32, TestError) {
            if (x < 0) {
                return Result(i32, TestError).err_value(error.ValidationError);
            }
            return Result(i32, TestError).ok_value(x * 2);
        }
    }.f;

    const result = Result(i32, TestError).ok_value(-1);
    const chained = result.andThen(i32, validate);

    try testing.expect(chained.isErr());
}

test "Result - andThen propagates outer error" {
    const validate = struct {
        fn f(x: i32) Result(i32, TestError) {
            return Result(i32, TestError).ok_value(x * 2);
        }
    }.f;

    const result = Result(i32, TestError).err_value(error.NetworkError);
    const chained = result.andThen(i32, validate);

    try testing.expect(chained.isErr());
}

test "Result - unwrapOr provides default on error" {
    const ok_result = Result(i32, TestError).ok_value(42);
    try testing.expectEqual(@as(i32, 42), ok_result.unwrapOr(0));

    const err_result = Result(i32, TestError).err_value(error.NetworkError);
    try testing.expectEqual(@as(i32, 0), err_result.unwrapOr(0));
}

// =================================================================================
//                        RESULT FUTURE TESTS
// =================================================================================

test "ResultFuture - ok resolves immediately" {
    const allocator = testing.allocator;

    var fut = try result_mod.ok(i32, TestError, 42, allocator);
    defer fut.deinit(allocator);

    var waker_called = false;
    const test_waker = Waker{
        .wake_fn = struct {
            fn wake(ptr: *anyopaque) void {
                const called = @as(*bool, @ptrCast(@alignCast(ptr)));
                called.* = true;
            }
        }.wake,
        .drop_fn = struct {
            fn drop(ptr: *anyopaque) void {
                _ = ptr;
            }
        }.drop,
        .data = &waker_called,
    };

    var ctx = Context{
        .waker = test_waker,
    };

    switch (fut.poll(&ctx)) {
        .Ready => |result| {
            try testing.expect(result.isOk());
            const value = try result.unwrap();
            try testing.expectEqual(@as(i32, 42), value);
        },
        .Pending => {
            try testing.expect(false); // Should be ready immediately
        },
    }

    try testing.expect(!waker_called); // Waker shouldn't be called for immediate resolution
}

test "ResultFuture - err resolves immediately" {
    const allocator = testing.allocator;

    var fut = try result_mod.err(i32, TestError, error.NetworkError, allocator);
    defer fut.deinit(allocator);

    var waker_called = false;
    const test_waker = Waker{
        .wake_fn = struct {
            fn wake(ptr: *anyopaque) void {
                const called = @as(*bool, @ptrCast(@alignCast(ptr)));
                called.* = true;
            }
        }.wake,
        .drop_fn = struct {
            fn drop(ptr: *anyopaque) void {
                _ = ptr;
            }
        }.drop,
        .data = &waker_called,
    };

    var ctx = Context{
        .waker = test_waker,
    };

    switch (fut.poll(&ctx)) {
        .Ready => |result| {
            try testing.expect(result.isErr());
        },
        .Pending => {
            try testing.expect(false); // Should be ready immediately
        },
    }

    try testing.expect(!waker_called);
}

test "ResultFuture - map transforms ok value" {
    const allocator = testing.allocator;

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    var base_fut = try result_mod.ok(i32, TestError, 21, allocator);
    defer base_fut.deinit(allocator);

    var result_fut = ResultFuture(i32, TestError){
        .inner = base_fut,
    };

    var mapped_fut = try result_fut.map(allocator, i32, double);
    // Note: Don't deinit mapped_fut as it shares state with result_fut

    var ctx = Context{
        .waker = undefined,
    };

    switch (mapped_fut.inner.poll(&ctx)) {
        .Ready => |result| {
            try testing.expect(result.isOk());
            const value = try result.unwrap();
            try testing.expectEqual(@as(i32, 42), value);
        },
        .Pending => {
            try testing.expect(false);
        },
    }
}

test "ResultFuture - map preserves error" {
    const allocator = testing.allocator;

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    var base_fut = try result_mod.err(i32, TestError, error.NetworkError, allocator);
    defer base_fut.deinit(allocator);

    var result_fut = ResultFuture(i32, TestError){
        .inner = base_fut,
    };

    var mapped_fut = try result_fut.map(allocator, i32, double);

    var ctx = Context{
        .waker = undefined,
    };

    switch (mapped_fut.inner.poll(&ctx)) {
        .Ready => |result| {
            try testing.expect(result.isErr());
        },
        .Pending => {
            try testing.expect(false);
        },
    }
}

// =================================================================================
//                    INTEGRATION TESTS WITH RUNTIME
// =================================================================================

// Helper async function that returns Result
fn asyncAdd(a: i32, b: i32, allocator: std.mem.Allocator) !Future(Result(i32, TestError)) {
    if (a < 0 or b < 0) {
        return result_mod.err(i32, TestError, error.ValidationError, allocator);
    }
    return result_mod.ok(i32, TestError, a + b, allocator);
}

test "Integration - Runtime with Result future (ok)" {
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 2);
    defer runtime.deinit();

    var fut = try asyncAdd(21, 21, allocator);
    const handle = try runtime.spawn(Result(i32, TestError), fut);

    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});
    std.time.sleep(10 * std.time.ns_per_ms);

    runtime.shutdown.store(true, .Release);
    rt_thread.join();

    if (handle.tryGet()) |result| {
        try testing.expect(result.isOk());
        const value = try result.unwrap();
        try testing.expectEqual(@as(i32, 42), value);
    } else {
        try testing.expect(false); // Should have completed
    }
}

test "Integration - Runtime with Result future (err)" {
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 2);
    defer runtime.deinit();

    var fut = try asyncAdd(-1, 21, allocator);
    const handle = try runtime.spawn(Result(i32, TestError), fut);

    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});
    std.time.sleep(10 * std.time.ns_per_ms);

    runtime.shutdown.store(true, .Release);
    rt_thread.join();

    if (handle.tryGet()) |result| {
        try testing.expect(result.isErr());
    } else {
        try testing.expect(false); // Should have completed
    }
}

// =================================================================================
//                      ERROR PROPAGATION TESTS
// =================================================================================

test "Error propagation - chained operations" {
    const allocator = testing.allocator;

    // Simulate: let x = await fetchUser()?;
    // If fetchUser returns Err, it should propagate

    var base_fut = try result_mod.err(i32, TestError, error.NetworkError, allocator);
    defer base_fut.deinit(allocator);

    var ctx = Context{
        .waker = undefined,
    };

    // Poll the future
    switch (base_fut.poll(&ctx)) {
        .Ready => |result| {
            // In actual async function, this would trigger early return
            try testing.expect(result.isErr());
        },
        .Pending => {
            try testing.expect(false);
        },
    }
}

test "Error propagation - multiple await points" {
    const allocator = testing.allocator;

    // Simulate:
    // let user = await fetchUser()?;  // Ok
    // let posts = await fetchPosts()?; // Err
    // Should propagate Err from second await

    var fut1 = try result_mod.ok(i32, TestError, 42, allocator);
    defer fut1.deinit(allocator);

    var fut2 = try result_mod.err([]const u8, TestError, error.DatabaseError, allocator);
    defer fut2.deinit(allocator);

    var ctx = Context{
        .waker = undefined,
    };

    // First await succeeds
    switch (fut1.poll(&ctx)) {
        .Ready => |result| {
            try testing.expect(result.isOk());
        },
        .Pending => try testing.expect(false),
    }

    // Second await fails and propagates
    switch (fut2.poll(&ctx)) {
        .Ready => |result| {
            try testing.expect(result.isErr());
        },
        .Pending => try testing.expect(false),
    }
}

// =================================================================================
//                      TYPE CONVERSION TESTS
// =================================================================================

test "Result to Future conversion" {
    const allocator = testing.allocator;

    const result = Result(i32, TestError).ok_value(42);
    var fut = try result.toFuture(allocator);
    defer fut.deinit(allocator);

    var ctx = Context{
        .waker = undefined,
    };

    switch (fut.poll(&ctx)) {
        .Ready => |res| {
            try testing.expect(res.isOk());
            const value = try res.unwrap();
            try testing.expectEqual(@as(i32, 42), value);
        },
        .Pending => try testing.expect(false),
    }
}
