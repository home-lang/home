//! Native OS queries for the repository-tool adapter.
const std = @import("std");
const builtin = @import("builtin");
const callback = @import("callback.zig");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");

fn homedir(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = count;
    _ = args;
    _ = exception;
    const c = ctx orelse return null;
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        const allocator = std.heap.smp_allocator;
        var size: usize = 1024;
        while (size <= 1024 * 1024) : (size *= 2) {
            const buffer = allocator.alloc(u8, size) catch return api.JSValueMakeNull(c);
            defer allocator.free(buffer);
            var account: std.c.passwd = undefined;
            var result: ?*std.c.passwd = null;
            // Reentrant lookup avoids libc's shared static passwd storage.
            const code = std.c.getpwuid_r(std.c.getuid(), &account, buffer.ptr, buffer.len, &result);
            if (code == @backingInt(std.c.E.RANGE)) continue;
            if (code != 0 or result == null) return api.JSValueMakeNull(c);
            const directory = account.dir orelse return api.JSValueMakeNull(c);
            const string = api.JSStringCreateWithUTF8CString(directory) orelse return api.JSValueMakeNull(c);
            defer api.JSStringRelease(string);
            return api.JSValueMakeString(c, string);
        }
    }
    return api.JSValueMakeNull(c);
}

fn availableParallelism(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = count;
    _ = args;
    _ = exception;
    const c = ctx orelse return null;
    const cpus = @import("tool_cpu.zig").availableParallelism() catch return api.JSValueMakeNull(c);
    return api.JSValueMakeNumber(c, @floatFromInt(cpus));
}

fn cpuInformation(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = count;
    _ = args;
    _ = exception;
    const c = ctx orelse return null;
    const allocator = std.heap.smp_allocator;
    var snapshot = @import("tool_cpu_info.zig").snapshot(allocator) catch return api.JSValueMakeNull(c);
    defer snapshot.deinit();
    const json = std.json.Stringify.valueAlloc(allocator, snapshot.records, .{}) catch return api.JSValueMakeNull(c);
    defer allocator.free(json);
    const encoded = @import("bun").dupeZ(allocator, u8, json) catch return api.JSValueMakeNull(c);
    defer allocator.free(encoded);
    const string = api.JSStringCreateWithUTF8CString(encoded.ptr) orelse return api.JSValueMakeNull(c);
    defer api.JSStringRelease(string);
    return api.JSValueMakeString(c, string);
}

fn endianness(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = count;
    _ = args;
    _ = exception;
    const c = ctx orelse return null;
    // Node reports the ABI of the compiled executable, including an explicit
    // big-endian target; do not infer it from replaceable JS constructors.
    const name: [:0]const u8 = if (builtin.cpu.arch.endian() == .little) "LE" else "BE";
    const string = api.JSStringCreateWithUTF8CString(name.ptr) orelse return api.JSValueMakeNull(c);
    defer api.JSStringRelease(string);
    return api.JSValueMakeString(c, string);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_endianness", endianness);
    callback.registerCallback(ctx, global, "__home_tool_account_homedir", homedir);
    callback.registerCallback(ctx, global, "__home_tool_available_parallelism", availableParallelism);
    callback.registerCallback(ctx, global, "__home_tool_cpu_information", cpuInformation);
}
