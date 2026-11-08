//! Pure native brand inspection, without JS traps or Promise reactions.
const options = @import("build_options");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");

extern "c" fn ZJSValueIsPromise(?*types.JSContextRef, ?*types.JSValue) bool;
extern "c" fn ZJSValueIsProxy(?*types.JSContextRef, ?*types.JSValue) bool;

fn inspectPromise(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const c = ctx orelse return null;
    return api.JSValueMakeBoolean(c, ZJSValueIsPromise(c, if (count > 0) args[0] else null));
}

fn inspectProxy(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const c = ctx orelse return null;
    return api.JSValueMakeBoolean(c, ZJSValueIsProxy(c, if (count > 0) args[0] else null));
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    if (comptime !options.use_zig_js) return;
    callback.registerCallback(ctx, global, "__home_tool_is_promise", inspectPromise);
    callback.registerCallback(ctx, global, "__home_tool_is_proxy", inspectProxy);
}
