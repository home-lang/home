// Phase 2 — a minimal `process` global for the native JSC eval/run realm.
//
// Like `console` (see `console.zig`), the bare `JSGlobalContextCreate` realm
// used by `home eval`/`home run` has no host globals. Bun's realms expose a
// rich `process`; this installs the core surface real scripts reach for:
// `argv`, `env`, `platform`, `arch`, `version`, `versions.node`, `pid`,
// `cwd()`, `exit()`, `nextTick()`, and `stdout.write`/`stderr.write`.
//
// The pattern mirrors `console.zig`: a handful of host callbacks are
// registered on the global under temporary names, then a static JS glue
// snippet (run inside an IIFE so the temporaries are captured as locals and
// then deleted from the global) assembles `globalThis.process`.
//
// `version`/`versions.node` report Bun's pinned Node-compat version
// (`BUN_REPORTED_NODEJS_VERSION` default `24.0.0`, per
// `~/Code/bun/src/bun_core/lib.rs`). It is a literal here rather than the
// runtime's `bun_core/env.reported_nodejs_version` because that decl is
// gated on a `build_options.reported_nodejs_version` the CLI build does not
// define. Object inspect-formatting and the full stream surface are
// deliberate later refinements.

const std = @import("std");
const bun = @import("bun");
const builtin = @import("builtin");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

/// Process argv backing the `process.argv` native. The CLI is single-threaded
/// and the slice outlives the eval, so a module-level reference is safe.
var g_argv: []const []const u8 = &.{};

const platform_name = switch (builtin.os.tag) {
    .macos => "darwin",
    .windows => "win32",
    else => "linux",
};
const arch_name = switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86_64 => "x64",
    else => @tagName(builtin.cpu.arch),
};
const node_version = "24.0.0";

const stdout_fd: c_int = 1;
const stderr_fd: c_int = 2;

fn writeAll(fd: c_int, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc <= 0) return;
        offset += @intCast(rc);
    }
}

