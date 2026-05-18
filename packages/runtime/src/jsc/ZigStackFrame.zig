// Copied from bun/src/jsc/ZigStackFrame.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Structural port. Upstream extern struct layout (function_name, source_url,
// position, code_type, is_async, remapped, jsc_stack_frame_index) is kept
// byte-for-byte so the C++ side keeps passing/returning frames unchanged.
//
// The two formatter sub-structs (`SourceURLFormatter`, `NameFormatter`) call
// `bun.Output.prettyFmt` for ANSI color escapes and `bun.strings.*` path
// helpers, neither of which is on the `home_rt` allow-list yet. They are
// omitted; re-land them when `home_rt.Output.prettyFmt` and the leading-/
// trailing-path-separator helpers are exposed.
//
// `toAPI` projects into `bun.schema.api.StackFrame` (the bindgen-generated
// IPC payload type) and pulls in `../url/url.zig`. Neither is ported yet;
// the method is omitted and re-lands with `api.StackFrame`.
//
// `bun.String` is stubbed as a `{tag, _pad, impl}` extern struct, matching
// the layout used by `SystemError.zig` so the C ABI is identical.

const std = @import("std");

// `bun.String` C ABI stub — re-attaches in Phase 12.2.
// Real layout is `{tag: u8, _padding: 7 bytes, impl: *anyopaque}` (see
// upstream src/string/BunString.h).
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,

    pub const empty: String = .{};

    pub fn ref(_: *const String) void {}
    pub fn deref(_: *const String) void {}
    pub fn isEmpty(this: *const String) bool {
        return this.tag == 0 and this.impl == null;
    }
};

const ZigStackFrameCode = @import("ZigStackFrameCode.zig").ZigStackFrameCode;
const ZigStackFramePosition = @import("ZigStackFramePosition.zig").ZigStackFramePosition;

/// Represents a single frame in a stack trace
pub const ZigStackFrame = extern struct {
    function_name: String,
    source_url: String,
    position: ZigStackFramePosition,
    code_type: ZigStackFrameCode,
    is_async: bool,

    /// This informs formatters whether to display as a blob URL or not
    remapped: bool = false,

    /// -1 means not set.
    jsc_stack_frame_index: i32 = -1,

    pub fn deinit(this: *ZigStackFrame) void {
        this.function_name.deref();
        this.source_url.deref();
    }

    pub const Zero: ZigStackFrame = .{
        .function_name = .empty,
        .code_type = .None,
        .source_url = .empty,
        .position = .invalid,
        .is_async = false,
        .jsc_stack_frame_index = -1,
    };
};

test "ZigStackFrame.Zero has expected defaults" {
    const f = ZigStackFrame.Zero;
    try std.testing.expect(f.function_name.isEmpty());
    try std.testing.expect(f.source_url.isEmpty());
    try std.testing.expectEqual(@as(i32, -1), f.jsc_stack_frame_index);
    try std.testing.expectEqual(@as(ZigStackFrameCode, .None), f.code_type);
    try std.testing.expectEqual(false, f.is_async);
    try std.testing.expectEqual(false, f.remapped);
}

test "ZigStackFrame is an extern struct with the expected field order" {
    const info = @typeInfo(ZigStackFrame).@"struct";
    try std.testing.expect(info.layout == .@"extern");
    try std.testing.expectEqualStrings("function_name", info.fields[0].name);
    try std.testing.expectEqualStrings("source_url", info.fields[1].name);
    try std.testing.expectEqualStrings("position", info.fields[2].name);
    try std.testing.expectEqualStrings("code_type", info.fields[3].name);
    try std.testing.expectEqualStrings("is_async", info.fields[4].name);
    try std.testing.expectEqualStrings("remapped", info.fields[5].name);
    try std.testing.expectEqualStrings("jsc_stack_frame_index", info.fields[6].name);
}
