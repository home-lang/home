// Home Runtime — formatting helpers.
//
// Mirrors the small subset of Bun's `fmt` namespace that the copied
// source needs. Coverage grows as more files land.

const std = @import("std");

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

pub fn formatUTF16Type(slice: []const u16, writer: *std.Io.Writer) !void {
    var remaining = slice;
    var buf: [1024]u8 = undefined;

    while (remaining.len > 0) {
        var read: usize = 0;
        var written: usize = 0;

        while (read < remaining.len and written < buf.len) {
            const cp = std.unicode.utf16DecodeSurrogatePair(remaining[read..]) catch blk: {
                const value: u21 = remaining[read];
                read += 1;
                break :blk value;
            };
            if (cp > 0xffff) read += 2;

            var encoded: [4]u8 = undefined;
            const width = std.unicode.utf8Encode(cp, &encoded) catch
                std.unicode.utf8Encode(0xfffd, &encoded) catch unreachable;
            if (written + width > buf.len) {
                if (cp > 0xffff) read -= 2 else read -= 1;
                break;
            }
            @memcpy(buf[written..][0..width], encoded[0..width]);
            written += width;
        }

        if (written == 0) break;
        try writer.writeAll(buf[0..written]);
        remaining = remaining[read..];
    }
}

pub fn formatLatin1(slice: []const u8, writer: *std.Io.Writer) !void {
    var buf: [1024]u8 = undefined;
    var remaining = slice;

    while (remaining.len > 0) {
        var written: usize = 0;
        var read: usize = 0;
        while (read < remaining.len and written < buf.len) : (read += 1) {
            const byte = remaining[read];
            if (byte < 0x80) {
                buf[written] = byte;
                written += 1;
            } else {
                if (written + 2 > buf.len) break;
                buf[written] = 0xc0 | @as(u8, @intCast(byte >> 6));
                buf[written + 1] = 0x80 | (byte & 0x3f);
                written += 2;
            }
        }

        if (written == 0) break;
        try writer.writeAll(buf[0..written]);
        remaining = remaining[read..];
    }
}

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
