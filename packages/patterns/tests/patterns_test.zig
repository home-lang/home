const std = @import("std");
const testing = std.testing;

// Pattern matching tests
// Tests for pattern matching and destructuring

test "patterns - basic switch matching" {
    const value: i32 = 42;

    const result = switch (value) {
        0 => "zero",
        1...10 => "small",
        11...100 => "medium",
        else => "large",
    };

    try testing.expectEqualStrings("medium", result);
}

test "patterns - enum pattern matching" {
    const Status = enum {
        Pending,
        Running,
        Complete,
        Failed,
    };

    const status: Status = .Complete;

    const message = switch (status) {
        .Pending => "waiting",
        .Running => "in progress",
        .Complete => "done",
        .Failed => "error",
    };

    try testing.expectEqualStrings("done", message);
}

test "patterns - tagged union matching" {
    const Value = union(enum) {
        Int: i32,
        Float: f32,
        String: []const u8,
    };

    const val = Value{ .Int = 42 };

    const result = switch (val) {
        .Int => |i| i * 2,
        .Float => |f| @as(i32, @intFromFloat(f)),
        .String => 0,
    };

    try testing.expect(result == 84);
}

test "patterns - optional unwrapping" {
    const maybe_value: ?i32 = 42;

    const result = if (maybe_value) |value| value * 2 else 0;

    try testing.expect(result == 84);
}

test "patterns - error union matching" {
    const result: anyerror!i32 = 42;

    const value = if (result) |v| v else |_| 0;

    try testing.expect(value == 42);
}

test "patterns - array destructuring" {
    const numbers = [_]i32{ 1, 2, 3, 4, 5 };

    const first = numbers[0];
    const last = numbers[numbers.len - 1];

    try testing.expect(first == 1);
    try testing.expect(last == 5);
}

test "patterns - struct destructuring" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    const point = Point{ .x = 10, .y = 20 };
    const x = point.x;
    const y = point.y;

    try testing.expect(x == 10);
    try testing.expect(y == 20);
}

test "patterns - nested pattern matching" {
    const Result = union(enum) {
        Ok: i32,
        Err: []const u8,
    };

    const Option = union(enum) {
        Some: Result,
        None,
    };

    const opt = Option{ .Some = .{ .Ok = 42 } };

    const value = switch (opt) {
        .Some => |result| switch (result) {
            .Ok => |v| v,
            .Err => 0,
        },
        .None => -1,
    };

    try testing.expect(value == 42);
}

test "patterns - guard clauses simulation" {
    const isPositiveEven = struct {
        fn check(n: i32) bool {
            return n > 0 and @mod(n, 2) == 0;
        }
    }.check;

    try testing.expect(isPositiveEven(42));
    try testing.expect(!isPositiveEven(41));
    try testing.expect(!isPositiveEven(-2));
}
