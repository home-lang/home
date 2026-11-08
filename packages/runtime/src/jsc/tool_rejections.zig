//! Consume actual engine notifications; do not approximate Promise tracking in JS.
const std = @import("std");
const options = @import("build_options");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const evaluate = @import("evaluate.zig");

extern "c" fn ZJSContextTakeUnhandledRejection(
    ctx: ?*types.JSContextRef,
    reason: api.ExceptionRef,
    rejected_promise: api.ExceptionRef,
    exception: api.ExceptionRef,
) bool;

/// Return an owned diagnostic only when the boundary itself failed. The
/// protected handler dispatches real process events and terminates fatal cases.
pub fn checkpoint(allocator: std.mem.Allocator, ctx: *types.JSContextRef, handler: *types.JSValue) !?[]u8 {
    if (comptime !options.use_zig_js) return error.UnhandledRejectionCheckpointUnsupported;
    const function = api.JSValueToObject(ctx, handler, null) orelse return error.InvalidRejectionHandler;
    if (!api.JSObjectIsFunction(ctx, function)) return error.InvalidRejectionHandler;
    const origin_string = api.JSStringCreateWithUTF8CString("unhandledRejection") orelse return error.OutOfMemory;
    defer api.JSStringRelease(origin_string);
    const origin = api.JSValueMakeString(ctx, origin_string) orelse return error.OutOfMemory;
    api.JSValueProtect(ctx, origin);
    defer api.JSValueUnprotect(ctx, origin);
    while (true) {
        var reason: ?*types.JSValue = null;
        var rejected: ?*types.JSValue = null;
        var exception: ?*types.JSValue = null;
        if (!ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception)) {
            if (exception) |thrown| return try evaluate.valueToUtf8(allocator, ctx, thrown);
            return null;
        }
        const reason_value = reason orelse return error.MissingRejectionReason;
        const promise_value = rejected orelse return error.MissingRejectedPromise;
        api.JSValueProtect(ctx, reason_value);
        defer api.JSValueUnprotect(ctx, reason_value);
        api.JSValueProtect(ctx, promise_value);
        defer api.JSValueUnprotect(ctx, promise_value);
        const arguments = [_]?*types.JSValue{ reason_value, origin, promise_value };
        const dispatched = api.JSObjectCallAsFunction(ctx, function, null, arguments.len, &arguments, &exception);
        if (exception) |thrown| return try evaluate.valueToUtf8(allocator, ctx, thrown);
        if (dispatched == null) return error.MissingRejectionDispatchResult;
        // Event listeners can schedule jobs or attach handlers. Complete their
        // checkpoint before consuming any newly queued rejection notification.
        const jobs = try evaluate.evaluateUtf8Detailed(allocator, ctx, "", "home:rejection-checkpoint", 1);
        defer jobs.deinit(allocator);
        if (jobs.exception) |thrown| return try evaluate.valueToUtf8(allocator, ctx, thrown);
    }
}
