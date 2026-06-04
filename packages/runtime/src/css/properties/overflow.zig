// Copied from bun/src/css/properties/overflow.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated properties table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

/// A value for the [overflow](https://www.w3.org/TR/css-overflow-3/#overflow-properties) shorthand property.
pub const Overflow = struct {
    /// A value for the [overflow](https://www.w3.org/TR/css-overflow-3/#overflow-properties) shorthand property.
    x: OverflowKeyword,
    /// The overflow mode for the y direction.
    y: OverflowKeyword,

    pub fn parse(input: *css.Parser) css.Result(Overflow) {
        const x = switch (OverflowKeyword.parse(input)) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };
        const y = input.tryParse(OverflowKeyword.parse, .{}).unwrapOr(x);
        return .{ .result = .{ .x = x, .y = y } };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        try this.x.toCss(dest);
        if (this.x != this.y) {
            try dest.writeChar(' ');
            try this.y.toCss(dest);
        }
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }

    pub inline fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }
};

/// An [overflow](https://www.w3.org/TR/css-overflow-3/#overflow-properties) keyword
/// as used in the `overflow-x`, `overflow-y`, and `overflow` properties.
pub const OverflowKeyword = enum {
    /// Overflowing content is visible.
    visible,
    /// Overflowing content is hidden. Programmatic scrolling is allowed.
    hidden,
    /// Overflowing content is clipped. Programmatic scrolling is not allowed.
    clip,
    /// The element is scrollable.
    scroll,
    /// Overflowing content scrolls if needed.
    auto,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;
};

/// A value for the [text-overflow](https://www.w3.org/TR/css-overflow-3/#text-overflow) property.
pub const TextOverflow = enum {
    /// Overflowing text is clipped.
    clip,
    /// Overflowing text is truncated with an ellipsis.
    ellipsis,

    const css_impl = css.DefineEnumProperty(@This());
    pub const eql = css_impl.eql;
    pub const parse = css_impl.parse;
    pub const toCss = css_impl.toCss;
    pub const deepClone = css_impl.deepClone;
};

test "OverflowKeyword has expected tags" {
    const v: OverflowKeyword = .visible;
    const h: OverflowKeyword = .hidden;
    try std.testing.expect(v == .visible);
    try std.testing.expect(h == .hidden);
}

test "Overflow holds two OverflowKeyword fields" {
    const o = Overflow{ .x = .auto, .y = .scroll };
    try std.testing.expect(o.x == .auto);
    try std.testing.expect(o.y == .scroll);
}

test "Overflow.eql compares both axes" {
    const a = Overflow{ .x = .visible, .y = .visible };
    const b = Overflow{ .x = .visible, .y = .visible };
    const c = Overflow{ .x = .hidden, .y = .visible };
    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&c));
}

test "TextOverflow has clip and ellipsis tags" {
    const c: TextOverflow = .clip;
    const e: TextOverflow = .ellipsis;
    try std.testing.expect(c == .clip);
    try std.testing.expect(e == .ellipsis);
}

test "OverflowKeyword.deepClone preserves value" {
    const v: OverflowKeyword = .clip;
    const cloned = OverflowKeyword.deepClone(&v, std.testing.allocator);
    try std.testing.expectEqual(v, cloned);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
