// Copied from bun/src/jsc/ZigString.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `ZigString` is the on-the-wire ABI used across the C++/Zig boundary: a
// tagged `[*]const u8` pointer plus a length. The bits we keep in this leaf
// are the pure-Zig data shape + the tag-bit primitives every other ported
// header already names (`is16Bit`, `isUTF8`, `markUTF8`, `markUTF16`,
// `markGlobal`, `markStatic`, `untagged`, etc.) — these are pointer-bit
// arithmetic with no JSC dependencies.
//
// Omitted until the JSC bridge re-attaches in Phase 12.2:
//   - `toJS`, `toJSONObject`, `toURL`, `toExternalValue*`, `to16BitValue`,
//     `toErrorInstance` / `toTypeErrorInstance` / `toDOMExceptionInstance` /
//     `toRangeErrorInstance` / `toSyntaxErrorInstance` / `toAtomicValue`,
//     `toJSStringRef`, `dupeForJS` — every one of these needs `JSValue`,
//     `JSGlobalObject`, or the `bun.cpp.ZigString__*` C++ shims.
//   - `eql`, `eqlCaseInsensitive`, `toSlice*`, `toOwnedSlice*`, `format`,
//     `byteLength` helpers, `withEncoding`, the sort helpers — these all
//     reach into `bun.strings` SIMD utilities and `bun.fmt` that aren't yet
//     wired into `home_rt`.
//   - The `ZigString__free` / `ZigString__freeGlobal` exports — they reach
//     into `bun.mimalloc`'s heap probes which aren't ported.
//
// The pure-Zig `Slice` and `StringPointer` carriers come along verbatim;
// `Slice` references `NullableAllocator` (already in `home_rt.ptr`).

const std = @import("std");
const home_rt = @import("home_rt");

/// Local copy of `bun.NullableAllocator` (`upstream/src/bun_alloc/NullableAllocator.zig`).
/// The upstream version also calls into `bun.String.isWTFAllocator` to bypass
/// `std.mem.Allocator.free`'s undefined-byte poisoning when the WTF allocator
/// owns the memory; we skip that branch until `bun.String` lands and instead
/// route through `std.mem.Allocator.free` unconditionally.
const NullableAllocator = struct {
    ptr: *anyopaque = undefined,
    // Utilize the null pointer optimization on the vtable instead of
    // the regular `ptr` because `ptr` may be undefined.
    vtable: ?*const std.mem.Allocator.VTable = null,

    pub inline fn init(allocator: ?std.mem.Allocator) NullableAllocator {
        return if (allocator) |a| .{ .ptr = a.ptr, .vtable = a.vtable } else .{};
    }

    pub inline fn isNull(this: NullableAllocator) bool {
        return this.vtable == null;
    }

    pub inline fn get(this: NullableAllocator) ?std.mem.Allocator {
        return if (this.vtable) |vt| std.mem.Allocator{ .ptr = this.ptr, .vtable = vt } else null;
    }

    pub fn free(this: *const NullableAllocator, bytes: []const u8) void {
        if (this.get()) |allocator| allocator.free(bytes);
    }

    comptime {
        if (@sizeOf(NullableAllocator) != @sizeOf(std.mem.Allocator)) {
            @compileError("Expected the sizes to be the same.");
        }
    }
};

