// Phase 12.2 M4 — JSC exception construction + propagation helpers.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M4 (Integration & High-Level APIs),
// this file is the public surface downstream code uses to build, throw,
// inspect, and clear JS-level exceptions. M1 named the opaques; M2/M3
// declared the C-API surface and Engine stub; M4 sits on top so callers
// can write idiomatic Zig that maps onto a future real JSC binding.
//
// The C-API does not expose a single `MakeError` symbol — instead, JSC
// surfaces error construction through `JSObjectMakeError`-style entry
// points that take a `JSValue` message argument and return a freshly
// allocated `Error` instance. The Bun upstream wraps these via the
// `JSC__JSValue__createTypeError` / `createErrorInstance` pathways
// (`~/Code/bun/src/jsc/JSValue.zig` L1925, `~/Code/bun/src/jsc/JSGlobalObject.zig`
// L287). Home's wrapping is intentionally thin: route every helper through
// `@panic("TODO(phase-12.2-M3)")` until the C++ bridge lands, with the
// signature pinned so callers can be written ahead of the wiring.
//
// Exception propagation in JSC is "out-param" style — the caller passes
// an `ExceptionRef` (a `JSValueRef*`) and JSC writes the thrown value
// through it. The `throwError` / `clearException` / `getCurrentException`
// helpers here wrap that pattern onto the M2 property/value surface so
// downstream callers don't need to thread the out-param themselves.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSString = opaques.JSString;

/// Construct a generic `Error` instance whose `.message` is the supplied
/// UTF-8 string. The returned value is a heap-allocated JSValue; callers
/// either throw it (via `throwError`) or hand it back to JS via return.
///
/// Bun upstream: `~/Code/bun/src/jsc/JSGlobalObject.zig` L287
/// (`createErrorInstance`). M4 keeps the body parked behind the M3
/// engine wiring; the signature stays stable so call sites compile.
pub fn makeError(ctx: *JSContextRef, message: []const u8) *JSValue {
    _ = ctx;
    _ = message;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Construct a `TypeError` instance. Same shape as `makeError` but the
/// resulting value is tagged with the `TypeError` prototype so JS-side
/// `instanceof TypeError` reflects correctly.
///
/// Bun upstream: `~/Code/bun/src/jsc/JSGlobalObject.zig` L313
/// (`createTypeErrorInstance`).
pub fn makeTypeError(ctx: *JSContextRef, message: []const u8) *JSValue {
    _ = ctx;
    _ = message;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Construct a `RangeError` instance. Used for numeric-domain failures
/// (e.g. `String.prototype.repeat` with a negative count).
pub fn makeRangeError(ctx: *JSContextRef, message: []const u8) *JSValue {
    _ = ctx;
    _ = message;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Record `error_value` as the current pending exception for `ctx`. Most
/// C-API entrypoints take an `ExceptionRef` out-parameter; this helper
/// stashes the value where the next `getCurrentException` call finds it,
/// modelling the "thread-local last exception" pattern downstream code
/// uses when it doesn't want to thread the out-param manually.
pub fn throwError(ctx: *JSContextRef, error_value: *JSValue) void {
    _ = ctx;
    _ = error_value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Clear any pending exception on `ctx`. No-op if none is set. The
/// canonical use is after a try/catch boundary where the caller has
/// already converted the thrown value to a Zig error.
pub fn clearException(ctx: *JSContextRef) void {
    _ = ctx;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// Return the currently-pending exception JSValue, or `null` if none
/// is set. Downstream callers use this to peek without clearing — pair
/// with `clearException` once the value has been consumed.
pub fn getCurrentException(ctx: *JSContextRef) ?*JSValue {
    _ = ctx;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

test "exception helpers expose the expected M4 signatures" {
    // Compile-time signature check. We never invoke the helpers (they
    // panic until M3 lands the C++ engine); the point is to assert each
    // entry exists as a function and has not silently drifted off the
    // M4 spec. Downstream callers can be written against these now.
    try std.testing.expect(@typeInfo(@TypeOf(makeError)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(makeTypeError)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(makeRangeError)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(throwError)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(clearException)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(getCurrentException)) == .@"fn");
}

test "make* helpers all return *JSValue and accept a context + message" {
    // Type-level: the three `make*` helpers share an identical signature
    // shape — `(ctx: *JSContextRef, message: []const u8) *JSValue`. This
    // gives downstream a uniform call site regardless of which error
    // class is constructed.
    try std.testing.expect(@TypeOf(makeError) == @TypeOf(makeTypeError));
    try std.testing.expect(@TypeOf(makeError) == @TypeOf(makeRangeError));
    // `getCurrentException` returns an optional pointer; the others do
    // not. Verifies the M4 shape distinction.
    const info = @typeInfo(@TypeOf(getCurrentException)).@"fn";
    try std.testing.expect(@typeInfo(info.return_type.?) == .optional);
}

// Silence unused-import lints — `JSString` is reserved for the M5
// "throw-from-string" convenience overload that lands once the C++
// engine is alive. Keeping the alias keeps the diff against upstream
// minimal.
comptime {
    _ = JSString;
}
