// Phase 12.2 M6 — JSON parse/stringify helpers.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M6 (the final scaffold milestone
// before C++ wiring), this file is the JSON entry point for downstream
// code that needs to serialize or deserialize JS values through JSC's
// native JSON engine. JSC's C API exposes the underlying machinery as
// `JSValueMakeFromJSONString` (parse) and `JSValueCreateJSONString`
// (stringify); the helpers below collapse those onto a uniform Zig
// surface that matches the rest of the M4-M5 helper layer.
//
// Semantics follow the ECMAScript abstract operations:
//   - `parseJSON(json_str)`     → `JSON.parse(json_str)` — throws on
//     malformed input (delivered via the exception out-param).
//   - `stringifyJSON(v, indent)` → `JSON.stringify(v, null, indent)` —
//     emits a freshly retained `*JSString` the caller must release via
//     `JSStringRelease`. `indent = 0` produces a single-line dump; any
//     positive value pretty-prints with that many spaces per level
//     (matching the second argument to ECMAScript `JSON.stringify`).
//
// Both helpers thread an optional `ExceptionRef` so callers can wire the
// thrown value back to JS without going through `throwError`/
// `clearException` from `jsc/exception_helpers.zig`. Passing `null` to
// the out-param discards the thrown value; the call returns a stable
// bottom (`undefined` for parse, `null` for stringify).
//
// `JSValueMakeFromJSONString` and `JSValueCreateJSONString` are not yet
// declared in `jsc/extern_fns.zig` (M1 scoped its initial 30-fn surface
// to the most-used inspect/coerce/property entries). They will be added
// alongside the M3 C++ wiring; until then the bodies here panic with
// `TODO(phase-12.2-M3)` so downstream call sites compile against the M6
// signature without forcing the linker to resolve those symbols early.
//
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSValue.zig` L2860 (`parseJSON`)
//   - `~/Code/bun/src/jsc/JSValue.zig` L2880 (`createJSONString`)
//
// All bodies panic with `TODO(phase-12.2-M3)`; the M6 contract is the
// shape of the surface, not its semantics.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSString = opaques.JSString;

/// `ExceptionRef` mirrors the M2 declaration in `extern_fns.zig` — a
/// nullable out-pointer JSC writes the thrown value through. Callers
/// pass `null` to discard the thrown value (the return is the stable
/// bottom for the helper: `undefined` for `parseJSON`, `null` for
/// `stringifyJSON`).
pub const ExceptionRef = [*c]?*JSValue;

/// `JSON.parse(json_str)`. Returns the parsed JSValue, or a bottom value
/// (`undefined` cast to `*JSValue`) on parse failure, with the thrown
/// SyntaxError delivered via `exception` if non-null.
///
/// Forwards (M3) to `JSValueMakeFromJSONString` (companion to the M1
/// extern fn set; declared in the M3 wiring batch). The input is taken
/// as a Zig `[]const u8`; the helper internally wraps it in a transient
/// `*JSString` via `JSStringCreateWithUTF8CString` and releases that
/// string before returning.
pub fn parseJSON(
    ctx: *JSContextRef,
    json_str: []const u8,
    exception: ?ExceptionRef,
) *JSValue {
    _ = ctx;
    _ = json_str;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `JSON.stringify(value, null, indent)`. Returns a freshly retained
/// `*JSString` the caller must release via `JSStringRelease`. Returns
/// `null` if `value` contains a cycle or a value that can't be
/// serialized (Symbol, function, etc.); the thrown TypeError is
/// delivered via `exception` if non-null.
///
/// `indent = 0` produces a single-line dump; any positive value
/// pretty-prints with that many spaces per nesting level (capped at 10
/// per the ECMAScript spec).
///
/// Forwards (M3) to `JSValueCreateJSONString` (companion to the M1
/// extern fn set; declared in the M3 wiring batch).
pub fn stringifyJSON(
    ctx: *JSContextRef,
    value: *JSValue,
    indent: u32,
    exception: ?ExceptionRef,
) ?*JSString {
    _ = ctx;
    _ = value;
    _ = indent;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

test "json helpers expose the expected M6 signatures" {
    // Compile-time signature check — bodies panic until M3 lands the
    // C++ engine; we only assert that each helper exists as a function
    // and has not drifted off the M6 spec. Downstream call sites can be
    // written against these shapes today without waiting on linkage.
    try std.testing.expect(@typeInfo(@TypeOf(parseJSON)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(stringifyJSON)) == .@"fn");
}

test "json return types match the M6 contract" {
    // `parseJSON` returns a non-optional `*JSValue` — JSC emits
    // `undefined` (not null) on parse failure, with the thrown value
    // surfaced through the exception out-param.
    const parse_info = @typeInfo(@TypeOf(parseJSON)).@"fn";
    try std.testing.expect(parse_info.return_type.? == *JSValue);
    // `stringifyJSON` returns an optional `*JSString` — JSC's
    // `JSValueCreateJSONString` returns null on serialization failure
    // (cycles, unserializable values), with the thrown value surfaced
    // through the exception out-param.
    const str_info = @typeInfo(@TypeOf(stringifyJSON)).@"fn";
    try std.testing.expect(@typeInfo(str_info.return_type.?) == .optional);
}