/// Build a JS string value from a Zig slice (page allocator: the C-ABI
/// callback carries no host allocator).
fn jsStringValue(ctx: *JSContextRef, text: []const u8) ?*JSValue {
    const allocator = std.heap.page_allocator;
    const text_z = bun.dupeZ(allocator, u8, text) catch return null;
    defer allocator.free(text_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

/// Set `object[key] = value` (no-op on allocation/JSC failure).
fn setProp(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: ?*JSValue) void {
    const allocator = std.heap.page_allocator;
    const key_z = bun.dupeZ(allocator, u8, key) catch return;
    defer allocator.free(key_z);
    const name = extern_fns.JSStringCreateWithUTF8CString(key_z.ptr) orelse return;
    defer extern_fns.JSStringRelease(name);
    extern_fns.JSObjectSetProperty(ctx, object, name, value, 0, null);
}

/// Write a single JS string argument to `fd` verbatim (no trailing newline,
/// matching `stream.write`).
fn writeArg(ctx: *JSContextRef, fd: c_int, value: *JSValue) void {
    const allocator = std.heap.page_allocator;
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    if (capacity == 1) return;
    const buf = allocator.alloc(u8, capacity) catch return;
    defer allocator.free(buf);
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    const end = if (written > 0) written - 1 else 0;
    writeAll(fd, buf[0..end]);
}

fn argvNative(
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
    const allocator = std.heap.page_allocator;
    const items = allocator.alloc(?*JSValue, g_argv.len) catch
        return @ptrCast(extern_fns.JSObjectMakeArray(c, 0, null, null) orelse return extern_fns.JSValueMakeUndefined(c));
    defer allocator.free(items);
    var n: usize = 0;
    for (g_argv) |arg| {
        items[n] = jsStringValue(c, arg) orelse continue;
        n += 1;
    }
    const array = extern_fns.JSObjectMakeArray(c, n, items.ptr, null) orelse return extern_fns.JSValueMakeUndefined(c);
    return @ptrCast(array);
}

fn envNative(
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
    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeUndefined(c);
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const value = jsStringValue(c, pair[eq + 1 ..]) orelse continue;
        setProp(c, object, pair[0..eq], value);
    }
    return @ptrCast(object);
}

fn staticInfoNative(
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
    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeUndefined(c);
    setProp(c, object, "platform", jsStringValue(c, platform_name));
    setProp(c, object, "arch", jsStringValue(c, arch_name));
    setProp(c, object, "version", jsStringValue(c, "v" ++ node_version));
    setProp(c, object, "node", jsStringValue(c, node_version));
    setProp(c, object, "pid", extern_fns.JSValueMakeNumber(c, @floatFromInt(std.c.getpid())));
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = if (std.process.executablePath(std.Options.debug_io, &exe_buf)) |n| exe_buf[0..n] else |_| "";
    setProp(c, object, "execPath", jsStringValue(c, exe));
    // glibc runtime version — non-empty only on a glibc Linux build, mirroring
    // process.report.getReport().header.glibcVersionRuntime (absent => musl).
    const glibc_ver: []const u8 = if (comptime (builtin.os.tag == .linux and builtin.abi == .gnu)) blk: {
        const c_ext = struct {
            extern fn gnu_get_libc_version() callconv(.c) [*:0]const u8;
        };
        break :blk std.mem.span(c_ext.gnu_get_libc_version());
    } else "";
    setProp(c, object, "glibc", jsStringValue(c, glibc_ver));
    return @ptrCast(object);
}

/// `__home_process_mono_ns()` -> monotonic clock in nanoseconds (used to build
/// process.hrtime / hrtime.bigint / uptime in JS).
fn monoNsNative(
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
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const ns: f64 = @as(f64, @floatFromInt(ts.sec)) * 1.0e9 + @as(f64, @floatFromInt(ts.nsec));
    return extern_fns.JSValueMakeNumber(c, ns);
}

/// `__home_process_kill(pid, sig)` -> kill(2) result (0 on success). Signal 0
/// only checks for the process's existence/permission.
fn killNative(
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
    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) return extern_fns.JSValueMakeNumber(c, -1);
    const pid: i32 = @intFromFloat(extern_fns.JSValueToNumber(c, arguments[0].?, null));
    const sig: c_int = @intFromFloat(extern_fns.JSValueToNumber(c, arguments[1].?, null));
    // Raw libc kill: signal 0 (existence probe) is not a member of std.c's typed
    // SIG enum, so @enumFromInt would trip a safety panic — pass a plain c_int.
    const c_kill = struct {
        extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;
    };
    const rc = c_kill.kill(@intCast(pid), sig);
    return extern_fns.JSValueMakeNumber(c, @floatFromInt(rc));
}

/// `__home_process_cpu_usage()` -> { user, system } CPU time in microseconds
/// for this process (getrusage RUSAGE_SELF), the basis for process.cpuUsage().
fn cpuUsageNative(
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
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const user_us: f64 = @as(f64, @floatFromInt(ru.utime.sec)) * 1.0e6 + @as(f64, @floatFromInt(ru.utime.usec));
    const sys_us: f64 = @as(f64, @floatFromInt(ru.stime.sec)) * 1.0e6 + @as(f64, @floatFromInt(ru.stime.usec));
    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeUndefined(c);
    setProp(c, object, "user", extern_fns.JSValueMakeNumber(c, user_us));
    setProp(c, object, "system", extern_fns.JSValueMakeNumber(c, sys_us));
    return @ptrCast(object);
}

fn cwdNative(
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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&buf, buf.len) orelse return jsStringValue(c, "") orelse extern_fns.JSValueMakeUndefined(c);
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    return jsStringValue(c, cwd) orelse extern_fns.JSValueMakeUndefined(c);
}

fn exitNative(
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
    var code: u8 = 0;
    if (argument_count >= 1) {
        if (arguments[0]) |value| {
            const n = extern_fns.JSValueToNumber(ctx, value, null);
            if (!std.math.isNan(n)) code = @intFromFloat(@max(0, @min(255, n)));
        }
    }
    std.process.exit(code);
}

