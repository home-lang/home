// Phase 12.2 M5 — JS function-call + constructor dispatch helpers.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M5 (Validation & call surface), this
// file is the central dispatch point for "I have a JSValue, invoke it as a
// function / method / constructor" calls. JSC's C API exposes the underlying
// machinery as `JSObjectCallAsFunction` (extern_fns.zig L84) and the
// companion `JSObjectCallAsConstructor`; the helpers below collapse those
// onto a uniform Zig surface that the rest of Home (and the 813 still-
// unported Bun files) can target without threading the exception out-param
// or building argv buffers by hand.
//
// Semantics follow the ECMAScript abstract operations:
//   - `callFunction` → `Call(F, V, argumentsList)` (ECMA §7.3.13)
//   - `callMethod`   → `GetV(V, P)` + `Call` (the "method-of" shorthand)
//   - `constructObject` → `Construct(F, argumentsList)` (ECMA §7.3.14)
//   - `isCallable`   → `IsCallable(V)`  (total, never throws)
//   - `isConstructor` → `IsConstructor(V)` (total, never throws)
//
// `callMethod` is sugar: it composes `JSObjectGetProperty` (extern_fns.zig
// L81) with `JSObjectCallAsFunction` so downstream callers can write the
// common "look up a property and invoke it" pattern in one line. The
// property name is taken as a Zig `[]const u8` — the helper does the
// `JSStringCreateWithUTF8CString` wrap + release internally.
//
// `JSObjectCallAsConstructor`, `JSObjectIsFunction`, and `JSObjectIsConstructor`
// are not yet declared in `jsc/extern_fns.zig` (M1 scoped its initial 30-fn
// surface to the most-used inspect/coerce/property entries). They will be
// added alongside the M3 C++ wiring; until then the bodies here panic with
// `TODO(phase-12.2-M3)` so downstream call sites compile against the M5
// signature without forcing the linker to resolve those symbols early.
//
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSValue.zig` L2407 (`call`)
//   - `~/Code/bun/src/jsc/JSValue.zig` L2455 (`construct`)
//   - `~/Code/bun/src/jsc/JSValue.zig` L2280 (`isCallable` / `isConstructor`)
//
// All bodies panic with `TODO(phase-12.2-M3)`; the M5 contract is the
// shape of the surface, not its semantics.

const std = @import("std");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSString = opaques.JSString;

/// `ExceptionRef` mirrors the M2 declaration in `extern_fns.zig` — a
/// nullable out-pointer JSC writes the thrown value through. Callers
/// pass `null` to discard the thrown value (the return is `undefined`
/// on failure).
pub const ExceptionRef = [*c]?*JSValue;

/// `Call(fn_value, this_arg, argumentsList)`. Invokes `fn_value` as a
/// JavaScript function with `this_arg` bound as the receiver and `args`
/// supplied positionally. The argv slice may be empty.
///
/// Forwards (M3) to `JSObjectCallAsFunction` (extern_fns.zig L84). The
/// argv slice is repacked into the C-API's `[*c]const ?*JSValue` shape
/// inside the wrapper so callers can pass an idiomatic Zig slice.
pub fn callFunction(
    ctx: *JSContextRef,
    fn_value: *JSValue,
    this_arg: ?*JSValue,
    args: []const *JSValue,
    exception: ?ExceptionRef,
) *JSValue {
    _ = ctx;
    _ = fn_value;
    _ = this_arg;
    _ = args;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `GetV(obj, method_name)` followed by `Call(method, obj, args)`. The
/// canonical "look up a property and invoke it" shorthand. Throws if
/// either the property lookup or the call itself throws.
///
/// Forwards (M3) to `JSObjectGetProperty` (extern_fns.zig L81) +
/// `JSObjectCallAsFunction` (L84), with `JSStringCreateWithUTF8CString`
/// wrapping `method_name`.
pub fn callMethod(
    ctx: *JSContextRef,
    obj: *JSValue,
    method_name: []const u8,
    args: []const *JSValue,
    exception: ?ExceptionRef,
) *JSValue {
    _ = ctx;
    _ = obj;
    _ = method_name;
    _ = args;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `Construct(F, argumentsList)`. Invokes `constructor` as a `new` call
/// and returns the freshly-allocated instance. Throws if `constructor`
/// is not a constructor (`isConstructor(v) == false`).
///
/// Forwards (M3) to `JSObjectCallAsConstructor` (companion to L84;
/// declared alongside `JSObjectCallAsFunction` in the M3 wiring batch).
pub fn constructObject(
    ctx: *JSContextRef,
    constructor: *JSValue,
    args: []const *JSValue,
    exception: ?ExceptionRef,
) *JSValue {
    _ = ctx;
    _ = constructor;
    _ = args;
    _ = exception;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `IsCallable(v)`. Returns `true` iff `v` is a callable function-like
/// object (the JSC engine carries the `[[Call]]` internal slot). Never
/// throws.
///
/// Forwards (M3) to `JSObjectIsFunction`.
pub fn isCallable(ctx: *JSContextRef, value: *JSValue) bool {
    _ = ctx;
    _ = value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

/// `IsConstructor(v)`. Returns `true` iff `v` carries the `[[Construct]]`
/// internal slot (every JS class and every non-arrow function does).
/// Never throws.
///
/// Forwards (M3) to `JSObjectIsConstructor`.
pub fn isConstructor(ctx: *JSContextRef, value: *JSValue) bool {
    _ = ctx;
    _ = value;
    @panic("TODO(phase-12.2-M3): JSC C++ engine wiring");
}

test "call helpers expose the expected M5 signatures" {
    // Compile-time signature check — bodies panic until M3 lands the
    // C++ engine; we only assert that each helper exists as a function
    // and has not drifted off the M5 spec. Downstream call sites can be
    // written against these shapes today without waiting on linkage.
    try std.testing.expect(@typeInfo(@TypeOf(callFunction)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(callMethod)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(constructObject)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(isCallable)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(isConstructor)) == .@"fn");
}

test "call return types match the M5 contract" {
    // `callFunction`, `callMethod`, `constructObject` all return a
    // non-optional `*JSValue` — JSC's call surface emits `undefined` on
    // failure (delivered via the exception out-param), not null.
    const call_info = @typeInfo(@TypeOf(callFunction)).@"fn";
    const method_info = @typeInfo(@TypeOf(callMethod)).@"fn";
    const ctor_info = @typeInfo(@TypeOf(constructObject)).@"fn";
    try std.testing.expect(call_info.return_type.? == *JSValue);
    try std.testing.expect(method_info.return_type.? == *JSValue);
    try std.testing.expect(ctor_info.return_type.? == *JSValue);
    // `isCallable` / `isConstructor` are predicates — return plain bool,
    // not optional or error-union. They never throw at the JSC level.
    const callable_info = @typeInfo(@TypeOf(isCallable)).@"fn";
    const ctor_pred_info = @typeInfo(@TypeOf(isConstructor)).@"fn";
    try std.testing.expect(callable_info.return_type.? == bool);
    try std.testing.expect(ctor_pred_info.return_type.? == bool);
    // The two predicates share an identical signature shape.
    try std.testing.expect(@TypeOf(isCallable) == @TypeOf(isConstructor));
}

// Silence unused-import lints — `JSObject` and `JSString` are reserved
// for the M3 wiring where the extern fn signatures take `*JSObject` and
// `*JSString` directly (the helpers above accept `*JSValue` and downcast
// internally). Keeping the aliases keeps the diff against the M3 batch
// minimal.
comptime {
    _ = JSObject;
    _ = JSString;
}
