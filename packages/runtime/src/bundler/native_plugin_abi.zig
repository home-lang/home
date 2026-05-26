//! Bun native bundler plugin C ABI.
//!
//! Faithfully mirrors:
//! - /Users/chrisbreuer/Code/bun/packages/bun-native-bundler-plugin-api/bundler_plugin.h
//! - /Users/chrisbreuer/Code/bun/src/jsc/bindings/napi_external.h
//! - /Users/chrisbreuer/Code/bun/src/jsc/bindings/JSBundlerPlugin.{h,cpp}
//!
//! Keep this module at the native boundary. Home's internal bundler loader
//! enum intentionally has extra values; native plugins must see Bun's public
//! header values instead.

const std = @import("std");

pub const Loader = enum(u8) {
    jsx = 0,
    js = 1,
    ts = 2,
    tsx = 3,
    css = 4,
    file = 5,
    json = 6,
    toml = 7,
    wasm = 8,
    napi = 9,
    base64 = 10,
    dataurl = 11,
    text = 12,
    html = 17,
    yaml = 18,
    _,

    pub const max = Loader.yaml;
};

pub const LogLevel = enum(i8) {
    verbose = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    _,
};

pub const NapiModuleMeta = extern struct {
    dlopen_handle: ?*anyopaque,
};

pub fn OnBeforeParseArguments(comptime Context: type) type {
    return extern struct {
        struct_size: usize = @sizeOf(@This()),
        context: *Context,
        path_ptr: ?[*]const u8 = "",
        path_len: usize = 0,
        namespace_ptr: ?[*]const u8 = "file",
        namespace_len: usize = "file".len,
        default_loader: Loader = .file,
        external: ?*anyopaque = null,
    };
}

pub const BunLogOptions = extern struct {
    struct_size: usize = @sizeOf(BunLogOptions),
    message_ptr: ?[*]const u8 = null,
    message_len: usize = 0,
    path_ptr: ?[*]const u8 = null,
    path_len: usize = 0,
    source_line_text_ptr: ?[*]const u8 = null,
    source_line_text_len: usize = 0,
    level: LogLevel = .err,
    line: i32 = 0,
    line_end: i32 = 0,
    column: i32 = 0,
    column_end: i32 = 0,
};

pub fn OnBeforeParseResult(comptime Arguments: type) type {
    return extern struct {
        const Self = @This();

        struct_size: usize = @sizeOf(Self),
        source_ptr: ?[*]const u8 = null,
        source_len: usize = 0,
        loader: Loader = .file,
        fetch_source_code_fn: *const fn (*Arguments, *Self) callconv(.c) i32,
        user_context: ?*anyopaque = null,
        free_user_context: ?*const fn (?*anyopaque) callconv(.c) void = null,
        log: *const fn (
            args_: ?*Arguments,
            log_options_: ?*BunLogOptions,
        ) callconv(.c) void,
    };
}

test "native plugin public loader ids match Bun bundler_plugin.h" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Loader.jsx));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(Loader.json));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(Loader.toml));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(Loader.napi));
    try std.testing.expectEqual(@as(u8, 12), @intFromEnum(Loader.text));
    try std.testing.expectEqual(@as(u8, 17), @intFromEnum(Loader.html));
    try std.testing.expectEqual(@as(u8, 18), @intFromEnum(Loader.max));
}

test "native plugin extern struct layout is the Bun header layout on 64-bit" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;

    const Args = OnBeforeParseArguments(anyopaque);
    const Result = OnBeforeParseResult(Args);

    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Args));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Args));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(BunLogOptions));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(BunLogOptions));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Result));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Result));
}
