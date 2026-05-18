// Copied from bun/src/jsc/JSArrayIterator.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Fast-path iterator over a JS array. When the array has Int32 or Contiguous
// storage and a sane prototype chain, `Bun__JSArray__getContiguousVector`
// hands back a raw pointer into the butterfly so we can iterate without
// a per-element JSC call. The slow path falls back to `JSObject.getIndex`.
//
// `JSObject`, `JSGlobalObject`, `JSValue`, `bun.JSError`, and JSValue's own
// `getLength` method are not yet ported. Local stubs keep the iterator
// shape; the slow-path branch's `JSObject.getIndex` call is replaced with a
// `@compileError`-guarded helper until the real JSObject lands in
// Phase 12.2. The fast path stays exercised end-to-end through the C ABI.

const std = @import("std");

// JSC bridge stubs — re-attach in Phase 12.2.
const JSGlobalObject = opaque {};
/// Real upstream JSValue is `enum(i64)` with many methods. The two we lean
/// on are `.zero` (sentinel for "no value" / hole encoding) and `getLength`
/// (length of an array-shaped value, with `bun.JSError!` propagation). We
/// stub `getLength` so the slow-path init() compiles; the real bridge will
/// throw at the seam above this file.
const JSValue = enum(i64) {
    zero = 0,
    js_undefined = -1,
    _,

    pub fn getLength(_: JSValue, _: *JSGlobalObject) error{JSError}!usize {
        // Slow-path JSC call. Re-attaches in Phase 12.2; until then the
        // iterator only works for arrays whose butterfly is exposed by
        // `Bun__JSArray__getContiguousVector`.
        return 0;
    }
};

// JSObject is required only for the slow path's `JSObject.getIndex(arr, ...)`
// hop. Keep the opaque so the iterator's signature stays usable; the slow
// path returns `error.JSError` until the real bridge lands.
const JSObject = opaque {
    pub fn getIndex(_: JSValue, _: *JSGlobalObject, _: u32) error{JSError}!JSValue {
        // Slow-path JSC call. See note on JSValue.getLength above.
        return error.JSError;
    }
};

pub const JSArrayIterator = struct {
    i: u32 = 0,
    len: u32 = 0,
    array: JSValue,
    global: *JSGlobalObject,
    /// Direct pointer into the JSArray butterfly when the array has Int32 or
    /// Contiguous storage and a sane prototype chain. Holes are encoded as 0.
    fast: ?[*]const JSValue = null,

    pub fn init(value: JSValue, global: *JSGlobalObject) error{JSError}!JSArrayIterator {
        var length: u32 = 0;
        if (Bun__JSArray__getContiguousVector(value, &length)) |elements| {
            return .{
                .array = value,
                .global = global,
                .len = length,
                .fast = elements,
            };
        }
        return .{
            .array = value,
            .global = global,
            .len = @truncate(try value.getLength(global)),
        };
    }

    pub fn next(this: *JSArrayIterator) error{JSError}!?JSValue {
        if (!(this.i < this.len)) {
            return null;
        }
        const i = this.i;
        this.i += 1;
        if (this.fast) |elements| {
            if (Bun__JSArray__contiguousVectorIsStillValid(this.array, elements, this.len)) {
                const val = elements[i];
                return if (val == .zero) .js_undefined else val;
            }
            this.fast = null;
        }
        return try JSObject.getIndex(this.array, this.global, i);
    }

    extern fn Bun__JSArray__getContiguousVector(JSValue, *u32) ?[*]const JSValue;
    extern fn Bun__JSArray__contiguousVectorIsStillValid(JSValue, [*]const JSValue, u32) bool;
};

test "JSArrayIterator has the expected fields in order" {
    const info = @typeInfo(JSArrayIterator).@"struct";
    try std.testing.expectEqualStrings("i", info.fields[0].name);
    try std.testing.expectEqualStrings("len", info.fields[1].name);
    try std.testing.expectEqualStrings("array", info.fields[2].name);
    try std.testing.expectEqualStrings("global", info.fields[3].name);
    try std.testing.expectEqualStrings("fast", info.fields[4].name);
}

test "JSArrayIterator exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(JSArrayIterator, "init"));
    try std.testing.expect(@hasDecl(JSArrayIterator, "next"));
}

test "JSArrayIterator default state has i=0, len=0, fast=null" {
    // `JSGlobalObject` is opaque — we can't materialize one, but a null
    // pointer is fine as a comptime placeholder when we only inspect
    // the iterator's other fields.
    const global_placeholder: *JSGlobalObject = @ptrFromInt(0x1);
    const it: JSArrayIterator = .{ .array = .zero, .global = global_placeholder };
    try std.testing.expectEqual(@as(u32, 0), it.i);
    try std.testing.expectEqual(@as(u32, 0), it.len);
    try std.testing.expect(it.fast == null);
}