fn stdoutWriteNative(
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
    if (ctx) |c| {
        if (argument_count >= 1) {
            if (arguments[0]) |value| writeArg(c, stdout_fd, value);
        }
    }
    return extern_fns.JSValueMakeBoolean(ctx, true);
}

fn stderrWriteNative(
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
    if (ctx) |c| {
        if (argument_count >= 1) {
            if (arguments[0]) |value| writeArg(c, stderr_fd, value);
        }
    }
    return extern_fns.JSValueMakeBoolean(ctx, true);
}

const install_glue =
    \\(function() {
    \\  var argvFn = globalThis.__home_process_argv;
    \\  var envFn = globalThis.__home_process_env;
    \\  var infoFn = globalThis.__home_process_static_info;
    \\  var cwdFn = globalThis.__home_process_cwd;
    \\  var exitFn = globalThis.__home_process_exit;
    \\  var outWriteFn = globalThis.__home_process_stdout_write;
    \\  var errWriteFn = globalThis.__home_process_stderr_write;
    \\  var monoFn = globalThis.__home_process_mono_ns;
    \\  var cpuFn = globalThis.__home_process_cpu_usage;
    \\  var killFn = globalThis.__home_process_kill;
    \\  // Signals whose numbers are identical across Linux and macOS/BSD.
    \\  var SIGNALS = { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGILL: 4, SIGTRAP: 5, SIGABRT: 6, SIGFPE: 8, SIGKILL: 9, SIGSEGV: 11, SIGPIPE: 13, SIGALRM: 14, SIGTERM: 15 };
    \\  var info = infoFn();
    \\  var startNs = BigInt(Math.round(monoFn()));
    \\  function nowNs() { return BigInt(Math.round(monoFn())); }
    \\  function hrtime(prev) {
    \\    var ns = nowNs();
    \\    if (prev) { ns = ns - (BigInt(prev[0]) * 1000000000n + BigInt(prev[1])); }
    \\    return [Number(ns / 1000000000n), Number(ns % 1000000000n)];
    \\  }
    \\  hrtime.bigint = function() { return nowNs(); };
    \\  globalThis.process = {
    \\    argv: argvFn(),
    \\    env: envFn(),
    \\    platform: info.platform,
    \\    arch: info.arch,
    \\    version: info.version,
    \\    versions: { node: info.node },
    \\    pid: info.pid,
    \\    execPath: info.execPath,
    \\    exitCode: undefined,
    \\    cwd: function() { return cwdFn(); },
    \\    exit: function(code) { return exitFn(code); },
    \\    uptime: function() { return Number(nowNs() - startNs) / 1e9; },
    \\    hrtime: hrtime,
    \\    cpuUsage: function(prev) { var u = cpuFn(); if (prev) return { user: u.user - prev.user, system: u.system - prev.system }; return u; },
    \\    kill: function(pid, sig) {
    \\      if (sig === undefined) sig = "SIGTERM";
    \\      var n = (typeof sig === "number") ? sig : SIGNALS[sig];
    \\      if (n === undefined) throw new Error("Unknown signal: " + sig);
    \\      var rc = killFn(pid | 0, n);
    \\      if (rc !== 0) { var e = new Error("kill " + pid + " failed"); e.code = "ESRCH"; e.errno = -3; e.syscall = "kill"; throw e; }
    \\      return true;
    \\    },
    \\    report: {
    \\      getReport: function() {
    \\        return {
    \\          header: {
    \\            platform: info.platform,
    \\            arch: info.arch,
    \\            nodejsVersion: info.version,
    \\            glibcVersionRuntime: info.glibc ? info.glibc : undefined,
    \\            glibcVersionCompiler: info.glibc ? info.glibc : undefined,
    \\          },
    \\          javascriptHeap: {},
    \\          resourceUsage: {},
    \\          libuv: [],
    \\          sharedObjects: [],
    \\        };
    \\      },
    \\    },
    \\    nextTick: function(cb) {
    \\      var args = Array.prototype.slice.call(arguments, 1);
    \\      Promise.resolve().then(function() { cb.apply(null, args); });
    \\    },
    \\    stdout: { write: function(s) { return outWriteFn(String(s)); }, isTTY: false, fd: 1 },
    \\    stderr: { write: function(s) { return errWriteFn(String(s)); }, isTTY: false, fd: 2 },
    \\  };
    \\  // process is an EventEmitter (process.on('exit'|'uncaughtException'|...)).
    \\  // Self-contained so it works in realms without node:events installed.
    \\  (function() {
    \\    var p = globalThis.process;
    \\    var events = Object.create(null);
    \\    function listFor(t) { return events[t] || (events[t] = []); }
    \\    p.on = function(t, fn) { listFor(t).push({ fn: fn, once: false }); return p; };
    \\    p.addListener = p.on;
    \\    p.prependListener = function(t, fn) { listFor(t).unshift({ fn: fn, once: false }); return p; };
    \\    p.once = function(t, fn) { listFor(t).push({ fn: fn, once: true }); return p; };
    \\    p.prependOnceListener = function(t, fn) { listFor(t).unshift({ fn: fn, once: true }); return p; };
    \\    p.off = function(t, fn) { var l = events[t]; if (l) events[t] = l.filter(function(e) { return e.fn !== fn; }); return p; };
    \\    p.removeListener = p.off;
    \\    p.removeAllListeners = function(t) { if (t === undefined) events = Object.create(null); else delete events[t]; return p; };
    \\    p.emit = function(t) { var l = events[t]; if (!l || !l.length) return false; var args = Array.prototype.slice.call(arguments, 1); var snap = l.slice(); for (var i = 0; i < snap.length; i++) { var e = snap[i]; if (e.once) p.off(t, e.fn); try { e.fn.apply(p, args); } catch (err) { void err; } } return true; };
    \\    p.listeners = function(t) { return (events[t] || []).map(function(e) { return e.fn; }); };
    \\    p.rawListeners = p.listeners;
    \\    p.listenerCount = function(t) { return (events[t] || []).length; };
    \\    p.eventNames = function() { return Object.keys(events); };
    \\    p.setMaxListeners = function() { return p; };
    \\    p.getMaxListeners = function() { return 10; };
    \\    // emitWarning: fire a 'warning' event with an Error-like payload, falling
    \\    // back to stderr when nothing is listening (Node's default behavior).
    \\    p.emitWarning = function(warning, options) {
    \\      var type = "Warning", code, detail;
    \\      if (typeof options === "string") { type = options; }
    \\      else if (options && typeof options === "object") { type = options.type || "Warning"; code = options.code; detail = options.detail; }
    \\      var w = (warning instanceof Error) ? warning : new Error(String(warning));
    \\      if (!(warning instanceof Error)) w.name = type;
    \\      if (code !== undefined) w.code = code;
    \\      if (detail !== undefined) w.detail = detail;
    \\      if (!p.emit("warning", w)) { try { p.stderr.write((w.name || "Warning") + ": " + w.message + "\n"); } catch (e) { void e; } }
    \\    };
    \\  })();
    \\  delete globalThis.__home_process_argv;
    \\  delete globalThis.__home_process_env;
    \\  delete globalThis.__home_process_static_info;
    \\  delete globalThis.__home_process_cwd;
    \\  delete globalThis.__home_process_exit;
    \\  delete globalThis.__home_process_stdout_write;
    \\  delete globalThis.__home_process_stderr_write;
    \\  delete globalThis.__home_process_mono_ns;
    \\  delete globalThis.__home_process_cpu_usage;
    \\  delete globalThis.__home_process_kill;
    \\})();
