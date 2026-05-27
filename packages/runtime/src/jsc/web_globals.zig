// Phase 3 — minimal Web Platform globals for the native JSC eval/run realm.
//
// The bare `JSGlobalContextCreate` realm has standard ECMAScript (JSON, Math,
// Promise, Uint8Array, …) but none of the Web/runtime globals Bun's realm
// exposes. This installs the synchronous, no-event-loop-needed subset that
// real scripts most commonly reach for:
//
//   - `TextEncoder` / `TextDecoder` (UTF-8) — backed by native callbacks that
//     bridge JS strings <-> `Uint8Array` through the JSC typed-array C API.
//   - `queueMicrotask` — the standard `Promise.resolve().then` scheduling.
//   - `btoa` / `atob` — Latin1 base64, implemented in JS so char-code access
//     is faithful (no UTF-8 reinterpretation of the input).
//
// Timers (`setTimeout`), `URL`, `crypto`, and `fetch` are intentionally left
// out: they need an event loop / larger subsystems (documented next steps).
// Same register-natives-then-JS-glue pattern as `console.zig`/`process.zig`.

const std = @import("std");
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
    const text_z = allocator.dupeZ(u8, text) catch return null;
    defer allocator.free(text_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

/// `TextEncoder.prototype.encode(string)` -> `Uint8Array` of the UTF-8 bytes.
fn textEncodeNative(
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
    const allocator = std.heap.page_allocator;

    var utf8: []const u8 = "";
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    if (argument_count >= 1) {
        if (arguments[0]) |value| {
            if (extern_fns.JSValueToStringCopy(c, value, null)) |string| {
                defer extern_fns.JSStringRelease(string);
                const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
                const buf = allocator.alloc(u8, capacity) catch return makeUint8Array(c, "");
                const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
                owned = buf;
                utf8 = buf[0 .. if (written > 0) written - 1 else 0];
            }
        }
    }
    return makeUint8Array(c, utf8);
}

fn makeUint8Array(ctx: *JSContextRef, bytes: []const u8) ?*JSValue {
    const array = extern_fns.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, null) orelse
        return extern_fns.JSValueMakeUndefined(ctx);
    if (bytes.len > 0) {
        if (extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, array, null)) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..bytes.len], bytes);
        }
    }
    return @ptrCast(array);
}

/// `TextDecoder.prototype.decode(uint8array)` -> UTF-8 string.
fn textDecodeNative(
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
    if (argument_count < 1) return jsStringValue(c, "");
    const value = arguments[0] orelse return jsStringValue(c, "");

    if (extern_fns.JSValueGetTypedArrayType(c, value, null) == .kJSTypedArrayTypeNone)
        return jsStringValue(c, "");
    const object = extern_fns.JSValueToObject(c, value, null) orelse return jsStringValue(c, "");
    const length = extern_fns.JSObjectGetTypedArrayLength(c, object, null);
    if (length == 0) return jsStringValue(c, "");
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(c, object, null) orelse return jsStringValue(c, "");
    const bytes: [*]const u8 = @ptrCast(ptr);

    const allocator = std.heap.page_allocator;
    const z = allocator.allocSentinel(u8, length, 0) catch return jsStringValue(c, "");
    defer allocator.free(z);
    @memcpy(z[0..length], bytes[0..length]);
    const string = extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse return jsStringValue(c, "");
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(c, string);
}

