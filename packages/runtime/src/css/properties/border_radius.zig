// Copied from bun/src/css/properties/border_radius.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated properties table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const LengthPercentage = css.css_values.length.LengthPercentage;
const Size2D = @import("../values/size.zig").Size2D;

pub const BorderRadiusHandler = struct {
    pub fn handleProperty(_: *BorderRadiusHandler, _: anytype, _: anytype, _: anytype) bool {
        return false;
    }

    pub fn finalize(_: *BorderRadiusHandler, _: anytype, _: anytype) void {}
};

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

    pub fn parse(input: *css.Parser) css.Result(BorderRadius) {
        const rect = switch (css.css_values.rect.Rect(Size2D(LengthPercentage)).parse(input)) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };
        return .{ .result = .{
            .top_left = rect.top,
            .top_right = rect.right,
            .bottom_right = rect.bottom,
            .bottom_left = rect.left,
        } };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        const rect = css.css_values.rect.Rect(Size2D(LengthPercentage)){
            .top = this.top_left,
            .right = this.top_right,
            .bottom = this.bottom_right,
            .left = this.bottom_left,
        };
        return rect.toCss(dest);
    }

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
