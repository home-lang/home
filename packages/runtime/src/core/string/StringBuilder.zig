// Copied from bun/src/string/StringBuilder.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Imports rewritten: @import("bun") → home_rt-style locals. The pure-Zig
// `string.StringBuilder` is a `{len, cap, ptr}` triple — a two-phase buffer
// builder that callers (notably `http.HeaderBuilder`) `count(...)` into to
// total up the needed capacity, then `allocate(...)` once, then `append(...)`
// without bounds checks.
//
// **Surface deltas (parked methods):**
//
//   * `count16` / `count16Z` / `append16` (UTF-16 in / UTF-8 out) park.
//     Upstream calls `bun.simdutf.length.utf8.from.utf16.le(slice)` and
//     `bun.simdutf.convert.utf16.to.utf8.with_errors.le(slice, buf)`; the
//     `home_rt.simdutf_sys` surface today only exposes the raw `simdutf__*`
//     externs, not the dotted helper namespaces. Reattach when the
//     `bun.simdutf` wrapper lands.
//   * `appendStr` (takes `bun.String`) parks. `bun.String` is the C ABI
//     `{tag, _padding, impl}` triple gated on `BunString__toUTF8`; not yet
//     ported.
//
// Everything else is verbatim. `bun.copy(u8, dst, src)` collapses to
// `@memcpy(dst[0..src.len], src)` — that's all upstream does for u8.
// `bun.StringPointer` is the canonical `{offset: u32, length: u32}` extern
// struct (from `bun/src/options_types/schema.zig:832`); we inline it here so
// the file has zero home_rt depends. Callers (HeaderBuilder, etc.) can either
// use this `StringPointer` directly or substitute their own structurally-
// identical type.
//
// `Environment.allow_assert` reads from `home_rt.Environment` (already
// wired). `assert` is `std.debug.assert`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const home_rt = @import("home");
const Environment = home_rt.Environment;
const assert = std.debug.assert;

const StringBuilder = @This();

/// `(offset, length)` pair into a backing buffer. Matches the canonical
/// `bun.StringPointer` extern struct shape — kept extern so callers using
/// the JSON-codec layout (`schema.api.StringPointer`) can interchange.
pub const StringPointer = extern struct {
    offset: u32 = 0,
    length: u32 = 0,
};

len: usize = 0,
cap: usize = 0,
ptr: ?[*]u8 = null,

pub fn initCapacity(
    allocator: std.mem.Allocator,
    cap: usize,
) Allocator.Error!StringBuilder {
    return StringBuilder{
        .cap = cap,
        .len = 0,
        .ptr = (try allocator.alloc(u8, cap)).ptr,
    };
}

pub fn countZ(this: *StringBuilder, slice: []const u8) void {
    this.cap += slice.len + 1;
}

pub fn count(this: *StringBuilder, slice: []const u8) void {
    this.cap += slice.len;
}

pub fn allocate(this: *StringBuilder, allocator: Allocator) Allocator.Error!void {
    const slice = try allocator.alloc(u8, this.cap);
    this.ptr = slice.ptr;
    this.len = 0;
}

pub fn deinit(this: *StringBuilder, allocator: Allocator) void {
    if (this.ptr == null or this.cap == 0) return;
    allocator.free(this.ptr.?[0..this.cap]);
}

// `count16` / `count16Z` / `append16` parked — see file header.

pub fn appendZ(this: *StringBuilder, slice: []const u8) [:0]const u8 {
    if (comptime Environment.allow_assert) {
        assert(this.len + 1 <= this.cap); // didn't count everything
        assert(this.ptr != null); // must call allocate first
    }

    @memcpy(this.ptr.?[this.len..][0..slice.len], slice);
    this.ptr.?[this.len + slice.len] = 0;
    const result = this.ptr.?[this.len..this.cap][0..slice.len :0];
    this.len += slice.len + 1;

    if (comptime Environment.allow_assert) assert(this.len <= this.cap);

    return result;
}

// `appendStr` (bun.String → []u8) parked — see file header.

pub fn append(this: *StringBuilder, slice: []const u8) []const u8 {
    if (comptime Environment.allow_assert) {
        assert(this.len <= this.cap); // didn't count everything
        assert(this.ptr != null); // must call allocate first
    }

    @memcpy(this.ptr.?[this.len..][0..slice.len], slice);
    const result = this.ptr.?[this.len..this.cap][0..slice.len];
    this.len += slice.len;

    if (comptime Environment.allow_assert) assert(this.len <= this.cap);

    return result;
}

pub fn addConcat(this: *StringBuilder, slices: []const []const u8) StringPointer {
    var remain = this.allocatedSlice()[this.len..];
    var len: usize = 0;
    for (slices) |slice| {
        @memcpy(remain[0..slice.len], slice);
        remain = remain[slice.len..];
        len += slice.len;
    }
    return this.add(len);
}

pub fn add(this: *StringBuilder, len: usize) StringPointer {
    if (comptime Environment.allow_assert) {
        assert(this.len <= this.cap); // didn't count everything
        assert(this.ptr != null); // must call allocate first
    }

    const start = this.len;
    this.len += len;

    if (comptime Environment.allow_assert) assert(this.len <= this.cap);

    return StringPointer{ .offset = @as(u32, @truncate(start)), .length = @as(u32, @truncate(len)) };
}
pub fn appendCount(this: *StringBuilder, slice: []const u8) StringPointer {
    if (comptime Environment.allow_assert) {
        assert(this.len <= this.cap); // didn't count everything
        assert(this.ptr != null); // must call allocate first
    }

    const start = this.len;
    @memcpy(this.ptr.?[this.len..][0..slice.len], slice);
    this.len += slice.len;

    if (comptime Environment.allow_assert) assert(this.len <= this.cap);

    return StringPointer{ .offset = @as(u32, @truncate(start)), .length = @as(u32, @truncate(slice.len)) };
}

