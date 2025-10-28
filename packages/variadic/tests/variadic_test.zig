// Home Programming Language - Comprehensive Variadic Tests
// Integration tests for the complete variadic system

const std = @import("std");
const testing = std.testing;
const variadic = @import("variadic");

// ============================================================================
// Printf Integration Tests
// ============================================================================

test "printf - comprehensive formatting" {
    var buf: [1024]u8 = undefined;

    // Integers
    const n1 = try variadic.printf.sprintf(&buf, "Dec: %d, Hex: %x, Oct: %o, Bin: %b", .{
        @as(i32, 42),
        @as(u32, 42),
        @as(u32, 42),
        @as(u32, 42),
    });
    try testing.expect(std.mem.eql(u8, "Dec: 42, Hex: 2a, Oct: 52, Bin: 0b101010", buf[0..n1]));

    // Floats
    const n2 = try variadic.printf.sprintf(&buf, "Pi: %.2f, E: %.4f", .{
        @as(f64, 3.14159),
        @as(f64, 2.71828),
    });
    try testing.expect(std.mem.eql(u8, "Pi: 3.14, E: 2.7183", buf[0..n2]));

    // Strings and chars
    const n3 = try variadic.printf.sprintf(&buf, "Char: %c, String: %s", .{
        @as(u8, 'A'),
        "Hello",
    });
    try testing.expect(std.mem.eql(u8, "Char: A, String: Hello", buf[0..n3]));
}

test "printf - width and padding" {
    var buf: [1024]u8 = undefined;

    // Right-aligned with spaces
    const n1 = try variadic.printf.sprintf(&buf, "[%10d]", .{@as(i32, 42)});
    try testing.expect(std.mem.eql(u8, "[        42]", buf[0..n1]));

    // Left-aligned
    const n2 = try variadic.printf.sprintf(&buf, "[%-10d]", .{@as(i32, 42)});
    try testing.expect(std.mem.eql(u8, "[42        ]", buf[0..n2]));

    // Zero-padded
    const n3 = try variadic.printf.sprintf(&buf, "[%010d]", .{@as(i32, 42)});
    try testing.expect(std.mem.eql(u8, "[0000000042]", buf[0..n3]));
}

test "printf - precision" {
    var buf: [1024]u8 = undefined;

    const n1 = try variadic.printf.sprintf(&buf, "%.0f", .{@as(f64, 3.14159)});
    try testing.expect(std.mem.eql(u8, "3", buf[0..n1]));

    const n2 = try variadic.printf.sprintf(&buf, "%.5f", .{@as(f64, 3.14159)});
    try testing.expect(std.mem.eql(u8, "3.14159", buf[0..n2]));
}

test "printf - alternate forms" {
    var buf: [1024]u8 = undefined;

    const n1 = try variadic.printf.sprintf(&buf, "%#x", .{@as(u32, 255)});
    try testing.expect(std.mem.eql(u8, "0xff", buf[0..n1]));

    const n2 = try variadic.printf.sprintf(&buf, "%#o", .{@as(u32, 64)});
    try testing.expect(std.mem.eql(u8, "0100", buf[0..n2]));
}

test "printf - escaped percent" {
    var buf: [1024]u8 = undefined;

    const n = try variadic.printf.sprintf(&buf, "100%% complete", .{});
    try testing.expect(std.mem.eql(u8, "100% complete", buf[0..n]));
}

test "printf - asprintf allocation" {
    const str = try variadic.printf.asprintf(testing.allocator, "Answer: %d", .{@as(i32, 42)});
    defer testing.allocator.free(str);

    try testing.expect(std.mem.eql(u8, "Answer: 42", str));
}

// ============================================================================
// Logger Integration Tests
// ============================================================================

test "logger - all levels" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = variadic.logger.Logger.init(testing.allocator, .{
        .min_level = .Debug,
        .use_colors = false,
        .show_timestamp = false,
        .writer = fbs.writer().any(),
    });

    try logger.debug("Debug message", .{});
    try logger.info("Info message", .{});
    try logger.warn("Warn message", .{});
    try logger.err("Error message", .{});
    try logger.fatal("Fatal message", .{});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "[DEBUG]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[INFO]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[WARN]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[ERROR]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[FATAL]") != null);
}

test "logger - formatted messages" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = variadic.logger.Logger.init(testing.allocator, .{
        .use_colors = false,
        .show_timestamp = false,
        .writer = fbs.writer().any(),
    });

    try logger.info("User %s logged in from %s:%d", .{ "alice", "192.168.1.1", @as(u16, 22) });

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, output, "192.168.1.1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "22") != null);
}

test "logger - level filtering" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = variadic.logger.Logger.init(testing.allocator, .{
        .min_level = .Error,
        .use_colors = false,
        .show_timestamp = false,
        .writer = fbs.writer().any(),
    });

    try logger.debug("Should not appear", .{});
    try logger.info("Should not appear", .{});
    try logger.warn("Should not appear", .{});
    try logger.err("Should appear", .{});
    try logger.fatal("Should appear", .{});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "DEBUG") == null);
    try testing.expect(std.mem.indexOf(u8, output, "INFO") == null);
    try testing.expect(std.mem.indexOf(u8, output, "WARN") == null);
    try testing.expect(std.mem.indexOf(u8, output, "ERROR") != null);
    try testing.expect(std.mem.indexOf(u8, output, "FATAL") != null);
}

// ============================================================================
// Format Validation Tests
// ============================================================================

