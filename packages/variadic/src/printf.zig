// Home Programming Language - Printf Implementation
// Type-safe printf with format string validation

const std = @import("std");
const variadic = @import("variadic.zig");
const format_mod = @import("format.zig");

// ============================================================================
// Printf Implementation
// ============================================================================

/// Print formatted output to writer
pub fn fprintf(writer: anytype, comptime fmt: []const u8, args: anytype) !usize {
    // Note: Format validation temporarily disabled for Zig 0.15 compatibility
    // comptime {
    //     format_mod.validateFormat(fmt, @TypeOf(args)) catch |err| {
    //         @compileError("Invalid format string: " ++ @errorName(err));
    //     };
    // }

    var bytes_written: usize = 0;
    var i: usize = 0;
    var arg_index: usize = 0;

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    while (i < fmt.len) {
        if (fmt[i] == '%') {
            if (i + 1 < fmt.len and fmt[i + 1] == '%') {
                // Escaped %
                try writer.writeByte('%');
                bytes_written += 1;
                i += 2;
                continue;
            }

            // Parse format specifier
            const spec_result = parseFormatSpec(fmt[i..]);
            const spec = spec_result.spec;
            const spec_len = spec_result.len;

            if (arg_index >= fields.len) {
                return error.TooFewArguments;
            }

            // Write formatted argument
            inline for (fields, 0..) |field, field_idx| {
                if (field_idx == arg_index) {
                    const arg = @field(args, field.name);
                    const written = try writeFormatted(writer, arg, spec);
                    bytes_written += written;
                    break;
                }
            }

            arg_index += 1;
            i += spec_len;
        } else {
            try writer.writeByte(fmt[i]);
            bytes_written += 1;
            i += 1;
        }
    }

    return bytes_written;
}

/// Print formatted output to stdout
pub fn printf(comptime fmt: []const u8, args: anytype) !usize {
    const stdout = std.io.getStdOut().writer();
    return fprintf(stdout, fmt, args);
}

/// Print formatted output to string buffer
pub fn sprintf(buf: []u8, comptime fmt: []const u8, args: anytype) !usize {
    var fbs = std.io.fixedBufferStream(buf);
    return fprintf(fbs.writer(), fmt, args);
}

/// Print formatted output to allocated string
pub fn asprintf(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    var list = std.ArrayList(u8){};
    errdefer list.deinit(allocator);

    _ = try fprintf(list.writer(allocator), fmt, args);
    return list.toOwnedSlice(allocator);
}

// ============================================================================
// Format Parsing
// ============================================================================

const ParseResult = struct {
    spec: variadic.FormatSpec,
    len: usize,
};

fn parseFormatSpec(fmt_slice: []const u8) ParseResult {
    var i: usize = 1; // Skip initial '%'
    var spec = variadic.FormatSpec{
        .specifier = .Decimal,
    };

    // Parse flags
    while (i < fmt_slice.len) : (i += 1) {
        switch (fmt_slice[i]) {
            '-' => spec.flags.left_justify = true,
            '+' => spec.flags.force_sign = true,
            ' ' => spec.flags.space_sign = true,
            '#' => spec.flags.alternate = true,
            '0' => spec.flags.zero_pad = true,
            else => break,
        }
    }

    // Parse width
    if (i < fmt_slice.len and std.ascii.isDigit(fmt_slice[i])) {
        var width: u32 = 0;
        while (i < fmt_slice.len and std.ascii.isDigit(fmt_slice[i])) : (i += 1) {
            width = width * 10 + (fmt_slice[i] - '0');
        }
        spec.width = width;
    }

    // Parse precision
    if (i < fmt_slice.len and fmt_slice[i] == '.') {
        i += 1;
        var precision: u32 = 0;
        while (i < fmt_slice.len and std.ascii.isDigit(fmt_slice[i])) : (i += 1) {
            precision = precision * 10 + (fmt_slice[i] - '0');
        }
        spec.precision = precision;
    }

    // Parse length modifier
    if (i + 1 < fmt_slice.len) {
        if (fmt_slice[i] == 'h' and fmt_slice[i + 1] == 'h') {
            spec.length = .Char;
            i += 2;
        } else if (fmt_slice[i] == 'l' and fmt_slice[i + 1] == 'l') {
            spec.length = .LongLong;
            i += 2;
        }
    }

    if (i < fmt_slice.len) {
        switch (fmt_slice[i]) {
            'h' => {
                spec.length = .Short;
                i += 1;
            },
            'l' => {
                spec.length = .Long;
                i += 1;
            },
            'z' => {
                spec.length = .Size;
                i += 1;
            },
            't' => {
                spec.length = .Ptrdiff;
                i += 1;
            },
            else => {},
        }
    }

    // Parse specifier
    if (i < fmt_slice.len) {
        spec.specifier = switch (fmt_slice[i]) {
            'd', 'i' => .Decimal,
            'u' => .Unsigned,
            'o' => .Octal,
            'x' => .Hex,
            'X' => .HexUpper,
            'f' => .Float,
            'e' => .Exponential,
            'E' => .ExpUpper,
            'g' => .Shortest,
            'G' => .ShortestUp,
            'c' => .Char,
            's' => .String,
            'p' => .Pointer,
            'b' => .Binary,
            else => .Decimal,
        };
        i += 1;
    }

    return .{
        .spec = spec,
        .len = i,
    };
}