/// On-wire string handoff between C++ and Zig.
///
/// `_unsafe_ptr_do_not_use` carries metadata in its top 4 bits:
///   - bit 63 ─ UTF-16 payload (16-bit code units)
///   - bit 62 ─ globally allocated (free with `bun.default_allocator`)
///   - bit 61 ─ UTF-8 payload (vs. Latin-1, which is the default)
///   - bit 60 ─ static / read-only payload
///
/// `untagged()` strips the metadata before any read.
pub const ZigString = extern struct {
    /// This can be a UTF-16, Latin1, or UTF-8 string.
    /// The pointer itself is tagged, so it cannot be used without untagging it first.
    /// Accessing it directly is unsafe.
    _unsafe_ptr_do_not_use: [*]const u8,
    len: usize,

    pub const ByteString = union(enum) {
        latin1: []const u8,
        utf16: []const u16,
    };

    pub const Empty = ZigString{ ._unsafe_ptr_do_not_use = "", .len = 0 };

    pub inline fn init(slice_: []const u8) ZigString {
        return ZigString{ ._unsafe_ptr_do_not_use = slice_.ptr, .len = slice_.len };
    }

    pub fn initUTF8(slice_: []const u8) ZigString {
        var out = init(slice_);
        out.markUTF8();
        return out;
    }

    pub fn initUTF16(items: []const u16) ZigString {
        var out = ZigString{ ._unsafe_ptr_do_not_use = @ptrCast(items.ptr), .len = items.len };
        out.markUTF16();
        return out;
    }

    pub fn from16Slice(slice_: []const u16) ZigString {
        return from16(slice_.ptr, slice_.len);
    }

    fn from16SliceMaybeGlobal(slice_: []const u16, global: bool) ZigString {
        var str = init(@as([*]const u8, @ptrCast(@alignCast(slice_.ptr)))[0..slice_.len]);
        str.markUTF16();
        if (global) {
            str.markGlobal();
        }
        return str;
    }

    /// Globally-allocated memory only.
    pub fn from16(slice_: [*]const u16, len: usize) ZigString {
        var str = init(@as([*]const u8, @ptrCast(slice_))[0..len]);
        str.markUTF16();
        str.markGlobal();
        return str;
    }

    pub fn static(comptime slice_: [:0]const u8) *const ZigString {
        const Holder = struct {
            const null_terminated_ascii_literal = slice_;
            pub const value = &ZigString{
                ._unsafe_ptr_do_not_use = null_terminated_ascii_literal.ptr,
                .len = null_terminated_ascii_literal.len,
            };
        };
        return Holder.value;
    }

    pub inline fn isEmpty(this: *const ZigString) bool {
        return this.len == 0;
    }

    pub inline fn length(this: ZigString) usize {
        return this.len;
    }

    pub fn trunc(this: ZigString, len: usize) ZigString {
        return .{ ._unsafe_ptr_do_not_use = this._unsafe_ptr_do_not_use, .len = @min(len, this.len) };
    }

    pub inline fn untagged(ptr: [*]const u8) [*]const u8 {
        // this can be null ptr, so long as it's also a 0 length string
        @setRuntimeSafety(false);
        return @as([*]const u8, @ptrFromInt(@as(u53, @truncate(@intFromPtr(ptr)))));
    }

    pub inline fn as(this: ZigString) ByteString {
        return if (this.is16Bit())
            .{ .utf16 = this.utf16SliceAligned() }
        else
            .{ .latin1 = this.slice() };
    }

    pub inline fn is16Bit(this: *const ZigString) bool {
        return (@intFromPtr(this._unsafe_ptr_do_not_use) & (1 << 63)) != 0;
    }

    pub inline fn isGloballyAllocated(this: ZigString) bool {
        return (@intFromPtr(this._unsafe_ptr_do_not_use) & (1 << 62)) != 0;
    }

    pub fn isUTF8(this: ZigString) bool {
        return (@intFromPtr(this._unsafe_ptr_do_not_use) & (1 << 61)) != 0;
    }

    pub fn isStatic(this: *const ZigString) bool {
        return @intFromPtr(this._unsafe_ptr_do_not_use) & (1 << 60) != 0;
    }

    pub fn markUTF8(this: *ZigString) void {
        this._unsafe_ptr_do_not_use = @as(
            [*]const u8,
            @ptrFromInt(@intFromPtr(this._unsafe_ptr_do_not_use) | (1 << 61)),
        );
    }

    pub fn markUTF16(this: *ZigString) void {
        this._unsafe_ptr_do_not_use = @as(
            [*]const u8,
            @ptrFromInt(@intFromPtr(this._unsafe_ptr_do_not_use) | (1 << 63)),
        );
    }

    pub inline fn markGlobal(this: *ZigString) void {
        this._unsafe_ptr_do_not_use = @as(
            [*]const u8,
            @ptrFromInt(@intFromPtr(this._unsafe_ptr_do_not_use) | (1 << 62)),
        );
    }

    pub fn markStatic(this: *ZigString) void {
        this._unsafe_ptr_do_not_use = @as(
            [*]const u8,
            @ptrFromInt(@intFromPtr(this._unsafe_ptr_do_not_use) | (1 << 60)),
        );
    }

    pub fn slice(this: *const ZigString) []const u8 {
        return untagged(this._unsafe_ptr_do_not_use)[0..@min(this.len, std.math.maxInt(u32))];
    }

    pub inline fn utf16Slice(this: *const ZigString) []align(1) const u16 {
        return @as([*]align(1) const u16, @ptrCast(untagged(this._unsafe_ptr_do_not_use)))[0..this.len];
    }

    pub inline fn utf16SliceAligned(this: *const ZigString) []const u16 {
        return @as([*]const u16, @ptrCast(@alignCast(untagged(this._unsafe_ptr_do_not_use))))[0..this.len];
    }

    pub fn byteSlice(this: ZigString) []const u8 {
        if (this.is16Bit()) {
            return std.mem.sliceAsBytes(this.utf16SliceAligned());
        }
        return this.slice();
    }

    /// Materialize this ZigString as a UTF-8 `Slice`. For Latin-1
    /// / UTF-8 contents the inner bytes are borrowed (no allocation,
    /// no free); for UTF-16 contents the code units are converted
    /// via `home_rt.strings.toUTF8Alloc` and the resulting buffer is
    /// owned by the returned Slice. Mirrors `bun.ZigString.toSlice`.
    /// On OOM during the UTF-16 path, returns `Slice.empty` so call
    /// sites read the same shape (caller checks `.length()` first).
    pub fn toSlice(this: ZigString, allocator: std.mem.Allocator) Slice {
        if (this.is16Bit()) {
            const utf16 = this.utf16SliceAligned();
            const owned = home_rt.strings.toUTF8Alloc(allocator, utf16) catch return Slice.empty;
            return Slice.init(allocator, owned);
        }
        return Slice.fromUTF8NeverFree(this.slice());
    }

    /// Compare this ZigString against a comptime byte literal. Returns
    /// true iff the lengths match and every code unit equals the
    /// corresponding byte. For UTF-16 strings the comparison is
    /// per-code-unit, so high code points (>= 0x80) only match if
    /// the comptime side spells them as the same raw byte — typical
    /// usage is ASCII-only comparison against keywords (`"length"`,
    /// `"undefined"`, etc.). Mirrors `bun.ZigString.eqlComptime`.
    pub fn eqlComptime(this: ZigString, comptime value: []const u8) bool {
        if (this.len != value.len) return false;
        if (this.is16Bit()) {
            const utf16 = this.utf16SliceAligned();
            inline for (value, 0..) |v, idx| {
                if (utf16[idx] != v) return false;
            }
            return true;
        }
        return std.mem.eql(u8, this.slice(), value);
    }

    pub inline fn full(this: *const ZigString) []const u8 {
        return untagged(this._unsafe_ptr_do_not_use)[0..this.len];
    }

    pub fn substringWithLen(this: ZigString, start_index: usize, end_index: usize) ZigString {
        if (this.is16Bit()) {
            return ZigString.from16SliceMaybeGlobal(
                this.utf16SliceAligned()[start_index..end_index],
                this.isGloballyAllocated(),
            );
        }

        var out = ZigString.init(this.slice()[start_index..end_index]);
        if (this.isUTF8()) {
            out.markUTF8();
        }

        if (this.isGloballyAllocated()) {
            out.markGlobal();
        }

        return out;
    }

    pub fn substring(this: ZigString, start_index: usize) ZigString {
        return this.substringWithLen(@min(this.len, start_index), this.len);
    }

    pub fn hasPrefixChar(this: ZigString, char: u8) bool {
        if (this.len == 0)
            return false;

        if (this.is16Bit()) {
            return this.utf16SliceAligned()[0] == char;
        }

        return this.slice()[0] == char;
    }

    pub fn maxUTF8ByteLength(this: ZigString) usize {
        if (this.isUTF8())
            return this.len;

        if (this.is16Bit()) {
            return this.utf16SliceAligned().len * 3;
        }

        // latin1
        return this.len * 2;
    }

    pub fn charAt(this: ZigString, offset: usize) u8 {
        if (this.is16Bit()) {
            return @as(u8, @truncate(this.utf16SliceAligned()[offset]));
        }

        return this.slice()[offset];
    }

    /// `(offset, length)` pair into a backing buffer. Used by the symbol /
    /// snapshot tables.
    pub const StringPointer = struct {
        offset: usize = 0,
        length: usize = 0,
    };

    pub fn fromStringPointer(ptr: ZigString.StringPointer, buf: []const u8, to: *ZigString) void {
        to.* = ZigString{
            .len = ptr.length,
            ._unsafe_ptr_do_not_use = buf[ptr.offset..][0..ptr.length].ptr,
        };
    }

    pub const Slice = struct {
        allocator: NullableAllocator = .{},
        ptr: [*]const u8 = &.{},
        len: u32 = 0,

        pub const empty = Slice{ .ptr = "", .len = 0 };

        pub fn init(allocator: std.mem.Allocator, input: []const u8) Slice {
            return .{
                .ptr = input.ptr,
                .len = @as(u32, @truncate(input.len)),
                .allocator = NullableAllocator.init(allocator),
            };
        }

        pub fn fromUTF8NeverFree(input: []const u8) Slice {
            return .{
                .ptr = input.ptr,
                .len = @as(u32, @truncate(input.len)),
                .allocator = .{},
            };
        }

        pub fn byteLength(this: *const Slice) usize {
            return this.len;
        }

        pub inline fn length(this: Slice) usize {
            return this.len;
        }

        pub inline fn isAllocated(this: Slice) bool {
            return !this.allocator.isNull();
        }

        pub fn slice(this: *const Slice) []const u8 {
            return this.ptr[0..this.len];
        }

        pub const byteSlice = Slice.slice;

        pub fn mut(this: Slice) []u8 {
            return @constCast(this.ptr)[0..this.len];
        }

        /// Does nothing if the slice is not allocated.
        pub fn deinit(this: *const Slice) void {
            this.allocator.free(this.slice());
        }
    };
};

