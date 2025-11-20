const std = @import("std");
const testing = std.testing;

// Import modules directly
const result_future = @import("src/result_future.zig");
const Result = result_future.Result;

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

    const err_val = result.unwrapErr();
    try testing.expectEqual(error.NetworkError, err_val);
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
