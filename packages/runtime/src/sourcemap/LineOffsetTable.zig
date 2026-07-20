// Copied from bun/src/sourcemap/LineOffsetTable.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten:
//   `@import("bun")`  → `@import("home")`
//   `bun.assert`      → `home_rt.assert`
//   `bun.MultiArrayList` → `home_rt.collections.MultiArrayList`
//
// Local stubs (Home does not yet expose Bun's BabyList / Logger / the WTF-8
// string toolkit). All are surgical 1:1 replicas of the upstream symbol's
// shape — see comments at each stub.
//
// Behavior preserved verbatim from upstream: WTF-8 decoding, line-break
// recognition (\r, \n, \r\n, U+2028, U+2029), and the final flush after the
// last codepoint. Zig 0.17-dev removed the stdlib `stackFallback` helper used
// upstream, so Home keeps the same owned-slice behavior through the caller's
// allocator until a new stdlib stack fallback lands.

const LineOffsetTable = @This();

/// The source map specification is very loose and does not specify what
/// column numbers actually mean. The popular "source-map" library from Mozilla
/// appears to interpret them as counts of UTF-16 code units, so we generate
/// those too for compatibility.
///
/// We keep mapping tables around to accelerate conversion from byte offsets
/// to UTF-16 code unit counts. However, this mapping takes up a lot of memory
/// and takes up a lot of memory. Since most JavaScript is ASCII and the
/// mapping for ASCII is 1:1, we avoid creating a table for ASCII-only lines
/// as an optimization.
///
columns_for_non_ascii: BabyList(i32) = .{},
byte_offset_to_first_non_ascii: u32 = 0,
byte_offset_to_start_of_line: u32 = 0,

pub const List = MultiArrayList(LineOffsetTable);

pub fn findLine(byte_offsets_to_start_of_line: []const u32, loc: anytype) i32 {
    home_rt.assert(loc.start > -1); // checked by caller
    var original_line: usize = 0;
    const loc_start = @as(usize, @intCast(loc.start));

    {
        var count = @as(usize, @truncate(byte_offsets_to_start_of_line.len));
        var i: usize = 0;
        while (count > 0) {
            const step = count / 2;
            i = original_line + step;
            if (byte_offsets_to_start_of_line[i] <= loc_start) {
                original_line = i + 1;
                count = count - step - 1;
            } else {
                count = step;
            }
        }
    }

    return @as(i32, @intCast(original_line)) - 1;
}

pub fn findIndex(byte_offsets_to_start_of_line: []const u32, loc: Loc) ?usize {
    home_rt.assert(loc.start > -1); // checked by caller
    var original_line: usize = 0;
    const loc_start = @as(usize, @intCast(loc.start));

    var count = @as(usize, @truncate(byte_offsets_to_start_of_line.len));
    var i: usize = 0;
    while (count > 0) {
        const step = count / 2;
        i = original_line + step;
        const byte_offset = byte_offsets_to_start_of_line[i];
        if (byte_offset == loc_start) {
            return i;
        }
        if (i + 1 < byte_offsets_to_start_of_line.len) {
            const next_byte_offset = byte_offsets_to_start_of_line[i + 1];
            if (byte_offset < loc_start and loc_start < next_byte_offset) {
                return i;
            }
        }

        if (byte_offset < loc_start) {
            original_line = i + 1;
            count = count - step - 1;
        } else {
            count = step;
        }
    }

    return null;
}

