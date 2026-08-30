// Copied from bun/src/jsc/ZigException.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Structural port. The extern struct layout is kept byte-for-byte so the
// C++ side keeps populating `ZigException` and `ZigException.Holder` through
// the existing `ZigException__collectSourceLines` / `__fromException` path.
//
// Re-attached 2026-08-29: `addToErrorList` projects exceptions into the
// Pechy/API fallback payload now that the schema and stack conversion path
// are available in home_rt.
//
// `Holder.deinit` calls `vm.module_loader.resetArena`. With the
// `VirtualMachine` JSC bridge stubbed (Phase 12.2), the call is dropped;
// the parser-arena reset re-attaches with the real VM.
//
// `bun.String` is stubbed as a `{tag, _pad, impl}` extern struct, matching
// the layout used by `SystemError.zig`.

const std = @import("std");

const String = @import("home").String;

// JSC bridge stubs — re-attach in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
const JSValue = @import("home").jsc.JSValue;
const VirtualMachine = home_rt.jsc.VirtualMachine;

const home_rt = @import("home");
const Exception = home_rt.jsc.Exception;
const JSRuntimeType = home_rt.jsc.JSRuntimeType;

const JSErrorCode = @import("JSErrorCode.zig").JSErrorCode;
const ZigStackFrame = @import("ZigStackFrame.zig").ZigStackFrame;
const ZigStackTrace = @import("ZigStackTrace.zig").ZigStackTrace;
const ZigURL = @import("../url/url.zig").URL;
const api = home_rt.schema.api;

/// Represents a JavaScript exception with additional information
pub const ZigException = extern struct {
    type: JSErrorCode,
    runtime_type: JSRuntimeType,

    /// SystemError only
    errno: c_int = 0,
    /// SystemError only
    syscall: String = String.empty,
    /// SystemError only
    system_code: String = String.empty,
    /// SystemError only
    path: String = String.empty,

    name: String,
    message: String,
    stack: ZigStackTrace,

    exception: ?*anyopaque,

    remapped: bool = false,

    fd: i32 = -1,

    browser_url: String = .empty,

    pub extern fn ZigException__collectSourceLines(jsValue: JSValue, global: *JSGlobalObject, exception: *ZigException) void;

    pub fn collectSourceLines(this: *ZigException, value: JSValue, global: *JSGlobalObject) void {
        ZigException__collectSourceLines(value, global, this);
    }

    pub fn addToErrorList(
        this: *ZigException,
        error_list: *std.array_list.Managed(api.JsException),
        root_path: []const u8,
        origin: ?*const ZigURL,
    ) !void {
        const name_slice = this.name.toUTF8(home_rt.default_allocator);
        const message_slice = this.message.toUTF8(home_rt.default_allocator);

        const name = name_slice.slice();
        defer name_slice.deinit();
        const message = message_slice.slice();
        defer message_slice.deinit();

        var is_empty = true;
        var api_exception = api.JsException{
            .runtime_type = @intFromEnum(this.runtime_type),
            .code = @intFromEnum(this.type),
        };

        if (name.len > 0) {
            api_exception.name = try error_list.allocator.dupe(u8, name);
            is_empty = false;
        }

        if (message.len > 0) {
            api_exception.message = try error_list.allocator.dupe(u8, message);
            is_empty = false;
        }

        if (this.stack.frames_len > 0) {
            api_exception.stack = try this.stack.toAPI(error_list.allocator, root_path, origin);
            is_empty = false;
        }

        if (!is_empty) {
            try error_list.append(api_exception);
        }
    }

    pub fn deinit(this: *ZigException) void {
        this.syscall.deref();
        this.system_code.deref();
        this.path.deref();

        this.name.deref();
        this.message.deref();

        for (this.stack.source_lines_ptr[0..this.stack.source_lines_len]) |*line| {
            line.deref();
        }

        for (this.stack.frames_ptr[0..this.stack.frames_len]) |*frame| {
            frame.deinit();
        }

        if (this.stack.referenced_source_provider) |source| {
            source.deref();
        }
    }

    pub const Holder = extern struct {
        const frame_count = 32;
        pub const source_lines_count = 6;
        source_line_numbers: [source_lines_count]i32,
        source_lines: [source_lines_count]String,
        frames: [frame_count]ZigStackFrame,
        loaded: bool,
        zig_exception: ZigException,
        need_to_clear_parser_arena_on_deinit: bool = false,

        pub const Zero: Holder = Holder{
            .frames = brk: {
                var _frames: [frame_count]ZigStackFrame = undefined;
                @memset(&_frames, ZigStackFrame.Zero);
                break :brk _frames;
            },
            .source_line_numbers = brk: {
                var lines: [source_lines_count]i32 = undefined;
                @memset(&lines, -1);
                break :brk lines;
            },

            .source_lines = brk: {
                var lines: [source_lines_count]String = undefined;
                @memset(&lines, String.empty);
                break :brk lines;
            },
            .zig_exception = undefined,
            .loaded = false,
        };

        pub fn init() Holder {
            return Holder.Zero;
        }

        pub fn deinit(this: *Holder, vm: *VirtualMachine) void {
            if (this.loaded) {
                this.zig_exception.deinit();
            }
            // The .print_source transpile (error source-code previews) skips
            // the normal per-fetch resetArena so its slices stay alive while
            // the error prints; the holder owns the deferred reset. Dropping
            // this leaked one full transpile per inspected error
            // (inspect-error-leak: 74MB/100k iters).
            if (this.need_to_clear_parser_arena_on_deinit) {
                vm.module_loader.resetArena(vm);
            }
        }

        pub fn zigException(this: *Holder) *ZigException {
            if (!this.loaded) {
                this.zig_exception = ZigException{
                    .type = @as(JSErrorCode, @enumFromInt(255)),
                    .runtime_type = JSRuntimeType.Nothing,
                    .name = String.empty,
                    .message = String.empty,
                    .exception = null,
                    .stack = ZigStackTrace{
                        // ZigStackTrace and ZigException each carry a local
                        // `bun.String` C ABI stub with identical extern
                        // layout. The `@ptrCast` is a no-op once the real
                        // `bun.String` re-exports from `home_rt` in Phase 12.2.
                        .source_lines_ptr = @ptrCast(&this.source_lines),
                        .source_lines_numbers = &this.source_line_numbers,
                        .source_lines_len = source_lines_count,
                        .source_lines_to_collect = source_lines_count,
                        .frames_ptr = &this.frames,
                        .frames_len = 0,
                        .frames_cap = this.frames.len,
                    },
                };
                this.loaded = true;
            }

            return &this.zig_exception;
        }
    };

    extern fn ZigException__fromException(*Exception) ZigException;
    pub const fromException = ZigException__fromException;
};