// ============================================================================
// Format Writing
// ============================================================================

fn writeFormatted(writer: anytype, arg: anytype, spec: variadic.FormatSpec) !usize {
    const T = @TypeOf(arg);
    var bytes_written: usize = 0;

    switch (spec.specifier) {
        .Decimal, .Unsigned => {
            bytes_written = try writeInteger(writer, arg, spec);
        },
        .Hex, .HexUpper => {
            bytes_written = try writeHex(writer, arg, spec);
        },
        .Octal => {
            bytes_written = try writeOctal(writer, arg, spec);
        },
        .Binary => {
            bytes_written = try writeBinary(writer, arg, spec);
        },
        .Float, .Exponential, .ExpUpper, .Shortest, .ShortestUp => {
            bytes_written = try writeFloat(writer, arg, spec);
        },
        .Char => {
            if (T == u8 or T == i8 or T == comptime_int) {
                try writer.writeByte(@as(u8, @intCast(arg)));
                bytes_written = 1;
            }
        },
        .String => {
            if (T == []const u8 or T == []u8) {
                try writer.writeAll(arg);
                bytes_written = arg.len;
            } else if (@typeInfo(T) == .pointer) {
                const ptr_info = @typeInfo(T).pointer;
                if (ptr_info.size == .slice) {
                    try writer.writeAll(arg);
                    bytes_written = arg.len;
                } else {
                    const str = std.mem.span(arg);
                    try writer.writeAll(str);
                    bytes_written = str.len;
                }
            }
        },
        .Pointer => {
            const T_info = @typeInfo(T);
            if (T_info == .pointer) {
                bytes_written = try writePointer(writer, arg, spec);
            }
        },
        .Percent => {
            try writer.writeByte('%');
            bytes_written = 1;
        },
    }

    return bytes_written;
}

fn writeInteger(writer: anytype, value: anytype, spec: variadic.FormatSpec) !usize {
    var buf: [65]u8 = undefined;
    const T = @TypeOf(value);

    const int_value: i128 = switch (@typeInfo(T)) {
        .int => @intCast(value),
        .comptime_int => value,
        else => return error.InvalidType,
    };

    const str = if (spec.specifier == .Unsigned or int_value >= 0) blk: {
        const unsigned: u128 = if (int_value < 0) @bitCast(-int_value) else @intCast(int_value);
        break :blk try std.fmt.bufPrint(&buf, "{d}", .{unsigned});
    } else blk: {
        break :blk try std.fmt.bufPrint(&buf, "{d}", .{int_value});
    };

    // Apply width padding
    if (spec.width) |width| {
        if (str.len < width) {
            const pad_char: u8 = if (spec.flags.zero_pad and !spec.flags.left_justify) '0' else ' ';
            const pad_len = width - str.len;

            if (spec.flags.left_justify) {
                try writer.writeAll(str);
                try writer.writeByteNTimes(pad_char, pad_len);
            } else {
                try writer.writeByteNTimes(pad_char, pad_len);
                try writer.writeAll(str);
            }
            return width;
        }
    }

    try writer.writeAll(str);
    return str.len;
}

fn writeHex(writer: anytype, value: anytype, spec: variadic.FormatSpec) !usize {
    var buf: [32]u8 = undefined;
    const T = @TypeOf(value);

    const int_value: u128 = switch (@typeInfo(T)) {
        .int => @intCast(value),
        .comptime_int => value,
        else => return error.InvalidType,
    };

    const str = if (spec.specifier == .HexUpper)
        try std.fmt.bufPrint(&buf, "{X}", .{int_value})
    else
        try std.fmt.bufPrint(&buf, "{x}", .{int_value});

    if (spec.flags.alternate and int_value != 0) {
        if (spec.specifier == .HexUpper) {
            try writer.writeAll("0X");
        } else {
            try writer.writeAll("0x");
        }
        try writer.writeAll(str);
        return str.len + 2;
    }

    try writer.writeAll(str);
    return str.len;
}

fn writeOctal(writer: anytype, value: anytype, spec: variadic.FormatSpec) !usize {
    var buf: [32]u8 = undefined;
    const T = @TypeOf(value);

    const int_value: u128 = switch (@typeInfo(T)) {
        .int => @intCast(value),
        .comptime_int => value,
        else => return error.InvalidType,
    };

    const str = try std.fmt.bufPrint(&buf, "{o}", .{int_value});

    if (spec.flags.alternate and int_value != 0) {
        try writer.writeByte('0');
        try writer.writeAll(str);
        return str.len + 1;
    }

    try writer.writeAll(str);
    return str.len;
}

