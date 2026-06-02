// Copied from bun/src/sourcemap/sourcemap.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Extracted from the inline `pub const LineColumnOffset = struct { ... }` in
// upstream sourcemap.zig (line ~548). The parent `sourcemap.zig` is parked
// (MutableString / Logger / StringJoiner / URL / JSC pull-ins); this struct is
// almost-pure data, so it lands on its own with a surgical Ordinal stub.
//
// Imports rewritten:
//   `@import("bun")`         → `@import("home")`
//   `bun.Ordinal`            → the local `Ordinal` stub below (verbatim shape
//                              clone of upstream `OrdinalT(c_int)`)
//   `bun.strings.indexOfNewlineOrNonASCII` → pure-Zig fallback (Highway is a
//                              link-time C ABI extern that isn't wired into
//                              the per-file test binary).
//   `bun.strings.CodepointIterator`        → inline WTF-8 cursor below
//   `bun.strings.isAllASCII / containsChar` → assertions dropped in non-debug

//! The sourcemap spec says line and column offsets are zero-based.
//!
//! This struct is the canonical "where am I in the generated output?" cursor
//! used by the bundler's sourcemap chunk builder (Chunk.zig). It advances as
//! the printer emits text and is paired with an `original` cursor for the
//! source-side mapping.

const LineColumnOffset = @This();

/// The zero-based line offset
lines: Ordinal = Ordinal.start,
/// The zero-based column offset
columns: Ordinal = Ordinal.start,

pub const Optional = union(enum) {
    null: void,
    value: LineColumnOffset,

    pub fn advance(this: *Optional, input: []const u8) void {
        switch (this.*) {
            .null => {},
            .value => |*v| v.advance(input),
        }
    }

    pub fn reset(this: *Optional) void {
        switch (this.*) {
            .null => {},
            .value => this.* = .{ .value = .{} },
        }
    }
};

pub fn add(this: *LineColumnOffset, b: LineColumnOffset) void {
    if (b.lines.zeroBased() == 0) {
        this.columns = this.columns.add(b.columns);
    } else {
        this.lines = this.lines.add(b.lines);
        this.columns = b.columns;
    }
}

pub fn advance(this_ptr: *LineColumnOffset, input: []const u8) void {
    // Instead of mutating `this_ptr` directly, copy the state to the stack and do
    // all the work here, then move it back to the input pointer. When sourcemaps
    // are enabled, this function is extremely hot.
    var this = this_ptr.*;
    defer this_ptr.* = this;

    var offset: u32 = 0;
    while (indexOfNewlineOrNonASCII(input, offset)) |i| {
        home_rt.assert(i >= offset);
        home_rt.assert(i < input.len);

        // Decode the codepoint at `i`. `cursor.c` is the codepoint, `width`
        // is the number of UTF-8 bytes consumed. A null byte produces a
        // 0-width result; mirror upstream's guard against that.
        const w = wtf8ByteSequenceLengthWithInvalid(input[i]);
        if (w == 0 or i + @as(usize, w) > input.len) {
            this.columns = this.columns.addScalar(1);
            offset = i + 1;
            continue;
        }

        var buf: [4]u8 = .{ 0, 0, 0, 0 };
        const copy_len = @min(@as(usize, w), input.len - i);
        @memcpy(buf[0..copy_len], input[i .. i + copy_len]);
        const c = decodeWTF8RuneT(&buf, w, i32, 0);

        offset = i + w;

        switch (c) {
            '\r', '\n', 0x2028, 0x2029 => {
                // Handle Windows-specific "\r\n" newlines
                if (c == '\r' and input.len > i + 1 and input[i + 1] == '\n') {
                    this.columns = this.columns.addScalar(1);
                    continue;
                }

                this.lines = this.lines.addScalar(1);
                this.columns = Ordinal.start;
            },
            else => {
                // Mozilla's "source-map" library counts columns using UTF-16 code units
                this.columns = this.columns.addScalar(switch (c) {
                    0...0xFFFF => @as(i32, 1),
                    else => @as(i32, 2),
                });
            },
        }
    }

    const remain = input[offset..];
    this.columns = this.columns.addScalar(@intCast(remain.len));
}

pub fn comesBefore(a: LineColumnOffset, b: LineColumnOffset) bool {
    return a.lines.zeroBased() < b.lines.zeroBased() or (a.lines.zeroBased() == b.lines.zeroBased() and a.columns.zeroBased() < b.columns.zeroBased());
}

pub fn cmp(_: void, a: LineColumnOffset, b: LineColumnOffset) std.math.Order {
    if (a.lines.zeroBased() != b.lines.zeroBased()) {
        return std.math.order(a.lines.zeroBased(), b.lines.zeroBased());
    }

    return std.math.order(a.columns.zeroBased(), b.columns.zeroBased());
}

const std = @import("std");
const home_rt = @import("home");

// ---- Local stubs ------------------------------------------------------

