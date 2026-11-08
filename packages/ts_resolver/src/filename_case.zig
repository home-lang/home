//! Compiler-host filename identity. This intentionally uses simple Unicode
//! casing, without normalization, full-string expansions or final sigma rules.
const std = @import("std");
const data = @import("filename_case_data.zig");

fn mapped(point: u21, upper: bool) u21 {
    if (point < 0x80) return if (upper) std.ascii.toUpper(@intCast(point)) else std.ascii.toLower(@intCast(point));
    var start: usize = 0;
    var end: usize = data.ranges.len;
    while (start < end) {
        const middle = start + (end - start) / 2;
        const range = data.ranges[middle];
        if (point < range.lo) {
            end = middle;
        } else if (point > range.hi) {
            start = middle + 1;
        } else {
            if (range.alternating) return range.lo + ((point - range.lo) & ~@as(u21, 1)) + @as(u21, if (upper) 0 else 1);
            return @intCast(@as(i32, point) + if (upper) range.upper else range.lower);
        }
    }
    return point;
}

fn fileNameLower(point: u21) u21 {
    // U+0130 and its lowercase spelling can coexist in TypeScript's host
    // keyspace. This exception belongs to filenames, not Unicode casing.
    return if (point == 0x130) point else mapped(point, false);
}

const Points = struct {
    bytes: []const u8,
    index: usize = 0,

    fn next(self: *Points) ?u21 {
        if (self.index == self.bytes.len) return null;
        const begin = self.index;
        self.index += 1;
        const length = std.unicode.utf8ByteSequenceLength(self.bytes[begin]) catch return 0xfffd;
        if (length > self.bytes.len - begin) return 0xfffd;
        const point = std.unicode.utf8Decode(self.bytes[begin..][0..length]) catch return 0xfffd;
        self.index = begin + length;
        return point;
    }
};

/// The native host probes its executable under the opposite simple case.
/// Unlike filename keys, this uses ordinary simple lowercase for U+0130.
pub fn swapCaseInto(path: []const u8, buffer: []u8) error{BufferTooSmall}![]const u8 {
    var points = Points{ .bytes = path };
    var length: usize = 0;
    while (points.next()) |point| {
        const upper = mapped(point, true);
        const swapped = if (upper == point) mapped(point, false) else upper;
        var bytes: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(swapped, &bytes) catch unreachable;
        if (count > buffer.len - length) return error.BufferTooSmall;
        @memcpy(buffer[length..][0..count], bytes[0..count]);
        length += count;
    }
    return buffer[0..length];
}

/// Allocation-free hash/equality for managed filename maps. Stored keys remain
/// authored paths; only their lookup identity follows the fixed host policy.
pub const Context = struct {
    case_sensitive: bool,

    pub fn hash(self: Context, path: []const u8) u64 {
        if (self.case_sensitive) return std.hash.Wyhash.hash(0, path);
        var hasher = std.hash.Wyhash.init(0);
        var points = Points{ .bytes = path };
        var bytes: [4]u8 = undefined;
        while (points.next()) |point| {
            const length = std.unicode.utf8Encode(fileNameLower(point), &bytes) catch unreachable;
            hasher.update(bytes[0..length]);
        }
        return hasher.final();
    }

    pub fn eql(self: Context, first: []const u8, second: []const u8) bool {
        if (self.case_sensitive) return std.mem.eql(u8, first, second);
        var a = Points{ .bytes = first };
        var b = Points{ .bytes = second };
        while (a.next()) |point| {
            const other = b.next() orelse return false;
            if (fileNameLower(point) != fileNameLower(other)) return false;
        }
        return b.next() == null;
    }
};

test "filename identity uses simple Unicode casing and matching hashes" {
    const insensitive = Context{ .case_sensitive = false };
    const sensitive = Context{ .case_sensitive = true };
    for ([_][2][]const u8{
        .{ "/Foo.ts", "/foo.ts" },
        .{ "/ΟΣ.ts", "/οσ.ts" },
        .{ "/K.ts", "/k.ts" },
        .{ "/𐐀.ts", "/𐐨.ts" },
        .{ "/ẞ.ts", "/ß.ts" },
        .{ "/İ.ts", "/i̇.ts" },
        .{ "/\xff.ts", "/�.ts" },
    }) |pair| {
        try std.testing.expect(insensitive.eql(pair[0], pair[1]));
        try std.testing.expectEqual(insensitive.hash(pair[0]), insensitive.hash(pair[1]));
        try std.testing.expect(!sensitive.eql(pair[0], pair[1]));
    }
    for ([_][2][]const u8{
        .{ "/İ.ts", "/i.ts" },
        .{ "/İ.ts", "/i̇.ts" },
        .{ "/ß.ts", "/ss.ts" },
        .{ "/ΟΣ.ts", "/ος.ts" },
        .{ "/é.ts", "/é.ts" },
    }) |pair| try std.testing.expect(!insensitive.eql(pair[0], pair[1]));
}

test "native executable case swapping uses simple Unicode and bounded storage" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/REPO/σk𐐨iIßß.TS", try swapCaseInto("/repo/ΣK𐐀İıẞß.ts", &buffer));
    try std.testing.expectEqualStrings("/���/tOOL", try swapCaseInto("/\xed\xa0\x80/Tool", &buffer));
    try std.testing.expectError(error.BufferTooSmall, swapCaseInto("abc", buffer[0..2]));
    try std.testing.expectEqualStrings("", try swapCaseInto("", buffer[0..0]));
}
