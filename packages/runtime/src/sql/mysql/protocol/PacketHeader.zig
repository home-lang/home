// Copied verbatim from bun/src/sql/mysql/protocol/PacketHeader.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.

const PacketHeader = @This();
length: u24,
sequence_id: u8,

pub const size = 4;

pub fn decode(bytes: []const u8) ?PacketHeader {
    if (bytes.len < 4) return null;

    return PacketHeader{
        .length = @as(u24, bytes[0]) |
            (@as(u24, bytes[1]) << 8) |
            (@as(u24, bytes[2]) << 16),
        .sequence_id = bytes[3],
    };
}

pub fn encode(self: PacketHeader) [4]u8 {
    return [4]u8{
        @intCast(self.length & 0xff),
        @intCast((self.length >> 8) & 0xff),
        @intCast((self.length >> 16) & 0xff),
        self.sequence_id,
    };
}

test "PacketHeader round-trips through encode + decode" {
    const std = @import("std");
    const h: PacketHeader = .{ .length = 0x123456, .sequence_id = 0x07 };
    const bytes = h.encode();
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12, 0x07 }, &bytes);
    const decoded = PacketHeader.decode(&bytes).?;
    try std.testing.expectEqual(@as(u24, 0x123456), decoded.length);
    try std.testing.expectEqual(@as(u8, 0x07), decoded.sequence_id);
}

test "PacketHeader.decode rejects under-length input" {
    const std = @import("std");
    try std.testing.expect(PacketHeader.decode(&.{}) == null);
    try std.testing.expect(PacketHeader.decode(&.{ 0x01, 0x02, 0x03 }) == null);
}
