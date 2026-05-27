// Phase 2 prep — a minimal `console` global for the native JSC eval/run path.
//
// `home eval` / (future) `home run` execute inside a bare
// `JSGlobalContextCreate` realm, which has no host globals — in particular no
// `console`. Bun's realms expose `console`; this installs a faithful-enough
// `console.{log,info,debug}` → stdout and `console.{error,warn}` → stderr.
//
// Each argument is rendered with `JSValueToStringCopy` and joined by a single
// space, then terminated with a newline. That matches the simple console path
// for primitive arguments; full `util.inspect`-style object pretty-printing
// (e.g. `{ a: 1 }` instead of `[object Object]`) is a deliberate later
// refinement — the first increment is "console exists and prints primitives".
//
// The two host functions are registered on the global under temporary names
// via `callback.registerCallback`, then a tiny JS glue snippet assembles the
// `console` object from them (reusing the proven registration + evaluation
// path rather than hand-building the object with JSObjectMake/SetProperty).

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

// POSIX stdout/stderr descriptors. The JSC C-ABI callback carries no host
// `std.Io`, so writes go straight through libc `write(2)` (we link `-lc`).
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

/// Render `console.log`-style arguments to `fd`: each value as its string
/// form, space-separated, newline-terminated. Uses the page allocator because
/// the JSC C-ABI callback carries no host allocator.
fn emit(ctx: *JSContextRef, fd: c_int, argument_count: usize, arguments: [*c]const ?*JSValue) void {
    const allocator = std.heap.page_allocator;
    var i: usize = 0;
    while (i < argument_count) : (i += 1) {
        if (i != 0) writeAll(fd, " ");
        const value = arguments[i] orelse continue;
        const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse continue;
        defer extern_fns.JSStringRelease(string);

        const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
        if (capacity == 1) continue;

        const buf = allocator.alloc(u8, capacity) catch continue;
        defer allocator.free(buf);

        const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
        const end = if (written > 0) written - 1 else 0;
        writeAll(fd, buf[0..end]);
    }
    writeAll(fd, "\n");
}

fn logNative(
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
    if (ctx) |c| emit(c, stdout_fd, argument_count, arguments);
    return extern_fns.JSValueMakeUndefined(ctx);
}

fn errorNative(
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
    if (ctx) |c| emit(c, stderr_fd, argument_count, arguments);
    return extern_fns.JSValueMakeUndefined(ctx);
}

const install_glue =
    \\globalThis.console = {
    \\  log: globalThis.__home_console_log_native,
    \\  info: globalThis.__home_console_log_native,
    \\  debug: globalThis.__home_console_log_native,
    \\  trace: globalThis.__home_console_log_native,
    \\  dir: globalThis.__home_console_log_native,
    \\  error: globalThis.__home_console_error_native,
    \\  warn: globalThis.__home_console_error_native,
    \\};
    \\delete globalThis.__home_console_log_native;
    \\delete globalThis.__home_console_error_native;
;

/// Install a minimal `console` global into `ctx`'s realm. No-op when JSC is
/// not linked. Silently leaves the realm untouched on the (unexpected) glue
/// evaluation failure so callers never have to special-case it.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_console_log_native", logNative);
    callback.registerCallback(ctx, global, "__home_console_error_native", errorNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:console-install", 1) catch return;
    result.deinit(allocator);
}

test "console install exposes log/error functions in the realm" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    // After install, the realm has a `console` whose methods are functions and
    // whose temporary registration globals are cleaned up.
    const probe = (try evaluate.evaluateUtf8(
        std.testing.allocator,
        ctx,
        "(typeof console === 'object') && " ++
            "['log','info','debug','warn','error'].every(k => typeof console[k] === 'function') && " ++
            "(typeof globalThis.__home_console_log_native === 'undefined')",
        "home:console-install-probe",
        1,
        null,
    )) orelse return error.JSEvaluateReturnedNull;

    try std.testing.expect(extern_fns.JSValueToBoolean(ctx, probe));
}

test "console.log returns undefined and does not throw" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    const evaluation = try evaluate.evaluateUtf8Detailed(
        std.testing.allocator,
        ctx,
        "console.log('home', 1 + 2); console.error('e'); 'ok'",
        "home:console-call",
        1,
    );
    defer evaluation.deinit(std.testing.allocator);

    try std.testing.expect(evaluation.exception == null);
    try std.testing.expect(evaluation.value != null);
}
