// Copied from bun/src/css/values/size.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Pure-data shape (`a: T`, `b: T`) is what downstream leaves need.

pub const css = @import("../css_parser.zig");
const Result = css.Result;
const Printer = css.Printer;
const PrintErr = css.PrintErr;

/// A generic value that represents a value with two components, e.g. a border radius.
///
/// When serialized, only a single component will be written if both are equal.
pub fn Size2D(comptime T: type) type {
    return struct {
        a: T,
        b: T,

        pub fn parse(input: *css.Parser) Result(@This()) {
            const a = switch (T.parse(input)) {
                .result => |v| v,
                .err => |e| return .{ .err = e },
            };
            const b = input.tryParse(T.parse, .{}).unwrapOr(a);
            return .{ .result = .{ .a = a, .b = b } };
        }

        pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
            try this.a.toCss(dest);
            if (!valEql(&this.a, &this.b)) {
                try dest.writeStr(" ");
                try this.b.toCss(dest);
            }
        }

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
            return css.implementDeepClone(@This(), this, allocator);
        }

        pub fn isCompatible(this: *const @This(), browsers: css.targets.Browsers) bool {
            return this.a.isCompatible(browsers) and this.b.isCompatible(browsers);
        }

        pub inline fn valEql(lhs: *const T, rhs: *const T) bool {
            return switch (T) {
                f32 => lhs.* == rhs.*,
                else => lhs.eql(rhs),
            };
        }

        pub inline fn eql(lhs: *const @This(), rhs: *const @This()) bool {
            return switch (T) {
                f32 => lhs.a == rhs.b,
                else => lhs.a.eql(&rhs.b),
            };
        }
    };
}

test "Size2D(f32) holds two values" {
    const s = Size2D(f32){ .a = 1.0, .b = 2.0 };
    try std.testing.expectEqual(@as(f32, 1.0), s.a);
    try std.testing.expectEqual(@as(f32, 2.0), s.b);
}

test "Size2D(f32).valEql compares directly" {
    const a: f32 = 3.14;
    const b: f32 = 3.14;
    try std.testing.expect(Size2D(f32).valEql(&a, &b));
}

test "Size2D(f32).valEql returns false when unequal" {
    const a: f32 = 1.0;
    const b: f32 = 2.0;
    try std.testing.expect(!Size2D(f32).valEql(&a, &b));
}

test "Size2D(f32).deepClone is a shallow copy" {
    const s = Size2D(f32){ .a = 5.0, .b = 10.0 };
    const cloned = s.deepClone(std.testing.allocator);
    try std.testing.expectEqual(s.a, cloned.a);
    try std.testing.expectEqual(s.b, cloned.b);
}

const std = @import("std");
