//! Decode raw JavaScript literal contents for semantic type identities.
const std = @import("std");

pub fn appendCookedStringText(
    allocator: std.mem.Allocator,
    raw: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\r') {
            try out.append(allocator, '\n');
            i += if (i + 1 < raw.len and raw[i + 1] == '\n') 2 else 1;
            continue;
        }
        if (c != '\\') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (i + 1 >= raw.len) {
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        const esc = raw[i + 1];
        i += 2;
        switch (esc) {
            '0' => try out.append(allocator, 0),
            'b' => try out.append(allocator, 0x08),
            'f' => try out.append(allocator, 0x0c),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'v' => try out.append(allocator, 0x0b),
            '\n' => {},
            '\r' => {
                if (i < raw.len and raw[i] == '\n') i += 1;
            },
            'x' => {
                if (i + 1 < raw.len) {
                    if (hexValue(raw[i])) |hi| {
                        if (hexValue(raw[i + 1])) |lo| {
                            try appendJsStringCodePoint(allocator, out, (hi << 4) | lo);
                            i += 2;
                            continue;
                        }
                    }
                }
                try out.appendSlice(allocator, "\\x");
            },
            'u' => {
                if (try appendUnicodeEscape(allocator, raw, &i, out)) continue;
                try out.appendSlice(allocator, "\\u");
            },
            else => try out.append(allocator, esc),
        }
    }
}

fn appendUnicodeEscape(
    allocator: std.mem.Allocator,
    raw: []const u8,
    index: *usize,
    out: *std.ArrayListUnmanaged(u8),
) error{OutOfMemory}!bool {
    const first = parseJsUnicodeEscape(raw, index.*) orelse return false;
    var cp = first.code_point;
    var end = first.end;
    if (isHighSurrogate(cp) and end + 2 <= raw.len and raw[end] == '\\' and raw[end + 1] == 'u') {
        if (parseJsUnicodeEscape(raw, end + 2)) |second| {
            if (isLowSurrogate(second.code_point)) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (second.code_point - 0xdc00);
                end = second.end;
            }
        }
    }
    try appendJsStringCodePoint(allocator, out, cp);
    index.* = end;
    return true;
}

const ParsedJsUnicodeEscape = struct {
    code_point: u21,
    end: usize,
};

fn parseJsUnicodeEscape(raw: []const u8, start: usize) ?ParsedJsUnicodeEscape {
    if (start < raw.len and raw[start] == '{') {
        var j = start + 1;
        var cp: u21 = 0;
        var saw_digit = false;
        while (j < raw.len and raw[j] != '}') : (j += 1) {
            const value = hexValue(raw[j]) orelse return null;
            saw_digit = true;
            const next = (@as(u32, cp) << 4) | value;
            if (next > 0x10ffff) return null;
            cp = @intCast(next);
        }
        if (!saw_digit or j >= raw.len or raw[j] != '}') return null;
        return .{ .code_point = cp, .end = j + 1 };
    }
    if (start + 3 >= raw.len) return null;
    var cp: u21 = 0;
    var j = start;
    while (j < start + 4) : (j += 1) {
        const value = hexValue(raw[j]) orelse return null;
        cp = @intCast((@as(u32, cp) << 4) | value);
    }
    return .{ .code_point = cp, .end = start + 4 };
}

pub fn appendJsStringCodePoint(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    cp: u21,
) error{OutOfMemory}!void {
    if (isHighSurrogate(cp) or isLowSurrogate(cp)) {
        const value: u16 = @intCast(cp);
        const cesu = [_]u8{
            0xe0 | @as(u8, @intCast(value >> 12)),
            0x80 | @as(u8, @intCast((value >> 6) & 0x3f)),
            0x80 | @as(u8, @intCast(value & 0x3f)),
        };
        try out.appendSlice(allocator, &cesu);
        return;
    }
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &encoded) catch return;
    try out.appendSlice(allocator, encoded[0..len]);
}

fn isHighSurrogate(cp: u21) bool {
    return cp >= 0xd800 and cp <= 0xdbff;
}

fn isLowSurrogate(cp: u21) bool {
    return cp >= 0xdc00 and cp <= 0xdfff;
}

fn hexValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

const T = std.testing;

test "string literal: raw escapes produce semantic Unicode text" {
    const Case = struct { raw: []const u8, value: []const u8 };
    for ([_]Case{
        .{ .raw = "a\\nb", .value = "a\nb" }, // newline
        .{ .raw = "\\x6f\\x6b", .value = "ok" }, // hex-ascii
        .{ .raw = "\\xE9", .value = "é" }, // hex-latin1
        .{ .raw = "\\u{1F600}", .value = "😀" }, // unicode-codepoint
        .{ .raw = "\\uD83D\\uDE00", .value = "😀" }, // surrogate-pair
        .{ .raw = "\\uD800", .value = "\xed\xa0\x80" }, // lone-surrogate
        .{ .raw = "a\r\nb", .value = "a\nb" }, // crlf
        .{ .raw = "a\\\r\nb", .value = "ab" }, // continued-line
        .{ .raw = "\\\\n", .value = "\\n" }, // escaped-backslash
    }) |case| {
        var output: std.ArrayListUnmanaged(u8) = .empty;
        defer output.deinit(T.allocator);
        try appendCookedStringText(T.allocator, case.raw, &output);
        try T.expectEqualStrings(case.value, output.items);
    }
}

test "string literal: partial decoding releases allocations on failure" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var output: std.ArrayListUnmanaged(u8) = .empty;
            defer output.deinit(allocator);
            try appendCookedStringText(allocator, "prefix\\n\\u{1F600}\\xE9", &output);
            try T.expectEqualStrings("prefix\n😀é", output.items);
        }
    };
    try T.checkAllAllocationFailures(T.allocator, Probe.run, .{});
}
