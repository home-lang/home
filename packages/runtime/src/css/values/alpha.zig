// Copied from bun/src/css/values/alpha.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Uses the real parser surface; alpha parsing feeds generated CSS properties.

pub const css = @import("../css_parser.zig");
const Result = css.Result;
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const CSSNumberFns = css.css_values.number.CSSNumberFns;
const NumberOrPercentage = css.css_values.percentage.NumberOrPercentage;

/// A CSS [`<alpha-value>`](https://www.w3.org/TR/css-color-4/#typedef-alpha-value),
/// used to represent opacity.
///
/// Parses either a `<number>` or `<percentage>`, but is always stored and serialized as a number.
pub const AlphaValue = struct {
    v: f32,

    pub fn parse(input: *css.Parser) Result(AlphaValue) {
        // For some reason NumberOrPercentage.parse makes zls crash, using this instead.
        const val: NumberOrPercentage = switch (@call(.auto, @field(NumberOrPercentage, "parse"), .{input})) {
            .result => |v| v,
            .err => |e| return .{ .err = e },
        };
        const final = switch (val) {
            .percentage => |percent| AlphaValue{ .v = percent.v },
            .number => |num| AlphaValue{ .v = num },
        };
        return .{ .result = final };
    }

    pub fn toCss(this: *const AlphaValue, dest: *css.Printer) css.PrintErr!void {
        return CSSNumberFns.toCss(&this.v, dest);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }

    pub fn hash(this: *const @This(), hasher: *std.hash.Wyhash) void {
        return css.implementHash(@This(), this, hasher);
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

test "AlphaValue holds a single f32" {
    const a = AlphaValue{ .v = 0.75 };
    try std.testing.expectEqual(@as(f32, 0.75), a.v);
}

test "AlphaValue boundary values" {
    const fully_opaque = AlphaValue{ .v = 1.0 };
    const fully_transparent = AlphaValue{ .v = 0.0 };
    try std.testing.expectEqual(@as(f32, 1.0), fully_opaque.v);
    try std.testing.expectEqual(@as(f32, 0.0), fully_transparent.v);
}

test "AlphaValue.eql compares values" {
    const a = AlphaValue{ .v = 0.5 };
    const b = AlphaValue{ .v = 0.5 };
    const c = AlphaValue{ .v = 0.75 };
    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&c));
}

test "AlphaValue.deepClone is a shallow copy" {
    const a = AlphaValue{ .v = 0.25 };
    const cloned = a.deepClone(std.testing.allocator);
    try std.testing.expectEqual(a.v, cloned.v);
}

const std = @import("std");