pub fn generate(allocator: std.mem.Allocator, contents: []const u8, approximate_line_count: i32) List {
    var list = List{};
    // Preallocate the top-level table using the approximate line count from the lexer
    list.ensureUnusedCapacity(allocator, @as(usize, @intCast(@max(approximate_line_count, 1)))) catch unreachable;
    var column: i32 = 0;
    var byte_offset_to_first_non_ascii: u32 = 0;
    var column_byte_offset: u32 = 0;
    var line_byte_offset: u32 = 0;

    var columns_for_non_ascii = std.array_list.Managed(i32).initCapacity(allocator, 120) catch unreachable;

    var remaining = contents;
    while (remaining.len > 0) {
        const len_ = wtf8ByteSequenceLengthWithInvalid(remaining[0]);
        // `len_` is the lead byte's *declared* width; a source whose final bytes
        // are a truncated multi-byte sequence declares more bytes than remain,
        // so every slice below (decode, SIMD-skip offset, advance) must use the
        // clamped width to avoid an out-of-bounds read/slice.
        const cp_len = @min(@as(usize, len_), remaining.len);
        const c = if (len_ == 1) @as(i32, remaining[0]) else brk: {
            var cp_bytes: [4]u8 = .{ 0, 0, 0, 0 };
            @memcpy(cp_bytes[0..cp_len], remaining[0..cp_len]);
            break :brk decodeWTF8RuneT(&cp_bytes, len_, i32, 0);
        };

        if (column == 0) {
            line_byte_offset = @as(
                u32,
                @truncate(@intFromPtr(remaining.ptr) - @intFromPtr(contents.ptr)),
            );
        }

        if (c > 0x7F and columns_for_non_ascii.items.len == 0) {
            home_rt.assert(@intFromPtr(
                remaining.ptr,
            ) >= @intFromPtr(
                contents.ptr,
            ));
            // we have a non-ASCII character, so we need to keep track of the
            // mapping from byte offsets to UTF-16 code unit counts
            columns_for_non_ascii.appendAssumeCapacity(column);
            column_byte_offset = @as(
                u32,
                @intCast((@intFromPtr(
                    remaining.ptr,
                ) - @intFromPtr(
                    contents.ptr,
                )) - line_byte_offset),
            );
            byte_offset_to_first_non_ascii = column_byte_offset;
        }

        // Update the per-byte column offsets
        if (columns_for_non_ascii.items.len > 0) {
            const line_bytes_so_far = @as(u32, @intCast(@as(
                u32,
                @truncate(@intFromPtr(remaining.ptr) - @intFromPtr(contents.ptr)),
            ))) - line_byte_offset;
            columns_for_non_ascii.ensureUnusedCapacity((line_bytes_so_far - column_byte_offset) + 1) catch unreachable;
            while (column_byte_offset <= line_bytes_so_far) : (column_byte_offset += 1) {
                columns_for_non_ascii.appendAssumeCapacity(column);
            }
        } else {
            switch (c) {
                (@max('\r', '\n') + 1)...127 => {
                    // skip ahead to the next newline or non-ascii character
                    if (indexOfNewlineOrNonASCIICheckStart(remaining, @as(u32, @intCast(cp_len)), false)) |j| {
                        column += @as(i32, @intCast(j));
                        remaining = remaining[j..];
                    } else {
                        // if there are no more lines, we are done!
                        column += @as(i32, @intCast(remaining.len));
                        remaining = remaining[remaining.len..];
                    }

                    continue;
                },
                else => {},
            }
        }

        switch (c) {
            '\r', '\n', 0x2028, 0x2029 => {
                // windows newline
                if (c == '\r' and remaining.len > 1 and remaining[1] == '\n') {
                    column += 1;
                    remaining = remaining[1..];
                    continue;
                }

                // Dupe the per-line columns and KEEP columns_for_non_ascii's
                // capacity for the next line. (Upstream reuses a stack-fallback
                // buffer; calling toOwnedSlice() here — as a prior port did —
                // resets the list to capacity 0, so the next line's first
                // appendAssumeCapacity at items.len==0 panics on any file whose
                // 2nd+ line has non-ASCII content.)
                const owned = allocator.dupe(i32, columns_for_non_ascii.items) catch unreachable;
                columns_for_non_ascii.clearRetainingCapacity();

                list.append(allocator, .{
                    .byte_offset_to_start_of_line = line_byte_offset,
                    .byte_offset_to_first_non_ascii = byte_offset_to_first_non_ascii,
                    .columns_for_non_ascii = BabyList(i32).fromOwnedSlice(owned),
                }) catch unreachable;

                column = 0;
                byte_offset_to_first_non_ascii = 0;
                column_byte_offset = 0;
                line_byte_offset = 0;
            },
            else => {
                // Mozilla's "source-map" library counts columns using UTF-16 code units
                column += @as(i32, @intFromBool(c > 0xFFFF)) + 1;
            },
        }

        remaining = remaining[cp_len..];
    }

    // Mark the start of the next line
    if (column == 0) {
        line_byte_offset = @as(u32, @intCast(contents.len));
    }

    if (columns_for_non_ascii.items.len > 0) {
        const line_bytes_so_far = @as(u32, @intCast(contents.len)) - line_byte_offset;
        columns_for_non_ascii.ensureUnusedCapacity((line_bytes_so_far - column_byte_offset) + 1) catch unreachable;
        while (column_byte_offset <= line_bytes_so_far) : (column_byte_offset += 1) {
            columns_for_non_ascii.appendAssumeCapacity(column);
        }
    }
    {
        const owned = columns_for_non_ascii.toOwnedSlice() catch unreachable;
        list.append(allocator, .{
            .byte_offset_to_start_of_line = line_byte_offset,
            .byte_offset_to_first_non_ascii = byte_offset_to_first_non_ascii,
            .columns_for_non_ascii = BabyList(i32).fromOwnedSlice(owned),
        }) catch unreachable;
    }

    if (list.capacity > list.len) {
        list.shrinkAndFree(allocator, list.len);
    }
    return list;
}