test "ZigException is an extern struct with the expected leading fields" {
    const info = @typeInfo(ZigException).@"struct";
    try std.testing.expect(info.layout == .@"extern");
    try std.testing.expectEqualStrings("type", info.field_names[0]);
    try std.testing.expectEqualStrings("runtime_type", info.field_names[1]);
    try std.testing.expectEqualStrings("errno", info.field_names[2]);
    try std.testing.expectEqualStrings("syscall", info.field_names[3]);
    try std.testing.expectEqualStrings("system_code", info.field_names[4]);
    try std.testing.expectEqualStrings("path", info.field_names[5]);
    try std.testing.expectEqualStrings("name", info.field_names[6]);
    try std.testing.expectEqualStrings("message", info.field_names[7]);
    try std.testing.expectEqualStrings("stack", info.field_names[8]);
}

test "ZigException.Holder.init produces a not-yet-loaded holder" {
    const holder = ZigException.Holder.init();
    try std.testing.expectEqual(false, holder.loaded);
    try std.testing.expectEqual(false, holder.need_to_clear_parser_arena_on_deinit);
    for (holder.source_line_numbers) |n| try std.testing.expectEqual(@as(i32, -1), n);
    for (holder.source_lines) |s| try std.testing.expect(s.isEmpty());
}

test "ZigException.Holder.zigException seeds an empty trace and flips loaded" {
    var holder = ZigException.Holder.init();
    const exc = holder.zigException();
    try std.testing.expectEqual(true, holder.loaded);
    try std.testing.expectEqual(@as(u8, 0), exc.stack.frames_len);
    try std.testing.expectEqual(@as(u8, ZigException.Holder.source_lines_count), exc.stack.source_lines_len);
    try std.testing.expectEqual(JSRuntimeType.Nothing, exc.runtime_type);
    try std.testing.expect(exc.name.isEmpty());
    try std.testing.expect(exc.message.isEmpty());
}

test "home_rt: ZigException projects messages into fallback exception lists" {
    var frames: [0]ZigStackFrame = .{};
    var exception = ZigException{
        .type = .TypeError,
        .runtime_type = .Object,
        .name = String.fromBytes("TypeError"),
        .message = String.fromBytes("streamed failure"),
        .stack = ZigStackTrace.fromFrames(&frames),
        .exception = null,
    };

    var list = std.array_list.Managed(api.JsException).init(std.testing.allocator);
    defer {
        for (list.items) |item| {
            if (item.name) |name| std.testing.allocator.free(name);
            if (item.message) |message| std.testing.allocator.free(message);
        }
        list.deinit();
    }

    try exception.addToErrorList(&list, "/", null);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("TypeError", list.items[0].name.?);
    try std.testing.expectEqualStrings("streamed failure", list.items[0].message.?);
    try std.testing.expectEqual(@as(?u16, @intFromEnum(JSRuntimeType.Object)), list.items[0].runtime_type);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(JSErrorCode.TypeError)), list.items[0].code);
    try std.testing.expect(list.items[0].stack == null);
}
