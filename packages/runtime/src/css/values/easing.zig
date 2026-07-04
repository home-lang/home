// Copied from bun/src/css/values/easing.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for transition timing functions.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const CSSNumber = css.css_values.number.CSSNumber;
const CSSNumberFns = css.css_values.number.CSSNumberFns;
const CSSIntegerFns = css.css_values.number.CSSIntegerFns;
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

    pub fn parse(input: *css.Parser) css.Result(EasingFunction) {
        const location = input.currentSourceLocation();
        if (input.tryParse(css.Parser.expectIdent, .{}).asValue()) |ident| {
            if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "linear")) return .{ .result = .linear };
            if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "ease")) return .{ .result = .ease };
            if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "ease-in")) return .{ .result = .ease_in };
            if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "ease-out")) return .{ .result = .ease_out };
            if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "ease-in-out")) return .{ .result = .ease_in_out };
            if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "step-start")) return .{ .result = .{ .steps = .{ .count = 1, .position = .start } } };
            if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "step-end")) return .{ .result = .{ .steps = .{ .count = 1, .position = .end } } };
            return .{ .err = location.newUnexpectedTokenError(.{ .ident = ident }) };
        }

        return EasingFunction.parseFunction(input);
    }

    pub fn parseFunction(input: *css.Parser) css.Result(EasingFunction) {
        const location = input.currentSourceLocation();
        const function = switch (input.expectFunction()) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        };
        const Closure = struct { loc: css.SourceLocation, function: []const u8 };
        return input.parseNestedBlock(
            EasingFunction,
            &Closure{ .loc = location, .function = function },
            struct {
                fn parse(closure: *const Closure, i: *css.Parser) css.Result(EasingFunction) {
                    if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(closure.function, "cubic-bezier")) {
                        const x1 = switch (CSSNumberFns.parse(i)) {
                            .result => |vv| vv,
                            .err => |e| return .{ .err = e },
                        };
                        if (i.expectComma().asErr()) |e| return .{ .err = e };
                        const y1 = switch (CSSNumberFns.parse(i)) {
                            .result => |vv| vv,
                            .err => |e| return .{ .err = e },
                        };
                        if (i.expectComma().asErr()) |e| return .{ .err = e };
                        const x2 = switch (CSSNumberFns.parse(i)) {
                            .result => |vv| vv,
                            .err => |e| return .{ .err = e },
                        };
                        if (i.expectComma().asErr()) |e| return .{ .err = e };
                        const y2 = switch (CSSNumberFns.parse(i)) {
                            .result => |vv| vv,
                            .err => |e| return .{ .err = e },
                        };
                        return .{ .result = EasingFunction{ .cubic_bezier = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 } } };
                    } else if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(closure.function, "steps")) {
                        const count = switch (CSSIntegerFns.parse(i)) {
                            .result => |vv| vv,
                            .err => |e| return .{ .err = e },
                        };
                        const position = i.tryParse(struct {
                            fn parse(p: *css.Parser) css.Result(StepPosition) {
                                if (p.expectComma().asErr()) |e| return .{ .err = e };
                                return StepPosition.parse(p);
                            }
                        }.parse, .{}).unwrapOr(StepPosition.default());
                        return .{ .result = EasingFunction{ .steps = .{ .count = count, .position = position } } };
                    } else {
                        return .{ .err = closure.loc.newUnexpectedTokenError(.{ .ident = closure.function }) };
                    }
                }
            }.parse,
        );
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        return switch (this.*) {
            .linear => try dest.writeStr("linear"),
            .ease => try dest.writeStr("ease"),
            .ease_in => try dest.writeStr("ease-in"),
            .ease_out => try dest.writeStr("ease-out"),
            .ease_in_out => try dest.writeStr("ease-in-out"),
            else => {
                if (this.isEase()) {
                    return dest.writeStr("ease");
                } else if (this.* == .cubic_bezier and this.cubic_bezier.eql(&.{ .x1 = 0.42, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 })) {
                    return dest.writeStr("ease-in");
                } else if (this.* == .cubic_bezier and this.cubic_bezier.eql(&.{ .x1 = 0.0, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 })) {
                    return dest.writeStr("ease-out");
                } else if (this.* == .cubic_bezier and this.cubic_bezier.eql(&.{ .x1 = 0.42, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 })) {
                    return dest.writeStr("ease-in-out");
                }

                switch (this.*) {
                    .cubic_bezier => |cb| {
                        try dest.writeStr("cubic-bezier(");
                        try css.generic.toCss(CSSNumber, &cb.x1, dest);
                        try dest.writeChar(',');
                        try css.generic.toCss(CSSNumber, &cb.y1, dest);
                        try dest.writeChar(',');
                        try css.generic.toCss(CSSNumber, &cb.x2, dest);
                        try dest.writeChar(',');
                        try css.generic.toCss(CSSNumber, &cb.y2, dest);
                        try dest.writeChar(')');
                    },
                    .steps => {
                        if (this.steps.count == 1 and this.steps.position == .start) {
                            return try dest.writeStr("step-start");
                        }
                        if (this.steps.count == 1 and this.steps.position == .end) {
                            return try dest.writeStr("step-end");
                        }
                        try dest.writeFmt("steps({d}", .{this.steps.count});
                        try dest.delim(',', false);
                        try this.steps.position.toCss(dest);
                        return try dest.writeChar(')');
                    },
                    .linear, .ease, .ease_in, .ease_out, .ease_in_out => unreachable,
                }
            },
        };
    }

    pub fn isEase(this: *const @This()) bool {
        return this.* == .ease or
            (this.* == .cubic_bezier and this.cubic_bezier.eql(&.{
                .x1 = 0.25,
                .y1 = 0.1,
                .x2 = 0.25,
                .y2 = 1.0,
            }));
    }

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

    pub const toCss = css.DeriveToCss(@This()).toCss;

    const Map = bun.ComptimeEnumMap(enum {
        start,
        end,
        @"jump-none",
        @"jump-both",
        @"jump-start",
        @"jump-end",
    });

    pub fn parse(input: *css.Parser) css.Result(StepPosition) {
        const location = input.currentSourceLocation();
        const ident = switch (input.expectIdent()) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        };
        const keyword = if (Map.getASCIIICaseInsensitive(ident)) |e| switch (e) {
            .start => StepPosition.start,
            .end => StepPosition.end,
            .@"jump-start" => StepPosition.start,
            .@"jump-end" => StepPosition.end,
            .@"jump-none" => StepPosition.@"jump-none",
            .@"jump-both" => StepPosition.@"jump-both",
        } else return .{ .err = location.newUnexpectedTokenError(.{ .ident = ident }) };

        return .{ .result = keyword };
    }

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
const bun = @import("bun");
