// Copied from bun/src/css/properties/box_shadow.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
//
// Strategy-B port over the stub. `BoxShadow` is a pure-data struct
// (color/x_offset/y_offset/blur/spread/inset) and survives intact. `CssColor`
// + `Length` (= `LengthValue`) resolve via the stub; their methods trip
// `@compileError` on call. `parse`/`toCss`/`isCompatible` reach for
// `Length.parse`, `CssColor.parse`, `dest.writeStr`, `css.targets.Browsers`,
// `Length.eql` etc. — all behind `@compileError` and stripped here.
//
// `BoxShadowHandler` reaches into `Property`/`DeclarationList`/
// `PropertyHandlerContext`/`ColorFallbackKind`/`prefixes.Feature`/`bun.bits`/
// `bun.take` (none of which are ported), so the entire handler + `flush` +
// `finalize` are stripped.

pub const css = @import("../css_parser_stub.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const CssColor = css.css_values.color.CssColor;
const Length = css.css_values.length.Length;

const VendorPrefix = css.VendorPrefix;

/// A value for the [box-shadow](https://drafts.csswg.org/css-backgrounds/#box-shadow) property.
pub const BoxShadow = struct {
    /// The color of the box shadow.
    color: CssColor,
    /// The x offset of the shadow.
    x_offset: Length,
    /// The y offset of the shadow.
    y_offset: Length,
    /// The blur radius of the shadow.
    blur: Length,
    /// The spread distance of the shadow.
    spread: Length,
    /// Whether the shadow is inset within the box.
    inset: bool,

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

test "BoxShadow holds pure-data fields" {
    const s = BoxShadow{
        .color = .current_color,
        .x_offset = .{},
        .y_offset = .{},
        .blur = .{},
        .spread = .{},
        .inset = false,
    };
    try std.testing.expect(s.color == .current_color);
    try std.testing.expect(!s.inset);
}

test "BoxShadow.inset flag round-trips" {
    const a = BoxShadow{
        .color = .current_color,
        .x_offset = .{},
        .y_offset = .{},
        .blur = .{},
        .spread = .{},
        .inset = true,
    };
    try std.testing.expect(a.inset);
}

test "BoxShadow.deepClone is a shallow copy" {
    const s = BoxShadow{
        .color = .current_color,
        .x_offset = .{},
        .y_offset = .{},
        .blur = .{},
        .spread = .{},
        .inset = false,
    };
    const cloned = s.deepClone(std.testing.allocator);
    try std.testing.expect(cloned.color == .current_color);
    try std.testing.expect(cloned.inset == s.inset);
}

const std = @import("std");
