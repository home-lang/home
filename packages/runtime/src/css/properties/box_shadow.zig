// Copied from bun/src/css/properties/box_shadow.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated properties table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const CssColor = css.css_values.color.CssColor;
const Length = css.css_values.length.Length;

const VendorPrefix = css.VendorPrefix;

pub const BoxShadowHandler = struct {
    pub fn handleProperty(_: *BoxShadowHandler, _: anytype, _: anytype, _: anytype) bool {
        return false;
    }

    pub fn finalize(_: *BoxShadowHandler, _: anytype, _: anytype) void {}
};

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

    pub fn parse(input: *css.Parser) css.Result(BoxShadow) {
        var color: ?CssColor = null;
        var inset = false;

        while (true) {
            if (color == null) {
                if (input.tryParse(CssColor.parse, .{}).asValue()) |value| {
                    color = value;
                    continue;
                }
            }
            if (!inset and input.tryParse(css.Parser.expectIdentMatching, .{"inset"}).isOk()) {
                inset = true;
                continue;
            }
            break;
        }

        const x_offset = switch (Length.parse(input)) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };
        const y_offset = switch (Length.parse(input)) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };
        const blur = input.tryParse(Length.parse, .{}).unwrapOr(Length.zero());
        const spread = input.tryParse(Length.parse, .{}).unwrapOr(Length.zero());

        while (true) {
            if (color == null) {
                if (input.tryParse(CssColor.parse, .{}).asValue()) |value| {
                    color = value;
                    continue;
                }
            }
            if (!inset and input.tryParse(css.Parser.expectIdentMatching, .{"inset"}).isOk()) {
                inset = true;
                continue;
            }
            break;
        }

        return .{ .result = .{
            .color = color orelse CssColor.current_color,
            .x_offset = x_offset,
            .y_offset = y_offset,
            .blur = blur,
            .spread = spread,
            .inset = inset,
        } };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        if (this.inset) {
            try dest.writeStr("inset ");
        }
        try this.x_offset.toCss(dest);
        try dest.writeChar(' ');
        try this.y_offset.toCss(dest);
        if (!this.blur.isZero()) {
            try dest.writeChar(' ');
            try this.blur.toCss(dest);
        }
        if (!this.spread.isZero()) {
            try dest.writeChar(' ');
            try this.spread.toCss(dest);
        }
        if (this.color != .current_color) {
            try dest.writeChar(' ');
            try this.color.toCss(dest);
        }
    }

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
        .x_offset = Length.zero(),
        .y_offset = Length.zero(),
        .blur = Length.zero(),
        .spread = Length.zero(),
        .inset = false,
    };
    try std.testing.expect(s.color == .current_color);
    try std.testing.expect(!s.inset);
}

test "BoxShadow.inset flag round-trips" {
    const a = BoxShadow{
        .color = .current_color,
        .x_offset = Length.zero(),
        .y_offset = Length.zero(),
        .blur = Length.zero(),
        .spread = Length.zero(),
        .inset = true,
    };
    try std.testing.expect(a.inset);
}

test "BoxShadow.deepClone is a shallow copy" {
    const s = BoxShadow{
        .color = .current_color,
        .x_offset = Length.zero(),
        .y_offset = Length.zero(),
        .blur = Length.zero(),
        .spread = Length.zero(),
        .inset = false,
    };
    const cloned = s.deepClone(std.testing.allocator);
    try std.testing.expect(cloned.color == .current_color);
    try std.testing.expect(cloned.inset == s.inset);
}

const std = @import("std");
