// Home Runtime — formatting helpers.
//
// Mirrors the small subset of Bun's `fmt` namespace that the copied
// source needs. Coverage grows as more files land.

const std = @import("std");

const strings = @import("strings.zig");

/// `std.fmt` formatter that prints a quoted string with backslash escapes.
/// Used by Bun source as `bun.fmt.quote(some_string)` -> `"...escaped..."`.
pub const QuotedFormatter = struct {
    text: []const u8,

    pub fn format(self: QuotedFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('"');
        for (self.text) |c| switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        };
        try writer.writeByte('"');
    }
};

pub fn quote(text: []const u8) QuotedFormatter {
    return .{ .text = text };
}

/// Lowercase / uppercase hex-int formatter. Used by Bun's source as
/// `bun.fmt.hexIntLower(value)` to print things like ETag hashes.
pub const HexIntFormatter = struct {
    value: u64,
    upper: bool = false,

    pub fn format(self: HexIntFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.upper) {
            try writer.print("{X}", .{self.value});
        } else {
            try writer.print("{x}", .{self.value});
        }
    }
};

pub fn hexIntLower(value: anytype) HexIntFormatter {
    return .{ .value = @intCast(value), .upper = false };
}

pub fn hexIntUpper(value: anytype) HexIntFormatter {
    return .{ .value = @intCast(value), .upper = true };
}

pub fn truncatedHash32(int: u64) std.fmt.Alt(u64, truncatedHash32Impl) {
    return .{ .data = int };
}

fn truncatedHash32Impl(int: u64, writer: *std.Io.Writer) !void {
    const in_bytes = std.mem.asBytes(&int);
    const chars = "0123456789abcdefghjkmnpqrstvwxyz";
    try writer.writeAll(&.{
        chars[in_bytes[0] & 31],
        chars[in_bytes[1] & 31],
        chars[in_bytes[2] & 31],
        chars[in_bytes[3] & 31],
        chars[in_bytes[4] & 31],
        chars[in_bytes[5] & 31],
        chars[in_bytes[6] & 31],
        chars[in_bytes[7] & 31],
    });
}

pub fn fmtIdentifier(name: []const u8) FormatValidIdentifier {
    return .{ .name = name };
}

pub const FormatValidIdentifier = struct {
    name: []const u8,

    pub fn format(self: FormatValidIdentifier, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var iterator = strings.CodepointIterator.init(self.name);
        var cursor = strings.CodepointIterator.Cursor{};

        if (self.name.len == 0) {
            try writer.writeByte('_');
            return;
        }

        _ = iterator.next(&cursor);
        var needs_gap = !isIdentifierStart(cursor.c);
        var start_i: usize = 0;

        if (!needs_gap) {
            while (iterator.next(&cursor)) {
                if (!isIdentifierContinue(cursor.c) or cursor.width > 1) {
                    needs_gap = true;
                    start_i = cursor.i;
                    break;
                }
            }
        }

        if (!needs_gap) {
            try writer.writeAll(self.name);
            return;
        }

        needs_gap = false;
        if (start_i > 0) try writer.writeAll(self.name[0..start_i]);

        const slice = self.name[start_i..];
        iterator = strings.CodepointIterator.init(slice);
        cursor = strings.CodepointIterator.Cursor{};
        while (iterator.next(&cursor)) {
            if (isIdentifierContinue(cursor.c) and cursor.width == 1) {
                if (needs_gap) {
                    try writer.writeByte('_');
                    needs_gap = false;
                }
                try writer.writeAll(slice[cursor.i..][0..cursor.width]);
            } else if (!needs_gap) {
                needs_gap = true;
            }
        }

        if (needs_gap) {
            try writer.writeByte('_');
        }
    }
};

fn isIdentifierStart(codepoint: i32) bool {
    return switch (codepoint) {
        'A'...'Z', 'a'...'z', '_', '$' => true,
        else => codepoint >= 0x80,
    };
}

fn isIdentifierContinue(codepoint: i32) bool {
    return isIdentifierStart(codepoint) or switch (codepoint) {
        '0'...'9' => true,
        else => false,
    };
}

pub const FormatDouble = struct {
    number: f64,

    pub fn dtoa(buf: *[124]u8, number: f64) []const u8 {
        return std.fmt.bufPrint(buf[0..], "{d}", .{number}) catch unreachable;
    }

    pub fn dtoaWithNegativeZero(buf: *[124]u8, number: f64) []const u8 {
        if (std.math.isNegativeZero(number)) return "-0";
        return dtoa(buf, number);
    }

    pub fn format(self: FormatDouble, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [124]u8 = undefined;
        try writer.writeAll(dtoa(&buf, self.number));
    }
};

test "hexIntLower prints lowercase hex" {
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{hexIntLower(@as(u32, 0xdeadbeef))});
    try std.testing.expectEqualStrings("deadbeef", writer.buffered());
}

test "hexIntUpper prints uppercase hex" {
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{hexIntUpper(@as(u32, 0xCAFE))});
    try std.testing.expectEqualStrings("CAFE", writer.buffered());
}

test "quote escapes the standard control characters" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{quote("hello\nworld")});
    try std.testing.expectEqualStrings("\"hello\\nworld\"", writer.buffered());
}

test "quote escapes embedded quotes and backslashes" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{quote("a\"b\\c")});
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", writer.buffered());
}

test "fmtIdentifier folds invalid separators into gaps" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{fmtIdentifier("pkg-name/file.ts")});
    try std.testing.expectEqualStrings("pkg_name_file_ts", writer.buffered());
}

test "FormatDouble dtoa writes a finite value" {
    var buf: [124]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", FormatDouble.dtoa(&buf, 1.5));
}
