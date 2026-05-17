// Copied verbatim from bun/src/sql/postgres/protocol/zHelpers.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.

pub fn zCount(slice: []const u8) usize {
    return if (slice.len > 0) slice.len + 1 else 0;
}

pub fn zFieldCount(prefix: []const u8, slice: []const u8) usize {
    if (slice.len > 0) {
        return zCount(prefix) + zCount(slice);
    }

    return zCount(prefix);
}

test "zCount adds NUL terminator for non-empty slices" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 0), zCount(""));
    try std.testing.expectEqual(@as(usize, 4), zCount("abc"));
}

test "zFieldCount combines prefix + slice with NUL terminators" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 0), zFieldCount("", ""));
    try std.testing.expectEqual(@as(usize, 4), zFieldCount("abc", ""));
    try std.testing.expectEqual(@as(usize, 8), zFieldCount("abc", "xyz"));
}
