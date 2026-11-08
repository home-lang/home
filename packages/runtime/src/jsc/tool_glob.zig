//! Real filesystem-backed Glob operations for either public-C engine backend.
const std = @import("std");
const callback = @import("callback.zig");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const fs = @import("tool_fs.zig");
const walk = @import("tool_glob_walk.zig");
const matcher = @import("tool_glob_matcher");

fn operation(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const c = ctx orelse return null;
    const object = api.JSObjectMake(c, null, null) orelse return api.JSValueMakeNull(c);
    if (count < 3) return fs.failure(c, object, error.Unsupported);
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const op = fs.string(c, args[0], allocator) orelse return fs.failure(c, object, error.OutOfMemory);
    const pattern = fs.string(c, args[1], allocator) orelse return fs.failure(c, object, error.OutOfMemory);
    const input = fs.string(c, args[2], allocator) orelse return fs.failure(c, object, error.OutOfMemory);
    if (std.mem.eql(u8, op, "match")) {
        fs.set(c, object, "matches", api.JSValueMakeBoolean(c, matcher.match(pattern, input).matches()));
    } else if (std.mem.eql(u8, op, "scan") and count >= 6) {
        const output = walk.scan(allocator, input, pattern, .{ .dot = api.JSValueToBoolean(c, args[3]), .absolute = api.JSValueToBoolean(c, args[4]), .only_files = api.JSValueToBoolean(c, args[5]) }) catch |err| {
            if (err == error.Unsupported) {
                fs.set(c, object, "error", fs.text(c, "ERR_HOME_UNSUPPORTED_GLOB"));
                return @ptrCast(object);
            }
            if (err == error.GlobLimit) {
                fs.set(c, object, "error", fs.text(c, "ERR_HOME_GLOB_LIMIT"));
                return @ptrCast(object);
            }
            return fs.failure(c, object, err);
        };
        const json = std.json.Stringify.valueAlloc(allocator, output, .{ .emit_null_optional_fields = false }) catch return fs.failure(c, object, error.OutOfMemory);
        fs.set(c, object, "json", fs.text(c, json));
    } else return fs.failure(c, object, error.Unsupported);
    return @ptrCast(object);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_glob", operation);
}
