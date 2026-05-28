// Phase 12.2 M1 — central JSC C-API extern-fn declarations.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M1 (Binding Layer Foundation),
// this file declares the ~30 most-used C-API entrypoints. Bodies are
// linker-resolved — we don't implement them. They will fail at link
// time until JSC C++ availability is settled (M3 lands the linkage).
//
// The function signatures mirror Apple's `<JavaScriptCore/JSValueRef.h>`
// and `<JSObjectRef.h>` so a downstream caller can swap in the system
// JSC framework with zero code changes. Each entry is `pub extern "c"`
// so the symbol is C-ABI by default.
//
// References:
//   - Bun upstream: `~/Code/bun/src/jsc/javascript_core_c_api.zig`
//   - Apple SDK: `<JavaScriptCore/JavaScriptCore.h>` (macOS 14+)
//   - Home leaf: `jsc/javascript_core_c_api.zig` (legacy entrypoints; the
//     full file already declares the legacy `JSC__*` exports — this file
//     is the "new code" pathway and stays minimal until M2).

const std = @import("std");
const opaques = @import("opaques.zig");
const types = @import("types.zig");

const JSValue = opaques.JSValue;
const JSGlobalObject = opaques.JSGlobalObject;
const JSObject = opaques.JSObject;
const JSObjectRef = opaques.JSObjectRef;
const JSContextRef = opaques.JSContextRef;
const JSString = opaques.JSString;
const VM = opaques.VM;
const JSType = types.JSType;
const JSTypedArrayType = types.JSTypedArrayType;

/// `ExceptionRef` is a sink for thrown values; C callers pass a
/// `JSValueRef*` and JSC writes back through the indirection.
pub const ExceptionRef = [*c]?*JSValue;
pub const JSObjectCallAsFunctionCallback = *const fn (
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: ExceptionRef,
) callconv(.c) ?*JSValue;

// ---- VM lifecycle -------------------------------------------------------

pub extern "c" fn JSGarbageCollect(ctx: ?*JSContextRef) void;
pub extern "c" fn JSGlobalContextCreate(global_class: ?*anyopaque) ?*JSContextRef;
pub extern "c" fn JSGlobalContextRelease(ctx: ?*JSContextRef) void;
pub extern "c" fn JSGlobalContextRetain(ctx: ?*JSContextRef) ?*JSContextRef;
pub extern "c" fn JSContextGetGlobalObject(ctx: ?*JSContextRef) ?*JSObject;
pub extern "c" fn JSEvaluateScript(ctx: ?*JSContextRef, script: ?*JSString, this_object: ?*JSObject, source_url: ?*JSString, starting_line_number: c_int, exception: ExceptionRef) ?*JSValue;

// ---- JSValue inspection ------------------------------------------------

