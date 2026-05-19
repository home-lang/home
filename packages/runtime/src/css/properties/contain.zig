// Copied from bun/src/css/properties/contain.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Wave-16 Tier-1 grinder. Pure-data leaf with `DefineEnumProperty` +
// `todo_stuff.depth` reaching into the css_parser stub. Mirrors the
// pattern used by `shape.zig`, `outline.zig`, etc.
//
// Imports rewritten:
//   @import("../css_parser.zig") → @import("../css_parser_stub.zig")
//
// The stub provides `css_rules.container.ContainerName` as a small
// `{ v: []const u8 }` shape so the `ContainerNameList.names` field
// resolves at field-declaration time. Runtime paths (parse/toCss) trip
// `@compileError`.

pub const css = @import("../css_parser_stub.zig");

const SmallList = css.SmallList;

const ContainerName = css.css_rules.container.ContainerName;

const ContainerIdent = ContainerName;

/// A value for the [container-type](https://drafts.csswg.org/css-contain-3/#container-type) property.
/// Establishes the element as a query container for the purpose of container queries.
pub const ContainerType = css.DefineEnumProperty(@compileError(css.todo_stuff.depth));

/// A value for the [container-name](https://drafts.csswg.org/css-contain-3/#container-name) property.
pub const ContainerNameList = union(enum) {
    /// The `none` keyword.
    none,
    /// A list of container names.
    names: SmallList(ContainerIdent, 1),
};

/// A value for the [container](https://drafts.csswg.org/css-contain-3/#container-shorthand) shorthand property.
pub const Container = css.DefineEnumProperty(@compileError(css.todo_stuff.depth));

const std = @import("std");

test "ContainerNameList: none variant is tag-equal" {
    const cn: ContainerNameList = .none;
    try std.testing.expect(cn == .none);
}

test "ContainerNameList: names variant carries SmallList(ContainerIdent, 1)" {
    const cn: ContainerNameList = .{ .names = .{} };
    try std.testing.expectEqual(@as(usize, 0), cn.names.items.len);
}