const install_glue =
    \\(function() {
    \\  var encodeFn = globalThis.__home_text_encode;
    \\  var decodeFn = globalThis.__home_text_decode;
    \\  globalThis.queueMicrotask = function(cb) {
    \\    if (typeof cb !== "function") throw new TypeError("queueMicrotask: argument is not a function");
    \\    Promise.resolve().then(cb);
    \\  };
    \\  globalThis.TextEncoder = class TextEncoder {
    \\    get encoding() { return "utf-8"; }
    \\    encode(input) { return encodeFn(input === undefined ? "" : String(input)); }
    \\  };
    \\  globalThis.TextDecoder = class TextDecoder {
    \\    constructor(label) { this._encoding = String(label || "utf-8").toLowerCase(); }
    \\    get encoding() { return "utf-8"; }
    \\    decode(input) { return input === undefined ? "" : decodeFn(input); }
    \\  };
    \\  var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    \\  globalThis.btoa = function(input) {
    \\    var str = String(input);
    \\    for (var k = 0; k < str.length; k++) {
    \\      if (str.charCodeAt(k) > 0xFF) throw new Error("btoa: The string contains characters outside the Latin1 range.");
    \\    }
    \\    var out = "";
    \\    for (var i = 0; i < str.length; i += 3) {
    \\      var b0 = str.charCodeAt(i);
    \\      var b1 = i + 1 < str.length ? str.charCodeAt(i + 1) : NaN;
    \\      var b2 = i + 2 < str.length ? str.charCodeAt(i + 2) : NaN;
    \\      var e0 = b0 >> 2;
    \\      var e1 = ((b0 & 3) << 4) | (isNaN(b1) ? 0 : (b1 >> 4));
    \\      var e2 = isNaN(b1) ? 64 : (((b1 & 15) << 2) | (isNaN(b2) ? 0 : (b2 >> 6)));
    \\      var e3 = isNaN(b2) ? 64 : (b2 & 63);
    \\      out += B64.charAt(e0) + B64.charAt(e1) + (e2 === 64 ? "=" : B64.charAt(e2)) + (e3 === 64 ? "=" : B64.charAt(e3));
    \\    }
    \\    return out;
    \\  };
    \\  globalThis.atob = function(input) {
    \\    var str = String(input).replace(/[ \t\r\n\f]/g, "");
    \\    if (str.length % 4 === 1) throw new Error("atob: invalid base64 length");
    \\    str = str.replace(/=+$/, "");
    \\    var out = "", bits = 0, nbits = 0;
    \\    for (var i = 0; i < str.length; i++) {
    \\      var idx = B64.indexOf(str.charAt(i));
    \\      if (idx === -1) throw new Error("atob: invalid base64 character");
    \\      bits = (bits << 6) | idx;
    \\      nbits += 6;
    \\      if (nbits >= 8) { nbits -= 8; out += String.fromCharCode((bits >> nbits) & 0xFF); }
    \\    }
    \\    return out;
    \\  };
    \\  delete globalThis.__home_text_encode;
    \\  delete globalThis.__home_text_decode;
    \\})();
;

/// Install the minimal Web Platform globals into `ctx`'s realm. No-op when
/// JSC is not linked.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_text_encode", textEncodeNative);
    callback.registerCallback(ctx, global, "__home_text_decode", textDecodeNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:web-globals-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:web-globals-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

test "web globals install exposes the expected surface" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof queueMicrotask === 'function' && typeof btoa === 'function' && typeof atob === 'function' && " ++
        "typeof TextEncoder === 'function' && typeof TextDecoder === 'function' && " ++
        "typeof globalThis.__home_text_encode === 'undefined'"));
}

test "TextEncoder/TextDecoder round-trip UTF-8 including multibyte" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    // ASCII byte length, a known UTF-8 multibyte length, and a full round-trip.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var enc = new TextEncoder();" ++
        "  var a = enc.encode('abc');" ++
        "  if (!(a instanceof Uint8Array) || a.length !== 3 || a[0] !== 97) return false;" ++
        "  var e = enc.encode('héllo');" ++ // é = 2 UTF-8 bytes -> length 6
        "  if (e.length !== 6) return false;" ++
        "  var dec = new TextDecoder();" ++
        "  return dec.decode(enc.encode('round → trip ✓')) === 'round → trip ✓';" ++
        "})()"));
}

test "btoa/atob round-trip and match known vectors" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "btoa('hello') === 'aGVsbG8=' && btoa('Man') === 'TWFu' && btoa('Ma') === 'TWE=' && " ++
        "atob('aGVsbG8=') === 'hello' && atob(btoa('any carnal pleasure.')) === 'any carnal pleasure.'"));
}

test "queueMicrotask runs the callback after the current job" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx, "globalThis.__q = 0; queueMicrotask(function() { globalThis.__q = 1; });", "home:qmt-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__q === 1"));
}
