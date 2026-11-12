// Phase 12.2 M3-real — native JSC script evaluation helper.
//
// This is the first Home-owned surface that can execute a JavaScript source
// string once `-Denable_jsc=true` links JavaScriptCore. Default builds still
// only compile the shape; callers must opt into JSC before invoking it.

const std = @import("std");
const bun = @import("bun");
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

pub const Evaluation = struct {
    value: ?*JSValue = null,
    exception: ?*JSValue = null,
    exception_message: ?[]u8 = null,

    pub fn deinit(self: Evaluation, allocator: std.mem.Allocator) void {
        if (self.exception_message) |message| allocator.free(message);
    }
};

/// C strings cannot carry embedded NULs. Preserve the full source/data length
/// with the existing public UTF-16 API when needed; retain the ordinary UTF-8
/// path for NUL-free text. JSChar values use native byte order.
pub fn createUtf8String(allocator: std.mem.Allocator, text: []const u8) !*opaques.JSString {
    if (std.mem.findScalar(u8, text, 0) != null) {
        const chars = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
        defer allocator.free(chars);
        for (chars) |*char| char.* = std.mem.littleToNative(u16, char.*);
        return extern_fns.JSStringCreateWithCharacters(chars.ptr, chars.len) orelse error.SourceStringInitFailed;
    }
    const text_z = try bun.dupeZ(allocator, u8, text);
    defer allocator.free(text_z);
    return extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse error.SourceStringInitFailed;
}

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

    const script = try createUtf8String(allocator, source);
    defer extern_fns.JSStringRelease(script);

    var source_url_string: ?*opaques.JSString = null;
    if (source_url) |url| {
        source_url_string = createUtf8String(allocator, url) catch |err| switch (err) {
            error.SourceStringInitFailed => return error.SourceUrlStringInitFailed,
            else => return err,
        };
    }
    defer if (source_url_string) |url_string| extern_fns.JSStringRelease(url_string);

    return extern_fns.JSEvaluateScript(ctx, script, null, source_url_string, starting_line_number, exception);
}

pub fn evaluateUtf8Detailed(
    allocator: std.mem.Allocator,
    ctx: *JSContextRef,
    source: []const u8,
    source_url: ?[]const u8,
    starting_line_number: c_int,
) !Evaluation {
    var exception: ?*JSValue = null;
    const value = try evaluateUtf8(allocator, ctx, source, source_url, starting_line_number, &exception);

    return .{
        .value = value,
        .exception = exception,
        .exception_message = if (exception) |thrown| try exceptionMessageUtf8(allocator, ctx, thrown) else null,
    };
}

/// Render a JSValue as its UTF-8 string form via `JSValueToStringCopy`, the
/// same conversion `exceptionMessageUtf8` applies to a thrown value. Used by
/// the `home eval --print` CLI surface to print a result value (mirroring
/// Bun's `--print`). Returns an empty string when JSC is not linked or the
/// conversion fails so callers never have to special-case the disabled build.
pub fn valueToUtf8(allocator: std.mem.Allocator, ctx: *JSContextRef, value: *JSValue) ![]u8 {
    if (comptime !build_options.enable_jsc) {
        return allocator.dupe(u8, "");
    }

    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse
        return allocator.dupe(u8, "");
    defer extern_fns.JSStringRelease(string);

    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    if (capacity == 1) return allocator.dupe(u8, "");

    const buf = try allocator.alloc(u8, capacity);
    defer allocator.free(buf);

    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    const end = if (written > 0) written - 1 else 0;
    return allocator.dupe(u8, buf[0..end]);
}

