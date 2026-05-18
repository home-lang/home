// Copied verbatim from bun/src/unicode/uucode_lib/src/x/types.x.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../../cli/LICENSE.bun.md.

pub const grapheme = @import("./types_x/grapheme.zig");

pub const GraphemeBreakNoControl = grapheme.GraphemeBreakNoControl;

test "x.types.x.zig re-exports the grapheme namespace" {
    const std = @import("std");
    try std.testing.expectEqual(GraphemeBreakNoControl, grapheme.GraphemeBreakNoControl);
    try std.testing.expectEqual(@as(u5, 0), @intFromEnum(GraphemeBreakNoControl.other));
}
