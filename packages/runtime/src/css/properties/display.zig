// Copied from bun/src/css/properties/display.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `DefineEnumProperty` (stub) backs `Visibility` / `DisplayKeyword` /
// `DisplayOutside`. `DisplayInside.flex/box` carry a `css.VendorPrefix`
// (real). `Display.parse`/`toCss` use `DeriveParse`/`DeriveToCss`. The
// non-pure-data parse bodies of `DisplayPair` and `DisplayInside` reach for
// `bun.ComptimeStringMap` and `input.expectIdent` — both stub-deferred —
// so they're dropped, leaving just the data shape. `eql`/`deepClone` keep
// their stubbed forms. Upstream `bun` is dropped.

pub const css = @import("../css_parser_stub.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

/// A value for the [display](https://drafts.csswg.org/css-display-3/#the-display-properties) property.
pub const Display = union(enum) {
    /// A display keyword.
    keyword: DisplayKeyword,
    /// The inside and outside display values.
    pair: DisplayPair,

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

/// A value for the [visibility](https://drafts.csswg.org/css-display-3/#visibility) property.
pub const Visibility = enum {
    /// The element is visible.
    visible,
    /// The element is hidden.
    hidden,
    /// The element is collapsed.
    collapse,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const deepClone = css_impl.deepClone;
};

/// A `display` keyword.
pub const DisplayKeyword = enum {
    none,
    contents,
    @"table-row-group",
    @"table-header-group",
    @"table-footer-group",
    @"table-row",
    @"table-cell",
    @"table-column-group",
    @"table-column",
    @"table-caption",
    @"ruby-base",
    @"ruby-text",
    @"ruby-base-container",
    @"ruby-text-container",

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const deepClone = css_impl.deepClone;
};

/// A pair of inside and outside display values, as used in the `display` property.
pub const DisplayPair = struct {
    /// The outside display value.
    outside: DisplayOutside,
    /// The inside display value.
    inside: DisplayInside,
    /// Whether this is a list item.
    is_list_item: bool,

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

/// A [`<display-outside>`](https://drafts.csswg.org/css-display-3/#typedef-display-outside) value.
pub const DisplayOutside = enum {
    block,
    @"inline",
    @"run-in",

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const deepClone = css_impl.deepClone;
};

/// A [`<display-inside>`](https://drafts.csswg.org/css-display-3/#typedef-display-inside) value.
pub const DisplayInside = union(enum) {
    flow,
    flow_root,
    table,
    flex: css.VendorPrefix,
    box: css.VendorPrefix,
    grid,
    ruby,

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

test "DisplayKeyword has none tag" {
    const k: DisplayKeyword = .none;
    try std.testing.expect(k == .none);
}

test "Visibility has 3 tags" {
    try std.testing.expect(@as(Visibility, .visible) == .visible);
    try std.testing.expect(@as(Visibility, .hidden) == .hidden);
    try std.testing.expect(@as(Visibility, .collapse) == .collapse);
}

test "DisplayPair holds outside + inside + is_list_item" {
    const d = DisplayPair{
        .outside = .block,
        .inside = .flow,
        .is_list_item = false,
    };
    try std.testing.expect(d.outside == .block);
    try std.testing.expect(d.inside == .flow);
    try std.testing.expect(!d.is_list_item);
}

test "DisplayInside.flex carries a VendorPrefix" {
    const d: DisplayInside = .{ .flex = css.VendorPrefix.WEBKIT };
    try std.testing.expect(d == .flex);
    try std.testing.expect(d.flex.webkit);
}

test "Display.keyword variant" {
    const d: Display = .{ .keyword = .none };
    try std.testing.expect(d == .keyword);
    try std.testing.expect(d.keyword == .none);
}

test "Display.pair variant" {
    const d: Display = .{ .pair = DisplayPair{
        .outside = .@"inline",
        .inside = .flow,
        .is_list_item = false,
    } };
    try std.testing.expect(d == .pair);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
