// Copied from bun/src/css/logical.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("./css_parser.zig") dropped. The original file
// only re-exported `Error = css.Error` which was never referenced inside
// this leaf module; the two enums (`PropertyCategory`, `LogicalGroup`) are
// pure data and stand alone. When css_parser.zig is eventually ported, the
// `Error` alias can be re-added without touching consumers.

pub const PropertyCategory = enum {
    logical,
    physical,

    pub fn default() PropertyCategory {
        return .physical;
    }
};

pub const LogicalGroup = enum {
    border_color,
    border_style,
    border_width,
    border_radius,
    margin,
    scroll_margin,
    padding,
    scroll_padding,
    inset,
    size,
    min_size,
    max_size,
};

test "PropertyCategory.default returns physical" {
    try std.testing.expectEqual(PropertyCategory.physical, PropertyCategory.default());
}

test "LogicalGroup enum tags are stable" {
    // Spot-check a few tags to lock the ordering against accidental reshuffles.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(LogicalGroup.border_color));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(LogicalGroup.border_radius));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(LogicalGroup.max_size));
}

test "PropertyCategory has two variants" {
    const info = @typeInfo(PropertyCategory).@"enum";
    try std.testing.expectEqual(@as(usize, 2), info.field_names.len);
}

const std = @import("std");
