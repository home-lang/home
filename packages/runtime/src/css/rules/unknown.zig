// Copied from bun/src/css/rules/unknown.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten:
//   @import("../css_parser.zig")     → @import("../css_parser_stub.zig")
//   @import("../values/values.zig")  → dropped (re-exports unused inside this leaf)
// `Error = css.Error` is not referenced inside this leaf; dropping the alias
// keeps the stub surface minimal. TokenList + Location resolve via the stub;
// Printer methods trip `@compileError` until css_parser ports.

pub const css = @import("../css_parser_stub.zig");
const Printer = css.Printer;
const PrintErr = css.PrintErr;

/// An unknown at-rule, stored as raw tokens.
pub const UnknownAtRule = struct {
    /// The name of the at-rule (without the @).
    name: []const u8,
    /// The prelude of the rule.
    prelude: css.TokenList,
    /// The contents of the block, if any.
    block: ?css.TokenList,
    /// The location of the rule in the source file.
    loc: css.Location,

    const This = @This();

    pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
        // #[cfg(feature = "sourcemap")]
        // dest.add_mapping(self.loc);

        try dest.writeChar('@');
        try dest.writeStr(this.name);

        if (this.prelude.v.items.len > 0) {
            try dest.writeChar(' ');
            try this.prelude.toCss(dest, false);
        }

        if (this.block) |*block| {
            try dest.whitespace();
            try dest.writeChar('{');
            dest.indent();
            try dest.newline();
            try block.toCss(dest, false);
            dest.dedent();
            try dest.newline();
            try dest.writeChar('}');
        } else {
            try dest.writeChar(';');
        }
    }

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
        return css.implementDeepClone(@This(), this, allocator);
    }
};

test "UnknownAtRule holds raw token data" {
    const rule = UnknownAtRule{
        .name = "my-custom-rule",
        .prelude = .{},
        .block = null,
        .loc = css.Location.dummy(),
    };
    try std.testing.expectEqualStrings("my-custom-rule", rule.name);
    try std.testing.expect(rule.block == null);
}

test "UnknownAtRule with block" {
    const rule = UnknownAtRule{
        .name = "block-rule",
        .prelude = .{},
        .block = css.TokenList{},
        .loc = .{ .source_index = 41, .line = 42, .column = 43 },
    };
    try std.testing.expect(rule.block != null);
}

test "UnknownAtRule.deepClone preserves shape" {
    const rule = UnknownAtRule{
        .name = "another",
        .prelude = .{},
        .block = null,
        .loc = .{ .source_index = 1, .line = 2, .column = 3 },
    };
    const cloned = rule.deepClone(std.testing.allocator);
    try std.testing.expectEqualStrings(rule.name, cloned.name);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