test "format validation - valid formats" {
    const Args1 = @TypeOf(.{@as(i32, 42)});
    try variadic.format.validateFormat("%d", Args1);

    const Args2 = @TypeOf(.{ "hello", @as(i32, 10) });
    try variadic.format.validateFormat("%s %d", Args2);

    const Args3 = @TypeOf(.{ @as(f64, 3.14), @as(u32, 0xff) });
    try variadic.format.validateFormat("%f %x", Args3);
}

test "format validation - too many specifiers" {
    const Args = @TypeOf(.{@as(i32, 42)});
    try testing.expectError(
        variadic.format.FormatError.TooManySpecifiers,
        variadic.format.validateFormat("%d %d", Args),
    );
}

test "format validation - too few specifiers" {
    const Args = @TypeOf(.{ @as(i32, 1), @as(i32, 2) });
    try testing.expectError(
        variadic.format.FormatError.TooFewSpecifiers,
        variadic.format.validateFormat("%d", Args),
    );
}

test "format validation - type mismatch" {
    const Args1 = @TypeOf(.{"string"});
    try testing.expectError(
        variadic.format.FormatError.MismatchedTypes,
        variadic.format.validateFormat("%d", Args1),
    );

    const Args2 = @TypeOf(.{@as(i32, 42)});
    try testing.expectError(
        variadic.format.FormatError.MismatchedTypes,
        variadic.format.validateFormat("%f", Args2),
    );
}

// ============================================================================
// Variadic Utility Tests
// ============================================================================

test "arg type detection" {
    try testing.expectEqual(variadic.ArgType.Int, variadic.ArgInfo.fromType(i32).arg_type);
    try testing.expectEqual(variadic.ArgType.UInt, variadic.ArgInfo.fromType(u32).arg_type);
    try testing.expectEqual(variadic.ArgType.Long, variadic.ArgInfo.fromType(i64).arg_type);
    try testing.expectEqual(variadic.ArgType.ULong, variadic.ArgInfo.fromType(u64).arg_type);
    try testing.expectEqual(variadic.ArgType.Float, variadic.ArgInfo.fromType(f32).arg_type);
    try testing.expectEqual(variadic.ArgType.Double, variadic.ArgInfo.fromType(f64).arg_type);
    try testing.expectEqual(variadic.ArgType.Bool, variadic.ArgInfo.fromType(bool).arg_type);
    try testing.expectEqual(variadic.ArgType.String, variadic.ArgInfo.fromType([]const u8).arg_type);
}

test "count arguments" {
    try testing.expectEqual(@as(usize, 0), variadic.countArgs(.{}));
    try testing.expectEqual(@as(usize, 1), variadic.countArgs(.{@as(i32, 42)}));
    try testing.expectEqual(@as(usize, 3), variadic.countArgs(.{ @as(i32, 1), @as(i32, 2), @as(i32, 3) }));
}

test "get arg by index" {
    const args = .{ @as(i32, 42), @as(f64, 3.14), "hello" };

    const arg0 = variadic.getArg(i32, args, 0);
    const arg1 = variadic.getArg(f64, args, 1);
    const arg2 = variadic.getArg([]const u8, args, 2);
    const arg3 = variadic.getArg(i32, args, 3);

    try testing.expect(arg0 != null);
    try testing.expectEqual(@as(i32, 42), arg0.?);

    try testing.expect(arg1 != null);
    try testing.expectEqual(@as(f64, 3.14), arg1.?);

    try testing.expect(arg2 != null);
    try testing.expect(std.mem.eql(u8, "hello", arg2.?));

    try testing.expect(arg3 == null);
}

// ============================================================================
// Real-World Scenarios
// ============================================================================

test "scenario - kernel logging" {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = variadic.logger.Logger.init(testing.allocator, .{
        .use_colors = false,
        .show_timestamp = false,
        .writer = fbs.writer().any(),
    });

    // Simulate kernel boot messages
    try logger.info("Kernel boot started", .{});
    try logger.info("Detected %d CPU cores", .{@as(u32, 4)});
    try logger.info("Memory: %d MB available", .{@as(u64, 8192)});
    try logger.warn("Device %s not found, using fallback", .{"eth0"});
    try logger.info("Kernel boot complete in %d ms", .{@as(u32, 1523)});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "4 CPU cores") != null);
    try testing.expect(std.mem.indexOf(u8, output, "8192 MB") != null);
    try testing.expect(std.mem.indexOf(u8, output, "eth0") != null);
}

test "scenario - system call tracing" {
    var buf: [1024]u8 = undefined;

    // Format syscall trace
    const n = try variadic.printf.sprintf(
        &buf,
        "syscall: %s(%d, 0x%x, %d) = %d",
        .{ "read", @as(i32, 3), @as(usize, 0x1000), @as(usize, 4096), @as(isize, 4096) },
    );

    try testing.expect(std.mem.indexOf(u8, buf[0..n], "read(3, 0x1000, 4096) = 4096") != null);
}

test "scenario - error messages" {
    var buf: [1024]u8 = undefined;

    const filename = "config.txt";
    const error_code = @as(i32, 2); // ENOENT

    const n = try variadic.printf.sprintf(
        &buf,
        "Error: Failed to open '%s': error %d (No such file or directory)",
        .{ filename, error_code },
    );

    try testing.expect(std.mem.indexOf(u8, buf[0..n], "config.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "error 2") != null);
}
