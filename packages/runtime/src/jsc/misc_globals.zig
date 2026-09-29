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
//     Set, ArrayBuffer, SharedArrayBuffer, typed arrays) with circular-reference
//     support and ArrayBuffer transfer; throws DataCloneError for unsupported
//     values. Shared buffers retain their backing-store identity when the
//     linked serializer supports it; otherwise cloning fails with
//     DataCloneError.
//   - `BroadcastChannel` — deliberately fails with `NotSupportedError` in this
//     single-context fallback instead of pretending to provide cross-context
//     delivery.
//
// Same install pattern as the other realm globals; comptime-gated on
// `enable_jsc`.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");
const node_util = @import("../node/util.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;
const InternalJSValue = @import("JSValue.zig").JSValue;
const InternalGlobalObject = @import("JSGlobalObject.zig").JSGlobalObject;

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

fn refToInternal(ref: *JSValue) InternalJSValue {
    return @fromBackingInt(@intCast(@as(i64, @bitCast(@intFromPtr(ref)))));
}

fn internalToRef(value: InternalJSValue) ?*JSValue {
    return @ptrFromInt(@as(usize, @bitCast(@backingInt(value))));
}

fn returnNativeException(
    context: *JSContextRef,
    global: *InternalGlobalObject,
    err: anytype,
    exception: extern_fns.ExceptionRef,
) ?*JSValue {
    if (exception != null) {
        exception[0] = internalToRef(global.takeException(err));
    }
    return extern_fns.JSValueMakeUndefined(context);
}

/// Clone one SharedArrayBuffer through JSC's native serializer. Older linked
/// serializers copied shared contents instead of retaining the shared backing
/// store, so verify both descriptors before publishing the clone. Returning
/// null makes the JS wrapper throw DataCloneError instead of silently changing
/// the memory model.
fn cloneSharedArrayBufferNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;

    const context = ctx orelse return null;
    if (argument_count < 1) return null;
    const value_ref = arguments[0] orelse return null;
    const global_ref = extern_fns.JSContextGetGlobalObject(context) orelse return null;
    const global: *InternalGlobalObject = @ptrCast(global_ref);
    const value = refToInternal(value_ref);
    const source = value.asArrayBuffer(global) orelse return null;
    if (!node_util.types.isSharedArrayBuffer(source)) return null;

    const serialized = value.serialize(global, .{}) catch |err| return returnNativeException(context, global, err, exception);
    defer serialized.deinit();
    const clone = InternalJSValue.deserialize(serialized.data, global) catch |err| return returnNativeException(context, global, err, exception);
    const cloned = clone.asArrayBuffer(global) orelse return null;
    if (!node_util.types.isSharedArrayBuffer(cloned) or source.byte_len != cloned.byte_len or source.ptr != cloned.ptr) return null;
    return internalToRef(clone);
}

