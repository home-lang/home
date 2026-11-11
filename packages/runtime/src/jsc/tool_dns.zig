//! Native resolver bridge for the repository-tool host's owning task queue.
const std = @import("std");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const fs = @import("tool_fs.zig");
const native = @import("tool_dns_lookup.zig");

fn lookup(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    const c = ctx orelse return null;
    if (count == 0) return api.JSValueMakeNumber(c, @floatFromInt(native.hintsMask()));
    if (count != 3 or !api.JSValueIsString(c, args[0]) or !api.JSValueIsNumber(c, args[1]) or !api.JSValueIsNumber(c, args[2])) return api.JSValueMakeNull(c);
    const family = api.JSValueToNumber(c, args[1], exception);
    const flags = api.JSValueToNumber(c, args[2], exception);
    if ((family != 0 and family != 4 and family != 6) or !std.math.isFinite(flags) or flags < 0 or flags > std.math.maxInt(u32) or @trunc(flags) != flags) return api.JSValueMakeNull(c);
    const allocator = std.heap.smp_allocator;
    const hostname = fs.string(c, args[0], allocator) orelse return api.JSValueMakeNull(c);
    defer allocator.free(hostname);
    var answer = native.lookup(allocator, hostname, @intFromFloat(family), @intFromFloat(flags)) catch |err| {
        const json = std.json.Stringify.valueAlloc(allocator, .{ .host_error = @errorName(err) }, .{}) catch return api.JSValueMakeNull(c);
        defer allocator.free(json);
        return fs.text(c, json);
    };
    defer answer.deinit(allocator);
    const json = std.json.Stringify.valueAlloc(allocator, .{ .records = answer.records.items, .failure = answer.failure }, .{}) catch return api.JSValueMakeNull(c);
    defer allocator.free(json);
    return fs.text(c, json);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    @import("callback.zig").registerCallback(ctx, global, "__home_tool_dns_lookup", lookup);
}
