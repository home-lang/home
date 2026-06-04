// Home Runtime - ported from Bun.
// Upstream:  /Users/chrisbreuer/Code/bun/src/ast/char_freq.zig
// Pinned SHA: fd0b6f1a271fca0b8124b69f230b100f4d636af6
//
// Renames/adaptations:
//   - `@import("bun")` -> `@import("home")`
//   - `bun.assert` -> `home_rt.assert`
//   - `js_ast.CharFreq` -> local `@This()`
//   - `js_ast.NameMinifier` -> local pure-data copy from
//     `src/js_parser/js_parser.zig` so this AST leaf does not pull in the
//     parser/logger-wide AST graph.
//   - Dropped the `Class = G.Class` re-export; that depends on `g.zig`.

pub const char_freq_count = 64;

pub const CharAndCount = struct {
    char: u8 = 0,
    count: i32 = 0,
    index: usize = 0,

    pub const Array = [char_freq_count]CharAndCount;

    pub fn lessThan(_: void, a: CharAndCount, b: CharAndCount) bool {
        if (a.count != b.count) {
            return a.count > b.count;
        }

        if (a.index != b.index) {
            return a.index < b.index;
        }

        return a.char < b.char;
    }
};

pub const NameMinifier = struct {
    head: std.array_list.Managed(u8),
    tail: std.array_list.Managed(u8),

    pub const default_head = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$";
    pub const default_tail = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$";

    pub fn init(allocator: std.mem.Allocator) NameMinifier {
        return .{
            .head = std.array_list.Managed(u8).init(allocator),
            .tail = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(this: *NameMinifier) void {
        this.head.deinit();
        this.tail.deinit();
    }

    pub fn numberToMinifiedName(this: *NameMinifier, name: *std.array_list.Managed(u8), _i: isize) !void {
        name.clearRetainingCapacity();
        var i = _i;
        var j = @as(usize, @intCast(@mod(i, 54)));
        try name.appendSlice(this.head.items[j .. j + 1]);
        i = @divFloor(i, 54);

        while (i > 0) {
            i -= 1;
            j = @as(usize, @intCast(@mod(i, char_freq_count)));
            try name.appendSlice(this.tail.items[j .. j + 1]);
            i = @divFloor(i, char_freq_count);
        }
    }

    pub fn defaultNumberToMinifiedName(allocator: std.mem.Allocator, _i: isize) ![]const u8 {
        var i = _i;
        var j = @as(usize, @intCast(@mod(i, 54)));
        var name = std.array_list.Managed(u8).init(allocator);
        try name.appendSlice(default_head[j .. j + 1]);
        i = @divFloor(i, 54);

        while (i > 0) {
            i -= 1;
            j = @as(usize, @intCast(@mod(i, char_freq_count)));
            try name.appendSlice(default_tail[j .. j + 1]);
            i = @divFloor(i, char_freq_count);
        }

        return name.items;
    }
};

const Buffer = [char_freq_count]i32;

freqs: Buffer align(1) = undefined,

const scan_big_chunk_size = 32;

pub fn initEmpty() CharFreq {
    return .{ .freqs = @splat(0) };
}

pub fn scan(this: *CharFreq, text: []const u8, delta: i32) void {
    if (delta == 0)
        return;

    if (text.len < scan_big_chunk_size) {
        scanSmall(&this.freqs, text, delta);
    } else {
        scanBig(&this.freqs, text, delta);
    }
}

fn scanBig(out: *align(1) Buffer, text: []const u8, delta: i32) void {
    var freqs = out.*;
    defer out.* = freqs;
    var deltas: [256]i32 = @splat(0);
    var remain = text;

    home_rt.assert(remain.len >= scan_big_chunk_size);

    const unrolled = remain.len - (remain.len % scan_big_chunk_size);
    var unrolled_index: usize = 0;
    remain = remain[unrolled..];

    while (unrolled_index < unrolled) : (unrolled_index += scan_big_chunk_size) {
        const chunk = text[unrolled_index..][0..scan_big_chunk_size].*;
        inline for (0..scan_big_chunk_size) |i| {
            deltas[@as(usize, chunk[i])] += delta;
        }
    }

    for (remain) |c| {
        deltas[@as(usize, c)] += delta;
    }

    freqs[0..26].* = deltas['a' .. 'a' + 26].*;
    freqs[26 .. 26 * 2].* = deltas['A' .. 'A' + 26].*;
    freqs[26 * 2 .. 62].* = deltas['0' .. '0' + 10].*;
    freqs[62] = deltas['_'];
    freqs[63] = deltas['$'];
}

fn scanSmall(out: *align(1) Buffer, text: []const u8, delta: i32) void {
    var freqs: [char_freq_count]i32 = out.*;
    defer out.* = freqs;

    for (text) |c| {
        const i: usize = switch (c) {
            'a'...'z' => @as(usize, @intCast(c)) - 'a',
            'A'...'Z' => @as(usize, @intCast(c)) - ('A' - 26),
            '0'...'9' => @as(usize, @intCast(c)) + (52 - '0'),
            '_' => 62,
            '$' => 63,
            else => continue,
        };
        freqs[i] += delta;
    }
}

pub fn include(this: *CharFreq, other: CharFreq) void {
    const left: @Vector(char_freq_count, i32) = this.freqs;
    const right: @Vector(char_freq_count, i32) = other.freqs;

    this.freqs = left + right;
}

pub fn compile(this: *const CharFreq, allocator: std.mem.Allocator) NameMinifier {
    const array: CharAndCount.Array = brk: {
        var _array: CharAndCount.Array = undefined;

        for (&_array, NameMinifier.default_tail, this.freqs, 0..) |*dest, char, freq, i| {
            dest.* = CharAndCount{
                .char = char,
                .index = i,
                .count = freq,
            };
        }

        std.sort.pdq(CharAndCount, &_array, {}, CharAndCount.lessThan);

        break :brk _array;
    };

    var minifier = NameMinifier.init(allocator);
    minifier.head.ensureTotalCapacityPrecise(NameMinifier.default_head.len) catch unreachable;
    minifier.tail.ensureTotalCapacityPrecise(NameMinifier.default_tail.len) catch unreachable;
    for (array) |item| {
        if (item.char < '0' or item.char > '9') {
            minifier.head.append(item.char) catch unreachable;
        }
        minifier.tail.append(item.char) catch unreachable;
    }

    return minifier;
}

const CharFreq = @This();

const std = @import("std");
const home_rt = @import("home");

test "CharFreq.scan counts identifier characters" {
    var freq = CharFreq.initEmpty();

    freq.scan("azAZ09_$.-", 1);

    try std.testing.expectEqual(@as(i32, 1), freq.freqs[0]);
    try std.testing.expectEqual(@as(i32, 1), freq.freqs[25]);
    try std.testing.expectEqual(@as(i32, 1), freq.freqs[26]);
    try std.testing.expectEqual(@as(i32, 1), freq.freqs[51]);
    try std.testing.expectEqual(@as(i32, 1), freq.freqs[52]);
    try std.testing.expectEqual(@as(i32, 1), freq.freqs[61]);
    try std.testing.expectEqual(@as(i32, 1), freq.freqs[62]);
    try std.testing.expectEqual(@as(i32, 1), freq.freqs[63]);
}

test "CharFreq.include adds frequency buffers" {
    var left = CharFreq.initEmpty();
    var right = CharFreq.initEmpty();

    left.scan("aaB", 1);
    right.scan("aB$", 1);
    left.include(right);

    try std.testing.expectEqual(@as(i32, 3), left.freqs[0]);
    try std.testing.expectEqual(@as(i32, 2), left.freqs[27]);
    try std.testing.expectEqual(@as(i32, 1), left.freqs[63]);
}

test "CharFreq.compile orders frequent characters first" {
    const allocator = std.testing.allocator;
    var freq = CharFreq.initEmpty();
    freq.scan("zzzzzaaB", 1);

    var minifier = freq.compile(allocator);
    defer minifier.deinit();

    try std.testing.expectEqualStrings("z", minifier.head.items[0..1]);
    try std.testing.expectEqualStrings("z", minifier.tail.items[0..1]);

    var name = std.array_list.Managed(u8).init(allocator);
    defer name.deinit();
    try minifier.numberToMinifiedName(&name, 0);
    try std.testing.expectEqualStrings("z", name.items);
}
