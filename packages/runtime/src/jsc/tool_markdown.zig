//! Public-C adapter for Home's existing CommonMark/GFM HTML renderer.
const std = @import("std");
const md = @import("tool_markdown_parser");
const callback = @import("callback.zig");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const fs = @import("tool_fs.zig");

fn failure(ctx: *types.JSContextRef, object: *types.JSObject, err: anyerror) ?*types.JSValue {
    fs.set(ctx, object, "error", fs.text(ctx, @errorName(err)));
    return @ptrCast(object);
}

fn sourceText(ctx: *types.JSContextRef, value: ?*types.JSValue, allocator: std.mem.Allocator) ![]u8 {
    const string = api.JSValueToStringCopy(ctx, value, null) orelse return error.OutOfMemory;
    defer api.JSStringRelease(string);
    const length = api.JSStringGetLength(string);
    if (length == 0) return allocator.dupe(u8, "");
    const chars = try allocator.dupe(u16, api.JSStringGetCharactersPtr(string)[0..length]);
    for (chars) |*char| char.* = std.mem.nativeToLittle(u16, char.*);
    // JSC's UTF-8 CString conversion can stop at an unpaired surrogate. Bun's
    // Markdown input conversion replaces it and continues through the full text.
    return std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf16Le(chars)});
}

fn render(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    const c = ctx orelse return null;
    const result = api.JSObjectMake(c, null, null) orelse return null;
    api.JSValueProtect(c, @ptrCast(result));
    defer api.JSValueUnprotect(c, @ptrCast(result));
    if (count < 2 or args[0] == null or args[1] == null) return failure(c, result, error.InvalidArguments);
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = fs.string(c, args[1], allocator) orelse return failure(c, result, error.OutOfMemory);
    const options = std.json.parseFromSlice(md.Options, allocator, json, .{}) catch |err| return failure(c, result, err);
    defer options.deinit();
    const input: []const u8 = if (api.JSValueIsString(c, args[0]))
        sourceText(c, args[0], allocator) catch |err| return failure(c, result, err)
    else input: {
        const kind = api.JSValueGetTypedArrayType(c, args[0], exception);
        if (kind == .kJSTypedArrayTypeNone or kind == .kJSTypedArrayTypeArrayBuffer) return failure(c, result, error.UnsupportedInput);
        const object = api.JSValueToObject(c, args[0], exception) orelse return failure(c, result, error.UnsupportedInput);
        const length = api.JSObjectGetTypedArrayByteLength(c, object, exception);
        if (length == 0) break :input &.{};
        const offset = api.JSObjectGetTypedArrayByteOffset(c, object, exception);
        const raw = api.JSObjectGetTypedArrayBytesPtr(c, object, exception);
        const bytes: [*]const u8 = @ptrCast(raw orelse return failure(c, result, error.UnsupportedInput));
        // The public C API returns the backing-store base, not the view start.
        break :input bytes[offset..][0..length];
    };
    // Shared parser offsets are u32. No JavaScript call occurs while a binary
    // view is borrowed; rendering only allocates native, callback-owned storage.
    if (input.len > std.math.maxInt(u32)) return failure(c, result, error.InputTooLarge);
    const html = md.renderToHtmlWithOptions(input, allocator, options.value) catch |err| return failure(c, result, err);
    // Length-bearing UTF-16 output preserves embedded NUL and supplementary
    // characters rather than passing HTML through a sentinel string constructor.
    const normalized = if (std.unicode.utf8ValidateSlice(html)) html else std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(html)}) catch |err| return failure(c, result, err);
    const chars = std.unicode.utf8ToUtf16LeAlloc(allocator, normalized) catch |err| return failure(c, result, err);
    for (chars) |*char| char.* = std.mem.littleToNative(u16, char.*);
    const string = api.JSStringCreateWithCharacters(chars.ptr, chars.len) orelse return failure(c, result, error.OutOfMemory);
    defer api.JSStringRelease(string);
    const value = api.JSValueMakeString(c, string) orelse return failure(c, result, error.OutOfMemory);
    fs.set(c, result, "html", value);
    return @ptrCast(result);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_render_markdown", render);
}