pub fn appendCountZ(this: *StringBuilder, slice: []const u8) StringPointer {
    if (comptime Environment.allow_assert) {
        assert(this.len <= this.cap); // didn't count everything
        assert(this.ptr != null); // must call allocate first
    }

    const start = this.len;
    @memcpy(this.ptr.?[this.len..][0..slice.len], slice);
    this.ptr.?[this.len + slice.len] = 0;
    this.len += slice.len;
    this.len += 1;

    if (comptime Environment.allow_assert) assert(this.len <= this.cap);

    return StringPointer{ .offset = @as(u32, @truncate(start)), .length = @as(u32, @truncate(slice.len)) };
}

pub fn fmt(this: *StringBuilder, comptime str: []const u8, args: anytype) []const u8 {
    if (comptime Environment.allow_assert) {
        assert(this.len <= this.cap); // didn't count everything
        assert(this.ptr != null); // must call allocate first
    }

    const buf = this.ptr.?[this.len..this.cap];
    const out = std.fmt.bufPrint(buf, str, args) catch unreachable;
    this.len += out.len;

    if (comptime Environment.allow_assert) assert(this.len <= this.cap);

    return out;
}

pub fn fmtAppendCount(this: *StringBuilder, comptime str: []const u8, args: anytype) StringPointer {
    if (comptime Environment.allow_assert) {
        assert(this.len <= this.cap); // didn't count everything
        assert(this.ptr != null); // must call allocate first
    }

    const buf = this.ptr.?[this.len..this.cap];
    const out = std.fmt.bufPrint(buf, str, args) catch unreachable;
    const off = this.len;
    this.len += out.len;

    if (comptime Environment.allow_assert) assert(this.len <= this.cap);

    return StringPointer{
        .offset = @as(u32, @truncate(off)),
        .length = @as(u32, @truncate(out.len)),
    };
}

pub fn fmtAppendCountZ(this: *StringBuilder, comptime str: []const u8, args: anytype) StringPointer {
    if (comptime Environment.allow_assert) {
        assert(this.len <= this.cap); // didn't count everything
        assert(this.ptr != null); // must call allocate first
    }

    const buf = this.ptr.?[this.len..this.cap];
    const out = std.fmt.bufPrintSentinel(buf, str, args, 0) catch unreachable;
    const off = this.len;
    this.len += out.len;
    this.len += 1;

    if (comptime Environment.allow_assert) assert(this.len <= this.cap);

    return StringPointer{
        .offset = @as(u32, @truncate(off)),
        .length = @as(u32, @truncate(out.len)),
    };
}

pub fn fmtCount(this: *StringBuilder, comptime str: []const u8, args: anytype) void {
    this.cap += std.fmt.count(str, args);
}

pub fn allocatedSlice(this: *StringBuilder) []u8 {
    const ptr = this.ptr orelse return &[_]u8{};
    if (comptime Environment.allow_assert) {
        assert(this.cap > 0);
    }
    return ptr[0..this.cap];
}

pub fn writable(this: *StringBuilder) []u8 {
    const ptr = this.ptr orelse return &[_]u8{};
    if (comptime Environment.allow_assert) {
        assert(this.cap > 0);
    }
    return ptr[this.len..this.cap];
}

/// Transfer ownership of the underlying memory to a slice.
///
/// After calling this, you are responsible for freeing the underlying memory.
/// This StringBuilder should not be used after calling this function.
pub fn moveToSlice(this: *StringBuilder, into_slice: *[]u8) void {
    into_slice.* = this.allocatedSlice();
    this.* = .{};
}

test "StringBuilder counts then allocates then appends without overflow" {
    var b = StringBuilder{};
    b.count("hello, ");
    b.count("world");
    try std.testing.expectEqual(@as(usize, 12), b.cap);
    try std.testing.expectEqual(@as(usize, 0), b.len);

    try b.allocate(std.testing.allocator);
    defer b.deinit(std.testing.allocator);

    const first = b.append("hello, ");
    try std.testing.expectEqualStrings("hello, ", first);
    const second = b.append("world");
    try std.testing.expectEqualStrings("world", second);

    try std.testing.expectEqual(@as(usize, 12), b.len);
    try std.testing.expectEqualStrings("hello, world", b.allocatedSlice());
}

test "StringBuilder.appendCount returns (offset, length) pointers" {
    var b = StringBuilder{};
    b.count("abc");
    b.count("defg");

    try b.allocate(std.testing.allocator);
    defer b.deinit(std.testing.allocator);

    const first = b.appendCount("abc");
    try std.testing.expectEqual(@as(u32, 0), first.offset);
    try std.testing.expectEqual(@as(u32, 3), first.length);

    const second = b.appendCount("defg");
    try std.testing.expectEqual(@as(u32, 3), second.offset);
    try std.testing.expectEqual(@as(u32, 4), second.length);
}

test "StringBuilder.fmt writes formatted bytes into the buffer" {
    var b = StringBuilder{};
    b.fmtCount("{d}={s}", .{ 42, "answer" });

    try b.allocate(std.testing.allocator);
    defer b.deinit(std.testing.allocator);

    const out = b.fmt("{d}={s}", .{ 42, "answer" });
    try std.testing.expectEqualStrings("42=answer", out);
}
