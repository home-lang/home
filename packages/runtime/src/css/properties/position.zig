// Copied from bun/src/css/properties/position.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated properties table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;

/// A value for the [position](https://www.w3.org/TR/css-position-3/#position-property) property.
pub const Position = union(enum) {
    /// The box is laid in the document flow.
    static,
    /// The box is laid out in the document flow and offset from the resulting position.
    relative,
    /// The box is taken out of document flow and positioned in reference to its relative ancestor.
    absolute,
    /// Similar to relative but adjusted according to the ancestor scrollable element.
    sticky: css.VendorPrefix,
    /// The box is taken out of the document flow and positioned in reference to the page viewport.
    fixed,

    pub fn parse(input: *css.Parser) css.Result(Position) {
        const location = input.currentSourceLocation();
        const ident = switch (input.expectIdent()) {
            .result => |value| value,
            .err => |e| return .{ .err = e },
        };

        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "static")) return .{ .result = .static };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "relative")) return .{ .result = .relative };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "absolute")) return .{ .result = .absolute };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "sticky")) return .{ .result = .{ .sticky = css.VendorPrefix.NONE } };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "-webkit-sticky")) return .{ .result = .{ .sticky = css.VendorPrefix.WEBKIT } };
        if (bun.strings.eqlCaseInsensitiveASCIIICheckLength(ident, "fixed")) return .{ .result = .fixed };

        return .{ .err = location.newUnexpectedTokenError(.{ .ident = ident }) };
    }

    pub fn toCss(this: *const @This(), dest: *Printer) PrintErr!void {
        switch (this.*) {
            .static => try dest.writeStr("static"),
            .relative => try dest.writeStr("relative"),
            .absolute => try dest.writeStr("absolute"),
            .sticky => |*prefix| {
                try prefix.toCss(dest);
                try dest.writeStr("sticky");
            },
            .fixed => try dest.writeStr("fixed"),
        }
    }

    pub fn eql(lhs: *const @This(), rhs: *const @This()) bool {
        return css.implementEql(@This(), lhs, rhs);
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

test "Position.static is a tag-only variant" {
    const p: Position = .static;
    try std.testing.expect(p == .static);
}

test "Position.sticky carries a VendorPrefix" {
    const p: Position = .{ .sticky = css.VendorPrefix.NONE };
    try std.testing.expect(p == .sticky);
    try std.testing.expect(p.sticky.none);
}

test "Position.sticky with webkit prefix" {
    const p: Position = .{ .sticky = css.VendorPrefix.WEBKIT };
    try std.testing.expect(p.sticky.webkit);
    try std.testing.expect(!p.sticky.none);
}

test "Position.deepClone is a shallow copy" {
    const p = Position{ .sticky = css.VendorPrefix.MOZ };
    const cloned = p.deepClone(std.testing.allocator);
    try std.testing.expect(cloned == .sticky);
    try std.testing.expect(cloned.sticky.moz);
}

test "Position.eql compares matching variants" {
    const a: Position = .absolute;
    const b: Position = .absolute;
    const c: Position = .relative;
    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&c));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const bun = @import("bun");
