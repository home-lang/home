// Phase 12.2 M4 — JS Array construction + element-access helpers.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M4 (Integration & High-Level APIs),
// this file wraps the JSC C-API's array surface (`JSObjectMakeArray`,
// `JSObjectGetPropertyAtIndex`, …) onto a small, uniform Zig API. The
// existing `jsc/JSArray.zig` leaf carries the per-type opaque shell;
// this file is the *operations* layer on top of it.
//
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSArray.zig` (opaque + element access helpers)
//   - `~/Code/bun/src/jsc/javascript_core_c_api.zig`
//     L`JSObjectMakeArray` / L`JSObjectGetPropertyAtIndex` /
//     L`JSObjectSetPropertyAtIndex`.
//
// All bodies panic with `TODO(phase-12.2-M3)` — the M4 contract is the
// surface shape, not the semantics. Once M3 lands the C++ bridge, each
// stub becomes a direct forward to the corresponding extern fn declared
// in `jsc/extern_fns.zig`.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;

/// Return the `.length` of a JS array as a `u32`. The argument must be
/// array-typed (`JSValueIsArray(array_value) == true`); behaviour on a
/// non-array is "return 0", matching ECMAScript host-object semantics.
///
/// Forwards (M3) to `JSObjectGetProperty(ctx, array_value, "length")`
/// followed by a `ToUInt32` coercion.
pub fn arrayLength(ctx: *JSContextRef, array_value: *JSValue) u32 {
    _ = ctx;
    _ = array_value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Read `array_value[idx]` and return the result. Out-of-bounds reads
/// yield `undefined` (per ECMAScript array semantics, not a Zig error).
///
/// Forwards (M3) to `JSObjectGetPropertyAtIndex` (extern_fns.zig L83).
pub fn arrayGet(ctx: *JSContextRef, array_value: *JSValue, idx: u32) *JSValue {
    _ = ctx;
    _ = array_value;
    _ = idx;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Write `value` to `array_value[idx]`. Out-of-bounds writes extend
/// the array (per ECMAScript sparse-array semantics).
///
/// Forwards (M3) to `JSObjectSetPropertyAtIndex` (companion extern fn
/// declared alongside `JSObjectGetPropertyAtIndex`).
pub fn arraySet(ctx: *JSContextRef, array_value: *JSValue, idx: u32, value: *JSValue) void {
    _ = ctx;
    _ = array_value;
    _ = idx;
    _ = value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Construct a fresh `Array` object. If `initial` is non-null, its
/// elements are copied in as the array contents; otherwise an empty
/// array is returned.
///
/// Forwards (M3) to `JSObjectMakeArray` (extern_fns.zig L80).
pub fn arrayCreate(ctx: *JSContextRef, initial: ?[]const *JSValue) *JSValue {
    _ = ctx;
    _ = initial;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

test "array helpers expose the expected M4 signatures" {
    // Compile-time signature check — bodies panic until M3 lands the
    // C++ engine; we only assert that each helper exists as a function
    // and has not drifted off the M4 spec.
    try std.testing.expect(@typeInfo(@TypeOf(arrayLength)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(arrayGet)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(arraySet)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(arrayCreate)) == .@"fn");
}

test "array return types match the M4 contract" {
    // `arrayLength` returns `u32` per the ECMAScript array-length cap.
    const len_info = @typeInfo(@TypeOf(arrayLength)).@"fn";
    try std.testing.expect(len_info.return_type.? == u32);
    // `arrayGet` and `arrayCreate` both return `*JSValue` (non-optional
    // — JSC returns `undefined` on miss, not null).
    const get_info = @typeInfo(@TypeOf(arrayGet)).@"fn";
    const create_info = @typeInfo(@TypeOf(arrayCreate)).@"fn";
    try std.testing.expect(get_info.return_type.? == *JSValue);
    try std.testing.expect(create_info.return_type.? == *JSValue);
    // `arraySet` is `void`-returning (the underlying C-API entry sinks
    // any thrown value through the exception out-param).
    const set_info = @typeInfo(@TypeOf(arraySet)).@"fn";
    try std.testing.expect(set_info.return_type.? == void);
}

// Silence unused-import — `JSObject` is reserved for the M5
// `arrayFromObject(*JSObject)` convenience overload (matches Bun's
// `JSArray.fromObject` upstream).
comptime {
    _ = JSObject;
}
