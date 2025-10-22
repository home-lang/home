const std = @import("std");
const testing = std.testing;
const Interpreter = @import("interpreter").Interpreter;
const Value = @import("interpreter").Value;

test "interpreter: create integer value" {
    const allocator = testing.allocator;

    const value = Value{ .Int = 42 };
    defer value.deinit(allocator);

    try testing.expectEqual(@as(i64, 42), value.Int);
}

test "interpreter: create float value" {
    const allocator = testing.allocator;

    const value = Value{ .Float = 3.14 };
    defer value.deinit(allocator);

    try testing.expectEqual(@as(f64, 3.14), value.Float);
}

test "interpreter: create boolean value" {
    const allocator = testing.allocator;

    const value = Value{ .Bool = true };
    defer value.deinit(allocator);

    try testing.expectEqual(true, value.Bool);
}

test "interpreter: create string value" {
    const allocator = testing.allocator;

    const value = Value{ .String = "hello" };
    defer value.deinit(allocator);

    try testing.expectEqualStrings("hello", value.String);
}

test "interpreter: create void value" {
    const allocator = testing.allocator;

    const value = Value{ .Void = {} };
    defer value.deinit(allocator);

    try testing.expect(value == .Void);
}

test "interpreter: integer truthiness" {
    const allocator = testing.allocator;

    const zero = Value{ .Int = 0 };
    const non_zero = Value{ .Int = 42 };

    defer zero.deinit(allocator);
    defer non_zero.deinit(allocator);

    try testing.expect(!zero.isTrue());
    try testing.expect(non_zero.isTrue());
}

test "interpreter: float truthiness" {
    const allocator = testing.allocator;

    const zero = Value{ .Float = 0.0 };
    const non_zero = Value{ .Float = 3.14 };

    defer zero.deinit(allocator);
    defer non_zero.deinit(allocator);

    try testing.expect(!zero.isTrue());
    try testing.expect(non_zero.isTrue());
}

test "interpreter: boolean truthiness" {
    const allocator = testing.allocator;

    const true_val = Value{ .Bool = true };
    const false_val = Value{ .Bool = false };

    defer true_val.deinit(allocator);
    defer false_val.deinit(allocator);

    try testing.expect(true_val.isTrue());
    try testing.expect(!false_val.isTrue());
}

test "interpreter: string truthiness" {
    const allocator = testing.allocator;

    const empty = Value{ .String = "" };
    const non_empty = Value{ .String = "hello" };

    defer empty.deinit(allocator);
    defer non_empty.deinit(allocator);

    try testing.expect(!empty.isTrue());
    try testing.expect(non_empty.isTrue());
}

test "interpreter: void truthiness" {
    const allocator = testing.allocator;

    const value = Value{ .Void = {} };
    defer value.deinit(allocator);

    try testing.expect(!value.isTrue());
}

test "interpreter: value formatting - integer" {
    const allocator = testing.allocator;

    const value = Value{ .Int = 42 };
    defer value.deinit(allocator);

    // Manually format using a buffer
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try value.format("", .{}, fbs.writer());
    const formatted = fbs.getWritten();

    try testing.expectEqualStrings("42", formatted);
}

test "interpreter: value formatting - float" {
    const allocator = testing.allocator;

    const value = Value{ .Float = 3.14 };
    defer value.deinit(allocator);

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try value.format("", .{}, fbs.writer());
    const formatted = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, formatted, "3.14") != null);
}

test "interpreter: value formatting - boolean" {
    const allocator = testing.allocator;

    const value = Value{ .Bool = true };
    defer value.deinit(allocator);

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try value.format("", .{}, fbs.writer());
    const formatted = fbs.getWritten();

    try testing.expectEqualStrings("true", formatted);
}

test "interpreter: value formatting - string" {
    const allocator = testing.allocator;

    const value = Value{ .String = "hello" };
    defer value.deinit(allocator);

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try value.format("", .{}, fbs.writer());
    const formatted = fbs.getWritten();

    try testing.expectEqualStrings("hello", formatted);
}

test "interpreter: value formatting - void" {
    const allocator = testing.allocator;

    const value = Value{ .Void = {} };
    defer value.deinit(allocator);

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try value.format("", .{}, fbs.writer());
    const formatted = fbs.getWritten();

    try testing.expectEqualStrings("void", formatted);
}
