// Copied from bun/src/css/rules/supports.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
//
// Strategy-B port over the stub. `SupportsCondition` is a tagged union with
// recursive (`*SupportsCondition`) + list (`ArrayList(SupportsCondition)`) +
// inline (`declaration: { property_id, value }`, `selector: []const u8`,
// `unknown: []const u8`) variants — all kept as pure data. `PropertyId`
// resolves via the stub (added in wave-10) and trips `@compileError` if a
// runtime method is reached.
//
// `parse`/`toCss`/`needsParens`/`toCssWithParensIfNeeded`/`deinit`/
// `cloneWithImportRecords`/`hash` all reach for `css.deepDeinit`,
// `css.serializer.serializeName`, `property_id.prefix()`/`name()`,
// `dest.writeStr` etc. — all behind `@compileError` and stripped here.
//
// `SupportsRule(R)` keeps `condition`/`rules: CssRuleList(R)`/`loc`. `toCss`/
// `minify` stripped.

pub const css = @import("../css_parser_stub.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = @import("./rules.zig").Location;
const RealCssRuleList = @import("./rules.zig").CssRuleList;

const ArrayList = std.ArrayListUnmanaged;

/// A [`<supports-condition>`](https://drafts.csswg.org/css-conditional-3/#typedef-supports-condition),
/// as used in the `@supports` and `@import` rules.
pub const SupportsCondition = union(enum) {
    /// A `not` expression.
    not: *SupportsCondition,

    /// An `and` expression.
    @"and": ArrayList(SupportsCondition),

    /// An `or` expression.
    @"or": ArrayList(SupportsCondition),

    /// A declaration to evaluate.
    declaration: struct {
        /// The property id for the declaration.
        property_id: css.PropertyId,
        /// The raw value of the declaration.
        ///
        /// What happens if the value is a URL? A URL in this context does nothing
        /// e.g. `@supports (background-image: url('example.png'))`
        value: []const u8,

        pub fn eql(this: *const @This(), other: *const @This()) bool {
            return css.implementEql(@This(), this, other);
        }

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
            return css.implementDeepClone(@This(), this, allocator);
        }
    },

    /// A selector to evaluate.
    selector: []const u8,

    /// An unknown condition.
    unknown: []const u8,

    pub fn eql(this: *const SupportsCondition, other: *const SupportsCondition) bool {
        return css.implementEql(SupportsCondition, this, other);
    }

    pub fn deepClone(this: *const SupportsCondition, allocator: std.mem.Allocator) SupportsCondition {
        return css.implementDeepClone(SupportsCondition, this, allocator);
    }

    pub fn deinit(_: *const SupportsCondition, _: std.mem.Allocator) void {}

    pub fn parse(_: *@import("../css_parser.zig").Parser) @import("../css_parser.zig").Result(SupportsCondition) {
        return .{ .result = .{ .unknown = "" } };
    }

    pub fn parseDeclaration(_: *@import("../css_parser.zig").Parser) @import("../css_parser.zig").Result(SupportsCondition) {
        return .{ .result = .{ .unknown = "" } };
    }

    pub fn cloneWithImportRecords(this: *const SupportsCondition, allocator: std.mem.Allocator, _: anytype) SupportsCondition {
        return this.deepClone(allocator);
    }

    pub fn toCss(this: *const SupportsCondition, dest: anytype) !void {
        switch (this.*) {
            .unknown, .selector => |text| try dest.writeStr(text),
            .declaration => |decl| try dest.writeStr(decl.value),
            .not => |condition| try condition.toCss(dest),
            .@"and", .@"or" => |list| {
                for (list.items, 0..) |*condition, i| {
                    if (i > 0) try dest.writeStr(" and ");
                    try condition.toCss(dest);
                }
            },
        }
    }
};

/// A [@supports](https://drafts.csswg.org/css-conditional-3/#at-supports) rule.
pub fn SupportsRule(comptime R: type) type {
    return struct {
        /// The supports condition.
        condition: SupportsCondition,
        /// The rules within the `@supports` rule.
        rules: RealCssRuleList(R),
        /// The location of the rule in the source file.
        loc: Location,

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) @This() {
            return css.implementDeepClone(@This(), this, allocator);
        }

        pub fn toCss(_: *const @This(), _: anytype) PrintErr!void {
            return;
        }

        pub fn minify(_: *@This(), _: anytype, _: bool) !bool {
            return false;
        }
    };
}

test "SupportsCondition selector + unknown variants carry raw strings" {
    const s: SupportsCondition = .{ .selector = "a > b" };
    const u: SupportsCondition = .{ .unknown = "weird()" };
    try std.testing.expectEqualStrings("a > b", s.selector);
    try std.testing.expectEqualStrings("weird()", u.unknown);
}

test "SupportsCondition.and is an ArrayList (empty default)" {
    const empty: ArrayList(SupportsCondition) = .empty;
    const c: SupportsCondition = .{ .@"and" = empty };
    try std.testing.expectEqual(@as(usize, 0), c.@"and".items.len);
}

test "SupportsCondition.declaration carries property_id + value" {
    const c: SupportsCondition = .{ .declaration = .{
        .property_id = .{},
        .value = "1px solid red",
    } };
    try std.testing.expectEqualStrings("1px solid red", c.declaration.value);
}

test "SupportsRule(void) keeps the three fields" {
    const T = SupportsRule(void);
    const r = T{
        .condition = .{ .selector = "*" },
        .rules = .{},
        .loc = Location.dummy(),
    };
    try std.testing.expect(r.condition == .selector);
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.source_index);
}

const std = @import("std");
