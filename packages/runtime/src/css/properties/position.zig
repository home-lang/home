// Copied from bun/src/css/properties/position.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `css.VendorPrefix` is real in the stub (bit-compatible). The `parse` body
// reaches for `bun.ComptimeStringMap` and `input.expectIdent` — both stub-
// deferred — so it's dropped. `toCss` reaches for `dest.writeStr` / vendor
// prefix `toCss` (both `@compileError`) — also dropped. The pure-data shape
// (the tagged-union variants `static`/`relative`/`absolute`/`sticky:VendorPrefix`/
// `fixed`) is what downstream leaves need. `eql`/`deepClone` keep their
// stubbed forms. `bun` import dropped (no comptime touchpoints remain).

pub const css = @import("../css_parser_stub.zig");

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

test "Position.eql returns false under stub" {
    const a: Position = .absolute;
    const b: Position = .absolute;
    try std.testing.expect(!a.eql(&b));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
