// Ported from bun/src/string/escapeRegExp.zig at pinned SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6.
//
// Wave-15 Tier-1 grinder copy. `jsEscapeRegExp` re-export omitted —
// JSC-bridge re-lands in Phase 12.2 (`packages/runtime/src/jsc/bun_string_jsc.zig`
// will provide it).

const special_characters = "|\\{}()[]^$+*?.-";

pub fn escapeRegExp(input: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var remain = input;

    while (strings.indexOfAny(remain, special_characters)) |i| {
        try writer.writeAll(remain[0..i]);
        switch (remain[i]) {
            '|',
            '\\',
            '{',
            '}',
            '(',
            ')',
            '[',
            ']',
            '^',
            '$',
            '+',
            '*',
            '?',
            '.',
            => |c| try writer.writeAll(&.{ '\\', c }),
            '-' => try writer.writeAll("\\x2d"),
            else => |c| {
                if (comptime Environment.isDebug) {
                    unreachable;
                }
                try writer.writeByte(c);
            },
        }
        remain = remain[i + 1 ..];
    }

    try writer.writeAll(remain);
}

/// '*' becomes '.*' instead of '\\*'
pub fn escapeRegExpForPackageNameMatching(input: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var remain = input;

    while (strings.indexOfAny(remain, special_characters)) |i| {
        try writer.writeAll(remain[0..i]);
        switch (remain[i]) {
            '|',
            '\\',
            '{',
            '}',
            '(',
            ')',
            '[',
            ']',
            '^',
            '$',
            '+',
            '?',
            '.',
            => |c| try writer.writeAll(&.{ '\\', c }),
            '*' => try writer.writeAll(".*"),
            '-' => try writer.writeAll("\\x2d"),
            else => |c| {
                if (comptime Environment.isDebug) {
                    unreachable;
                }
                try writer.writeByte(c);
            },
        }
        remain = remain[i + 1 ..];
    }

    try writer.writeAll(remain);
}

// JSC-bridge `jsEscapeRegExp` / `jsEscapeRegExpForPackageNameMatching`
// re-exports omitted — re-lands in Phase 12.2.

const std = @import("std");

const home_rt = @import("home");
const Environment = home_rt.Environment;
const strings = home_rt.strings;

test "escapeRegExp: escapes special characters" {
    var buf: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try escapeRegExp("hello.world", &stream);
    try std.testing.expectEqualStrings("hello\\.world", stream.buffered());
}

test "escapeRegExp: escapes hyphen to hex" {
    var buf: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try escapeRegExp("a-b", &stream);
    try std.testing.expectEqualStrings("a\\x2db", stream.buffered());
}

test "escapeRegExp: passthrough plain text" {
    var buf: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try escapeRegExp("abc123", &stream);
    try std.testing.expectEqualStrings("abc123", stream.buffered());
}

test "escapeRegExpForPackageNameMatching: turns * into .*" {
    var buf: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try escapeRegExpForPackageNameMatching("foo*bar", &stream);
    try std.testing.expectEqualStrings("foo.*bar", stream.buffered());
}
