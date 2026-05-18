// Copied from bun/src/css/rules/counter_style.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// CustomIdent / DeclarationBlock / Printer / PrintErr / Location resolve via
// the local stub. The `toCss` body references stub methods that trip
// `@compileError` if exercised — the data shape (`name`/`declarations`/`loc`)
// compiles cleanly, which is the wave-7 deliverable.

pub const css = @import("../css_parser_stub.zig");
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.Location;

/// A [@counter-style](https://drafts.csswg.org/css-counter-styles/#the-counter-style-rule) rule.
pub const CounterStyleRule = struct {
    /// The name of the counter style to declare.
    name: css.css_values.ident.CustomIdent,
    /// Declarations in the `@counter-style` rule.
    declarations: css.DeclarationBlock,
    /// The location of the rule in the source file.
    loc: Location,

    const This = @This();

    pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
        // #[cfg(feature = "sourcemap")]
        // dest.add_mapping(self.loc);

        try dest.writeStr("@counter-style");
        try css.css_values.ident.CustomIdentFns.toCss(&this.name, dest);
        try this.declarations.toCssBlock(dest);
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

test "CounterStyleRule holds name, declarations, loc" {
    const rule = CounterStyleRule{
        .name = "thumbs",
        .declarations = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expectEqualStrings("thumbs", rule.name);
}

test "CounterStyleRule.deepClone shallow-copies under the stub" {
    const rule = CounterStyleRule{
        .name = "stars",
        .declarations = .{},
        .loc = .{ .source_index = 4, .line = 5, .column = 6 },
    };
    const cloned = rule.deepClone(std.testing.allocator);
    try std.testing.expectEqualStrings(rule.name, cloned.name);
    try std.testing.expectEqual(rule.loc.line, cloned.loc.line);
}

const std = @import("std");
