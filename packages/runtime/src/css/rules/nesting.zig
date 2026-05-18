// Copied from bun/src/css/rules/nesting.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `style.StyleRule(R)` and `Location` resolve via the stub (the stub's
// `css_rules.style.StyleRule` is the matching generic). Method bodies that
// touch the Printer / StyleRule.toCss trip `@compileError` until the real
// css_parser ports.

pub const css = @import("../css_parser_stub.zig");
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.css_rules.Location;
const style = css.css_rules.style;

/// A [@nest](https://www.w3.org/TR/css-nesting-1/#at-nest) rule.
pub fn NestingRule(comptime R: type) type {
    return struct {
        /// The style rule that defines the selector and declarations for the `@nest` rule.
        style: style.StyleRule(R),
        /// The location of the rule in the source file.
        loc: Location,

        const This = @This();

        pub fn toCss(this: *const This, dest: *Printer) PrintErr!void {
            // #[cfg(feature = "sourcemap")]
            // dest.add_mapping(self.loc);
            if (dest.context() == null) {
                try dest.writeStr("@nest ");
            }
            return try this.style.toCss(dest);
        }

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
            return css.implementDeepClone(@This(), this, allocator);
        }
    };
}

test "NestingRule generic instantiates" {
    const Inst = NestingRule(u8);
    const r = Inst{
        .style = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.source_index);
}

test "NestingRule.deepClone shallow copy" {
    const Inst = NestingRule(u16);
    const r = Inst{
        .style = .{},
        .loc = .{ .source_index = 11, .line = 12, .column = 13 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expectEqual(r.loc.source_index, cloned.loc.source_index);
}

const std = @import("std");
