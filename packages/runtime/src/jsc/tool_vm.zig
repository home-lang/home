//! Global Script evaluation for the repository-tool's bounded vm adapter.
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");

fn runScript(ctx: ?*types.JSContextRef, _: ?*types.JSObject, _: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    const c = ctx orelse return null;
    if (count != 2 or !api.JSValueIsString(c, args[0]) or !api.JSValueIsString(c, args[1])) return null;
    // Keep the engine string intact, including embedded NULs. Script evaluation
    // shares the global environment, not the calling module's lexical scope.
    const source = api.JSValueToStringCopy(c, args[0], exception) orelse return null;
    defer api.JSStringRelease(source);
    const filename = api.JSValueToStringCopy(c, args[1], exception) orelse return null;
    defer api.JSStringRelease(filename);
    return api.JSEvaluateScript(c, source, null, filename, 1, exception);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    @import("callback.zig").registerCallback(ctx, global, "__home_tool_run_script", runScript);
}
