// Copied from bun/src/css/properties/border_radius.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten:
//   @import("../css_parser.zig")     → @import("../css_parser_stub.zig")
//   @import("../values/size.zig")    → local relative import (ported leaf).
//
// Strategy-B port over the stub. `BorderRadius` is a pure-data struct
// holding four `Size2D(LengthPercentage)` corner radii. `LengthPercentage`
// resolves via the stub; `Size2D` resolves to the ported leaf
// (`../values/size.zig`). `parse`/`toCss` reach for `Rect(LengthPercentage)`
// (ported) but exercise `Rect.parse` / `Rect.deepClone` / `dest.delim` which
// all trip `@compileError` under the stub — stripped here.
//
// `BorderRadiusHandler` references `Property`/`PropertyId`/`PropertyIdTag`/
// `DeclarationList`/`PropertyHandlerContext`/`bun.bits`/`bun.handleOom`/
// `bun.take` — all unported, so the entire handler + companion helpers
// + the two `isBorderRadiusProperty` / `isLogicalBorderRadiusProperty`
// classifier helpers are stripped.

pub const css = @import("../css_parser_stub.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const LengthPercentage = css.css_values.length.LengthPercentage;
const Size2D = @import("../values/size.zig").Size2D;

/// A value for the [border-radius](https://www.w3.org/TR/css-backgrounds-3/#border-radius) property.
pub const BorderRadius = struct {
    /// The x and y radius values for the top left corner.
    top_left: Size2D(LengthPercentage),
    /// The x and y radius values for the top right corner.
    top_right: Size2D(LengthPercentage),
    /// The x and y radius values for the bottom right corner.
    bottom_right: Size2D(LengthPercentage),
    /// The x and y radius values for the bottom left corner.
    bottom_left: Size2D(LengthPercentage),

    pub const PropertyFieldMap = .{
        .top_left = "border-top-left-radius",
        .top_right = "border-top-right-radius",
        .bottom_right = "border-bottom-right-radius",
        .bottom_left = "border-bottom-left-radius",
    };

    pub const VendorPrefixMap = .{
        .top_left = true,
        .top_right = true,
        .bottom_right = true,
        .bottom_left = true,
    };

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

test "BorderRadius holds four corners" {
    const zero = LengthPercentage.zero();
    const r = BorderRadius{
        .top_left = .{ .a = zero, .b = zero },
        .top_right = .{ .a = zero, .b = zero },
        .bottom_right = .{ .a = zero, .b = zero },
        .bottom_left = .{ .a = zero, .b = zero },
    };
    try std.testing.expect(r.top_left.a == .dimension);
}

test "BorderRadius.deepClone preserves shape" {
    const zero = LengthPercentage.zero();
    const r = BorderRadius{
        .top_left = .{ .a = zero, .b = zero },
        .top_right = .{ .a = zero, .b = zero },
        .bottom_right = .{ .a = zero, .b = zero },
        .bottom_left = .{ .a = zero, .b = zero },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expect(cloned.top_left.a == .dimension);
}

test "BorderRadius.PropertyFieldMap names individual corners" {
    try std.testing.expectEqualStrings("border-top-left-radius", BorderRadius.PropertyFieldMap.top_left);
    try std.testing.expectEqualStrings("border-bottom-right-radius", BorderRadius.PropertyFieldMap.bottom_right);
}

const std = @import("std");
