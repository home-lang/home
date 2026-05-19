// Copied from bun/src/css/properties/shape.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `FillRule` resolves through the stub's `DefineEnumProperty` (the generated
// `parse`/`toCss` paths trip `@compileError` if reached; the type-name itself
// resolves so downstream files referencing `FillRule` continue to compile).

pub const css = @import("../css_parser_stub.zig");

/// A [`<fill-rule>`](https://www.w3.org/TR/css-shapes-1/#typedef-fill-rule) used to
/// determine the interior of a `polygon()` shape.
///
/// See [Polygon](Polygon).
pub const FillRule = css.DefineEnumProperty(@compileError(css.todo_stuff.depth));

/// A CSS [`<alpha-value>`](https://www.w3.org/TR/css-color-4/#typedef-alpha-value),
/// used to represent opacity.
///
/// Parses either a `<number>` or `<percentage>`, but is always stored and serialized as a number.
pub const AlphaValue = struct {
    v: f32,
};

test "shape.AlphaValue: stores a single f32" {
    const std = @import("std");
    const a = AlphaValue{ .v = 0.5 };
    try std.testing.expectEqual(@as(f32, 0.5), a.v);
}
