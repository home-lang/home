// Copied from bun/src/css/values/easing.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
//
// Strategy-B port over the stub. `EasingFunction` is a pure-data tagged union
// (linear/ease/ease_in/ease_out/ease_in_out/cubic_bezier/steps); the cubic
// bezier + steps payloads are kept. `StepPosition` is a pure enum with
// `default()`. `CSSNumber`/`CSSInteger` are aliased locally (`f32`/`i32`)
// to keep the type names accurate — the stub's `CSSNumber = f32` is reused.
//
// `Map = bun.ComptimeEnumMap(...)` cached in the original at struct scope
// (which would force comptime eval through unported `bun`) is dropped here,
// along with `parse`/`toCss`/`isIdent`/`isEase` which all reach for
// `bun.strings.eqlCaseInsensitiveASCIIICheckLength`, `css.generic.toCss`,
// `dest.writeStr`, etc. The pure-data shape + `eql`/`deepClone` stubs
// (returning placeholder values) survive.

pub const css = @import("../css_parser_stub.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const CSSNumber = css.css_values.number.CSSNumber;
/// Upstream `CSSInteger` is `i32`; alias locally.
pub const CSSInteger = i32;

/// A CSS [easing function](https://www.w3.org/TR/css-easing-1/#easing-functions).
pub const EasingFunction = union(enum) {
    /// A linear easing function.
    linear,
    /// Equivalent to `cubic-bezier(0.25, 0.1, 0.25, 1)`.
    ease,
    /// Equivalent to `cubic-bezier(0.42, 0, 1, 1)`.
    ease_in,
    /// Equivalent to `cubic-bezier(0, 0, 0.58, 1)`.
    ease_out,
    /// Equivalent to `cubic-bezier(0.42, 0, 0.58, 1)`.
    ease_in_out,
    /// A custom cubic Bézier easing function.
    cubic_bezier: struct {
        /// The x-position of the first point in the curve.
        x1: CSSNumber,
        /// The y-position of the first point in the curve.
        y1: CSSNumber,
        /// The x-position of the second point in the curve.
        x2: CSSNumber,
        /// The y-position of the second point in the curve.
        y2: CSSNumber,

        pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
            return css.implementEql(@This(), lhs, rhs);
        }
    },
    /// A step easing function.
    steps: struct {
        /// The number of intervals in the function.
        count: CSSInteger,
        /// The step position.
        position: StepPosition = StepPosition.default(),

        pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
            return css.implementEql(@This(), lhs, rhs);
        }
    },

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

/// A [step position](https://www.w3.org/TR/css-easing-1/#step-position), used within the `steps()` function.
pub const StepPosition = enum {
    /// The first rise occurs at input progress value of 0.
    start,
    /// The last rise occurs at input progress value of 1.
    end,
    /// All rises occur within the range (0, 1).
    @"jump-none",
    /// The first rise occurs at input progress value of 0 and the last rise occurs at input progress value of 1.
    @"jump-both",

    pub fn default() StepPosition {
        return .end;
    }
};

test "EasingFunction tags include the five keyword shortcuts" {
    const a: EasingFunction = .linear;
    const b: EasingFunction = .ease;
    const c: EasingFunction = .ease_in;
    const d: EasingFunction = .ease_out;
    const e: EasingFunction = .ease_in_out;
    try std.testing.expect(a == .linear);
    try std.testing.expect(b == .ease);
    try std.testing.expect(c == .ease_in);
    try std.testing.expect(d == .ease_out);
    try std.testing.expect(e == .ease_in_out);
}

test "EasingFunction.cubic_bezier holds four control points" {
    const fn1 = EasingFunction{ .cubic_bezier = .{ .x1 = 0.25, .y1 = 0.1, .x2 = 0.25, .y2 = 1.0 } };
    try std.testing.expectEqual(@as(f32, 0.25), fn1.cubic_bezier.x1);
    try std.testing.expectEqual(@as(f32, 1.0), fn1.cubic_bezier.y2);
}

test "EasingFunction.steps holds count + position" {
    const s = EasingFunction{ .steps = .{ .count = 4, .position = .start } };
    try std.testing.expectEqual(@as(i32, 4), s.steps.count);
    try std.testing.expect(s.steps.position == .start);
}

test "StepPosition.default returns end" {
    try std.testing.expect(StepPosition.default() == .end);
}

test "EasingFunction.steps default position is end" {
    const s = EasingFunction{ .steps = .{ .count = 1 } };
    try std.testing.expect(s.steps.position == .end);
}

const std = @import("std");
