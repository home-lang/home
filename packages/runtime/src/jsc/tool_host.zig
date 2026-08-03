//! Host capabilities intentionally exposed to repository tools.
//!
//! These are Home-owned primitives over Zig stdlib APIs. They are identical
//! across zig-js and JSC and avoid inheriting Node/Bun module semantics.

const std = @import("std");
const bun = @import("bun");
const build_options = @import("build_options");
const callback = @import("callback.zig");
const evaluate = @import("evaluate.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;
const g_io = std.Io.Threaded.global_single_threaded.io();

fn valueToOwnedUtf8(ctx: *JSContextRef, value: *JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buffer = allocator.alloc(u8, capacity) catch return null;
    defer allocator.free(buffer);
    const written = extern_fns.JSStringGetUTF8CString(string, buffer.ptr, buffer.len);
    const end = if (written > 0) written - 1 else 0;
    return allocator.dupe(u8, buffer[0..end]) catch null;
}

fn stringValue(ctx: *JSContextRef, text: []const u8) ?*JSValue {
    const allocator = std.heap.smp_allocator;
    const text_z = bun.dupeZ(allocator, u8, text) catch return null;
    defer allocator.free(text_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

fn setProperty(ctx: *JSContextRef, object: *JSObject, name: []const u8, value: ?*JSValue) void {
    const allocator = std.heap.page_allocator;
    const name_z = bun.dupeZ(allocator, u8, name) catch return;
    defer allocator.free(name_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(name_z.ptr) orelse return;
    defer extern_fns.JSStringRelease(string);
    extern_fns.JSObjectSetProperty(ctx, object, string, value, 0, null);
}

fn readTextFileNative(
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
    if (argument_count == 0 or arguments[0] == null) return extern_fns.JSValueMakeNull(c);
    const allocator = std.heap.page_allocator;
    const path = valueToOwnedUtf8(c, arguments[0].?, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path);
    const contents = std.Io.Dir.cwd().readFileAlloc(g_io, path, allocator, std.Io.Limit.unlimited) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(contents);
    return stringValue(c, contents) orelse extern_fns.JSValueMakeNull(c);
}

fn writeTextFileNative(
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
    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) return extern_fns.JSValueMakeBoolean(c, false);
    const allocator = std.heap.page_allocator;
    const path = valueToOwnedUtf8(c, arguments[0].?, allocator) orelse return extern_fns.JSValueMakeBoolean(c, false);
    defer allocator.free(path);
    const contents = valueToOwnedUtf8(c, arguments[1].?, allocator) orelse return extern_fns.JSValueMakeBoolean(c, false);
    defer allocator.free(contents);
    std.Io.Dir.cwd().writeFile(g_io, .{ .sub_path = path, .data = contents }) catch
        return extern_fns.JSValueMakeBoolean(c, false);
    return extern_fns.JSValueMakeBoolean(c, true);
}

fn readFileHexNative(
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
    if (argument_count == 0 or arguments[0] == null) return extern_fns.JSValueMakeNull(c);
    const allocator = std.heap.page_allocator;
    const path = valueToOwnedUtf8(c, arguments[0].?, allocator) orelse return extern_fns.JSValueMakeNull(c);
    defer allocator.free(path);
    const contents = std.Io.Dir.cwd().readFileAlloc(g_io, path, allocator, std.Io.Limit.unlimited) catch
        return extern_fns.JSValueMakeNull(c);
    defer allocator.free(contents);
    const encoded = allocator.alloc(u8, contents.len * 2) catch return extern_fns.JSValueMakeNull(c);
    defer allocator.free(encoded);
    const digits = "0123456789abcdef";
    for (contents, 0..) |byte, index| {
        encoded[index * 2] = digits[byte >> 4];
        encoded[index * 2 + 1] = digits[byte & 0x0f];
    }
    return stringValue(c, encoded) orelse extern_fns.JSValueMakeNull(c);
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn writeFileHexNative(
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
    if (argument_count < 2 or arguments[0] == null or arguments[1] == null) return extern_fns.JSValueMakeBoolean(c, false);
    const allocator = std.heap.page_allocator;
    const path = valueToOwnedUtf8(c, arguments[0].?, allocator) orelse return extern_fns.JSValueMakeBoolean(c, false);
    defer allocator.free(path);
    const encoded = valueToOwnedUtf8(c, arguments[1].?, allocator) orelse return extern_fns.JSValueMakeBoolean(c, false);
    defer allocator.free(encoded);
    if (encoded.len % 2 != 0) return extern_fns.JSValueMakeBoolean(c, false);
    const contents = allocator.alloc(u8, encoded.len / 2) catch return extern_fns.JSValueMakeBoolean(c, false);
    defer allocator.free(contents);
    for (contents, 0..) |*byte, index| {
        const high = hexNibble(encoded[index * 2]) orelse return extern_fns.JSValueMakeBoolean(c, false);
        const low = hexNibble(encoded[index * 2 + 1]) orelse return extern_fns.JSValueMakeBoolean(c, false);
        byte.* = (high << 4) | low;
    }
    std.Io.Dir.cwd().writeFile(g_io, .{ .sub_path = path, .data = contents }) catch
        return extern_fns.JSValueMakeBoolean(c, false);
    return extern_fns.JSValueMakeBoolean(c, true);
}

fn fileExistsNative(
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
    if (argument_count == 0 or arguments[0] == null) return extern_fns.JSValueMakeBoolean(c, false);
    const allocator = std.heap.page_allocator;
    const path = valueToOwnedUtf8(c, arguments[0].?, allocator) orelse return extern_fns.JSValueMakeBoolean(c, false);
    defer allocator.free(path);
    std.Io.Dir.cwd().access(g_io, path, .{}) catch return extern_fns.JSValueMakeBoolean(c, false);
    return extern_fns.JSValueMakeBoolean(c, true);
}

fn cpuCountNative(
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
    const count = std.Thread.getCpuCount() catch 1;
    return extern_fns.JSValueMakeNumber(c, @floatFromInt(@max(1, count)));
}

fn spawnSyncNative(
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
    if (argument_count == 0 or arguments[0] == null or !extern_fns.JSValueIsArray(c, arguments[0]))
        return extern_fns.JSValueMakeNull(c);
    const allocator = std.heap.smp_allocator;
    const array = extern_fns.JSValueToObject(c, arguments[0], null) orelse return extern_fns.JSValueMakeNull(c);
    const length_name = extern_fns.JSStringCreateWithUTF8CString("length") orelse return extern_fns.JSValueMakeNull(c);
    defer extern_fns.JSStringRelease(length_name);
    const length_value = extern_fns.JSObjectGetProperty(c, array, length_name, null) orelse return extern_fns.JSValueMakeNull(c);
    const length_number = extern_fns.JSValueToNumber(c, length_value, null);
    if (!std.math.isFinite(length_number) or length_number < 1 or length_number > 4096) return extern_fns.JSValueMakeNull(c);
    const length: usize = @intFromFloat(length_number);
    const argv = allocator.alloc([]const u8, length) catch return extern_fns.JSValueMakeNull(c);
    defer allocator.free(argv);
    var initialized: usize = 0;
    defer for (argv[0..initialized]) |item| allocator.free(item);
    while (initialized < length) : (initialized += 1) {
        const value = extern_fns.JSObjectGetPropertyAtIndex(c, array, @intCast(initialized), null) orelse
            return extern_fns.JSValueMakeNull(c);
        argv[initialized] = valueToOwnedUtf8(c, value, allocator) orelse return extern_fns.JSValueMakeNull(c);
    }
    var cwd: ?[]u8 = null;
    defer if (cwd) |path| allocator.free(path);
    if (argument_count > 1 and arguments[1] != null and
        !extern_fns.JSValueIsNull(c, arguments[1]) and !extern_fns.JSValueIsUndefined(c, arguments[1]))
    {
        cwd = valueToOwnedUtf8(c, arguments[1].?, allocator) orelse return extern_fns.JSValueMakeNull(c);
    }
    var timeout: std.Io.Timeout = .none;
    if (argument_count > 2 and arguments[2] != null and extern_fns.JSValueIsNumber(c, arguments[2])) {
        const timeout_ms = extern_fns.JSValueToNumber(c, arguments[2], null);
        if (!std.math.isFinite(timeout_ms) or timeout_ms <= 0 or timeout_ms > @as(f64, @floatFromInt(std.math.maxInt(i32))))
            return extern_fns.JSValueMakeNull(c);
        timeout = .{ .duration = .{
            .raw = .fromMilliseconds(@intFromFloat(timeout_ms)),
            .clock = .awake,
        } };
    }
    if (std.mem.indexOfScalar(u8, argv[0], '/') == null) {
        const path_value = if (std.c.getenv("PATH")) |raw| std.mem.span(raw) else "";
        var paths = std.mem.splitScalar(u8, path_value, ':');
        while (paths.next()) |directory| {
            const candidate = std.fs.path.join(allocator, &.{ if (directory.len == 0) "." else directory, argv[0] }) catch
                return extern_fns.JSValueMakeNull(c);
            if (std.Io.Dir.cwd().access(g_io, candidate, .{})) |_| {
                allocator.free(argv[0]);
                argv[0] = candidate;
                break;
            } else |_| allocator.free(candidate);
        }
    }
    // The global single-threaded Io singleton has no process-spawn arena and
    // reports OutOfMemory from spawnPosix. A scoped Threaded instance owns the
    // argv/environment arena and the two pipe readers for this synchronous run.
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const inherit_environment = argument_count <= 5 or arguments[5] == null or extern_fns.JSValueToBoolean(c, arguments[5]);
    var inherited = if (inherit_environment)
        std.process.Environ.createMap(.{ .block = .{ .slice = std.mem.span(std.c.environ) } }, allocator) catch
            return extern_fns.JSValueMakeNull(c)
    else
        std.process.Environ.Map.init(allocator);
    defer inherited.deinit();
    if (argument_count > 4 and arguments[3] != null and arguments[4] != null and
        extern_fns.JSValueIsArray(c, arguments[3]) and extern_fns.JSValueIsArray(c, arguments[4]))
    {
        const keys = extern_fns.JSValueToObject(c, arguments[3], null) orelse return extern_fns.JSValueMakeNull(c);
        const values = extern_fns.JSValueToObject(c, arguments[4], null) orelse return extern_fns.JSValueMakeNull(c);
        const env_length_name = extern_fns.JSStringCreateWithUTF8CString("length") orelse return extern_fns.JSValueMakeNull(c);
        defer extern_fns.JSStringRelease(env_length_name);
        const env_length_value = extern_fns.JSObjectGetProperty(c, keys, env_length_name, null) orelse return extern_fns.JSValueMakeNull(c);
        const env_length_number = extern_fns.JSValueToNumber(c, env_length_value, null);
        if (!std.math.isFinite(env_length_number) or env_length_number < 0 or env_length_number > 4096)
            return extern_fns.JSValueMakeNull(c);
        const env_length: usize = @intFromFloat(env_length_number);
        for (0..env_length) |index| {
            const key_value = extern_fns.JSObjectGetPropertyAtIndex(c, keys, @intCast(index), null) orelse return extern_fns.JSValueMakeNull(c);
            const env_value = extern_fns.JSObjectGetPropertyAtIndex(c, values, @intCast(index), null) orelse return extern_fns.JSValueMakeNull(c);
            const key = valueToOwnedUtf8(c, key_value, allocator) orelse return extern_fns.JSValueMakeNull(c);
            defer allocator.free(key);
            const value = valueToOwnedUtf8(c, env_value, allocator) orelse return extern_fns.JSValueMakeNull(c);
            defer allocator.free(value);
            inherited.put(key, value) catch return extern_fns.JSValueMakeNull(c);
        }
    }
    const result = std.process.run(allocator, threaded.io(), .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = &inherited,
        .timeout = timeout,
    }) catch |err| {
        if (err == error.Timeout) {
            const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
            setProperty(c, object, "exitCode", extern_fns.JSValueMakeNull(c));
            setProperty(c, object, "stdout", stringValue(c, ""));
            setProperty(c, object, "stderr", stringValue(c, ""));
            setProperty(c, object, "timedOut", extern_fns.JSValueMakeBoolean(c, true));
            return @ptrCast(object);
        }
        std.debug.print("home-tool: cannot spawn {s}: {t}\n", .{ argv[0], err });
        return extern_fns.JSValueMakeNull(c);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    const exit_code: ?u32 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    setProperty(c, object, "exitCode", if (exit_code) |code| extern_fns.JSValueMakeNumber(c, @floatFromInt(code)) else extern_fns.JSValueMakeNull(c));
    setProperty(c, object, "stdout", stringValue(c, result.stdout));
    setProperty(c, object, "stderr", stringValue(c, result.stderr));
    setProperty(c, object, "timedOut", extern_fns.JSValueMakeBoolean(c, false));
    return @ptrCast(object);
}

const install_glue =
    \\(function() {
    \\  var read = globalThis.__home_tool_read_text_file;
    \\  var write = globalThis.__home_tool_write_text_file;
    \\  var readHex = globalThis.__home_tool_read_file_hex;
    \\  var writeHex = globalThis.__home_tool_write_file_hex;
    \\  var exists = globalThis.__home_tool_file_exists;
    \\  var cpuCount = globalThis.__home_tool_cpu_count;
    \\  var spawn = globalThis.__home_tool_spawn_sync;
    \\  globalThis.Home = {
    \\    readTextFile: function(path) { var out = read(String(path)); if (out === null) throw new Error("cannot read " + path); return out; },
    \\    writeTextFile: function(path, text) { if (!write(String(path), String(text))) throw new Error("cannot write " + path); },
    \\    readFileHex: function(path) { var out = readHex(String(path)); if (out === null) throw new Error("cannot read " + path); return out; },
    \\    writeFileHex: function(path, hex) { if (!writeHex(String(path), String(hex))) throw new Error("cannot write " + path); },
    \\    fileExists: function(path) { return exists(String(path)); },
    \\    cpuCount: function() { return cpuCount(); },
    \\    spawnSync: function(argv, options) {
    \\      options = options || {};
    \\      var env = options.env || {};
    \\      var keys = Object.keys(env);
    \\      var values = keys.map(function(key) { return String(env[key]); });
    \\      var out = spawn(argv, options.cwd == null ? null : String(options.cwd), options.timeoutMs == null ? null : Number(options.timeoutMs), keys, values, options.inheritEnv !== false);
    \\      if (out === null) throw new Error("cannot spawn process");
    \\      return out;
    \\    },
    \\    engine: "
++ build_options.js_engine ++
    \\"
    \\  };
    \\  delete globalThis.__home_tool_read_text_file;
    \\  delete globalThis.__home_tool_write_text_file;
    \\  delete globalThis.__home_tool_read_file_hex;
    \\  delete globalThis.__home_tool_write_file_hex;
    \\  delete globalThis.__home_tool_file_exists;
    \\  delete globalThis.__home_tool_cpu_count;
    \\  delete globalThis.__home_tool_spawn_sync;
    \\})();
;

pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_read_text_file", readTextFileNative);
    callback.registerCallback(ctx, global, "__home_tool_write_text_file", writeTextFileNative);
    callback.registerCallback(ctx, global, "__home_tool_read_file_hex", readFileHexNative);
    callback.registerCallback(ctx, global, "__home_tool_write_file_hex", writeFileHexNative);
    callback.registerCallback(ctx, global, "__home_tool_file_exists", fileExistsNative);
    callback.registerCallback(ctx, global, "__home_tool_cpu_count", cpuCountNative);
    callback.registerCallback(ctx, global, "__home_tool_spawn_sync", spawnSyncNative);
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:tool-host-install", 1) catch return;
    result.deinit(allocator);
}