// Re-export at file level for callers that import `StringPointer` directly.
pub const StringPointer = ZigString.StringPointer;

test "ZigString.init / slice round-trip" {
    const z = ZigString.init("hello");
    try std.testing.expectEqualStrings("hello", z.slice());
    try std.testing.expectEqual(@as(usize, 5), z.length());
    try std.testing.expect(!z.is16Bit());
    try std.testing.expect(!z.isUTF8());
    try std.testing.expect(!z.isGloballyAllocated());
}

test "ZigString tag bit setters are idempotent" {
    var z = ZigString.init("x");
    try std.testing.expect(!z.isUTF8());
    z.markUTF8();
    try std.testing.expect(z.isUTF8());
    z.markUTF8();
    try std.testing.expect(z.isUTF8());

    try std.testing.expect(!z.isGloballyAllocated());
    z.markGlobal();
    try std.testing.expect(z.isGloballyAllocated());
}

test "ZigString.untagged strips top-4 metadata bits" {
    var z = ZigString.init("abc");
    z.markUTF8();
    z.markGlobal();
    z.markStatic();
    // Bit 63 is set by `markUTF16` only — we left it alone, so the underlying
    // payload bits should not include it. Just check that `slice()` returns
    // the same payload as the borrow we constructed from.
    try std.testing.expectEqualStrings("abc", z.slice());
}