const std = @import("std");
const home_rt = @import("home");
// Upstream spells this `bun.MultiArrayList`, which is a near-verbatim
// copy of `std.MultiArrayList` with two extra methods (`zero` + `memoryCost`).
// The ported home_rt copy at `collections/multi_array_list.zig` is not
// re-exported on the `home_rt` aggregator, and the public API used here
// (`ensureUnusedCapacity` / `append` / `shrinkAndFree` / `len` / `capacity` /
// `slice` / `items` / `deinit`) is identical to the std version, so we
// route through the stdlib directly until the aggregator surfaces it.
const MultiArrayList = std.MultiArrayList;

// ---- Local stubs ------------------------------------------------------
// `Loc` is a verbatim shape match for `bun.logger.Loc`. The full Logger
// substrate (Source, Log, MsgKind, Range, Comment, …) is far too heavy to
// pull in here; we copy just the `start: i32` field plus the trivial
// helpers `LineOffsetTable` callers spell.
const Loc = struct {
    start: i32 = -1,

    pub inline fn toNullable(loc: Loc) ?Loc {
        return if (loc.start == -1) null else loc;
    }

    pub inline fn eql(loc: Loc, other: Loc) bool {
        return loc.start == other.start;
    }
};

// `BabyList(i32)` is the upstream owned-pointer + u32-len-and-cap list type.
// LineOffsetTable only ever uses the default-init shape (`.{}`) and the
// `fromOwnedSlice` constructor; we surface only those + `slice()` so callers
// reading the table can iterate the columns.
fn BabyList(comptime T: type) type {
    return struct {
        const Self = @This();
        ptr: [*]T = undefined,
        len: u32 = 0,
        cap: u32 = 0,

        pub const empty: Self = .{};

        pub fn fromOwnedSlice(items: []T) Self {
            return .{
                .ptr = items.ptr,
                .len = @intCast(items.len),
                .cap = @intCast(items.len),
            };
        }

        pub fn slice(self: Self) []T {
            if (self.len == 0) return &.{};
            return self.ptr[0..self.len];
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.cap == 0) return;
            allocator.free(self.ptr[0..self.cap]);
            self.* = .{};
        }
    };
}

// ---- WTF-8 + scanner helpers ------------------------------------------
// Surgical copies from upstream `src/bun_core/string/immutable/unicode.zig`
// (wtf8ByteSequenceLengthWithInvalid, decodeWTF8RuneT, decodeWTF8RuneTMultibyte)
// and `src/string/immutable.zig` (indexOfNewlineOrNonASCIICheckStart). All
// land in `home_rt.strings` once the broader string toolkit ports — at which
// point these stubs can be deleted in favor of the canonical impls.
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

// Pure-Zig fallback for `bun.highway.indexOfNewlineOrNonASCII`. Highway is
// a C ABI extern that needs link-time wiring with the vendored Highway
// library; the unit tests for `LineOffsetTable` exercise this path but the
// test binary is not linked against Highway, so we walk the buffer in Zig.
// Once the Highway library lands in the test build, callers can swap back
// to `home_rt.highway.indexOfNewlineOrNonASCII` — semantics are identical
// (return the first index ≥ offset whose byte is non-ASCII or a newline,
// where "newline" matches the set tested by upstream Highway: `\r`, `\n`).
fn indexOfNewlineOrNonASCIICheckStart(slice_: []const u8, offset: u32, comptime check_start: bool) ?u32 {
    const slice = slice_[offset..];
    const remaining = slice;

    if (remaining.len == 0)
        return null;

    if (comptime check_start) {
        if (remaining[0] > 127 or (remaining[0] < 0x20 and remaining[0] != 0x09)) {
            return offset;
        }
    }

    for (remaining, 0..) |byte, i| {
        if (byte > 127 or byte == '\r' or byte == '\n') {
            return @as(u32, @truncate(i)) + offset;
        }
    }
    return null;
}

