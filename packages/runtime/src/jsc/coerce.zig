// Phase 12.2 M4 — JSValue → Zig primitive coercion helpers.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M4 (Integration & High-Level APIs),
// this file is the central dispatch point for "I have a JSValue, give me
// a Zig primitive" calls — the bread-and-butter of every host-fn binding.
// JSC's C API exposes the underlying machinery as separate entrypoints
// (`JSValueToBoolean`, `JSValueToNumber`, `JSValueToStringCopy`, …) which
// the helpers below collapse into a uniform Zig-shaped surface.
//
// The semantics follow the ECMAScript abstract operations:
//   - `toBool`    → `ToBoolean(v)` — total, never throws.
//   - `toNumber`  → `ToNumber(v)` — can throw (e.g. Symbol coercion).
//   - `toInt32`   → `ToInt32(v)` — truncates after ToNumber; can throw.
//   - `toUInt32`  → `ToUInt32(v)` — same path as toInt32, unsigned cast.
//   - `toString`  → `ToString(v)` — returns a freshly allocated JSString
//     the caller must `JSStringRelease` once consumed.
//
// `toCStringBuffer` is the C-string convenience: it composes `toString`
// with `JSStringGetUTF8CString` into a single call that fills a caller-
// supplied byte buffer and returns the populated slice. The buffer must
// be large enough; otherwise the result is truncated (same semantics as
// JSC's underlying entrypoint).
//
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSValue.zig` L2103 (`toBoolean`)
//   - `~/Code/bun/src/jsc/JSValue.zig` L120 (`toNumber`)
//   - `~/Code/bun/src/jsc/JSValue.zig` L2124 (`toInt32`)
//
// All bodies panic with `TODO(phase-12.2-M3)` until the C++ engine wiring
// lands; the M4 contract is the shape of the surface, not its semantics.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSString = opaques.JSString;

/// `ExceptionRef` mirrors the M2 declaration in `extern_fns.zig` — a
/// nullable out-pointer JSC writes the thrown value through. Helpers
/// that can throw take a nullable pointer; passing `null` discards the
/// thrown value (the call still returns a stable bottom).
pub const ExceptionRef = [*c]?*JSValue;

/// `ToBoolean(v)`. Never throws. Maps `undefined`, `null`, `0`, `NaN`,
/// the empty string, and `false` to `false`; everything else to `true`.
///
/// Forwards to `JSValueToBoolean` (extern_fns.zig line 70).
pub fn toBool(ctx: *JSContextRef, v: *JSValue) bool {
    _ = ctx;
    _ = v;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `ToNumber(v)`. May throw — passes `exception` to JSC. Pass `null` to
/// discard the thrown value (the return is `NaN` on failure).
///
/// Forwards to `JSValueToNumber` (extern_fns.zig line 71).
pub fn toNumber(ctx: *JSContextRef, v: *JSValue, exception: ?ExceptionRef) f64 {
    _ = ctx;
    _ = v;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `ToInt32(v)`. Truncates the result of `ToNumber` to an int32. May
/// throw if the underlying `ToNumber` throws.
pub fn toInt32(ctx: *JSContextRef, v: *JSValue, exception: ?ExceptionRef) i32 {
    _ = ctx;
    _ = v;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `ToUInt32(v)`. Same coercion path as `toInt32`, returned as `u32`.
pub fn toUInt32(ctx: *JSContextRef, v: *JSValue, exception: ?ExceptionRef) u32 {
    _ = ctx;
    _ = v;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `ToString(v)`. Returns a freshly retained `*JSString` the caller is
/// responsible for releasing via `JSStringRelease`. May throw on
/// uncoercible inputs (e.g. Symbol primitives).
///
/// Forwards to `JSValueToStringCopy` (extern_fns.zig line 72).
pub fn toString(ctx: *JSContextRef, v: *JSValue, exception: ?ExceptionRef) ?*JSString {
    _ = ctx;
    _ = v;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Convenience: coerce `v` to a string, then populate `buf` with its
/// UTF-8 encoding and return the populated slice. The string is
/// internally released after copying. Errors out (`error.OutOfBuffer`)
/// if `buf` is too small for the null-terminated result.
///
/// This composes the `JSValueToStringCopy` + `JSStringGetUTF8CString`
/// extern_fns pair into a single ergonomic call.
pub fn toCStringBuffer(ctx: *JSContextRef, v: *JSValue, buf: []u8) ![]const u8 {
    _ = ctx;
    _ = v;
    _ = buf;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

test "coerce helpers expose the expected M4 signatures" {
    // Compile-time signature check. Bodies panic until M3; we only
    // verify the shape of the surface here.
    try std.testing.expect(@typeInfo(@TypeOf(toBool)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(toNumber)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(toInt32)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(toUInt32)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(toString)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(toCStringBuffer)) == .@"fn");
}

test "coerce return types match the M4 contract" {
    // `toBool` returns `bool`, never throws — verify the return type
    // is the plain primitive (not an optional or error union).
    const bool_info = @typeInfo(@TypeOf(toBool)).@"fn";
    try std.testing.expect(bool_info.return_type.? == bool);
    // `toNumber` returns `f64` — also primitive (exception goes via
    // the out-param).
    const num_info = @typeInfo(@TypeOf(toNumber)).@"fn";
    try std.testing.expect(num_info.return_type.? == f64);
    // `toInt32` / `toUInt32` differ only in signedness.
    const i32_info = @typeInfo(@TypeOf(toInt32)).@"fn";
    const u32_info = @typeInfo(@TypeOf(toUInt32)).@"fn";
    try std.testing.expect(i32_info.return_type.? == i32);
    try std.testing.expect(u32_info.return_type.? == u32);
    // `toString` returns an optional `*JSString` — JSC's
    // `JSValueToStringCopy` returns null on failure.
    const str_info = @typeInfo(@TypeOf(toString)).@"fn";
    try std.testing.expect(@typeInfo(str_info.return_type.?) == .optional);
    // `toCStringBuffer` is the only fallible helper — error union.
    const cstr_info = @typeInfo(@TypeOf(toCStringBuffer)).@"fn";
    try std.testing.expect(@typeInfo(cstr_info.return_type.?) == .error_union);
}
