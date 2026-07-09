// Copied verbatim from bun/src/unicode/uucode_lib/src/x/types_x/grapheme.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../../../cli/LICENSE.bun.md.

pub const GraphemeBreakNoControl = enum(u5) {
    other,
    prepend,
    regional_indicator,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
    zwj,
    zwnj,
    extended_pictographic,
    emoji_modifier_base,
    emoji_modifier,
    // extend, ==
    //   zwnj +
    //   indic_conjunct_break_extend +
    //   indic_conjunct_break_linker
    indic_conjunct_break_extend,
    indic_conjunct_break_linker,
    indic_conjunct_break_consonant,
};

test "GraphemeBreakNoControl enum has 17 variants and fits in u5" {
    const std = @import("std");
    try std.testing.expectEqual(@as(comptime_int, 17), @typeInfo(GraphemeBreakNoControl).@"enum".field_names.len);
    // Confirm the tag type is exactly u5 (max 32 values).
    try std.testing.expectEqual(u5, @typeInfo(GraphemeBreakNoControl).@"enum".tag_type);
    // Spot-check a couple of tag values.
    try std.testing.expectEqual(@as(u5, 0), @intFromEnum(GraphemeBreakNoControl.other));
    try std.testing.expectEqual(@as(u5, 9), @intFromEnum(GraphemeBreakNoControl.zwj));
    try std.testing.expectEqual(@as(u5, 16), @intFromEnum(GraphemeBreakNoControl.indic_conjunct_break_consonant));
}
