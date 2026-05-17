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
