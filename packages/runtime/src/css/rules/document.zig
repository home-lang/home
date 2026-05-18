// Copied from bun/src/css/rules/document.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `CssRuleList(R)` resolves via the stub; Printer methods trip `@compileError`
// until css_parser ports.

pub const css = @import("../css_parser_stub.zig");
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.css_rules.Location;

/// A [@-moz-document](https://www.w3.org/TR/2012/WD-css3-conditional-20120911/#at-document) rule.
///
/// Note that only the `url-prefix()` function with no arguments is supported, and only the `-moz` prefix
/// is allowed since Firefox was the only browser that ever implemented this rule.
pub fn MozDocumentRule(comptime R: type) type {
    return struct {
        /// Nested rules within the `@-moz-document` rule.
        rules: css.CssRuleList(R),
        /// The location of the rule in the source file.
        loc: Location,

        const This = @This();

        pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
            // #[cfg(feature = "sourcemap")]
            // dest.add_mapping(self.loc);
            try dest.writeStr("@-moz-document url-prefix()");
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

test "MozDocumentRule generic instantiates" {
    const Inst = MozDocumentRule(u8);
    const r = Inst{
        .rules = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.column);
}

test "MozDocumentRule.deepClone shallow copy" {
    const Inst = MozDocumentRule(u64);
    const r = Inst{
        .rules = .{},
        .loc = .{ .source_index = 31, .line = 32, .column = 33 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 33), cloned.loc.column);
}

const std = @import("std");
