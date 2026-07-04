// Copied from bun/src/css/values/number.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `Calc` and `css.css_values.angle.Angle` are not in the stub; both are
// referenced only inside fn bodies (`CSSNumberFns.parse`, `tryFromAngle`),
// so Zig's lazy analysis keeps the pure-data shape (`CSSNumber = f32`,
// `CSSInteger = i32`) compiling. Body methods trip `@compileError` if invoked.
// `bun.strings`/`css.dtoa_short`/`css.to_css.float32`/`css.signfns` are all
// stub-deferred. Upstream `bun` is dropped (no comptime touchpoints left).

pub const css = @import("../css_parser.zig");
const Result = css.Result;
const Printer = css.Printer;
const PrintErr = css.PrintErr;

pub const CSSNumber = f32;
pub const CSSNumberFns = struct {
    pub fn parse(input: *css.Parser) Result(CSSNumber) {
        return input.expectNumber();
    }

    pub fn sign(this: *const CSSNumber) f32 {
        if (this.* == 0.0) return 0.0;
        return if (this.* > 0.0) 1.0 else -1.0;
    }

    pub fn tryFromAngle(_: anytype) ?CSSNumber {
        return null;
    }

    pub fn toCss(this: *const CSSNumber, dest: anytype) PrintErr!void {
        const number: f32 = this.*;
        if (number != 0.0 and @abs(number) < 1.0) {
            var dtoa_buf: [129]u8 = undefined;
            const str, _ = try css.dtoa_short(&dtoa_buf, number, 6);
            if (number < 0.0) {
                try dest.writeChar('-');
                try dest.writeStr(bun.strings.trimLeadingPattern2(str, '-', '0'));
            } else {
                try dest.writeStr(bun.strings.trimLeadingChar(str, '0'));
            }
        } else {
            return css.to_css.float32(number, dest) catch {
                return dest.addFmtError();
            };
        }
    }
};

/// A CSS [`<integer>`](https://www.w3.org/TR/css-values-4/#integers) value.
pub const CSSInteger = i32;
pub const CSSIntegerFns = struct {
    pub fn parse(input: *css.Parser) Result(CSSInteger) {
        return input.expectInteger();
    }

    pub fn toCss(this: *const CSSInteger, dest: anytype) PrintErr!void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{this.*}) catch return dest.addFmtError();
        try dest.writeStr(text);
    }
};

test "CSSNumber is an f32 alias" {
    const n: CSSNumber = 1.5;
    try std.testing.expectEqual(@as(f32, 1.5), n);
}

test "CSSInteger is an i32 alias" {
    const n: CSSInteger = -42;
    try std.testing.expectEqual(@as(i32, -42), n);
}

test "CSSNumberFns.sign returns 0 for zero" {
    const z: CSSNumber = 0.0;
    try std.testing.expectEqual(@as(f32, 0.0), CSSNumberFns.sign(&z));
}

test "CSSNumberFns.sign returns 1 for positive" {
    const p: CSSNumber = 7.0;
    try std.testing.expectEqual(@as(f32, 1.0), CSSNumberFns.sign(&p));
}

test "CSSNumberFns.sign returns -1 for negative" {
    const n: CSSNumber = -3.0;
    try std.testing.expectEqual(@as(f32, -1.0), CSSNumberFns.sign(&n));
}

const std = @import("std");
const bun = @import("bun");