;

/// Install a minimal `process` global into `ctx`'s realm. `argv` becomes
/// `process.argv` (the slice must outlive the realm). No-op when JSC is not
/// linked.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject, argv: []const []const u8) void {
    if (comptime !build_options.enable_jsc) return;

    g_argv = argv;
    callback.registerCallback(ctx, global, "__home_process_argv", argvNative);
    callback.registerCallback(ctx, global, "__home_process_env", envNative);
    callback.registerCallback(ctx, global, "__home_process_static_info", staticInfoNative);
    callback.registerCallback(ctx, global, "__home_process_cwd", cwdNative);
    callback.registerCallback(ctx, global, "__home_process_exit", exitNative);
    callback.registerCallback(ctx, global, "__home_process_stdout_write", stdoutWriteNative);
    callback.registerCallback(ctx, global, "__home_process_stderr_write", stderrWriteNative);
    callback.registerCallback(ctx, global, "__home_process_mono_ns", monoNsNative);
    callback.registerCallback(ctx, global, "__home_process_cpu_usage", cpuUsageNative);
    callback.registerCallback(ctx, global, "__home_process_kill", killNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:process-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:process-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

test "process install exposes the core surface" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const argv = [_][]const u8{ "home", "script.js", "a" };
    install(std.testing.allocator, ctx, engine.currentGlobalObject(), &argv);

    // Shape: process is an object with the expected primitive/array/object members.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof process === 'object' && " ++
        "Array.isArray(process.argv) && process.argv.length === 3 && process.argv[0] === 'home' && " ++
        "typeof process.env === 'object' && " ++
        "typeof process.platform === 'string' && typeof process.arch === 'string' && " ++
        "process.version[0] === 'v' && typeof process.versions.node === 'string' && " ++
        "typeof process.pid === 'number' && " ++
        "typeof process.cwd === 'function' && typeof process.exit === 'function' && " ++
        "typeof process.nextTick === 'function' && " ++
        "typeof process.stdout.write === 'function' && typeof process.stderr.write === 'function'"));

    // The temporary registration globals were cleaned up.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof globalThis.__home_process_argv === 'undefined' && " ++
        "typeof globalThis.__home_process_static_info === 'undefined'"));
}

