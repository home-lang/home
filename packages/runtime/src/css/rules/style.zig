// Copied from bun/src/css/rules/style.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
//
// Strategy-B port over the stub. `StyleRule(R)` carries pure-data fields:
//   - `selectors: css.selector.parser.SelectorList` (stubbed),
//   - `vendor_prefix: css.VendorPrefix`,
//   - `declarations: css.DeclarationBlock` (stubbed),
//   - `rules: css.CssRuleList(R)` (stubbed),
//   - `loc: css.Location`.
//
// `isEmpty`/`hashKey`/`updatePrefix`/`isCompatible`/`toCss`/`toCssBase`/
// `minify`/`isDuplicate` all reach for `SelectorList.v.isEmpty` /
// `DeclarationBlock.hashPropertyIds` / `dest.writeStr` / `css.selector.*`
// helpers — all behind `@compileError` and stripped here. `deepClone` keeps
// the per-field clones; under the stub each `deepClone` is a shallow copy.

pub const css = @import("../css_parser_stub.zig");

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
