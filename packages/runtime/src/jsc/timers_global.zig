// Phase 2 — a minimal timer event loop for the native JSC eval/run realm.
//
// JSC's `JSGlobalContext` drains *microtasks* (Promise jobs) on returning to
// the embedder, but it has no notion of *timers*. This installs
// `setTimeout`/`setInterval`/`clearTimeout`/`clearInterval` backed by a small
// native timer registry, plus `drain(ctx)` which the CLI runs after the main
// script returns: it repeatedly fires the earliest-due timer (sleeping to its
// due time) until no active timers remain. Firing a callback via
// `JSObjectCallAsFunction` also lets JSC drain any microtasks it queued, so
// `await`/`.then` chains scheduled from a timer run too.
//
// This is distinct from the parked full `jsc/event_loop.zig` (Bun's complete
// event loop with I/O); it is the minimal timer pump the eval/run realm needs.
// Same register-natives pattern as the other realm globals; comptime-gated on
// `enable_jsc`. An uncleared `setInterval` keeps the loop running (faithful to
// Bun/Node — the process stays alive), so callers/tests must clear intervals.

const std = @import("std");
const build_options = @import("build_options");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

const Timer = struct {
    id: i64,
    due_ns: i128,
    interval_ns: i128, // 0 == one-shot
    callback: *JSValue, // protected while active
    args: []?*JSValue, // protected extra args (len 0 == none)
    active: bool,
};

var g_timers: std.ArrayListUnmanaged(Timer) = .empty;
var g_next_id: i64 = 1;
var g_allocator: std.mem.Allocator = undefined;
var g_ready = false;

fn nowNs() i128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s + @as(i128, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&req, null);
}

fn releaseTimer(ctx: *JSContextRef, timer: *Timer) void {
    extern_fns.JSValueUnprotect(ctx, timer.callback);
    for (timer.args) |arg| {
        if (arg) |a| extern_fns.JSValueUnprotect(ctx, a);
    }
    if (timer.args.len > 0) g_allocator.free(timer.args);
    timer.args = &.{};
}

fn registerTimer(ctx: *JSContextRef, argument_count: usize, arguments: [*c]const ?*JSValue, repeating: bool) ?*JSValue {
    if (!g_ready or argument_count < 1) return extern_fns.JSValueMakeNumber(ctx, 0);
    const cb = arguments[0] orelse return extern_fns.JSValueMakeNumber(ctx, 0);

    // Callback must be callable; otherwise this is a no-op returning id 0.
    const cb_obj = extern_fns.JSValueToObject(ctx, cb, null);
    if (cb_obj == null or !extern_fns.JSObjectIsFunction(ctx, cb_obj)) return extern_fns.JSValueMakeNumber(ctx, 0);

    var delay_ms: f64 = 0;
    if (argument_count >= 2) {
        if (arguments[1]) |d| {
            const n = extern_fns.JSValueToNumber(ctx, d, null);
            if (!std.math.isNan(n) and n > 0) delay_ms = n;
        }
    }

    const extra_n: usize = if (argument_count > 2) argument_count - 2 else 0;
    var args: []?*JSValue = &.{};
    if (extra_n > 0) {
        if (g_allocator.alloc(?*JSValue, extra_n)) |buf| {
            for (0..extra_n) |i| {
                const a = arguments[2 + i];
                if (a) |av| extern_fns.JSValueProtect(ctx, av);
                buf[i] = a;
            }
            args = buf;
        } else |_| {}
    }

    extern_fns.JSValueProtect(ctx, cb);
    const delay_ns: i128 = @intFromFloat(delay_ms * std.time.ns_per_ms);
    const id = g_next_id;
    g_next_id += 1;
    g_timers.append(g_allocator, .{
        .id = id,
        .due_ns = nowNs() + delay_ns,
        .interval_ns = if (repeating) @max(@as(i128, std.time.ns_per_ms), delay_ns) else 0,
        .callback = cb,
        .args = args,
        .active = true,
    }) catch {
        // On OOM, undo the protections so we don't leak GC roots.
        extern_fns.JSValueUnprotect(ctx, cb);
        for (args) |a| {
            if (a) |av| extern_fns.JSValueUnprotect(ctx, av);
        }
        if (args.len > 0) g_allocator.free(args);
        return extern_fns.JSValueMakeNumber(ctx, 0);
    };
    return extern_fns.JSValueMakeNumber(ctx, @floatFromInt(id));
}

fn setTimeoutNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argument_count: usize, arguments: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    return registerTimer(c, argument_count, arguments, false);
}

fn setIntervalNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argument_count: usize, arguments: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    return registerTimer(c, argument_count, arguments, true);
}

fn clearTimerNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argument_count: usize, arguments: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (g_ready and argument_count >= 1) {
        if (arguments[0]) |value| {
            const n = extern_fns.JSValueToNumber(c, value, null);
            if (!std.math.isNan(n)) {
                const id: i64 = @intFromFloat(n);
                for (g_timers.items) |*timer| {
                    if (timer.id == id and timer.active) {
                        timer.active = false;
                        releaseTimer(c, timer);
                    }
                }
            }
        }
    }
    return extern_fns.JSValueMakeUndefined(c);
}

fn reportUncaught(ctx: *JSContextRef, value: *JSValue) void {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    if (capacity == 1) return;
    const buf = g_allocator.alloc(u8, capacity) catch return;
    defer g_allocator.free(buf);
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    const end = if (written > 0) written - 1 else 0;
    const prefix = "Uncaught (in timer): ";
    _ = std.c.write(2, prefix, prefix.len);
    _ = std.c.write(2, buf.ptr, end);
    _ = std.c.write(2, "\n", 1);
}