fn exceptionMessageUtf8(allocator: std.mem.Allocator, ctx: *JSContextRef, value: *JSValue) ![]u8 {
    if (comptime !build_options.enable_jsc) {
        return allocator.dupe(u8, "JSC exception unavailable in default build");
    }

    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse
        return allocator.dupe(u8, "exception string conversion failed");
    defer extern_fns.JSStringRelease(string);

    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    if (capacity == 1) return allocator.dupe(u8, "");

    const buf = try allocator.alloc(u8, capacity);
    defer allocator.free(buf);

    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    const end = if (written > 0) written - 1 else 0;
    return allocator.dupe(u8, buf[0..end]);
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

test "evaluate helper captures thrown exception text when JSC is enabled" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const evaluation = try evaluateUtf8Detailed(
        std.testing.allocator,
        engine.currentContext(),
        "throw new Error('boom')",
        "home:jsc-evaluate-throw-smoke",
        1,
    );
    defer evaluation.deinit(std.testing.allocator);

    try std.testing.expect(evaluation.value == null);
    try std.testing.expect(evaluation.exception != null);
    try std.testing.expect(evaluation.exception_message != null);
    try std.testing.expect(std.mem.indexOf(u8, evaluation.exception_message.?, "boom") != null);
}

test "evaluate helper exposes whether JSC drains promise microtasks after script evaluation" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try evaluateUtf8(
        std.testing.allocator,
        engine.currentContext(),
        "globalThis.__home_microtask_smoke = 0; Promise.resolve().then(() => { globalThis.__home_microtask_smoke = 1; });",
        "home:jsc-microtask-smoke-setup",
        1,
        null,
    );

    const value = (try evaluateUtf8(
        std.testing.allocator,
        engine.currentContext(),
        "globalThis.__home_microtask_smoke",
        "home:jsc-microtask-smoke-read",
        1,
        null,
    )) orelse return error.JSEvaluateReturnedNull;

    const number = extern_fns.JSValueToNumber(engine.currentContext(), value, null);
    try std.testing.expectEqual(@as(f64, 1), number);
}

test "valueToUtf8 renders a result value as its string form when JSC is enabled" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();

    // String concatenation result renders without surrounding quotes, matching
    // JSValueToString semantics (the same path `home eval --print` prints).
    const str_value = (try evaluateUtf8(
        std.testing.allocator,
        ctx,
        "'hello' + 'world'",
        "home:value-to-utf8-string",
        1,
        null,
    )) orelse return error.JSEvaluateReturnedNull;
    const str_text = try valueToUtf8(std.testing.allocator, ctx, str_value);
    defer std.testing.allocator.free(str_text);
    try std.testing.expectEqualStrings("helloworld", str_text);

    // Numeric result renders as its decimal string.
    const num_value = (try evaluateUtf8(
        std.testing.allocator,
        ctx,
        "1 + 2",
        "home:value-to-utf8-number",
        1,
        null,
    )) orelse return error.JSEvaluateReturnedNull;
    const num_text = try valueToUtf8(std.testing.allocator, ctx, num_value);
    defer std.testing.allocator.free(num_text);
    try std.testing.expectEqualStrings("3", num_text);
}

test "evaluate embedded NUL literal preserves the suffix" {
    try std.testing.expect(build_options.enable_jsc);
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const result = try evaluateUtf8Detailed(std.testing.allocator, engine.currentContext(), "`prefix\x00suffix Ω😀`", "home:nul-literal", 1);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.exception == null);
    const text = try valueToUtf8(std.testing.allocator, engine.currentContext(), result.value orelse return error.MissingValue);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("prefix\x00suffix Ω😀", text);
}

test "evaluate embedded NUL invalid script never executes a prefix" {
    try std.testing.expect(build_options.enable_jsc);
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const result = try evaluateUtf8Detailed(std.testing.allocator, engine.currentContext(), "globalThis.nulPrefixRan = true;\x00globalThis.nulSuffixRan = true;", "home:nul-invalid", 1);
    defer result.deinit(std.testing.allocator);
    const state = try evaluateUtf8Detailed(std.testing.allocator, engine.currentContext(), "typeof nulPrefixRan + ':' + typeof nulSuffixRan", "home:nul-state", 1);
    defer state.deinit(std.testing.allocator);
    try std.testing.expect(state.exception == null);
    const text = try valueToUtf8(std.testing.allocator, engine.currentContext(), state.value orelse return error.MissingValue);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("undefined:undefined", text);
    try std.testing.expect(result.exception != null);
}

comptime {
    _ = JSObject;
}
