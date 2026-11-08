//! Actual engine execution snapshots; no Promise monkeypatch or ambient JS store.
const options = @import("build_options");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");

extern "c" fn ZJSContextGetAsyncContext(?*types.JSContextRef, api.ExceptionRef) ?*types.JSValue;
extern "c" fn ZJSContextSwapAsyncContext(?*types.JSContextRef, ?*types.JSValue, api.ExceptionRef) ?*types.JSValue;

fn get(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = count;
    _ = args;
    return ZJSContextGetAsyncContext(ctx, exception);
}

fn swap(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    return ZJSContextSwapAsyncContext(ctx, if (count != 0) args[0] else null, exception);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    if (comptime !options.use_zig_js) return;
    callback.registerCallback(ctx, global, "__home_tool_get_async_context", get);
    callback.registerCallback(ctx, global, "__home_tool_swap_async_context", swap);
}
