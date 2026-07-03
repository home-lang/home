// Copied from bun/src/css/rules/starting_style.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `CssRuleList(R)` resolves via the stub. Body method calls trip
// `@compileError` until css_parser ports.

pub const css = @import("../css_parser.zig");
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.css_rules.Location;
const CssRuleList = css.CssRuleList;

/// A [@starting-style](https://drafts.csswg.org/css-transitions-2/#defining-before-change-style-the-starting-style-rule) rule.
pub fn StartingStyleRule(comptime R: type) type {
    return struct {
        /// Nested rules within the `@starting-style` rule.
        rules: css.CssRuleList(R),
        /// The location of the rule in the source file.
        loc: Location,

        const This = @This();

        pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
            // #[cfg(feature = "sourcemap")]
            // dest.add_mapping(self.loc);

            try dest.writeStr("@starting-style");
            try dest.whitespace();
            try dest.writeChar('{');
            dest.indent();
            try dest.newline();
            try this.rules.toCss(dest);
            dest.dedent();
            try dest.newline();
            try dest.writeChar('}');
        }

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
            return css.implementDeepClone(@This(), this, allocator);
        }
    };
}

test "StartingStyleRule generic instantiates" {
    const Inst = StartingStyleRule(u8);
    const r = Inst{
        .rules = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.source_index);
}

test "StartingStyleRule.deepClone shallow copy" {
    const Inst = StartingStyleRule(u32);
    const r = Inst{
        .rules = .{},
        .loc = .{ .source_index = 21, .line = 22, .column = 23 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expectEqual(r.loc.line, cloned.loc.line);
}

const std = @import("std");
