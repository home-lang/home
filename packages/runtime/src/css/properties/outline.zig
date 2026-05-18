// Copied from bun/src/css/properties/outline.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `GenericBorder` + `LineStyle` resolve via the stub's `css_properties.border`
// surface. The stubbed `GenericBorder` returns a slim placeholder struct
// (`{style}` + `default()`/`deepClone()`/`eql()`) — enough for `Outline` /
// `OutlineStyle` to compile. `DeriveParse`/`DeriveToCss` `.parse`/`.toCss`
// helpers trip `@compileError` if called (the real parser/printer hasn't
// landed yet); `eql` returns `false` per the stub `implementEql` policy.

pub const css = @import("../css_parser_stub.zig");

const GenericBorder = css.css_properties.border.GenericBorder;
const LineStyle = css.css_properties.border.LineStyle;

/// A value for the [outline](https://drafts.csswg.org/css-ui/#outline) shorthand property.
pub const Outline = GenericBorder(OutlineStyle, 11);

/// A value for the [outline-style](https://drafts.csswg.org/css-ui/#outline-style) property.
pub const OutlineStyle = union(enum) {
    /// The `auto` keyword.
    auto: void,
    /// A value equivalent to the `border-style` property.
    line_style: LineStyle,

    pub const parse = css.DeriveParse(@This()).parse;
    pub const toCss = css.DeriveToCss(@This()).toCss;

    pub fn default() @This() {
        return .{ .line_style = .none };
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

test "OutlineStyle.default is line_style.none" {
    const d = OutlineStyle.default();
    try std.testing.expect(d == .line_style);
    try std.testing.expectEqual(LineStyle.none, d.line_style);
}

test "OutlineStyle.auto variant" {
    const a: OutlineStyle = .{ .auto = {} };
    try std.testing.expect(a == .auto);
}

test "Outline carries OutlineStyle via GenericBorder" {
    const o = Outline.default();
    try std.testing.expect(o.style == .line_style);
}

test "Outline.deepClone is a shallow copy under the stub" {
    const o = Outline{ .style = .{ .auto = {} } };
    const cloned = o.deepClone(std.testing.allocator);
    try std.testing.expect(cloned.style == .auto);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
