//! Native descriptor classification; terminal streams need a separate host.
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

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_isatty", isatty);
}
