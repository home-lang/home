// Copied from bun/src/css/rules/media.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("../css_parser.zig") → @import("../css_parser_stub.zig").
// `css.MediaList`, `css.CssRuleList`, `Location`, `MinifyContext`, `MinifyErr`
// all resolve via the stub. The generic `MediaRule(R)` carries pure-data
// fields (`query`, `rules`, `loc`); body methods (`minify`, `toCss`) reach
// for stub-deferred surface (`MediaList.alwaysMatches`, `CssRuleList.toCss`,
// `dest.writeStr`, `dest.indent`, etc.) and trip `@compileError` if invoked.
// `deepClone` re-uses `implementDeepClone` (shallow copy under stub).

pub const css = @import("../css_parser_stub.zig");
const MediaList = css.MediaList;
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const Location = css.css_rules.Location;
const CssRuleList = css.CssRuleList;

pub fn MediaRule(comptime R: type) type {
    return struct {
        /// The media query list.
        query: css.MediaList,
        /// The rules within the `@media` rule.
        rules: css.CssRuleList(R),
        /// The location of the rule in the source file.
        loc: Location,

        const This = @This();

        pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
            return css.implementDeepClone(@This(), this, allocator);
        }
    };
}

test "MediaRule(void) has expected fields" {
    const T = MediaRule(void);
    const r = T{
        .query = .{},
        .rules = .{},
        .loc = css.Location.dummy(),
    };
    _ = r.query;
    try std.testing.expectEqual(std.math.maxInt(u32), r.loc.source_index);
}

test "MediaRule(u8).deepClone is a shallow copy" {
    const T = MediaRule(u8);
    const r = T{
        .query = .{},
        .rules = .{},
        .loc = .{ .source_index = 11, .line = 22, .column = 33 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 22), cloned.loc.line);
}

const std = @import("std");
