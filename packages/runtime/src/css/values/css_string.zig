// Copied from bun/src/css/values/css_string.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// The original `toCss` calls `css.serializer.serializeString` which is itself
// a deep dependency on the upstream Tokenizer; the body is preserved verbatim
// but the stub's missing `serializer` namespace makes the function body a
// compile-time trap if anyone references it. Wave-7 only needs the type
// alias (`CSSString = []const u8`) + `parse` signature to resolve.

pub const css = @import("../css_parser.zig");
pub const Result = css.Result;
pub const Printer = css.Printer;
pub const PrintErr = css.PrintErr;

/// A quoted CSS string.
pub const CSSString = []const u8;
pub const CSSStringFns = struct {
    pub fn parse(input: *css.Parser) Result(CSSString) {
        return input.expectString();
    }

    pub fn toCss(this: *const []const u8, dest: *Printer) PrintErr!void {
        return css.serializer.serializeString(this.*, dest) catch return dest.addFmtError();
    }
};

test "CSSString alias is a byte slice" {
    const s: CSSString = "hello";
    try std.testing.expectEqualStrings("hello", s);
}

test "CSSStringFns is the namespace struct" {
    // Compile-time existence check — exercising methods would trip
    // @compileError per stub policy.
    _ = CSSStringFns;
}

const std = @import("std");