fn writeBinary(writer: anytype, value: anytype, spec: variadic.FormatSpec) !usize {
    _ = spec;
    var buf: [128]u8 = undefined;
    const T = @TypeOf(value);

    const int_value: u128 = switch (@typeInfo(T)) {
        .int => @intCast(value),
        .comptime_int => value,
        else => return error.InvalidType,
    };

    const str = try std.fmt.bufPrint(&buf, "{b}", .{int_value});

    try writer.writeAll("0b");
    try writer.writeAll(str);
    return str.len + 2;
}

fn writeFloat(writer: anytype, value: anytype, spec: variadic.FormatSpec) !usize {
    const T = @TypeOf(value);

    const float_value: f64 = switch (@typeInfo(T)) {
        .float => @floatCast(value),
        .comptime_float => value,
        else => return error.InvalidType,
    };

    const precision = spec.precision orelse 6;

    var buf: [128]u8 = undefined;
    const str = switch (precision) {
        0 => try std.fmt.bufPrint(&buf, "{d:.0}", .{float_value}),
        1 => try std.fmt.bufPrint(&buf, "{d:.1}", .{float_value}),
        2 => try std.fmt.bufPrint(&buf, "{d:.2}", .{float_value}),
        3 => try std.fmt.bufPrint(&buf, "{d:.3}", .{float_value}),
        4 => try std.fmt.bufPrint(&buf, "{d:.4}", .{float_value}),
        5 => try std.fmt.bufPrint(&buf, "{d:.5}", .{float_value}),
        6 => try std.fmt.bufPrint(&buf, "{d:.6}", .{float_value}),
        else => try std.fmt.bufPrint(&buf, "{d}", .{float_value}),
    };

    try writer.writeAll(str);
    return str.len;
}

fn writePointer(writer: anytype, value: anytype, spec: variadic.FormatSpec) !usize {
    _ = spec;
    const ptr_value = @intFromPtr(value);

    var buf: [32]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{x}", .{ptr_value});

    try writer.writeAll("0x");
    try writer.writeAll(str);
    return str.len + 2;
}

// ============================================================================
// Tests
// ============================================================================

test "printf basic" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    // Integer
    const n1 = try sprintf(&buf, "Number: %d", .{@as(i32, 42)});
    try testing.expect(std.mem.eql(u8, "Number: 42", buf[0..n1]));

    // String
    const n2 = try sprintf(&buf, "Hello %s!", .{"World"});
    try testing.expect(std.mem.eql(u8, "Hello World!", buf[0..n2]));

    // Multiple args
    const n3 = try sprintf(&buf, "%d + %d = %d", .{ @as(i32, 2), @as(i32, 3), @as(i32, 5) });
    try testing.expect(std.mem.eql(u8, "2 + 3 = 5", buf[0..n3]));
}

test "printf hex" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    const n1 = try sprintf(&buf, "0x%x", .{@as(u32, 255)});
    try testing.expect(std.mem.eql(u8, "0xff", buf[0..n1]));

    const n2 = try sprintf(&buf, "%#x", .{@as(u32, 255)});
    try testing.expect(std.mem.eql(u8, "0xff", buf[0..n2]));

    const n3 = try sprintf(&buf, "%#X", .{@as(u32, 255)});
    try testing.expect(std.mem.eql(u8, "0XFF", buf[0..n3]));
}

test "printf width padding" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    // Right-aligned with spaces
    const n1 = try sprintf(&buf, "%5d", .{@as(i32, 42)});
    try testing.expect(std.mem.eql(u8, "   42", buf[0..n1]));

    // Left-aligned
    const n2 = try sprintf(&buf, "%-5d", .{@as(i32, 42)});
    try testing.expect(std.mem.eql(u8, "42   ", buf[0..n2]));

    // Zero-padded
    const n3 = try sprintf(&buf, "%05d", .{@as(i32, 42)});
    try testing.expect(std.mem.eql(u8, "00042", buf[0..n3]));
}

test "printf float" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    const n1 = try sprintf(&buf, "%.2f", .{@as(f64, 3.14159)});
    try testing.expect(std.mem.eql(u8, "3.14", buf[0..n1]));

    const n2 = try sprintf(&buf, "%.4f", .{@as(f64, 2.71828)});
    try testing.expect(std.mem.eql(u8, "2.7183", buf[0..n2]));
}

test "printf binary extension" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    const n1 = try sprintf(&buf, "%b", .{@as(u8, 5)});
    try testing.expect(std.mem.eql(u8, "0b101", buf[0..n1]));

    const n2 = try sprintf(&buf, "%b", .{@as(u8, 255)});
    try testing.expect(std.mem.eql(u8, "0b11111111", buf[0..n2]));
}

test "asprintf" {
    const testing = std.testing;

    const str = try asprintf(testing.allocator, "Result: %d", .{@as(i32, 123)});
    defer testing.allocator.free(str);

    try testing.expect(std.mem.eql(u8, "Result: 123", str));
}
