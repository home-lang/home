// Copied from bun/src/jsc/JSUint8Array.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Thin wrapper around `JSC::JSUint8Array`. `ptr()` / `len()` read the
// JSArrayBufferView layout directly using offsets from `jsc.sizes`; the
// `fromBytes*` constructors hop through C++ exports that allocate the
// typed-array on the JS side.
//
// `JSGlobalObject` and `JSValue` are not yet ported. Local stubs keep the
// `extern fn` ABI accurate (opaque pointer + 8-byte enum, respectively); the
// JSC bridge re-attaches in Phase 12.2.

const std = @import("std");
const home_rt = @import("home_rt");
const Sizes = home_rt.jsc.sizes;

// JSC bridge stubs — re-attach in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
const JSValue = @import("home_rt").jsc.JSValue;

pub const JSUint8Array = opaque {
    pub fn ptr(this: *JSUint8Array) [*]u8 {
        return @as(*[*]u8, @ptrFromInt(@intFromPtr(this) + Sizes.Bun_FFI_PointerOffsetToTypedArrayVector)).*;
    }

    pub fn len(this: *JSUint8Array) usize {
        return @as(*usize, @ptrFromInt(@intFromPtr(this) + Sizes.Bun_FFI_PointerOffsetToTypedArrayLength)).*;
    }

    pub fn slice(this: *JSUint8Array) []u8 {
        return this.ptr()[0..this.len()];
    }

    extern fn JSUint8Array__fromDefaultAllocator(*JSGlobalObject, ptr: [*]u8, len: usize) JSValue;
    /// *bytes* must come from `home_rt.default_allocator`.
    pub fn fromBytes(globalThis: *JSGlobalObject, bytes: []u8) JSValue {
        return JSUint8Array__fromDefaultAllocator(globalThis, bytes.ptr, bytes.len);
    }

    extern fn Bun__createUint8ArrayForCopy(*JSGlobalObject, ptr: ?*const anyopaque, len: usize, buffer: bool) JSValue;
    pub fn fromBytesCopy(globalThis: *JSGlobalObject, bytes: []const u8) JSValue {
        return Bun__createUint8ArrayForCopy(globalThis, bytes.ptr, bytes.len, false);
    }

    pub fn createEmpty(globalThis: *JSGlobalObject) JSValue {
        return Bun__createUint8ArrayForCopy(globalThis, null, 0, false);
    }
};

test "JSUint8Array is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*JSUint8Array) == @sizeOf(usize));
}

test "JSUint8Array exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(JSUint8Array, "ptr"));
    try std.testing.expect(@hasDecl(JSUint8Array, "len"));
    try std.testing.expect(@hasDecl(JSUint8Array, "slice"));
    try std.testing.expect(@hasDecl(JSUint8Array, "fromBytes"));
    try std.testing.expect(@hasDecl(JSUint8Array, "fromBytesCopy"));
    try std.testing.expect(@hasDecl(JSUint8Array, "createEmpty"));
}

test "JSUint8Array uses Sizes from home_rt.jsc.sizes" {
    // Re-exported as a sanity check that the offsets are wired through.
    try std.testing.expectEqual(@as(comptime_int, 16), Sizes.Bun_FFI_PointerOffsetToTypedArrayVector);
}
