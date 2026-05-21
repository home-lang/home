// Copied from bun/src/css/values/ratio.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `CSSNumber`/`CSSNumberFns` resolve via the stub. Body methods (parse,
// parseRequired, toCss) reference stub members that trip `@compileError`
// on call; Zig's lazy analysis keeps the file compiling as long as the
// pure-data shape (`numerator`/`denominator`/`addF32`) is the only thing
// exercised. `eql` mirrors the structural equality that upstream reaches
// through `css.implementEql`.

pub const css = @import("../css_parser_stub.zig");
const Result = css.Result;
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const CSSNumber = css.css_values.number.CSSNumber;
const CSSNumberFns = css.css_values.number.CSSNumberFns;

/// A CSS [`<ratio>`](https://www.w3.org/TR/css-values-4/#ratios) value,
/// representing the ratio of two numeric values.
pub const Ratio = struct {
    numerator: CSSNumber,
    denominator: CSSNumber,

    pub fn parse(input: *css.Parser) Result(Ratio) {
        const first = switch (CSSNumberFns.parse(input)) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        };
        const second = if (input.tryParse(css.Parser.expectDelim, .{'/'}).isOk()) switch (CSSNumberFns.parse(input)) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        } else 1.0;

        return .{ .result = Ratio{ .numerator = first, .denominator = second } };
    }

    /// Parses a ratio where both operands are required.
    pub fn parseRequired(input: *css.Parser) Result(Ratio) {
        const first = switch (CSSNumberFns.parse(input)) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        };
        if (input.expectDelim('/').asErr()) |e| return .{ .err = e };
        const second = switch (CSSNumberFns.parse(input)) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        };
        return .{ .result = Ratio{ .numerator = first, .denominator = second } };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        try CSSNumberFns.toCss(&this.numerator, dest);
        if (this.denominator != 1.0) {
            try dest.delim('/', true);
            try CSSNumberFns.toCss(&this.denominator, dest);
        }
    }

    pub fn addF32(this: Ratio, _: std.mem.Allocator, other: f32) Ratio {
        return .{ .numerator = this.numerator + other, .denominator = this.denominator };
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return lhs.numerator == rhs.numerator and lhs.denominator == rhs.denominator;
    }
};

test "Ratio holds numerator/denominator" {
    const r = Ratio{ .numerator = 16, .denominator = 9 };
    try std.testing.expectEqual(@as(f32, 16), r.numerator);
    try std.testing.expectEqual(@as(f32, 9), r.denominator);
}

test "Ratio.addF32 adds to numerator only" {
    const r = Ratio{ .numerator = 4, .denominator = 3 };
    const r2 = r.addF32(std.testing.allocator, 0.5);
    try std.testing.expectEqual(@as(f32, 4.5), r2.numerator);
    try std.testing.expectEqual(@as(f32, 3), r2.denominator);
}

test "Ratio.eql compares numerator and denominator" {
    const a = Ratio{ .numerator = 1, .denominator = 2 };
    const b = Ratio{ .numerator = 1, .denominator = 2 };
    const c = Ratio{ .numerator = 2, .denominator = 1 };
    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&c));
}

const std = @import("std");