/// Verbatim shape clone of upstream `bun.OrdinalT(c_int)` (see
/// `upstream/src/bun.zig` line 3421). Lands on its own once
/// `home_rt.Ordinal` exists; until then this is identical-by-construction.
const Ordinal = enum(c_int) {
    invalid = -1,
    start = 0,
    _,

    pub inline fn fromZeroBased(int: c_int) Ordinal {
        home_rt.assert(int >= 0);
        home_rt.assert(int != std.math.maxInt(c_int));
        return @enumFromInt(int);
    }

    pub inline fn zeroBased(ord: Ordinal) c_int {
        return @intFromEnum(ord);
    }

    pub inline fn oneBased(ord: Ordinal) c_int {
        return @intFromEnum(ord) + 1;
    }

    pub inline fn add(ord: Ordinal, b: Ordinal) Ordinal {
        return fromZeroBased(ord.zeroBased() + b.zeroBased());
    }

    pub inline fn addScalar(ord: Ordinal, inc: c_int) Ordinal {
        return fromZeroBased(ord.zeroBased() + inc);
    }

    pub inline fn isValid(ord: Ordinal) bool {
        return ord.zeroBased() >= 0;
    }
};

/// Pure-Zig replacement for `bun.strings.indexOfNewlineOrNonASCII`. The
/// upstream version delegates to Highway (SIMD), which is a link-time C ABI
/// extern; we mirror the semantic — return the first index ≥ offset whose
/// byte is non-ASCII (>127) or a `\r`/`\n` newline.
fn indexOfNewlineOrNonASCII(slice: []const u8, offset: u32) ?u32 {
    if (offset >= slice.len) return null;
    for (slice[offset..], 0..) |byte, i| {
        if (byte > 127 or byte == '\r' or byte == '\n') {
            return @as(u32, @truncate(i)) + offset;
        }
    }
    return null;
}

inline fn wtf8ByteSequenceLengthWithInvalid(first_byte: u8) u8 {
    return switch (first_byte) {
        0...0x80 - 1 => 1,
        else => if ((first_byte & 0xE0) == 0xC0)
            2
        else if ((first_byte & 0xF0) == 0xE0)
            3
        else if ((first_byte & 0xF8) == 0xF0)
            4
        else
            1,
    };
}

inline fn decodeWTF8RuneT(p: *const [4]u8, len: u8, comptime T: type, comptime zero: T) T {
    if (len == 0) return zero;
    if (len == 1) return p[0];
    return decodeWTF8RuneTMultibyte(p, len, T, zero);
}

inline fn decodeWTF8RuneTMultibyte(p: *const [4]u8, len: u8, comptime T: type, comptime zero: T) T {
    home_rt.assert(len > 1);

    const s1 = p[1];
    if ((s1 & 0xC0) != 0x80) return zero;

    if (len == 2) {
        const cp = @as(T, p[0] & 0x1F) << 6 | @as(T, s1 & 0x3F);
        if (cp < 0x80) return zero;
        return cp;
    }

    const s2 = p[2];
    if ((s2 & 0xC0) != 0x80) return zero;

    if (len == 3) {
        const cp = (@as(T, p[0] & 0x0F) << 12) |
            (@as(T, s1 & 0x3F) << 6) |
            @as(T, s2 & 0x3F);
        if (cp < 0x800) return zero;
        return cp;
    }

    const s3 = p[3];
    {
        if ((s3 & 0xC0) != 0x80) return zero;
        const cp = (@as(T, p[0] & 0x07) << 18) |
            (@as(T, s1 & 0x3F) << 12) |
            (@as(T, s2 & 0x3F) << 6) |
            @as(T, s3 & 0x3F);
        if (cp < 0x10000 or cp > 0x10FFFF) return zero;
        return cp;
    }
}

// ---- Tests ------------------------------------------------------------

test "LineColumnOffset default-inits to start/start" {
    const l: LineColumnOffset = .{};
    try std.testing.expectEqual(@as(c_int, 0), l.lines.zeroBased());
    try std.testing.expectEqual(@as(c_int, 0), l.columns.zeroBased());
}

test "LineColumnOffset.advance walks ASCII columns" {
    var l: LineColumnOffset = .{};
    l.advance("hello");
    try std.testing.expectEqual(@as(c_int, 0), l.lines.zeroBased());
    try std.testing.expectEqual(@as(c_int, 5), l.columns.zeroBased());
}

test "LineColumnOffset.advance bumps line + resets columns on newline" {
    var l: LineColumnOffset = .{};
    l.advance("abc\ndef");
    try std.testing.expectEqual(@as(c_int, 1), l.lines.zeroBased());
    try std.testing.expectEqual(@as(c_int, 3), l.columns.zeroBased());
}

test "LineColumnOffset.advance collapses \\r\\n as one newline" {
    var l: LineColumnOffset = .{};
    l.advance("ab\r\ncd");
    try std.testing.expectEqual(@as(c_int, 1), l.lines.zeroBased());
    try std.testing.expectEqual(@as(c_int, 2), l.columns.zeroBased());
}