test "ZigString.static produces a borrow with the right length" {
    const s = ZigString.static("hello");
    try std.testing.expectEqual(@as(usize, 5), s.length());
    try std.testing.expectEqualStrings("hello", s.slice());
}

test "ZigString.charAt / hasPrefixChar on latin1" {
    const z = ZigString.init("home");
    try std.testing.expectEqual(@as(u8, 'h'), z.charAt(0));
    try std.testing.expectEqual(@as(u8, 'e'), z.charAt(3));
    try std.testing.expect(z.hasPrefixChar('h'));
    try std.testing.expect(!z.hasPrefixChar('H'));
}

test "ZigString.substring and trunc preserve tag bits" {
    var z = ZigString.init("home-runtime");
    z.markUTF8();
    z.markGlobal();
    const sub = z.substringWithLen(0, 4);
    try std.testing.expectEqualStrings("home", sub.slice());
    try std.testing.expect(sub.isUTF8());
    try std.testing.expect(sub.isGloballyAllocated());

    const t = z.trunc(2);
    try std.testing.expectEqual(@as(usize, 2), t.length());
}

test "ZigString.maxUTF8ByteLength upper bounds the bytes" {
    var z = ZigString.init("abc");
    try std.testing.expectEqual(@as(usize, 6), z.maxUTF8ByteLength()); // latin1 → ×2
    z.markUTF8();
    try std.testing.expectEqual(@as(usize, 3), z.maxUTF8ByteLength());
}