const install_glue =
    "(function() {\n" ++ @embedFile("urlpattern_polyfill.js") ++ "\n})();\n" ++
    \\(function() {
    \\  var nowFn = globalThis.__home_perf_now;
    \\  var timeOrigin = globalThis.__home_perf_time_origin();
    \\  var perfEntries = [];
    \\  function illegalPerformanceConstructor(name) {
    \\    var error = new TypeError("Illegal constructor: " + name);
    \\    error.code = "ERR_ILLEGAL_CONSTRUCTOR";
    \\    error.operation = "web.performance.construct";
    \\    return error;
    \\  }
    \\  if (typeof globalThis.Performance !== "function") globalThis.Performance = function Performance() { throw illegalPerformanceConstructor("Performance"); };
    \\  if (typeof globalThis.PerformanceEntry !== "function") globalThis.PerformanceEntry = function PerformanceEntry() { throw illegalPerformanceConstructor("PerformanceEntry"); };
    \\  if (typeof globalThis.PerformanceMark !== "function") {
    \\    globalThis.PerformanceMark = function PerformanceMark() { throw illegalPerformanceConstructor("PerformanceMark"); };
    \\    PerformanceMark.prototype = Object.create(PerformanceEntry.prototype);
    \\    PerformanceMark.prototype.constructor = PerformanceMark;
    \\  }
    \\  if (typeof globalThis.PerformanceMeasure !== "function") {
    \\    globalThis.PerformanceMeasure = function PerformanceMeasure() { throw illegalPerformanceConstructor("PerformanceMeasure"); };
    \\    PerformanceMeasure.prototype = Object.create(PerformanceEntry.prototype);
    \\    PerformanceMeasure.prototype.constructor = PerformanceMeasure;
    \\  }
    \\  if (typeof globalThis.PerformanceObserver !== "function") {
    \\    globalThis.PerformanceObserver = function PerformanceObserver(callback) {
    \\      if (!(this instanceof PerformanceObserver)) throw new TypeError("PerformanceObserver requires 'new'");
    \\      if (typeof callback !== "function") throw new TypeError("PerformanceObserver callback must be a function");
    \\      this.callback = callback; this.options = null;
    \\    };
    \\    PerformanceObserver.prototype.observe = function(options) { this.options = options || {}; };
    \\    PerformanceObserver.prototype.disconnect = function() { this.options = null; };
    \\    PerformanceObserver.prototype.takeRecords = function() { return []; };
    \\  }
    \\  if (typeof globalThis.PerformanceObserverEntryList !== "function") {
    \\    globalThis.PerformanceObserverEntryList = function PerformanceObserverEntryList() { throw illegalPerformanceConstructor("PerformanceObserverEntryList"); };
    \\    PerformanceObserverEntryList.prototype.getEntries = function() { return []; };
    \\    PerformanceObserverEntryList.prototype.getEntriesByName = function() { return []; };
    \\    PerformanceObserverEntryList.prototype.getEntriesByType = function() { return []; };
    \\  }
    \\  if (typeof globalThis.PerformanceResourceTiming !== "function") {
    \\    globalThis.PerformanceResourceTiming = function PerformanceResourceTiming() { throw illegalPerformanceConstructor("PerformanceResourceTiming"); };
    \\    PerformanceResourceTiming.prototype = Object.create(PerformanceEntry.prototype);
    \\    PerformanceResourceTiming.prototype.constructor = PerformanceResourceTiming;
    \\  }
    \\  if (typeof globalThis.PerformanceServerTiming !== "function") globalThis.PerformanceServerTiming = function PerformanceServerTiming() { throw illegalPerformanceConstructor("PerformanceServerTiming"); };
    \\  if (typeof globalThis.PerformanceTiming !== "function") globalThis.PerformanceTiming = function PerformanceTiming() { throw illegalPerformanceConstructor("PerformanceTiming"); };
    \\  globalThis.performance = Object.assign(Object.create(globalThis.Performance.prototype), {
    \\    now: function() { return nowFn(); },
    \\    timeOrigin: timeOrigin,
    \\    mark: function(name, options) {
    \\      var startTime = (options && typeof options.startTime === "number") ? options.startTime : nowFn();
    \\      var e = Object.assign(Object.create(globalThis.PerformanceMark.prototype), { name: String(name), entryType: "mark", startTime: startTime, duration: 0, detail: (options && options.detail) || null });
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
    \\      var e = Object.assign(Object.create(globalThis.PerformanceMeasure.prototype), { name: String(name), entryType: "measure", startTime: start, duration: end - start, detail: null });
    \\      perfEntries.push(e); return e;
    \\    },
    \\    getEntries: function() { return perfEntries.slice(); },
    \\    getEntriesByName: function(name, type) { return perfEntries.filter(function(e) { return e.name === name && (!type || e.entryType === type); }); },
    \\    getEntriesByType: function(type) { return perfEntries.filter(function(e) { return e.entryType === type; }); },
    \\    clearMarks: function(name) { perfEntries = perfEntries.filter(function(e) { return e.entryType !== "mark" || (name !== undefined && e.name !== name); }); },
    \\    clearMeasures: function(name) { perfEntries = perfEntries.filter(function(e) { return e.entryType !== "measure" || (name !== undefined && e.name !== name); }); },
    \\    eventCounts: new Map(),
    \\    toJSON: function() { return { timeOrigin: timeOrigin }; },
    \\  });
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
    \\  Object.defineProperty(globalThis, "self", {
    \\    configurable: true,
    \\    enumerable: true,
    \\    get: function() { return globalThis; },
    \\    set: function(value) { Object.defineProperty(globalThis, "self", { configurable: true, enumerable: true, writable: true, value: value }); },
    \\  });
    \\  function dataCloneError(message) {
    \\    var error = new Error(message);
    \\    error.name = "DataCloneError";
    \\    return error;
    \\  }
    \\  var cloneSharedArrayBuffer = globalThis.__home_clone_shared_array_buffer;
    \\  var sharedArrayBufferByteLength = (typeof SharedArrayBuffer !== "undefined")
    \\    ? Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "byteLength").get
    \\    : null;
    \\  function isSharedArrayBuffer(value) {
    \\    if (!sharedArrayBufferByteLength || value === null || typeof value !== "object") return false;
    \\    try { sharedArrayBufferByteLength.call(value); return true; } catch (error) { return false; }
    \\  }
    \\  globalThis.structuredClone = function(value, options) {
    \\    var transferList = [];
    \\    if (options != null && options.transfer !== undefined) {
    \\      try { transferList = Array.from(options.transfer); }
    \\      catch (error) { throw new TypeError("structuredClone: transfer must be iterable"); }
    \\    }
    \\    var transfers = new Map();
    \\    for (var transferIndex = 0; transferIndex < transferList.length; transferIndex++) {
    \\      var transferable = transferList[transferIndex];
    \\      if (typeof ArrayBuffer === "undefined" || !(transferable instanceof ArrayBuffer) || isSharedArrayBuffer(transferable)) {
    \\        throw dataCloneError("structuredClone: value in transfer list is not transferable");
    \\      }
    \\      if (transfers.has(transferable)) throw dataCloneError("structuredClone: duplicate transferable");
    \\      if (typeof transferable.transfer !== "function") {
    \\        throw dataCloneError("structuredClone: ArrayBuffer transfer is unavailable in this realm");
    \\      }
    \\      transfers.set(transferable, null);
    \\    }
    \\    var seen = new Map();
    \\    function clone(v) {
    \\      if (v === null || typeof v !== "object") {
    \\        if (typeof v === "function" || typeof v === "symbol") {
    \\          throw dataCloneError("structuredClone: " + typeof v + " could not be cloned.");
    \\        }
    \\        return v;
    \\      }
    \\      if (seen.has(v)) return seen.get(v);
    \\      if (v instanceof Date) return new Date(v.getTime());
    \\      if (v instanceof RegExp) return new RegExp(v.source, v.flags);
    \\      if (isSharedArrayBuffer(v)) {
    \\        var copiedSharedBuffer = cloneSharedArrayBuffer(v);
    \\        if (!isSharedArrayBuffer(copiedSharedBuffer) || copiedSharedBuffer === v) {
    \\          throw dataCloneError("structuredClone: SharedArrayBuffer backing-store cloning is unavailable in this realm");
    \\        }
    \\        seen.set(v, copiedSharedBuffer); return copiedSharedBuffer;
    \\      }
    \\      if (typeof ArrayBuffer !== "undefined" && v instanceof ArrayBuffer) {
    \\        var copiedBuffer = v.slice(0); seen.set(v, copiedBuffer); return copiedBuffer;
    \\      }
    \\      if (ArrayBuffer.isView(v)) {
    \\        var copiedView;
    \\        if (v instanceof DataView) copiedView = new DataView(clone(v.buffer), v.byteOffset, v.byteLength);
    \\        else copiedView = new v.constructor(clone(v.buffer), v.byteOffset, v.length);
    \\        seen.set(v, copiedView); return copiedView;
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
    \\    var result = clone(value);
    \\    transfers.forEach(function(unused, transferable) { transferable.transfer(0); });
    \\    return result;
    \\  };
    \\  // A same-realm registry cannot satisfy BroadcastChannel's cross-context
    \\  // contract. Fail at construction until the native shared registry lands.
    \\  if (typeof globalThis.BroadcastChannel !== "function") {
    \\    function BroadcastChannel(name) {
    \\      void name;
    \\      var error = new Error("BroadcastChannel requires cross-context delivery, which is unavailable in this realm");
    \\      error.name = "NotSupportedError";
    \\      throw error;
    \\    }
    \\    globalThis.BroadcastChannel = BroadcastChannel;
    \\  }
    \\  // URLPattern — pathname/host/etc. matching with :named groups and * wildcards.
    \\  if (typeof globalThis.URLPattern !== "function") {
    \\    function compilePart(pattern) {
    \\      if (pattern === undefined || pattern === null || pattern === "*") return { re: /^.*$/, groups: [] };
    \\      var groups = [], re = "", i = 0, src = String(pattern);
    \\      while (i < src.length) {
    \\        var ch = src[i];
    \\        if (ch === ":") { i++; var nm = ""; while (i < src.length && /[a-zA-Z0-9_]/.test(src[i])) nm += src[i++]; groups.push(nm); re += "([^/]+)"; }
    \\        else if (ch === "*") { groups.push(String(groups.length)); re += "(.*)"; i++; }
    \\        else { re += ch.replace(/[.+?^${}()|[\]\\]/g, "\\$&"); i++; }
    \\      }
    \\      return { re: new RegExp("^" + re + "$"), groups: groups };
    \\    }
    \\    function URLPattern(input, baseURL) {
    \\      var parts = {};
    \\      if (typeof input === "string") {
    \\        try { var u = new globalThis.URL(input, baseURL || "https://example.com"); parts = { protocol: u.protocol.slice(0, -1), hostname: u.hostname, pathname: u.pathname, search: "*", hash: "*" }; }
    \\        catch (e) { parts = { pathname: input }; }
    \\      } else if (input && typeof input === "object") { parts = input; }
    \\      this._parts = parts; this._compiled = {};
    \\      var keys = ["protocol", "username", "password", "hostname", "port", "pathname", "search", "hash"];
    \\      for (var k = 0; k < keys.length; k++) this._compiled[keys[k]] = compilePart(parts[keys[k]]);
    \\    }
    \\    function partsOf(input, baseURL) {
    \\      if (typeof input === "string") { var u = new globalThis.URL(input, baseURL || "https://example.com"); return { protocol: u.protocol.slice(0, -1), username: u.username, password: u.password, hostname: u.hostname, port: u.port, pathname: u.pathname, search: u.search.slice(1), hash: u.hash.slice(1) }; }
    \\      return input || {};
    \\    }
    \\    URLPattern.prototype.exec = function(input, baseURL) {
    \\      var values; try { values = partsOf(input, baseURL); } catch (e) { return null; }
    \\      var result = { inputs: [input] };
    \\      for (var k in this._compiled) {
    \\        var cv = values[k] !== undefined && values[k] !== null ? String(values[k]) : "";
    \\        var m = this._compiled[k].re.exec(cv);
    \\        if (!m) return null;
    \\        var grp = {};
    \\        for (var g = 0; g < this._compiled[k].groups.length; g++) grp[this._compiled[k].groups[g]] = m[g + 1];
    \\        result[k] = { input: cv, groups: grp };
    \\      }
    \\      return result;
    \\    };
    \\    URLPattern.prototype.test = function(input, baseURL) { return this.exec(input, baseURL) !== null; };
    \\    globalThis.URLPattern = URLPattern;
    \\  }
    \\  delete globalThis.__home_perf_now;
    \\  delete globalThis.__home_perf_time_origin;
    \\  delete globalThis.__home_clone_shared_array_buffer;
    \\})();
    ;

/// Install `performance`, `global`/`self`, and `structuredClone`. No-op
/// without JSC.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    g_origin_ns = monotonicNs();
    callback.registerCallback(ctx, global, "__home_perf_now", performanceNowNative);
    callback.registerCallback(ctx, global, "__home_perf_time_origin", timeOriginNative);
    callback.registerCallback(ctx, global, "__home_clone_shared_array_buffer", cloneSharedArrayBufferNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:misc-globals-install", 1) catch |err| {
        std.log.err("failed to evaluate miscellaneous web globals installer: {t}", .{err});
        return;
    };
    defer result.deinit(allocator);
    if (result.exception_message) |message| {
        std.log.err("failed to install miscellaneous web globals: {s}", .{message});
    }
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

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "typeof performance === 'object' && typeof performance.now === 'function' && " ++
        "typeof performance.timeOrigin === 'number' && " ++
        "globalThis.global === globalThis && globalThis.self === globalThis && " ++
        "typeof structuredClone === 'function' && " ++
        "typeof globalThis.__home_perf_now === 'undefined'"));
}

