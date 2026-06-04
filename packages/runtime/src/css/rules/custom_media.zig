// Copied from bun/src/css/rules/custom_media.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten:
//   @import("../css_parser.zig")    → @import("../css_parser_stub.zig")
//   @import("../values/values.zig") → kept (real ported sibling)
// `css_values.ident.DashedIdent` resolves via the stub (alias to []const u8).
// `css.MediaList` is a stub opaque carrying `.deepClone`/`.toCss`. The
// `toCss` body reaches for `dest.writeStr`/`DashedIdentFns.toCss` — both
// stub-deferred. `deepClone` re-uses `MediaList.deepClone` (stub returns
// `this.*`). `Error` re-export kept.

pub const css = @import("../css_parser_stub.zig");
pub const css_values = @import("../values/values.zig");
pub const Error = css.Error;
const Printer = css.Printer;
const PrintErr = css.PrintErr;
const MediaList = @import("../media_query.zig").MediaList;

/// A [@custom-media](https://drafts.csswg.org/mediaqueries-5/#custom-mq) rule.
pub const CustomMediaRule = struct {
    /// The name of the declared media query.
    name: css.css_values.ident.DashedIdent,
    /// The media query to declare.
    query: MediaList,
    /// The location of the rule in the source file.
    loc: css.Location,

    const This = @This();

    pub fn deepClone(this: *const @This(), allocator: std.mem.Allocator) This {
        return This{
            .name = this.name,
            .query = this.query.deepClone(allocator),
            .loc = this.loc,
        };
    }
};

test "CustomMediaRule holds name + query + loc" {
    const r = CustomMediaRule{
        .name = "--narrow",
        .query = .{},
        .loc = css.Location.dummy(),
    };
    try std.testing.expectEqualStrings("--narrow", r.name);
}

test "CustomMediaRule.deepClone preserves name" {
    const r = CustomMediaRule{
        .name = "--mobile",
        .query = .{},
        .loc = .{ .source_index = 5, .line = 6, .column = 7 },
    };
    const cloned = r.deepClone(std.testing.allocator);
    try std.testing.expectEqualStrings("--mobile", cloned.name);
    try std.testing.expectEqual(@as(u32, 5), cloned.loc.source_index);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
