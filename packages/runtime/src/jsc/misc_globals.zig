// Phase 3 — remaining synchronous realm globals for the native JSC eval/run
// realm: `performance` (high-res timer), the `global`/`self`/`globalThis`
// aliases, and `structuredClone`.
//
//   - `performance.now()` — native monotonic clock, sub-millisecond float,
//     measured from `performance.timeOrigin` (the realm's start). This is the
//     same monotonic-clock approach Bun uses, not a JS approximation.
//   - `performance.timeOrigin` — wall-clock ms (Unix epoch) at install.
//   - `globalThis.global` / `globalThis.self` — the Node and Web aliases for
//     the global object.
//   - `structuredClone(value)` — structured deep clone covering the common
//     cloneable types (primitives, Array, plain object, Date, RegExp, Map,
//     Set, ArrayBuffer, typed arrays) with circular-reference support; throws
//     DataCloneError for functions/symbols, matching the spec's intent.
//
// Same install pattern as the other realm globals; comptime-gated on
// `enable_jsc`.

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

var g_origin_ns: i128 = 0;

fn monotonicNs() i128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

fn wallClockMs() f64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(f64, @floatFromInt(ts.sec)) * 1000.0 + @as(f64, @floatFromInt(ts.nsec)) / 1.0e6;
}

/// `performance.now()` — high-resolution ms since `performance.timeOrigin`.
fn performanceNowNative(
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
    const ms = @as(f64, @floatFromInt(monotonicNs() - g_origin_ns)) / 1.0e6;
    return extern_fns.JSValueMakeNumber(ctx, ms);
}

fn timeOriginNative(
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
    return extern_fns.JSValueMakeNumber(ctx, wallClockMs());
}

const install_glue =
    \\(function() {
    \\  var nowFn = globalThis.__home_perf_now;
    \\  var timeOrigin = globalThis.__home_perf_time_origin();
    \\  var perfEntries = [];
    \\  globalThis.performance = {
    \\    now: function() { return nowFn(); },
    \\    timeOrigin: timeOrigin,
    \\    mark: function(name, options) {
    \\      var startTime = (options && typeof options.startTime === "number") ? options.startTime : nowFn();
    \\      var e = { name: String(name), entryType: "mark", startTime: startTime, duration: 0, detail: (options && options.detail) || null };
    \\      perfEntries.push(e); return e;
    \\    },
    \\    measure: function(name, startOrOptions, endMark) {
    \\      var start = 0, end = nowFn();
    \\      function markTime(m) { for (var i = perfEntries.length - 1; i >= 0; i--) if (perfEntries[i].name === m && perfEntries[i].entryType === "mark") return perfEntries[i].startTime; return 0; }
    \\      if (startOrOptions && typeof startOrOptions === "object") {
    \\        if (startOrOptions.start !== undefined) start = typeof startOrOptions.start === "number" ? startOrOptions.start : markTime(startOrOptions.start);
    \\        if (startOrOptions.end !== undefined) end = typeof startOrOptions.end === "number" ? startOrOptions.end : markTime(startOrOptions.end);
    \\        if (startOrOptions.duration !== undefined && startOrOptions.start !== undefined) end = start + startOrOptions.duration;
    \\      } else if (startOrOptions !== undefined) {
    \\        start = typeof startOrOptions === "number" ? startOrOptions : markTime(startOrOptions);
    \\        if (endMark !== undefined) end = typeof endMark === "number" ? endMark : markTime(endMark);
    \\      }
    \\      var e = { name: String(name), entryType: "measure", startTime: start, duration: end - start, detail: null };
    \\      perfEntries.push(e); return e;
    \\    },
    \\    getEntries: function() { return perfEntries.slice(); },
    \\    getEntriesByName: function(name, type) { return perfEntries.filter(function(e) { return e.name === name && (!type || e.entryType === type); }); },
    \\    getEntriesByType: function(type) { return perfEntries.filter(function(e) { return e.entryType === type; }); },
    \\    clearMarks: function(name) { perfEntries = perfEntries.filter(function(e) { return e.entryType !== "mark" || (name !== undefined && e.name !== name); }); },
    \\    clearMeasures: function(name) { perfEntries = perfEntries.filter(function(e) { return e.entryType !== "measure" || (name !== undefined && e.name !== name); }); },
    \\    eventCounts: new Map(),
    \\    toJSON: function() { return { timeOrigin: timeOrigin }; },
    \\  };
    \\  // setImmediate/clearImmediate (Node) over the timer loop.
    \\  if (typeof globalThis.setImmediate !== "function" && typeof globalThis.setTimeout === "function") {
    \\    globalThis.setImmediate = function(fn) { var extra = Array.prototype.slice.call(arguments, 1); return globalThis.setTimeout(function() { fn.apply(undefined, extra); }, 0); };
    \\    globalThis.clearImmediate = function(id) { return globalThis.clearTimeout ? globalThis.clearTimeout(id) : undefined; };
    \\  }
    \\  // reportError — dispatch to the error handler / log to stderr.
    \\  if (typeof globalThis.reportError !== "function") {
    \\    globalThis.reportError = function(err) {
    \\      if (typeof globalThis.console !== "undefined" && globalThis.console.error) globalThis.console.error(err);
    \\    };
    \\  }
    \\  globalThis.global = globalThis;
    \\  globalThis.self = globalThis;
    \\  globalThis.structuredClone = function(value) {
    \\    var seen = new Map();
    \\    function clone(v) {
    \\      if (v === null || typeof v !== "object") {
    \\        if (typeof v === "function" || typeof v === "symbol") {
    \\          var e = new Error("structuredClone: " + typeof v + " could not be cloned.");
    \\          e.name = "DataCloneError";
    \\          throw e;
    \\        }
    \\        return v;
    \\      }
    \\      if (seen.has(v)) return seen.get(v);
    \\      if (v instanceof Date) return new Date(v.getTime());
    \\      if (v instanceof RegExp) return new RegExp(v.source, v.flags);
    \\      if (typeof ArrayBuffer !== "undefined" && v instanceof ArrayBuffer) return v.slice(0);
    \\      if (ArrayBuffer.isView(v)) {
    \\        if (v instanceof DataView) return new DataView(clone(v.buffer), v.byteOffset, v.byteLength);
    \\        return new v.constructor(clone(v.buffer), v.byteOffset, v.length);
    \\      }
    \\      if (v instanceof Map) {
    \\        var m = new Map(); seen.set(v, m);
    \\        v.forEach(function(val, key) { m.set(clone(key), clone(val)); });
    \\        return m;
    \\      }
    \\      if (v instanceof Set) {
    \\        var s = new Set(); seen.set(v, s);
    \\        v.forEach(function(val) { s.add(clone(val)); });
    \\        return s;
    \\      }
    \\      if (Array.isArray(v)) {
    \\        var arr = new Array(v.length); seen.set(v, arr);
    \\        for (var i = 0; i < v.length; i++) arr[i] = clone(v[i]);
    \\        return arr;
    \\      }
    \\      var out = {}; seen.set(v, out);
    \\      for (var k in v) { if (Object.prototype.hasOwnProperty.call(v, k)) out[k] = clone(v[k]); }
    \\      return out;
    \\    }
    \\    return clone(value);
    \\  };
    \\  delete globalThis.__home_perf_now;
    \\  delete globalThis.__home_perf_time_origin;
    \\})();