test "performance constructors and writable self accessor match the web realm" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  var names = ['Performance', 'PerformanceEntry', 'PerformanceMark', 'PerformanceMeasure', 'PerformanceObserver', 'PerformanceObserverEntryList', 'PerformanceResourceTiming', 'PerformanceServerTiming', 'PerformanceTiming'];" ++
        "  if (!names.every(function(name) { return typeof globalThis[name] === 'function'; })) return false;" ++
        "  var mark = performance.mark('ready');" ++
        "  if (!(mark instanceof PerformanceMark) || !(mark instanceof PerformanceEntry)) return false;" ++
        "  var failure = null; try { new PerformanceTiming(); } catch (error) { failure = error; }" ++
        "  if (!(failure instanceof TypeError) || failure.code !== 'ERR_ILLEGAL_CONSTRUCTOR' || failure.operation !== 'web.performance.construct') return false;" ++
        "  var descriptor = Object.getOwnPropertyDescriptor(globalThis, 'self');" ++
        "  if (!descriptor || typeof descriptor.get !== 'function' || typeof descriptor.set !== 'function') return false;" ++
        "  globalThis.self = 123; if (globalThis.self !== 123) return false;" ++
        "  Object.defineProperty(globalThis, 'self', descriptor);" ++
        "  return globalThis.self === globalThis;" ++
        "})()"));
}

