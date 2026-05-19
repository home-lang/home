// Phase 12.2 M6 — global-object accessor helpers.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M6 (the final scaffold milestone
// before C++ wiring), this file is the central entry point for host
// code that needs to read/write the realm's global object (`globalThis`).
// JSC's C API exposes the underlying machinery as `JSContextGetGlobalObject`
// (already declared in `jsc/extern_fns.zig` L44) plus the standard
// property surface; the helpers below collapse those into a uniform
// Zig surface with ergonomic UTF-8 string keys.
//
// The three entries are:
//   - `getGlobalObject(ctx)`     → returns the realm's `globalThis` as
//     a `*JSValue` (downcast from the C-API's `*JSObject` return).
//   - `setOnGlobal(ctx, name, v)` → sugar over `getGlobalObject` +
//     `JSObjectSetProperty`. The name string is wrapped + released
//     internally.
//   - `getOnGlobal(ctx, name)`    → mirror of `setOnGlobal` for reads,
//     returning `null` if the property is missing (vs. `undefined` —
//     the helper inspects the result to distinguish the two and folds
//     `undefined` to `null` so call sites can use the natural `if (…)
//     |v|` pattern).
//
// These sit on top of the M2 property + M5 call surface, which means
// they need no new extern fns. Once M3 lands the C++ engine, the bodies
// are ~5 lines each of plain Zig glue.
//
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSGlobalObject.zig` (the per-type opaque +
//     `getGlobalObject` shortcut from a `*JSContextRef`)
//   - `~/Code/bun/src/bun.js/javascript.zig` L1080 (the `VirtualMachine`
//     side that exposes a `globalThis` accessor for host-side patching)
//
// All bodies panic with `TODO(phase-12.2-M3)`; the M6 contract is the
// shape of the surface, not its semantics.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSGlobalObject = opaques.JSGlobalObject;
const JSObject = opaques.JSObject;

/// Return the realm's `globalThis` as a `*JSValue`. The C-API's
/// `JSContextGetGlobalObject` returns a `*JSObject`; this helper
/// downcasts it to `*JSValue` so callers can pass the result directly
/// into the rest of the M4-M5 helper surface (which uniformly speaks
/// `*JSValue` rather than `*JSObject`).
///
/// Forwards (M3) to `JSContextGetGlobalObject` (extern_fns.zig L44).
pub fn getGlobalObject(ctx: *JSContextRef) *JSValue {
    _ = ctx;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Sugar over `getGlobalObject` + `JSObjectSetProperty`: install
/// `value` at `globalThis[name]`. The name string is wrapped in a
/// transient `*JSString` via `JSStringCreateWithUTF8CString` and
/// released before return.
///
/// Throws on attempts to redefine a non-configurable own property of
/// the global object; the thrown value is sunk silently (callers that
/// need to observe it should drop down to `JSObjectSetProperty` with
/// an explicit `ExceptionRef`).
///
/// Forwards (M3) to `JSContextGetGlobalObject` (extern_fns.zig L44) +
/// `JSObjectSetProperty` (L82) + `JSStringCreateWithUTF8CString` (L88).
pub fn setOnGlobal(ctx: *JSContextRef, name: []const u8, value: *JSValue) void {
    _ = ctx;
    _ = name;
    _ = value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Read `globalThis[name]`. Returns `null` if the property is missing
/// or if its value is `undefined` (the two states are folded for
/// caller convenience — most host code treats them identically); use
/// the lower-level `JSObjectGetProperty` directly if the distinction
/// matters.
///
/// Forwards (M3) to `JSContextGetGlobalObject` (extern_fns.zig L44) +
/// `JSObjectGetProperty` (L81) + `JSValueIsUndefined` (L49) +
/// `JSStringCreateWithUTF8CString` (L88).
pub fn getOnGlobal(ctx: *JSContextRef, name: []const u8) ?*JSValue {
    _ = ctx;
    _ = name;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

test "global helpers expose the expected M6 signatures" {
    // Compile-time signature check — bodies panic until M3 lands the
    // C++ engine; we only assert that each helper exists as a function
    // and has not drifted off the M6 spec.
    try std.testing.expect(@typeInfo(@TypeOf(getGlobalObject)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(setOnGlobal)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(getOnGlobal)) == .@"fn");
}

test "global return types match the M6 contract" {
    // `getGlobalObject` returns non-optional `*JSValue` — the realm
    // always has a global object on a live context (JSC aborts at
    // context-create time if the realm can't allocate one).
    const get_info = @typeInfo(@TypeOf(getGlobalObject)).@"fn";
    try std.testing.expect(get_info.return_type.? == *JSValue);
    // `setOnGlobal` is `void`-returning — the property is installed
    // as a side effect; failure (e.g. non-configurable redefinition)
    // is sunk silently at this layer.
    const set_info = @typeInfo(@TypeOf(setOnGlobal)).@"fn";
    try std.testing.expect(set_info.return_type.? == void);
    // `getOnGlobal` returns an optional `*JSValue` — `null` covers
    // both "property missing" and "property is undefined" (the two
    // are folded for caller convenience).
    const opt_info = @typeInfo(@TypeOf(getOnGlobal)).@"fn";
    try std.testing.expect(@typeInfo(opt_info.return_type.?) == .optional);
    try std.testing.expect(@typeInfo(opt_info.return_type.?).optional.child == *JSValue);
}

// Silence unused-import lints — `JSGlobalObject` and `JSObject` are
// reserved for the M3 wiring where the upcast from `*JSObject` (the
// `JSContextGetGlobalObject` return) to `*JSGlobalObject` happens
// inline before re-casting down to `*JSValue` for the helper return.
// Keeping the aliases keeps the M3 diff against this file minimal.
comptime {
    _ = JSGlobalObject;
    _ = JSObject;
}
