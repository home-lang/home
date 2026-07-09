// Phase 3 — minimal `crypto` global (Web Crypto subset) for the native JSC
// eval/run realm.
//
// The bare realm has no `crypto`. This installs the two synchronous Web
// Crypto entry points scripts most commonly use:
//
//   - `crypto.getRandomValues(typedArray)` — fills an integer typed array
//     with CSPRNG bytes (libc `arc4random_buf`) and returns it.
//   - `crypto.randomUUID()` — a RFC 4122 v4 UUID string.
//
// `crypto.subtle` (async digest/sign/etc.) needs Promises + larger subsystems
// and is a documented later step. Same register-natives-then-JS-glue pattern
// as the other realm globals; comptime-gated on `enable_jsc`.

const std = @import("std");
const bun = @import("bun");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

fn jsStringValue(ctx: *JSContextRef, text: []const u8) ?*JSValue {
    const allocator = std.heap.page_allocator;
    const text_z = bun.dupeZ(allocator, u8, text) catch return null;
    defer allocator.free(text_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

/// `crypto.getRandomValues(view)` — fill an integer typed array in place.
fn getRandomValuesNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argument_count < 1) return extern_fns.JSValueMakeUndefined(c);
    const value = arguments[0] orelse return extern_fns.JSValueMakeUndefined(c);

    // Integer typed arrays only (Float/ArrayBuffer/None are not accepted).
    switch (extern_fns.JSValueGetTypedArrayType(c, value, null)) {
        .kJSTypedArrayTypeInt8Array,
        .kJSTypedArrayTypeUint8Array,
        .kJSTypedArrayTypeUint8ClampedArray,
        .kJSTypedArrayTypeInt16Array,
        .kJSTypedArrayTypeUint16Array,
        .kJSTypedArrayTypeInt32Array,
        .kJSTypedArrayTypeUint32Array,
        .kJSTypedArrayTypeBigInt64Array,
        .kJSTypedArrayTypeBigUint64Array,
        => {},
        else => return value,
    }

    const object = extern_fns.JSValueToObject(c, value, null) orelse return value;
    const byte_length = extern_fns.JSObjectGetTypedArrayByteLength(c, object, null);
    // Web Crypto quota is 65536 bytes; over that the spec throws. Keep within.
    if (byte_length == 0 or byte_length > 65536) return value;
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(c, object, null) orelse return value;
    std.c.arc4random_buf(@ptrCast(ptr), byte_length);
    return value;
}

/// `crypto.randomUUID()` — RFC 4122 version 4 UUID string.
fn randomUUIDNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = argument_count;
    _ = arguments;
    _ = exception;
    const c = ctx orelse return null;

    var bytes: [16]u8 = undefined;
    std.c.arc4random_buf(&bytes, bytes.len);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant

    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var oi: usize = 0;
    for (bytes, 0..) |b, bi| {
        if (bi == 4 or bi == 6 or bi == 8 or bi == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[b >> 4];
        out[oi + 1] = hex[b & 0x0f];
        oi += 2;
    }
    return jsStringValue(c, &out) orelse extern_fns.JSValueMakeUndefined(c);
}

const install_glue =
    \\(function() {
    \\  var getRandomValuesFn = globalThis.__home_crypto_get_random_values;
    \\  var randomUUIDFn = globalThis.__home_crypto_random_uuid;
    \\  if (typeof globalThis.crypto !== "object" || globalThis.crypto === null) globalThis.crypto = {};
    \\  globalThis.crypto.getRandomValues = function(view) { return getRandomValuesFn(view); };
    \\  globalThis.crypto.randomUUID = function() { return randomUUIDFn(); };
    \\  // crypto.timingSafeEqual(a, b) — constant-time byte comparison (Bun
    \\  // exposes node:crypto's helper on the global crypto too). Throws when the
    \\  // two views differ in byte length, like Node.
    \\  globalThis.crypto.timingSafeEqual = function(a, b) {
    \\    function u8(v) {
    \\      if (v instanceof ArrayBuffer) return new Uint8Array(v);
    \\      if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    \\      throw new TypeError("timingSafeEqual expects an ArrayBuffer or ArrayBufferView");
    \\    }
    \\    var ua = u8(a), ub = u8(b);
    \\    if (ua.length !== ub.length) throw new RangeError("Input buffers must have the same byte length");
    \\    var diff = 0; for (var i = 0; i < ua.length; i++) diff |= ua[i] ^ ub[i];
    \\    return diff === 0;
    \\  };
    \\  delete globalThis.__home_crypto_get_random_values;
    \\  delete globalThis.__home_crypto_random_uuid;
    \\})();
;

/// Install the minimal `crypto` global into `ctx`'s realm. No-op when JSC is
/// not linked.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_crypto_get_random_values", getRandomValuesNative);
    callback.registerCallback(ctx, global, "__home_crypto_random_uuid", randomUUIDNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:crypto-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:crypto-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

test "crypto install exposes getRandomValues + randomUUID" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof crypto === 'object' && typeof crypto.getRandomValues === 'function' && " ++
        "typeof crypto.randomUUID === 'function' && " ++
        "typeof globalThis.__home_crypto_random_uuid === 'undefined'"));
}

test "crypto.getRandomValues fills the view and returns it" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Returns the same object; a 32-byte view is not left all-zero (the
    // all-zero probability is 256^-32, i.e. impossible in practice).
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var a = new Uint8Array(32); var r = crypto.getRandomValues(a); " ++
        "return r === a && a.some(function(x){ return x !== 0; }); })()"));
}

test "crypto.randomUUID matches the v4 shape and is unique" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var re = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/; " ++
        "var u1 = crypto.randomUUID(); var u2 = crypto.randomUUID(); " ++
        "return re.test(u1) && re.test(u2) && u1 !== u2; })()"));
}

test "crypto.timingSafeEqual compares bytes and enforces equal length" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var a = new Uint8Array([1, 2, 3]);" ++
        "  if (crypto.timingSafeEqual(a, new Uint8Array([1, 2, 3])) !== true) return false;" ++
        "  if (crypto.timingSafeEqual(a, new Uint8Array([1, 2, 4])) !== false) return false;" ++
        "  if (crypto.timingSafeEqual(a.buffer, new Uint8Array([1, 2, 3]).buffer) !== true) return false;" ++
        "  var threw = false; try { crypto.timingSafeEqual(a, new Uint8Array([1, 2])); } catch (e) { threw = e instanceof RangeError; }" ++
        "  return threw;" ++
        "})()"));
}