test "performance.now is monotonic non-decreasing and sub-ms resolution" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() { var a = performance.now(); var b = performance.now(); " ++
        "return typeof a === 'number' && b >= a && a >= 0; })()"));
}

test "structuredClone deep-clones and preserves cycles" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
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

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() { try { structuredClone(function(){}); return false; } " ++
        "catch (e) { return e.name === 'DataCloneError'; } })()"));
}

test "structuredClone preserves shared backing stores and transfers ArrayBuffers" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  if (typeof SharedArrayBuffer !== 'function') return false;" ++
        "  var shared = new SharedArrayBuffer(8); var source = new Uint8Array(shared); source[2] = 7;" ++
        "  try {" ++
        "    var sharedClone = structuredClone({ shared: shared, view: source });" ++
        "    if (sharedClone.shared === shared || sharedClone.view === source || sharedClone.view.buffer !== sharedClone.shared) return false;" ++
        "    sharedClone.view[2] = 19; if (source[2] !== 19) return false;" ++
        "  } catch (error) {" ++
        "    if (error.name !== 'DataCloneError') return false;" ++
        "    try { structuredClone(source); return false; } catch (viewError) { if (viewError.name !== 'DataCloneError') return false; }" ++
        "  }" ++
        "  var buffer = new ArrayBuffer(4); new Uint8Array(buffer).set([1, 2, 3, 4]);" ++
        "  var first = new Uint8Array(buffer); var second = new DataView(buffer);" ++
        "  var moved = structuredClone({ first: first, second: second }, { transfer: [buffer] });" ++
        "  if (buffer.byteLength !== 0 || moved.first.buffer !== moved.second.buffer) return false;" ++
        "  if (moved.first[0] !== 1 || moved.second.getUint8(3) !== 4) return false;" ++
        "  var rollback = new ArrayBuffer(2);" ++
        "  try { structuredClone({ bad: function() {} }, { transfer: [rollback] }); return false; } catch (error) {" ++
        "    if (error.name !== 'DataCloneError' || rollback.byteLength !== 2) return false;" ++
        "  }" ++
        "  try { structuredClone(null, { transfer: [shared] }); return false; } catch (error) {" ++
        "    if (error.name !== 'DataCloneError') return false;" ++
        "  }" ++
        "  return true;" ++
        "})()"));
}

test "BroadcastChannel fallback fails loudly without cross-context delivery" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  if (typeof BroadcastChannel !== 'function') return false;" ++
        "  try { new BroadcastChannel('room'); return false; }" ++
        "  catch (error) { return error.name === 'NotSupportedError' && /cross-context/.test(error.message); }" ++
        "})()"));
}

test "URLPattern matches named groups, wildcards, and rejects non-matches" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    @import("url_global.zig").install(std.testing.allocator, ctx, engine.currentGlobalObject());
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "(function() {" ++
        "  if (typeof URLPattern !== 'function') return false;" ++
        "  var p = new URLPattern({ pathname: '/books/:id' });" ++
        "  var m = p.exec({ pathname: '/books/42' });" ++
        "  if (!m || m.pathname.groups.id !== '42') return false;" ++
        "  if (p.test({ pathname: '/movies/42' })) return false;" ++
        "  var w = new URLPattern({ pathname: '/files/*' });" ++
        "  if (!w.test({ pathname: '/files/a/b/c' })) return false;" ++
        "  return p.test({ pathname: '/books/99' });" ++
        "})()"));
}
