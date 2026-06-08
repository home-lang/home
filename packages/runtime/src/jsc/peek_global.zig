// Native `Bun.peek` for the eval/run realm. Mirrors Bun's peek: synchronously
// inspect a Promise's settled state without awaiting.
//
//   - `Bun.peek(value)` -> the fulfilled value / rejection reason for a settled
//     promise, the promise itself if still pending, or `value` unchanged if it
//     is not a real promise.
//   - `Bun.peek.status(value)` -> "pending" | "fulfilled" | "rejected"
//     ("fulfilled" for non-promises).
//
// This needs JSC promise introspection that the public C API does not expose,
// so it bridges the realm's C-API `JSValueRef` to the internal `jsc.JSValue`
// (they share the EncodedJSValue bit pattern) and uses `JSValue.asPromise`
// (a safe dynamic cast — null for non-promises and Promise-prototype fakes)
// plus `JSPromise.status`/`result`. comptime-gated on `enable_jsc`.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const CJSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const CJSObject = opaques.JSObject;
const CJSGlobalObject = opaques.JSGlobalObject;

const JSValue = @import("JSValue.zig").JSValue;
const IGlobal = @import("JSGlobalObject.zig").JSGlobalObject;

/// C-API `JSValueRef` -> internal `jsc.JSValue`. The two share the
/// EncodedJSValue representation (`enum(i64)`), so this is a bit reinterpret.
fn refToInternal(ref: *CJSValue) JSValue {
    return @enumFromInt(@as(i64, @bitCast(@intFromPtr(ref))));
}
fn internalToRef(v: JSValue) ?*CJSValue {
    return @ptrFromInt(@as(usize, @bitCast(@intFromEnum(v))));
}

fn makeJsString(ctx: *JSContextRef, s: [:0]const u8) ?*CJSValue {
    const js = extern_fns.JSStringCreateWithUTF8CString(s.ptr) orelse return extern_fns.JSValueMakeNull(ctx);
    defer extern_fns.JSStringRelease(js);
    return extern_fns.JSValueMakeString(ctx, js);
}

/// `__home_peek(value)` — see file header.
fn peekNative(ctx: ?*JSContextRef, function: ?*CJSObject, this_object: ?*CJSObject, argc: usize, argv: [*c]const ?*CJSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*CJSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 1) return extern_fns.JSValueMakeUndefined(c);
    const ref = argv[0] orelse return extern_fns.JSValueMakeUndefined(c);
    const promise = refToInternal(ref).asPromise() orelse return ref;
    if (promise.status() == .pending) return ref;
    const cglobal = extern_fns.JSContextGetGlobalObject(c) orelse return ref;
    const iglobal: *IGlobal = @ptrCast(cglobal);
    const res = promise.result(iglobal.vm());
    return internalToRef(res) orelse extern_fns.JSValueMakeUndefined(c);
}

/// `__home_peek_status(value)` — see file header.
fn peekStatusNative(ctx: ?*JSContextRef, function: ?*CJSObject, this_object: ?*CJSObject, argc: usize, argv: [*c]const ?*CJSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*CJSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 1) return makeJsString(c, "fulfilled");
    const ref = argv[0] orelse return makeJsString(c, "fulfilled");
    const promise = refToInternal(ref).asPromise() orelse return makeJsString(c, "fulfilled");
    return makeJsString(c, switch (promise.status()) {
        .pending => "pending",
        .fulfilled => "fulfilled",
        .rejected => "rejected",
    });
}

const install_glue =
    \\(function() {
    \\  var peekFn = globalThis.__home_peek;
    \\  var statusFn = globalThis.__home_peek_status;
    \\  function peek(value) { return peekFn(value); }
    \\  peek.status = function(value) { return statusFn(value); };
    \\  if (typeof globalThis.Bun === "object" && globalThis.Bun) globalThis.Bun.peek = peek;
    \\  delete globalThis.__home_peek;
    \\  delete globalThis.__home_peek_status;
    \\})();
;

/// Install `Bun.peek`. No-op without JSC. Must run after `bun_global.install`.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *CJSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_peek", peekNative);
    callback.registerCallback(ctx, global, "__home_peek_status", peekStatusNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:bun-peek-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:peek-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *CJSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("bun_global.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Bun.peek inspects settled promises synchronously (corpus parity)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/peek.test.ts.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (Bun.peek(Promise.resolve(true)) !== true) return false;" ++
        "  if (Bun.peek(42) !== 42) return false;" ++
        "  var pending = new Promise(function() {});" ++
        "  if (Bun.peek(pending) !== pending) return false;" ++
        "  var rejected = Promise.reject(new Error('nope'));" ++
        "  var p = Bun.peek(rejected);" ++
        "  if (!(p instanceof Error) || p.message !== 'nope') return false;" ++
        "  rejected.catch(function() {});" ++
        "  if (!(Bun.peek({ __proto__: Promise.prototype }) instanceof Promise)) return false;" ++
        "  return true; })()"));
}

test "Bun.peek.status reports pending/fulfilled/rejected (corpus parity)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (Bun.peek.status(Promise.resolve(true)) !== 'fulfilled') return false;" ++
        "  if (Bun.peek.status(new Promise(function() {})) !== 'pending') return false;" ++
        "  var rejected = Promise.reject(new Error('oh no'));" ++
        "  var ok = Bun.peek.status(rejected) === 'rejected';" ++
        "  rejected.catch(function() {});" ++
        "  if (!ok) return false;" ++
        "  return Bun.peek.status(1) === 'fulfilled'; })()"));
}
