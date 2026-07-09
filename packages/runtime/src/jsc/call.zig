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
// Bun upstream parity:
//   - `~/Code/bun/src/jsc/JSValue.zig` L2407 (`call`)
//   - `~/Code/bun/src/jsc/JSValue.zig` L2455 (`construct`)
//   - `~/Code/bun/src/jsc/JSValue.zig` L2280 (`isCallable` / `isConstructor`)

const std = @import("std");
const bun = @import("bun");
const build_options = @import("build_options");
const Engine = @import("engine.zig").Engine;
const evaluate = @import("evaluate.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSString = opaques.JSString;

/// `ExceptionRef` mirrors the M2 declaration in `extern_fns.zig` — a
/// nullable out-pointer JSC writes the thrown value through. Callers
/// pass `null` to discard the thrown value (the return is `undefined`
/// on failure).
pub const ExceptionRef = extern_fns.ExceptionRef;

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
    var argv = argvFromSlice(args);
    defer argv.deinit();
    const exception_ref = exception orelse null;
    const result = extern_fns.JSObjectCallAsFunction(
        ctx,
        @ptrCast(fn_value),
        if (this_arg) |value| @ptrCast(value) else null,
        argv.len(),
        argv.ptr(),
        exception_ref,
    );
    return result orelse makeUndefined(ctx);
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
    const name_string = makeNameString(method_name);
    defer extern_fns.JSStringRelease(name_string);

    const exception_ref = exception orelse null;
    const method = extern_fns.JSObjectGetProperty(ctx, @ptrCast(obj), name_string, exception_ref) orelse
        return makeUndefined(ctx);
    return callFunction(ctx, method, obj, args, exception);
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
    var argv = argvFromSlice(args);
    defer argv.deinit();
    const result = extern_fns.JSObjectCallAsConstructor(
        ctx,
        @ptrCast(constructor),
        argv.len(),
        argv.ptr(),
        exception orelse null,
    );
    return @ptrCast(result orelse return makeUndefined(ctx));
}

/// `IsCallable(v)`. Returns `true` iff `v` is a callable function-like
/// object (the JSC engine carries the `[[Call]]` internal slot). Never
/// throws.
///
/// Forwards (M3) to `JSObjectIsFunction`.
pub fn isCallable(ctx: *JSContextRef, value: *JSValue) bool {
    if (!extern_fns.JSValueIsObject(ctx, value)) return false;
    return extern_fns.JSObjectIsFunction(ctx, @ptrCast(value));
}

/// `IsConstructor(v)`. Returns `true` iff `v` carries the `[[Construct]]`
/// internal slot (every JS class and every non-arrow function does).
/// Never throws.
///
/// Forwards (M3) to `JSObjectIsConstructor`.
pub fn isConstructor(ctx: *JSContextRef, value: *JSValue) bool {
    if (!extern_fns.JSValueIsObject(ctx, value)) return false;
    return extern_fns.JSObjectIsConstructor(ctx, @ptrCast(value));
}

const Argv = struct {
    values: []?*JSValue,

    pub fn deinit(self: *Argv) void {
        if (self.values.len > 0) std.heap.smp_allocator.free(self.values);
        self.values = &.{};
    }

    pub fn ptr(self: *const Argv) [*c]const ?*JSValue {
        return if (self.values.len == 0) null else self.values.ptr;
    }

    pub fn len(self: *const Argv) usize {
        return self.values.len;
    }
};

fn argvFromSlice(args: []const *JSValue) Argv {
    if (args.len == 0) return .{ .values = &.{} };
    const values = std.heap.smp_allocator.alloc(?*JSValue, args.len) catch
        @panic("JSC: failed to allocate call argv");
    for (args, values) |arg, *slot| slot.* = arg;
    return .{ .values = values };
}

fn makeUndefined(ctx: *JSContextRef) *JSValue {
    return extern_fns.JSValueMakeUndefined(ctx) orelse
        @panic("JSC: failed to create undefined");
}

fn makeNameString(method_name: []const u8) *JSString {
    const allocator = std.heap.smp_allocator;
    const name_z = bun.dupeZ(allocator, u8, method_name) catch @panic("JSC: failed to allocate method name");
    defer allocator.free(name_z);

    return extern_fns.JSStringCreateWithUTF8CString(name_z.ptr) orelse
        @panic("JSC: failed to create method name string");
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

test "call helpers invoke functions and methods when JSC is enabled" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const fn_value = (try evaluate.evaluateUtf8(std.testing.allocator, ctx, "(function(value) { return value + 1; })", "home:jsc-call-fn", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    const arg = extern_fns.JSValueMakeNumber(ctx, 41) orelse return error.JSValueMakeFailed;
    const result = callFunction(ctx, fn_value, null, &.{arg}, null);
    try std.testing.expectEqual(@as(f64, 42), extern_fns.JSValueToNumber(ctx, result, null));

    const obj = (try evaluate.evaluateUtf8(std.testing.allocator, ctx, "({ plusTwo(value) { return value + 2; } })", "home:jsc-call-method", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    const method_result = callMethod(ctx, obj, "plusTwo", &.{arg}, null);
    try std.testing.expectEqual(@as(f64, 43), extern_fns.JSValueToNumber(ctx, method_result, null));
}

test "call helpers detect constructors when JSC is enabled" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const constructor = (try evaluate.evaluateUtf8(std.testing.allocator, ctx, "(function Box(value) { this.value = value; })", "home:jsc-ctor", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    const arrow = (try evaluate.evaluateUtf8(std.testing.allocator, ctx, "(() => 1)", "home:jsc-arrow", 1, null)) orelse
        return error.JSEvaluateReturnedNull;

    try std.testing.expect(isCallable(ctx, constructor));
    try std.testing.expect(isConstructor(ctx, constructor));
    try std.testing.expect(isCallable(ctx, arrow));
    try std.testing.expect(!isConstructor(ctx, arrow));

    const arg = extern_fns.JSValueMakeNumber(ctx, 42) orelse return error.JSValueMakeFailed;
    const instance = constructObject(ctx, constructor, &.{arg}, null);
    const value_name = extern_fns.JSStringCreateWithUTF8CString("value") orelse return error.StringInitFailed;
    defer extern_fns.JSStringRelease(value_name);
    const value = extern_fns.JSObjectGetProperty(ctx, @ptrCast(instance), value_name, null) orelse
        return error.JSPropertyGetFailed;
    try std.testing.expectEqual(@as(f64, 42), extern_fns.JSValueToNumber(ctx, value, null));
}

comptime {
    _ = JSObject;
}