test "process exposes execPath, exitCode, uptime, and hrtime(+bigint)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const argv = [_][]const u8{"home"};
    install(std.testing.allocator, ctx, engine.currentGlobalObject(), &argv);

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (typeof process.execPath !== 'string' || process.execPath.length === 0) return false;" ++
        "  if (!('exitCode' in process) || process.exitCode !== undefined) return false;" ++
        "  process.exitCode = 3; if (process.exitCode !== 3) return false;" ++
        "  if (typeof process.uptime !== 'function' || !(process.uptime() >= 0)) return false;" ++
        "  var t = process.hrtime();" ++
        "  if (!Array.isArray(t) || t.length !== 2 || t[1] < 0 || t[1] >= 1e9) return false;" ++
        "  var d = process.hrtime(t);" ++ // diff from a near-now mark is tiny
        "  if (d[0] < 0 || (d[0] === 0 && d[1] < 0)) return false;" ++
        "  if (typeof process.hrtime.bigint !== 'function' || typeof process.hrtime.bigint() !== 'bigint') return false;" ++
        "  if (process.hrtime.bigint() < 0n) return false;" ++
        "  var cu = process.cpuUsage();" ++
        "  if (typeof cu !== 'object' || typeof cu.user !== 'number' || typeof cu.system !== 'number' || cu.user < 0) return false;" ++
        "  var cd = process.cpuUsage(cu);" ++ // diff from a near-now mark is non-negative
        "  return cd.user >= 0 && cd.system >= 0;" ++
        "})()"));

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof globalThis.__home_process_mono_ns === 'undefined' && typeof globalThis.__home_process_cpu_usage === 'undefined'"));
}

test "process.emitWarning fires a warning event with code/detail" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const argv = [_][]const u8{"home"};
    install(std.testing.allocator, ctx, engine.currentGlobalObject(), &argv);

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (typeof process.emitWarning !== 'function') return false;" ++
        "  if (process.stdout.fd !== 1 || process.stderr.fd !== 2) return false;" ++
        "  var got = null; process.on('warning', function(w) { got = w; });" ++
        "  process.emitWarning('be careful', { code: 'W001', detail: 'more' });" ++
        "  if (!got || !(got instanceof Error) || got.message !== 'be careful') return false;" ++
        "  if (got.name !== 'Warning' || got.code !== 'W001' || got.detail !== 'more') return false;" ++
        "  var e2 = new Error('boom'); process.emitWarning(e2);" ++ // Error passes through
        "  return got === e2 && got.message === 'boom';" ++
        "})()"));
}