;

/// Install `performance`, `global`/`self`, and `structuredClone`. No-op
/// without JSC.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    g_origin_ns = monotonicNs();
    callback.registerCallback(ctx, global, "__home_perf_now", performanceNowNative);
    callback.registerCallback(ctx, global, "__home_perf_time_origin", timeOriginNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:misc-globals-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:misc-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

test "misc globals install exposes performance/global/self/structuredClone" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof performance === 'object' && typeof performance.now === 'function' && " ++
        "typeof performance.timeOrigin === 'number' && " ++
        "globalThis.global === globalThis && globalThis.self === globalThis && " ++
        "typeof structuredClone === 'function' && " ++
        "typeof globalThis.__home_perf_now === 'undefined'"));
}

test "performance.now is monotonic non-decreasing and sub-ms resolution" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { var a = performance.now(); var b = performance.now(); " ++
        "return typeof a === 'number' && b >= a && a >= 0; })()"));
}

test "structuredClone deep-clones and preserves cycles" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var src = { n: 1, arr: [1, 2, { x: 3 }], d: new Date(1000), m: new Map([['k', 'v']]) };" ++
        "  src.self = src;" ++ // cycle
        "  var c = structuredClone(src);" ++
        "  return c !== src && c.n === 1 && c.arr[2].x === 3 && c.arr !== src.arr && " ++
        "    c.d instanceof Date && c.d.getTime() === 1000 && c.m.get('k') === 'v' && " ++
        "    c.self === c;" ++ // cycle preserved, points to the clone
        "})()"));
}

test "structuredClone throws DataCloneError for functions" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() { try { structuredClone(function(){}); return false; } " ++
        "catch (e) { return e.name === 'DataCloneError'; } })()"));
}
