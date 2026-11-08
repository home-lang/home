//! Native monotonic samples for the repository tool's bounded Performance API.
const std = @import("std");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");

fn milliseconds(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = count;
    _ = args;
    _ = exception;
    const c = ctx orelse return null;
    var timestamp: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    // A failed OS clock is refused by the adapter, never a synthetic zero.
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &timestamp) != 0)
        return api.JSValueMakeNull(c);
    const result = @as(f64, @floatFromInt(timestamp.sec)) * 1.0e3 + @as(f64, @floatFromInt(timestamp.nsec)) / 1.0e6;
    return api.JSValueMakeNumber(c, result);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_monotonic_millis", milliseconds);
}