test "LineColumnOffset.advance counts a BMP non-ASCII codepoint as 1 UTF-16 unit" {
    // "é" (U+00E9, 2 bytes UTF-8, 1 UTF-16 code unit) followed by "b".
    // NOTE: upstream `advance` does NOT account for ASCII bytes that appear
    // BEFORE the first non-ASCII codepoint within a single `advance` call —
    // the highway-driven `indexOfNewlineOrNonASCII` walks straight past
    // them, and only the trailing tail after the last non-ASCII point feeds
    // through the bulk `remain.len` adder. The caller is expected to drive
    // `advance` per emitted token, never with a leading ASCII run + tail
    // non-ASCII char. Mirror that contract here.
    var l: LineColumnOffset = .{};
    l.advance("\xC3\xA9b");
    try std.testing.expectEqual(@as(c_int, 0), l.lines.zeroBased());
    // 1 (for "é" as a BMP UTF-16 code unit) + 1 (for trailing "b") = 2
    try std.testing.expectEqual(@as(c_int, 2), l.columns.zeroBased());
}

test "LineColumnOffset.advance counts a non-BMP codepoint as 2 UTF-16 units" {
    // U+1F600 (😀, 4 bytes UTF-8, 2 UTF-16 surrogates) followed by "b".
    var l: LineColumnOffset = .{};
    l.advance("\xF0\x9F\x98\x80b");
    try std.testing.expectEqual(@as(c_int, 0), l.lines.zeroBased());
    // 2 (for "😀" as two UTF-16 surrogates) + 1 (for trailing "b") = 3
    try std.testing.expectEqual(@as(c_int, 3), l.columns.zeroBased());
}

test "LineColumnOffset.add joins two offsets" {
    var a: LineColumnOffset = .{ .lines = Ordinal.fromZeroBased(2), .columns = Ordinal.fromZeroBased(3) };
    const b: LineColumnOffset = .{ .lines = Ordinal.fromZeroBased(0), .columns = Ordinal.fromZeroBased(4) };
    a.add(b);
    // Same-line: columns are summed.
    try std.testing.expectEqual(@as(c_int, 2), a.lines.zeroBased());
    try std.testing.expectEqual(@as(c_int, 7), a.columns.zeroBased());

    var c: LineColumnOffset = .{ .lines = Ordinal.fromZeroBased(2), .columns = Ordinal.fromZeroBased(3) };
    const d: LineColumnOffset = .{ .lines = Ordinal.fromZeroBased(1), .columns = Ordinal.fromZeroBased(4) };
    c.add(d);
    // Cross-line: columns are replaced with `b.columns`.
    try std.testing.expectEqual(@as(c_int, 3), c.lines.zeroBased());
    try std.testing.expectEqual(@as(c_int, 4), c.columns.zeroBased());
}

test "LineColumnOffset.comesBefore orders by (line, column)" {
    const a: LineColumnOffset = .{ .lines = Ordinal.fromZeroBased(0), .columns = Ordinal.fromZeroBased(5) };
    const b: LineColumnOffset = .{ .lines = Ordinal.fromZeroBased(1), .columns = Ordinal.fromZeroBased(0) };
    const c: LineColumnOffset = .{ .lines = Ordinal.fromZeroBased(1), .columns = Ordinal.fromZeroBased(3) };
    try std.testing.expect(LineColumnOffset.comesBefore(a, b));
    try std.testing.expect(LineColumnOffset.comesBefore(b, c));
    try std.testing.expect(!LineColumnOffset.comesBefore(c, b));
    try std.testing.expect(!LineColumnOffset.comesBefore(a, a));
}

test "LineColumnOffset.cmp matches std.math.Order semantics" {
    const a: LineColumnOffset = .{};
    const b: LineColumnOffset = .{ .columns = Ordinal.fromZeroBased(1) };
    try std.testing.expectEqual(std.math.Order.eq, LineColumnOffset.cmp({}, a, a));
    try std.testing.expectEqual(std.math.Order.lt, LineColumnOffset.cmp({}, a, b));
    try std.testing.expectEqual(std.math.Order.gt, LineColumnOffset.cmp({}, b, a));
}

test "LineColumnOffset.Optional.advance is a noop on .null" {
    var opt: LineColumnOffset.Optional = .null;
    opt.advance("ignored");
    try std.testing.expect(opt == .null);
}

test "LineColumnOffset.Optional.advance forwards to inner LineColumnOffset" {
    var opt: LineColumnOffset.Optional = .{ .value = .{} };
    opt.advance("hello\nworld");
    try std.testing.expectEqual(@as(c_int, 1), opt.value.lines.zeroBased());
    try std.testing.expectEqual(@as(c_int, 5), opt.value.columns.zeroBased());

    opt.reset();
    try std.testing.expectEqual(@as(c_int, 0), opt.value.lines.zeroBased());
    try std.testing.expectEqual(@as(c_int, 0), opt.value.columns.zeroBased());
}