/// Run the timer loop until no active timers remain. Called after the main
/// script returns. Re-scans each iteration so timers scheduled by a firing
/// callback are picked up. The pointer into `g_timers` is never held across
/// the JS call (a callback may append and realloc the list).
pub fn drain(ctx: *JSContextRef) void {
    if (comptime !build_options.enable_jsc) return;
    if (!g_ready) return;

    while (true) {
        var best_idx: ?usize = null;
        var best_due: i128 = 0;
        for (g_timers.items, 0..) |timer, i| {
            if (!timer.active) continue;
            if (best_idx == null or timer.due_ns < best_due) {
                best_idx = i;
                best_due = timer.due_ns;
            }
        }
        const idx = best_idx orelse break;

        const now = nowNs();
        if (best_due > now) {
            const wait_ns: u64 = @intCast(@min(best_due - now, @as(i128, std.time.ns_per_s) * 60));
            sleepNs(wait_ns);
            continue;
        }

        // Snapshot by value: the JS call below may append timers and realloc
        // `g_timers`, invalidating any pointer/index we hold.
        const fire_id = g_timers.items[idx].id;
        const cb = g_timers.items[idx].callback;
        const args = g_timers.items[idx].args;
        const is_interval = g_timers.items[idx].interval_ns > 0;

        if (is_interval) {
            g_timers.items[idx].due_ns = now + g_timers.items[idx].interval_ns;
        } else {
            g_timers.items[idx].active = false;
        }

        if (extern_fns.JSValueToObject(ctx, cb, null)) |fun| {
            var exception: ?*JSValue = null;
            _ = extern_fns.JSObjectCallAsFunction(ctx, fun, null, args.len, if (args.len > 0) args.ptr else null, &exception);
            if (exception) |e| reportUncaught(ctx, e);
        }

        // A one-shot is done: release its GC roots. Re-find by id because the
        // list may have moved during the call. (An interval keeps its roots
        // until cleared; if the callback cleared it, clearTimerNative already
        // released it and marked it inactive.)
        if (!is_interval) {
            for (g_timers.items) |*timer| {
                if (timer.id == fire_id and !timer.active and timer.callback == cb) {
                    releaseTimer(ctx, timer);
                    break;
                }
            }
        }
    }

    // All timers are inactive; free the registry's backing buffer so a
    // subsequent realm starts clean and no allocation leaks at exit.
    g_timers.deinit(g_allocator);
    g_timers = .empty;
}

/// Install `setTimeout`/`setInterval`/`clearTimeout`/`clearInterval`. The
/// realm's timers are pumped later by `drain(ctx)`. No-op without JSC.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    g_allocator = allocator;
    g_timers = .empty;
    g_next_id = 1;
    g_ready = true;

    callback.registerCallback(ctx, global, "setTimeout", setTimeoutNative);
    callback.registerCallback(ctx, global, "setInterval", setIntervalNative);
    callback.registerCallback(ctx, global, "clearTimeout", clearTimerNative);
    callback.registerCallback(ctx, global, "clearInterval", clearTimerNative);
}

// ---- tests --------------------------------------------------------------

const evaluate = @import("evaluate.zig");

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:timers-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

test "timers install exposes setTimeout/setInterval/clearTimeout/clearInterval" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());
    defer g_ready = false;

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "['setTimeout','setInterval','clearTimeout','clearInterval'].every(function(k){ return typeof globalThis[k] === 'function'; })"));
}

test "setTimeout fires during drain, in due-time order, with args" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());
    defer g_ready = false;

    // Schedule two timers out of order plus an arg-passing one.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__log = [];" ++
        "setTimeout(function(){ globalThis.__log.push('b'); }, 20);" ++
        "setTimeout(function(){ globalThis.__log.push('a'); }, 5);" ++
        "setTimeout(function(x, y){ globalThis.__log.push(x + y); }, 1, 'h', 'i');",
        "home:timers-order-setup", 1, null);

    // Before draining nothing has fired.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__log.length === 0"));

    drain(ctx);

    // Fired in due order: 'hi' (1ms), 'a' (5ms), 'b' (20ms).
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "globalThis.__log.join(',') === 'hi,a,b'"));
}

test "clearTimeout prevents a pending timer from firing" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());
    defer g_ready = false;

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__fired = false;" ++
        "var id = setTimeout(function(){ globalThis.__fired = true; }, 5);" ++
        "clearTimeout(id);",
        "home:timers-clear-setup", 1, null);

    drain(ctx);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__fired === false"));
}

test "setInterval repeats and clears itself from inside the callback" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());
    defer g_ready = false;

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__n = 0;" ++
        "var id = setInterval(function(){ globalThis.__n++; if (globalThis.__n >= 3) clearInterval(id); }, 1);",
        "home:timers-interval-setup", 1, null);

    drain(ctx);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__n === 3"));
}

test "a timer callback can schedule another timer (drain re-scans)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());
    defer g_ready = false;

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__chain = 0;" ++
        "setTimeout(function(){ globalThis.__chain = 1; setTimeout(function(){ globalThis.__chain = 2; }, 1); }, 1);",
        "home:timers-chain-setup", 1, null);

    drain(ctx);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__chain === 2"));
}
