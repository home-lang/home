//! Fresh OS entropy for the repository tool's synchronous crypto adapter.
const std = @import("std");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");

fn randomBytes(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    const c = ctx orelse return null;
    if (count != 1 or args[0] == null or api.JSValueGetTypedArrayType(c, args[0], exception) != .kJSTypedArrayTypeUint8Array)
        return api.JSValueMakeBoolean(c, false);
    const object = api.JSValueToObject(c, args[0], exception) orelse return api.JSValueMakeBoolean(c, false);
    const length = api.JSObjectGetTypedArrayByteLength(c, object, exception);
    if (length == 0) return api.JSValueMakeBoolean(c, true);
    const raw = api.JSObjectGetTypedArrayBytesPtr(c, object, exception) orelse return api.JSValueMakeBoolean(c, false);
    const bytes: [*]u8 = @ptrCast(raw);
    // Unlike Io.random, randomSecure never substitutes a weak seed when the
    // OS entropy source fails. No JS calls occur while the borrowed view is held.
    const io = std.Io.Threaded.global_single_threaded.io();
    io.randomSecure(bytes[0..length]) catch return api.JSValueMakeBoolean(c, false);
    return api.JSValueMakeBoolean(c, true);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_random_bytes", randomBytes);
}
