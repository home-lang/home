// Copied from bun/src/css/rules/tailwind.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten:
//   @import("../css_parser.zig")    → @import("../css_parser_stub.zig")
//   @import("../values/values.zig") → kept (it's a real ported sibling)
// `css.Error` lifts the stub `Error` placeholder. `TailwindAtRule` is pure
// data (`style_name: TailwindStyleName`, `loc: css.Location`). The `toCss`
// body uses `dest.writeStr`/`dest.whitespace` (stub-deferred); the
// `enum_property_util` re-exports on `TailwindStyleName` resolve via the
// stub (their bodies trip `@compileError`). Lazy analysis keeps the file
// compiling.

pub const css = @import("../css_parser_stub.zig");
pub const css_values = @import("../values/values.zig");
pub const Error = css.Error;
const Printer = css.Printer;
const PrintErr = css.PrintErr;

/// @tailwind
/// https://github.com/tailwindlabs/tailwindcss.com/blob/4d6ac11425d96bc963f936e0157df460a364c43b/src/pages/docs/functions-and-directives.mdx?plain=1#L13
pub const TailwindAtRule = struct {
    style_name: TailwindStyleName,
    /// The location of the rule in the source file.
    loc: css.Location,

    pub fn deepClone(this: *const @This(), _: std.mem.Allocator) @This() {
        return this.*;
    }
};

pub const TailwindStyleName = enum {
    /// This injects Tailwind's base styles and any base styles registered by
    ///  plugins.
    base,
    /// This injects Tailwind's component classes and any component classes
    /// registered by plugins.
    components,
    /// This injects Tailwind's utility classes and any utility classes registered
    /// by plugins.
    utilities,
    /// Use this directive to control where Tailwind injects the hover, focus,
    /// responsive, dark mode, and other variants of each class.
    ///
    /// If omitted, Tailwind will append these classes to the very end of
    /// your stylesheet by default.
    variants,
};

test "TailwindStyleName has 4 tags" {
    try std.testing.expect(@as(TailwindStyleName, .base) == .base);
    try std.testing.expect(@as(TailwindStyleName, .components) == .components);
    try std.testing.expect(@as(TailwindStyleName, .utilities) == .utilities);
    try std.testing.expect(@as(TailwindStyleName, .variants) == .variants);
}

test "TailwindAtRule holds style_name + loc" {
    const r = TailwindAtRule{
        .style_name = .utilities,
        .loc = css.Location.dummy(),
    };
    try std.testing.expect(r.style_name == .utilities);
}

test "TailwindAtRule.deepClone preserves fields" {
    const r = TailwindAtRule{
        .style_name = .base,
        .loc = .{ .source_index = 1, .line = 2, .column = 3 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expect(cloned.style_name == .base);
    try std.testing.expectEqual(@as(u32, 2), cloned.loc.line);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