test "ZigString.fromStringPointer reads from a backing buffer" {
    const buf = "hello-world";
    var out: ZigString = undefined;
    ZigString.fromStringPointer(.{ .offset = 6, .length = 5 }, buf, &out);
    try std.testing.expectEqualStrings("world", out.slice());
}

test "ZigString.toSlice borrows for Latin-1 (no allocation)" {
    const z = ZigString.init("hello");
    const slice = z.toSlice(std.testing.allocator);
    defer slice.deinit();
    try std.testing.expectEqualStrings("hello", slice.slice());
    try std.testing.expect(!slice.isAllocated());
}

test "ZigString.toSlice allocates for UTF-16" {
    const utf16: []const u16 = &.{ 'h', 'i', 0x4E2D }; // "hi中"
    const z = ZigString.initUTF16(utf16);
    const slice = z.toSlice(std.testing.allocator);
    defer slice.deinit();
    // 中 (U+4E2D) is 3 bytes in UTF-8.
    try std.testing.expectEqualStrings("hi\xE4\xB8\xAD", slice.slice());
    try std.testing.expect(slice.isAllocated());
}

test "ZigString.eqlComptime: Latin-1 path matches and rejects by length" {
    const z = ZigString.init("length");
    try std.testing.expect(z.eqlComptime("length"));
    try std.testing.expect(!z.eqlComptime("lengths"));
    try std.testing.expect(!z.eqlComptime("Length"));
}

test "ZigString.eqlComptime: UTF-16 path checks per code unit" {
    const utf16: []const u16 = &.{ 'a', 'b', 'c' };
    const z = ZigString.initUTF16(utf16);
    try std.testing.expect(z.eqlComptime("abc"));
    try std.testing.expect(!z.eqlComptime("ab"));
    try std.testing.expect(!z.eqlComptime("abd"));
}

test "ZigString.Slice round-trip + deinit no-op for borrows" {
    const s = ZigString.Slice.fromUTF8NeverFree("hi");
    try std.testing.expectEqualStrings("hi", s.slice());
    try std.testing.expect(!s.isAllocated());
    s.deinit(); // no-op — allocator is null
}

comptime {
    _ = home_rt;
}