test "process is an EventEmitter (on/once/off/emit/listeners)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const argv = [_][]const u8{"home"};
    install(std.testing.allocator, ctx, engine.currentGlobalObject(), &argv);

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (typeof process.on !== 'function' || typeof process.emit !== 'function') return false;" ++
        "  var sum = 0; function add(n) { sum += n; }" ++
        "  process.on('tick', add);" ++
        "  if (process.emit('tick', 2) !== true || process.emit('tick', 3) !== true || sum !== 5) return false;" ++
        "  if (process.listenerCount('tick') !== 1) return false;" ++
        "  process.off('tick', add); if (process.emit('tick', 1) !== false || sum !== 5) return false;" ++
        "  var once = 0; process.once('go', function() { once++; });" ++
        "  process.emit('go'); process.emit('go'); if (once !== 1) return false;" ++
        "  if (process.emit('nobody') !== false) return false;" ++ // no listeners
        "  process.on('multi', function(){}); process.on('multi', function(){});" ++
        "  if (process.listeners('multi').length !== 2) return false;" ++
        "  process.removeAllListeners('multi'); return process.listenerCount('multi') === 0;" ++
        "})()"));
}

test "process.kill sends signals; signal 0 probes existence" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const argv = [_][]const u8{"home"};
    install(std.testing.allocator, ctx, engine.currentGlobalObject(), &argv);

    // Note: we never send a real (terminating) signal to ourselves. Signal 0 is
    // a no-op existence probe; named/numeric signals are exercised against a pid
    // that cannot exist so they fail with ESRCH instead of killing the test.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (typeof process.kill !== 'function') return false;" ++
        "  if (process.kill(process.pid, 0) !== true) return false;" ++ // self exists, no-op
        "  var NOPID = 0x7ffffffe;" ++ // far above any real pid
        "  var e1 = false; try { process.kill(NOPID, 0); } catch (e) { e1 = (e.code === 'ESRCH'); } if (!e1) return false;" ++
        "  var e2 = false; try { process.kill(NOPID, 'SIGTERM'); } catch (e) { e2 = (e.code === 'ESRCH'); } if (!e2) return false;" ++ // name maps, then ESRCH
        "  var unknown = false; try { process.kill(process.pid, 'NOPE'); } catch (e) { unknown = (e.code !== 'ESRCH'); }" ++ // rejected before syscall
        "  return unknown;" ++
        "})()"));
}

test "process.report.getReport returns a header echoing platform/arch" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const argv = [_][]const u8{"home"};
    install(std.testing.allocator, ctx, engine.currentGlobalObject(), &argv);

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (typeof process.report !== 'object' || typeof process.report.getReport !== 'function') return false;" ++
        "  var r = process.report.getReport();" ++
        "  if (!r || typeof r.header !== 'object') return false;" ++
        "  if (r.header.platform !== process.platform || r.header.arch !== process.arch) return false;" ++
        // glibcVersionRuntime is a truthy string on glibc, undefined elsewhere (e.g. macOS)
        "  var g = r.header.glibcVersionRuntime;" ++
        "  if (g !== undefined && typeof g !== 'string') return false;" ++
        "  return Array.isArray(r.libuv) && Array.isArray(r.sharedObjects);" ++
        "})()"));
}

test "process.cwd returns a non-empty absolute path" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const argv = [_][]const u8{"home"};
    install(std.testing.allocator, ctx, engine.currentGlobalObject(), &argv);

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof process.cwd() === 'string' && process.cwd().length > 0 && process.cwd()[0] === '/'"));
}

test "process.nextTick runs the callback after the current job" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const argv = [_][]const u8{"home"};
    install(std.testing.allocator, ctx, engine.currentGlobalObject(), &argv);

    // Synchronously the tick has not run; after microtasks drain it has.
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx, "globalThis.__t = 0; process.nextTick(function() { globalThis.__t = 1; });", "home:nexttick-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__t === 1"));
}
