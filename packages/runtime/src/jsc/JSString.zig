// Copied from bun/src/jsc/JSString.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC-bridge wrappers around `JSC::JSString*`. `JSGlobalObject`, `JSValue`,
// `JSObject`, `ZigString`, and `bun.JSError` are not yet ported; we stub them
// locally so the public surface stays usable. The real JSC types re-attach in
// Phase 12.2.
//
// `toSlice` / `toSliceClone` / `toSliceZ` are omitted — they need
// `ZigString.Slice` and an allocator-bound conversion path that lives in
// `ZigString.zig` (not yet ported). The Iterator callback typedefs and struct
// stay because callers spell them in signatures.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = opaque {};
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2. Same `enum(i64)`
// representation as the real type so pass-by-value extern signatures stay
// ABI-stable.
const JSValue = enum(i64) { _ };
// JSC bridge JSObject stubbed — re-attaches in Phase 12.2.
const JSObject = opaque {};

// JSC bridge ZigString stubbed — re-attaches in Phase 12.2. Real ZigString
// is a `{ptr, len}` pair; we only need the address-of operations here, so a
// minimal extern struct is enough to keep the signatures honest.
const ZigString = extern struct {
    _ptr: ?[*]const u8 = null,
    _len: usize = 0,
};

pub const JSString = opaque {
    extern fn JSC__JSString__toObject(this: *JSString, global: *JSGlobalObject) ?*JSObject;
    extern fn JSC__JSString__toZigString(this: *JSString, global: *JSGlobalObject, zig_str: *ZigString) void;
    extern fn JSC__JSString__eql(this: *const JSString, global: *JSGlobalObject, other: *JSString) bool;
    extern fn JSC__JSString__iterator(this: *JSString, globalObject: *JSGlobalObject, iter: *anyopaque) void;
    extern fn JSC__JSString__length(this: *const JSString) usize;
    extern fn JSC__JSString__is8Bit(this: *const JSString) bool;

    // `toJS` upstream calls `JSValue.fromCell(str)`. The real conversion
    // re-lands once JSValue has the `fromCell` constructor — until then,
    // callers wanting to go from `*JSString` to a JSValue must bottle the
    // raw bits themselves.

    pub fn toObject(this: *JSString, global: *JSGlobalObject) ?*JSObject {
        return JSC__JSString__toObject(this, global);
    }

    pub fn toZigString(this: *JSString, global: *JSGlobalObject, zig_str: *ZigString) void {
        return JSC__JSString__toZigString(this, global, zig_str);
    }

    pub fn ensureStillAlive(this: *JSString) void {
        std.mem.doNotOptimizeAway(this);
    }

    pub fn getZigString(this: *JSString, global: *JSGlobalObject) ZigString {
        var out: ZigString = .{};
        this.toZigString(global, &out);
        return out;
    }

    pub const view = getZigString;

    pub fn eql(this: *const JSString, global: *JSGlobalObject, other: *JSString) bool {
        return JSC__JSString__eql(this, global, other);
    }

    pub fn iterator(this: *JSString, globalObject: *JSGlobalObject, iter: *anyopaque) void {
        return JSC__JSString__iterator(this, globalObject, iter);
    }

    pub fn length(this: *const JSString) usize {
        return JSC__JSString__length(this);
    }

    pub fn is8Bit(this: *const JSString) bool {
        return JSC__JSString__is8Bit(this);
    }

    pub const JStringIteratorAppend8Callback = *const fn (*Iterator, [*]const u8, u32) callconv(.c) void;
    pub const JStringIteratorAppend16Callback = *const fn (*Iterator, [*]const u16, u32) callconv(.c) void;
    pub const JStringIteratorWrite8Callback = *const fn (*Iterator, [*]const u8, u32, u32) callconv(.c) void;
    pub const JStringIteratorWrite16Callback = *const fn (*Iterator, [*]const u16, u32, u32) callconv(.c) void;
    pub const Iterator = extern struct {
        data: ?*anyopaque,
        stop: u8,
        append8: ?JStringIteratorAppend8Callback,
        append16: ?JStringIteratorAppend16Callback,
        write8: ?JStringIteratorWrite8Callback,
        write16: ?JStringIteratorWrite16Callback,
    };
};

test "JSString is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*JSString) == @sizeOf(usize));
}

test "JSString exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(JSString, "toObject"));
    try std.testing.expect(@hasDecl(JSString, "toZigString"));
    try std.testing.expect(@hasDecl(JSString, "ensureStillAlive"));
    try std.testing.expect(@hasDecl(JSString, "getZigString"));
    try std.testing.expect(@hasDecl(JSString, "view"));
    try std.testing.expect(@hasDecl(JSString, "eql"));
    try std.testing.expect(@hasDecl(JSString, "iterator"));
    try std.testing.expect(@hasDecl(JSString, "length"));
    try std.testing.expect(@hasDecl(JSString, "is8Bit"));
}

test "JSString.Iterator has the expected C-ABI layout" {
    // Six pointer-sized members (one is a u8 + padding, but we only check
    // it carries the callbacks). Probe the field names so the layout is
    // pinned against accidental reordering when callers across the FFI
    // boundary rely on the same struct.
    const info = @typeInfo(JSString.Iterator).@"struct";
    try std.testing.expect(info.layout == .@"extern");
    try std.testing.expectEqualStrings("data", info.fields[0].name);
    try std.testing.expectEqualStrings("stop", info.fields[1].name);
    try std.testing.expectEqualStrings("append8", info.fields[2].name);
    try std.testing.expectEqualStrings("append16", info.fields[3].name);
    try std.testing.expectEqualStrings("write8", info.fields[4].name);
    try std.testing.expectEqualStrings("write16", info.fields[5].name);
}
