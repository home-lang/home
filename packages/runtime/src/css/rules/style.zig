// Copied from bun/src/css/rules/style.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Minimal real parser/printer surface for the generated rule table.

pub const css = @import("../css_parser.zig");

const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.css_rules.Location;

pub fn StyleRule(comptime R: type) type {
    return struct {
        /// The selectors for the style rule.
        selectors: css.selector.parser.SelectorList,
        /// A vendor prefix override, used during selector printing.
        vendor_prefix: css.VendorPrefix,
        /// The declarations within the style rule.
        declarations: css.DeclarationBlock,
        /// Nested rules within the style rule.
        rules: css.CssRuleList(R),
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

        pub fn isCompatible(_: *const @This(), _: anytype) bool {
            return true;
        }

        pub fn isEmpty(_: *const @This()) bool {
            return false;
        }

        pub fn hashKey(_: *const @This()) u64 {
            return 0;
        }

        pub fn isDuplicate(_: *const @This(), _: *const @This()) bool {
            return false;
        }

        pub fn updatePrefix(_: *@This(), _: anytype) void {}
    };
}

test "StyleRule(void) has expected shape" {
    const T = StyleRule(void);
    const r = T{
        .selectors = .{},
        .vendor_prefix = css.VendorPrefix.NONE,
        .declarations = .{},
        .rules = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expect(r.vendor_prefix.none);
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.source_index);
}

test "StyleRule(u8) deepClone preserves loc + vendor_prefix" {
    const T = StyleRule(u8);
    const r = T{
        .selectors = .{},
        .vendor_prefix = css.VendorPrefix.WEBKIT,
        .declarations = .{},
        .rules = .{},
        .loc = .{ .source_index = 9, .line = 8, .column = 7 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expect(cloned.vendor_prefix.webkit);
    try std.testing.expectEqual(@as(u32, 8), cloned.loc.line);
}

const std = @import("std");
