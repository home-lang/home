//! Native terminal classification and read-only window-size queries.
const std = @import("std");
const builtin = @import("builtin");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");

fn isatty(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const c = ctx orelse return null;
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        if (count == 0 or args[0] == null or !api.JSValueIsNumber(c, args[0])) return api.JSValueMakeBoolean(c, false);
        const number = api.JSValueToNumber(c, args[0], null);
        if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > std.math.maxInt(c_int))
            return api.JSValueMakeBoolean(c, false);
        const descriptor: c_int = @intFromFloat(number);
        return api.JSValueMakeBoolean(c, std.c.isatty(descriptor) != 0);
    }
    return api.JSValueMakeNull(c);
}

// Read-only native terminal facts; stream ownership stays in the FS host.
fn windowSize(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const c = ctx orelse return null;
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        if (count == 0 or !api.JSValueIsNumber(c, args[0])) return api.JSValueMakeNull(c);
        const number = api.JSValueToNumber(c, args[0], null);
        if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > std.math.maxInt(c_int)) return api.JSValueMakeNull(c);
        const descriptor: c_int = @intFromFloat(number);
        if (std.c.isatty(descriptor) == 0) return api.JSValueMakeNull(c);
        var size: std.posix.winsize = undefined;
        if (std.posix.system.ioctl(@intCast(descriptor), std.posix.T.IOCGWINSZ, @intFromPtr(&size)) != 0) return api.JSValueMakeNull(c);
        const object = api.JSObjectMake(c, null, null) orelse return api.JSValueMakeNull(c);
        api.JSValueProtect(c, @ptrCast(object));
        defer api.JSValueUnprotect(c, @ptrCast(object));
        @import("tool_fs.zig").set(c, object, "columns", api.JSValueMakeNumber(c, @floatFromInt(size.col)));
        @import("tool_fs.zig").set(c, object, "rows", api.JSValueMakeNumber(c, @floatFromInt(size.row)));
        return @ptrCast(object);
    }
    return api.JSValueMakeNull(c);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_isatty", isatty);
    callback.registerCallback(ctx, global, "__home_tool_tty_size", windowSize);
}
