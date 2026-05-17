// Copied verbatim from bun/src/sql/postgres/types/int_types.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.

pub const int4 = u32;
pub const PostgresInt32 = int4;
pub const int8 = i64;
pub const PostgresInt64 = int8;
pub const short = u16;
pub const PostgresShort = u16;

pub fn Int32(value: anytype) [4]u8 {
    return @bitCast(@byteSwap(@as(int4, @intCast(value))));
}

test "Int32 encodes big-endian" {
    const std = @import("std");
    const bytes = Int32(@as(u32, 0x01020304));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x04 }, &bytes);
}