// ---- Tests ------------------------------------------------------------

test "LineOffsetTable.findLine binary-searches line boundaries" {
    const offsets = [_]u32{ 0, 10, 20, 35, 50 };
    try std.testing.expectEqual(@as(i32, 0), findLine(&offsets, .{ .start = 0 }));
    try std.testing.expectEqual(@as(i32, 0), findLine(&offsets, .{ .start = 5 }));
    try std.testing.expectEqual(@as(i32, 1), findLine(&offsets, .{ .start = 10 }));
    try std.testing.expectEqual(@as(i32, 1), findLine(&offsets, .{ .start = 15 }));
    try std.testing.expectEqual(@as(i32, 3), findLine(&offsets, .{ .start = 40 }));
    try std.testing.expectEqual(@as(i32, 4), findLine(&offsets, .{ .start = 999 }));
}

test "LineOffsetTable.findIndex returns enclosing-line index" {
    const offsets = [_]u32{ 0, 10, 20, 35, 50 };
    try std.testing.expectEqual(@as(?usize, 0), findIndex(&offsets, .{ .start = 0 }));
    try std.testing.expectEqual(@as(?usize, 0), findIndex(&offsets, .{ .start = 5 }));
    try std.testing.expectEqual(@as(?usize, 1), findIndex(&offsets, .{ .start = 10 }));
    try std.testing.expectEqual(@as(?usize, 2), findIndex(&offsets, .{ .start = 22 }));
    // An exact-equal byte offset maps back to its own line index.
    try std.testing.expectEqual(@as(?usize, 4), findIndex(&offsets, .{ .start = 50 }));
    // A start past the last line has no enclosing line in this table.
    try std.testing.expectEqual(@as(?usize, null), findIndex(&offsets, .{ .start = 9999 }));
}

test "LineOffsetTable.generate handles a pure-ASCII document" {
    const allocator = std.testing.allocator;
    var list = generate(allocator, "abc\ndef\nghi", 3);
    defer {
        var s = list.slice();
        for (s.items(.columns_for_non_ascii)) |*c| {
            var col_copy = c.*;
            col_copy.deinit(allocator);
        }
        list.deinit(allocator);
    }
    // 2 newlines (each emits an entry) + 1 final flush = 3 entries.
    try std.testing.expectEqual(@as(usize, 3), list.len);
    const starts = list.slice().items(.byte_offset_to_start_of_line);
    try std.testing.expectEqual(@as(u32, 0), starts[0]);
    try std.testing.expectEqual(@as(u32, 4), starts[1]);
    try std.testing.expectEqual(@as(u32, 8), starts[2]);
    // ASCII-only input must never allocate a per-line columns table.
    for (list.slice().items(.columns_for_non_ascii)) |c| {
        try std.testing.expectEqual(@as(u32, 0), c.len);
    }
}

test "LineOffsetTable.generate populates columns_for_non_ascii for unicode lines" {
    const allocator = std.testing.allocator;
    // "a" + U+00E9 ("é", 2 bytes) + "b\n" then a plain ASCII line.
    var list = generate(allocator, "a\xC3\xA9b\nfoo", 2);
    defer {
        var s = list.slice();
        for (s.items(.columns_for_non_ascii)) |*c| {
            var col_copy = c.*;
            col_copy.deinit(allocator);
        }
        list.deinit(allocator);
    }
    try std.testing.expect(list.len >= 2);
    const s = list.slice();
    const first_first_non_ascii = s.items(.byte_offset_to_first_non_ascii)[0];
    // Byte offset 1 is where "é" starts on the first line.
    try std.testing.expectEqual(@as(u32, 1), first_first_non_ascii);
    // The first line should have a populated columns_for_non_ascii table.
    try std.testing.expect(s.items(.columns_for_non_ascii)[0].len > 0);
}
