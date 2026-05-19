// Ported from bun/src/css/properties/shape.zig at pinned SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6.
//
// Wave-15 Tier-1 grinder copy. Pure-data leaf with `DefineEnumProperty`
// + `todo_stuff.depth` reaching into the css_parser stub.
//
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").

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

const std = @import("std");

test "AlphaValue: stores opacity as a single float" {
    const a = AlphaValue{ .v = 0.5 };
    try std.testing.expectEqual(@as(f32, 0.5), a.v);
}

test "AlphaValue: zero / one are valid endpoints" {
    const transparent = AlphaValue{ .v = 0.0 };
    const opaque_v = AlphaValue{ .v = 1.0 };
    try std.testing.expectEqual(@as(f32, 0.0), transparent.v);
    try std.testing.expectEqual(@as(f32, 1.0), opaque_v.v);
}
