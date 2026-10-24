const std = @import("std");
const video = @import("video");
test "public video RTP sender produces independently specified single-NAL bytes" {
    const t = std.testing;
    var p = try video.RtpPacketizer.init(.{ .codec = .h264, .format = .annex_b, .mtu = 1200, .payload_type = 96, .sequence = 0x1234, .timestamp = 0x01020304, .ssrc = 0x05060708 }, &.{ 0, 0, 0, 1, 0x65, 0x80 }, .{});
    var bytes: [32]u8 = undefined;
    const length = try p.next(&bytes);
    try t.expectEqualSlices(u8, &.{ 0x80, 0xe0, 0x12, 0x34, 1, 2, 3, 4, 5, 6, 7, 8, 0x65, 0x80 }, bytes[0..length]);
    const parsed = try video.RtpPacket.parse(bytes[0..length]);
    try t.expectEqualSlices(u8, &.{ 0x65, 0x80 }, parsed.payload);
}
