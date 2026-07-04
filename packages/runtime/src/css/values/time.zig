// Copied from bun/src/css/values/time.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
//
// Strategy-B port over the stub. `Time` is a pure-data tagged union
// (seconds/milliseconds), so the data shape + the simple computed helpers
// (`toMs` / `isZero` / `tryFromAngle` / `map`) survive. `parse`/`toCss`/`op`/
// `opTo`/`mulF32`/`addInternal`/`intoCalc`/`partialCmp`/`tryFromToken` all
// reach for `Calc(Time)`/`bun.strings.eql*`/`bun.create`/
// `css.generic.partialCmpF32`/`CSSNumberFns.toCss` etc. (none of which are
// ported) and are stripped here. The original `Tag` enum is retained.

pub const css = @import("../css_parser.zig");
const bun = @import("bun");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

const number = @import("./number.zig");
const CSSNumber = number.CSSNumber;
const CSSNumberFns = number.CSSNumberFns;
const Calc = @import("./calc.zig").Calc;

/// A CSS [`<time>`](https://www.w3.org/TR/css-values-4/#time) value, in either
/// seconds or milliseconds.
pub const Time = union(Tag) {
    /// A time in seconds.
    seconds: CSSNumber,
    /// A time in milliseconds.
    milliseconds: CSSNumber,

    pub const Tag = enum(u8) { seconds = 1, milliseconds = 2 };

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }

    /// Returns whether the value is zero.
    pub fn isZero(this: *const Time) bool {
        return switch (this.*) {
            .seconds => |s| s == 0.0,
            .milliseconds => |ms| ms == 0.0,
        };
    }

    /// Returns the time in milliseconds.
    pub fn toMs(this: *const Time) CSSNumber {
        return switch (this.*) {
            .seconds => |v| v * 1000.0,
            .milliseconds => |v| v,
        };
    }

    pub fn sign(this: *const Time) f32 {
        const ms = this.toMs();
        if (ms == 0.0) return 0.0;
        return if (ms > 0.0) 1.0 else -1.0;
    }

    pub fn toCss(this: *const Time, dest: anytype) PrintErr!void {
        // 0.1s is shorter than 100ms
        // anything smaller is longer
        switch (this.*) {
            .seconds => |s| {
                if (s > 0.0 and s < 0.1) {
                    try CSSNumberFns.toCss(&(s * 1000.0), dest);
                    try dest.writeStr("ms");
                } else {
                    try CSSNumberFns.toCss(&s, dest);
                    try dest.writeChar('s');
                }
            },
            .milliseconds => |ms| {
                if (ms == 0.0 or ms >= 100.0) {
                    try CSSNumberFns.toCss(&(ms / 1000.0), dest);
                    try dest.writeChar('s');
                } else {
                    try CSSNumberFns.toCss(&ms, dest);
                    try dest.writeStr("ms");
                }
            },
        }
    }

    pub fn tryFromAngle(_: anytype) ?@This() {
        return null;
    }

    pub fn tryFromToken(_: anytype) @import("../css_parser.zig").Result(Time) {
        return .{ .err = @import("../css_parser.zig").ParseError(@import("../css_parser.zig").ParserError){
            .kind = .{ .custom = .{ .unexpected_value = .{ .expected = "time", .received = "token" } } },
            .location = .{ .line = 0, .column = 0 },
        } };
    }

    pub fn parse(input: *css.Parser) css.Result(Time) {
        if (input.tryParse(Calc(Time).parse, .{}).asValue()) |calc_value| {
            if (calc_value == .value) return .{ .result = calc_value.value.* };
            // Time is always compatible, so they will always compute to a value.
            return .{ .err = input.newErrorForNextToken() };
        }

        const location = input.currentSourceLocation();
        const token = switch (input.next()) {
            .result => |vv| vv,
            .err => |e| return .{ .err = e },
        };
        switch (token.*) {
            .dimension => |*dim| {
                if (bun.strings.eqlCaseInsensitiveASCIIICheckLength("s", dim.unit)) {
                    return .{ .result = .{ .seconds = dim.num.value } };
                } else if (bun.strings.eqlCaseInsensitiveASCIIICheckLength("ms", dim.unit)) {
                    return .{ .result = .{ .milliseconds = dim.num.value } };
                } else {
                    return .{ .err = location.newUnexpectedTokenError(css.Token{ .ident = dim.unit }) };
                }
            },
            else => return .{ .err = location.newUnexpectedTokenError(token.*) },
        }
    }

    pub fn mulF32(this: Time, _: std.mem.Allocator, other: f32) Time {
        return switch (this) {
            .seconds => |v| .{ .seconds = v * other },
            .milliseconds => |v| .{ .milliseconds = v * other },
        };
    }

    pub fn addInternal(this: Time, _: std.mem.Allocator, other: Time) Time {
        return .{ .milliseconds = this.toMs() + other.toMs() };
    }

    pub fn intoCalc(this: Time, allocator: std.mem.Allocator) @import("./calc.zig").Calc(Time) {
        return .{ .value = bun.create(allocator, Time, this) };
    }

    pub fn tryOpTo(
        lhs: *const Time,
        rhs: *const Time,
        comptime R: type,
        ctx: anytype,
        comptime op_fn: *const fn (@TypeOf(ctx), a: f32, b: f32) R,
    ) ?R {
        return op_fn(ctx, lhs.toMs(), rhs.toMs());
    }

    pub fn tryOp(
        lhs: *const Time,
        rhs: *const Time,
        ctx: anytype,
        comptime op_fn: *const fn (@TypeOf(ctx), a: f32, b: f32) f32,
    ) ?Time {
        return .{ .milliseconds = op_fn(ctx, lhs.toMs(), rhs.toMs()) };
    }

    pub fn partialCmp(this: *const Time, other: *const Time) ?std.math.Order {
        return std.math.order(this.toMs(), other.toMs());
    }

    pub fn map(this: *const @This(), comptime map_fn: *const fn (f32) f32) Time {
        return switch (this.*) {
            .seconds => Time{ .seconds = map_fn(this.seconds) },
            .milliseconds => Time{ .milliseconds = map_fn(this.milliseconds) },
        };
    }
};

test "Time variants carry an f32" {
    const a = Time{ .seconds = 1.5 };
    const b = Time{ .milliseconds = 250.0 };
    try std.testing.expectEqual(@as(f32, 1.5), a.seconds);
    try std.testing.expectEqual(@as(f32, 250.0), b.milliseconds);
}

test "Time.isZero recognises zero seconds and milliseconds" {
    const z1 = Time{ .seconds = 0.0 };
    const z2 = Time{ .milliseconds = 0.0 };
    const nz = Time{ .seconds = 0.5 };
    try std.testing.expect(z1.isZero());
    try std.testing.expect(z2.isZero());
    try std.testing.expect(!nz.isZero());
}

test "Time.toMs normalises to milliseconds" {
    const a = Time{ .seconds = 2.0 };
    const b = Time{ .milliseconds = 500.0 };
    try std.testing.expectEqual(@as(f32, 2000.0), a.toMs());
    try std.testing.expectEqual(@as(f32, 500.0), b.toMs());
}

test "Time.Tag values are pinned (seconds=1, milliseconds=2)" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Time.Tag.seconds));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Time.Tag.milliseconds));
}

test "Time.map applies a function elementwise" {
    const doubled = (Time{ .seconds = 1.5 }).map(struct {
        fn doubl(x: f32) f32 {
            return x * 2.0;
        }
    }.doubl);
    try std.testing.expectEqual(@as(f32, 3.0), doubled.seconds);
}

const std = @import("std");
