// Phase 12.2 M3-real — native JSC script evaluation helper.
//
// This is the first Home-owned surface that can execute a JavaScript source
// string once `-Denable_jsc=true` links JavaScriptCore. Default builds still
// only compile the shape; callers must opt into JSC before invoking it.

const std = @import("std");
const build_options = @import("build_options");
const Engine = @import("engine.zig").Engine;
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;

pub const EvaluateError = error{
    JSCDisabled,
    SourceStringInitFailed,
    SourceUrlStringInitFailed,
};

/// Evaluate UTF-8 JavaScript source in `ctx`.
///
/// `source_url` is optional and only used for diagnostics/stack traces.
/// Exceptions are delivered through JSC's out-param; pass `null` to discard
/// the thrown value and inspect the nullable return.
pub fn evaluateUtf8(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    source: []const u8,
    source_url: ?[]const u8,
    starting_line_number: c_int,
    exception: extern_fns.ExceptionRef,
) !?*JSValue {
    if (!build_options.enable_jsc) return error.JSCDisabled;

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    const script = extern_fns.JSStringCreateWithUTF8CString(source_z.ptr) orelse
        return error.SourceStringInitFailed;
    defer extern_fns.JSStringRelease(script);

    var source_url_string: ?*opaques.JSString = null;
    if (source_url) |url| {
        const url_z = try allocator.dupeZ(u8, url);
        defer allocator.free(url_z);

        source_url_string = extern_fns.JSStringCreateWithUTF8CString(url_z.ptr) orelse
            return error.SourceUrlStringInitFailed;
    }
    defer if (source_url_string) |url_string| extern_fns.JSStringRelease(url_string);

    return extern_fns.JSEvaluateScript(ctx, script, null, source_url_string, starting_line_number, exception);
}

test "evaluate helper exposes a native JSC execution surface" {
    try std.testing.expect(@typeInfo(@TypeOf(evaluateUtf8)) == .@"fn");

    const info = @typeInfo(@TypeOf(evaluateUtf8)).@"fn";
    const ret = @typeInfo(info.return_type.?).error_union;
    try std.testing.expect(@typeInfo(ret.payload) == .optional);
    try std.testing.expect(@typeInfo(ret.payload).optional.child == *JSValue);
    try std.testing.expect(@typeInfo(ret.error_set) == .error_set);
}

test "evaluate helper executes a script when JSC is enabled" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const value = (try evaluateUtf8(
        std.testing.allocator,
        engine.currentContext(),
        "1 + 2",
        "home:jsc-evaluate-smoke",
        1,
        null,
    )) orelse return error.JSEvaluateReturnedNull;

    const number = extern_fns.JSValueToNumber(engine.currentContext(), value, null);
    try std.testing.expectEqual(@as(f64, 3), number);
}

comptime {
    _ = JSObject;
}