pub extern "c" fn JSValueGetType(ctx: ?*JSContextRef, value: ?*JSValue) JSType;
pub extern "c" fn JSValueIsUndefined(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueIsNull(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueIsBoolean(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueIsNumber(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueIsString(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueIsObject(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueIsArray(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueIsDate(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueIsEqual(ctx: ?*JSContextRef, a: ?*JSValue, b: ?*JSValue, exception: ExceptionRef) bool;
pub extern "c" fn JSValueIsStrictEqual(ctx: ?*JSContextRef, a: ?*JSValue, b: ?*JSValue) bool;

// ---- JSValue constructors ---------------------------------------------

pub extern "c" fn JSValueMakeUndefined(ctx: ?*JSContextRef) ?*JSValue;
pub extern "c" fn JSValueMakeNull(ctx: ?*JSContextRef) ?*JSValue;
pub extern "c" fn JSValueMakeBoolean(ctx: ?*JSContextRef, b: bool) ?*JSValue;
pub extern "c" fn JSValueMakeNumber(ctx: ?*JSContextRef, n: f64) ?*JSValue;
pub extern "c" fn JSValueMakeString(ctx: ?*JSContextRef, str: ?*JSString) ?*JSValue;

// ---- JSValue coercion -------------------------------------------------

pub extern "c" fn JSValueToBoolean(ctx: ?*JSContextRef, value: ?*JSValue) bool;
pub extern "c" fn JSValueToNumber(ctx: ?*JSContextRef, value: ?*JSValue, exception: ExceptionRef) f64;
pub extern "c" fn JSValueToStringCopy(ctx: ?*JSContextRef, value: ?*JSValue, exception: ExceptionRef) ?*JSString;
pub extern "c" fn JSValueToObject(ctx: ?*JSContextRef, value: ?*JSValue, exception: ExceptionRef) ?*JSObject;
pub extern "c" fn JSValueProtect(ctx: ?*JSContextRef, value: ?*JSValue) void;
pub extern "c" fn JSValueUnprotect(ctx: ?*JSContextRef, value: ?*JSValue) void;

// ---- JSObject construction & properties --------------------------------

pub extern "c" fn JSObjectMake(ctx: ?*JSContextRef, class: ?*anyopaque, data: ?*anyopaque) ?*JSObject;
pub extern "c" fn JSObjectMakeArray(ctx: ?*JSContextRef, argc: usize, argv: [*c]const ?*JSValue, exception: ExceptionRef) ?*JSObject;
pub extern "c" fn JSObjectMakeDeferredPromise(ctx: ?*JSContextRef, resolve: [*c]?*JSObject, reject: [*c]?*JSObject, exception: ExceptionRef) ?*JSObject;
pub extern "c" fn JSObjectGetProperty(ctx: ?*JSContextRef, object: ?*JSObject, name: ?*JSString, exception: ExceptionRef) ?*JSValue;
pub extern "c" fn JSObjectSetProperty(ctx: ?*JSContextRef, object: ?*JSObject, name: ?*JSString, value: ?*JSValue, attrs: c_uint, exception: ExceptionRef) void;
pub extern "c" fn JSObjectGetPropertyAtIndex(ctx: ?*JSContextRef, object: ?*JSObject, index: c_uint, exception: ExceptionRef) ?*JSValue;
pub extern "c" fn JSObjectCallAsFunction(ctx: ?*JSContextRef, fun: ?*JSObject, this: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: ExceptionRef) ?*JSValue;
pub extern "c" fn JSObjectMakeFunctionWithCallback(ctx: ?*JSContextRef, name: ?*JSString, callback: JSObjectCallAsFunctionCallback) ?*JSObject;
pub extern "c" fn JSObjectCallAsConstructor(ctx: ?*JSContextRef, constructor: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: ExceptionRef) ?*JSObject;
pub extern "c" fn JSObjectIsFunction(ctx: ?*JSContextRef, object: ?*JSObject) bool;
pub extern "c" fn JSObjectIsConstructor(ctx: ?*JSContextRef, object: ?*JSObject) bool;

// ---- Typed arrays (TextEncoder/TextDecoder etc.) -----------------------
// Mirrors <JavaScriptCore/JSTypedArray.h>.
pub extern "c" fn JSObjectMakeTypedArray(ctx: ?*JSContextRef, array_type: JSTypedArrayType, length: usize, exception: ExceptionRef) ?*JSObject;
pub extern "c" fn JSObjectGetTypedArrayBytesPtr(ctx: ?*JSContextRef, object: ?*JSObject, exception: ExceptionRef) ?*anyopaque;
pub extern "c" fn JSObjectGetTypedArrayLength(ctx: ?*JSContextRef, object: ?*JSObject, exception: ExceptionRef) usize;
pub extern "c" fn JSObjectGetTypedArrayByteLength(ctx: ?*JSContextRef, object: ?*JSObject, exception: ExceptionRef) usize;
pub extern "c" fn JSValueGetTypedArrayType(ctx: ?*JSContextRef, value: ?*JSValue, exception: ExceptionRef) JSTypedArrayType;

// ---- JSString lifecycle ----------------------------------------------

pub extern "c" fn JSStringCreateWithUTF8CString(utf8: [*:0]const u8) ?*JSString;
pub extern "c" fn JSStringRetain(str: ?*JSString) ?*JSString;
pub extern "c" fn JSStringRelease(str: ?*JSString) void;
pub extern "c" fn JSStringGetLength(str: ?*JSString) usize;
pub extern "c" fn JSStringGetUTF8CString(str: ?*JSString, buf: [*]u8, buf_size: usize) usize;

test "extern fn type signatures are well-formed" {
    // Type-level only — we never reference the extern symbols themselves,
    // so this test compiles without forcing the linker to resolve them.
    // Bodies stay unresolved until M3 lands the JSC C++ linkage; running
    // `home_rt_tests` will fail at link with these new symbols and that
    // is the expected M1 acceptance condition.
    try std.testing.expect(@typeInfo(@TypeOf(JSGarbageCollect)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSValueGetType)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSValueMakeNull)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSEvaluateScript)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSObjectMake)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSObjectMakeDeferredPromise)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSObjectMakeFunctionWithCallback)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSObjectCallAsConstructor)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSObjectIsFunction)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(JSStringRelease)) == .@"fn");
    try std.testing.expect(@TypeOf(JSGarbageCollect) != @TypeOf(JSValueMakeNull));
}
