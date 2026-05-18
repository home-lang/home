// Copied verbatim from bun/src/jsc/ZigStackFrameCode.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const ZigStackFrameCode = enum(u8) {
    None = 0,
    /// 🏃
    Eval = 1,
    /// 📦
    Module = 2,
    /// λ
    Function = 3,
    /// 🌎
    Global = 4,
    /// ⚙️
    Wasm = 5,
    /// 👷
    Constructor = 6,
    _,

    pub fn emoji(this: ZigStackFrameCode) u21 {
        return switch (this) {
            .Eval => 0x1F3C3,
            .Module => 0x1F4E6,
            .Function => 0x03BB,
            .Global => 0x1F30E,
            .Wasm => 0xFE0F,
            .Constructor => 0xF1477,
            else => ' ',
        };
    }

    pub fn ansiColor(this: ZigStackFrameCode) []const u8 {
        return switch (this) {
            .Eval => "\x1b[31m",
            .Module => "\x1b[36m",
            .Function => "\x1b[32m",
            .Global => "\x1b[35m",
            .Wasm => "\x1b[37m",
            .Constructor => "\x1b[33m",
            else => "",
        };
    }
};

test "ZigStackFrameCode.emoji returns expected codepoints" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u21, 0x1F3C3), ZigStackFrameCode.Eval.emoji());
    try std.testing.expectEqual(@as(u21, 0x1F4E6), ZigStackFrameCode.Module.emoji());
    try std.testing.expectEqual(@as(u21, 0x03BB), ZigStackFrameCode.Function.emoji());
    try std.testing.expectEqual(@as(u21, ' '), ZigStackFrameCode.None.emoji());
}

test "ZigStackFrameCode.ansiColor maps Function to green" {
    const std = @import("std");
    try std.testing.expectEqualStrings("\x1b[32m", ZigStackFrameCode.Function.ansiColor());
    try std.testing.expectEqualStrings("", ZigStackFrameCode.None.ansiColor());
}
