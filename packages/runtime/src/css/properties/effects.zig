// Copied from bun/src/css/properties/effects.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// Wave-9 (2026-05-18) port — `effects.zig` is a pure-data leaf describing
// `filter` / `backdrop-filter` values. There are no method bodies. Type
// references (`CssColor`, `LengthValue`, `NumberOrPercentage`, `Angle`, `Url`)
// resolve against the stub's new wave-9 surface; no parse / toCss / handler
// methods exist here so nothing in this file traps `@compileError`.

pub const css = @import("../css_parser_stub.zig");

const SmallList = css.SmallList;

const CssColor = css.css_values.color.CssColor;
const Length = css.css_values.length.LengthValue;
const NumberOrPercentage = css.css_values.percentage.NumberOrPercentage;
const Angle = css.css_values.angle.Angle;
const Url = css.css_values.url.Url;

/// A value for the [filter](https://drafts.fxtf.org/filter-effects-1/#FilterProperty) and
/// [backdrop-filter](https://drafts.fxtf.org/filter-effects-2/#BackdropFilterProperty) properties.
pub const FilterList = union(enum) {
    /// The `none` keyword.
    none,
    /// A list of filter functions.
    filters: SmallList(Filter, 1),
};

/// A [filter](https://drafts.fxtf.org/filter-effects-1/#filter-functions) function.
pub const Filter = union(enum) {
    /// A `blur()` filter.
    blur: Length,
    /// A `brightness()` filter.
    brightness: NumberOrPercentage,
    /// A `contrast()` filter.
    contrast: NumberOrPercentage,
    /// A `grayscale()` filter.
    grayscale: NumberOrPercentage,
    /// A `hue-rotate()` filter.
    hue_rotate: Angle,
    /// An `invert()` filter.
    invert: NumberOrPercentage,
    /// An `opacity()` filter.
    opacity: NumberOrPercentage,
    /// A `saturate()` filter.
    saturate: NumberOrPercentage,
    /// A `sepia()` filter.
    sepia: NumberOrPercentage,
    /// A `drop-shadow()` filter.
    drop_shadow: DropShadow,
    /// A `url()` reference to an SVG filter.
    url: Url,
};

/// A [`drop-shadow()`](https://drafts.fxtf.org/filter-effects-1/#funcdef-filter-drop-shadow) filter function.
pub const DropShadow = struct {
    /// The color of the drop shadow.
    color: CssColor,
    /// The x offset of the drop shadow.
    x_offset: Length,
    /// The y offset of the drop shadow.
    y_offset: Length,
    /// The blur radius of the drop shadow.
    blur: Length,
};

test "DropShadow holds CssColor + three Lengths" {
    const ds = DropShadow{
        .color = .current_color,
        .x_offset = .{},
        .y_offset = .{},
        .blur = .{},
    };
    try std.testing.expect(ds.color == .current_color);
}

test "Filter tags compile" {
    const f1: Filter = .{ .blur = .{} };
    const f2: Filter = .{ .hue_rotate = .{ .deg = 90.0 } };
    const f3: Filter = .{ .url = .{ .import_record_idx = 0, .loc = css.Location.dummy() } };
    try std.testing.expect(f1 == .blur);
    try std.testing.expect(f2 == .hue_rotate);
    try std.testing.expect(f3 == .url);
}

test "FilterList.none is a valid tag" {
    const list: FilterList = .none;
    try std.testing.expect(list == .none);
}

const std = @import("std");
