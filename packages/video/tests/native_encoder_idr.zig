//! Standalone adapter test; link native_encoder.c with system x264/x265.
const std = @import("std");
const native = @import("encoder");
fn observe(packet: native.Packet, codec: u32, seen: *[8]bool) !void {
    const index: usize = @intCast(@divTrunc(packet.pts, 41667));
    try std.testing.expect(index < 8 and !seen[index]);
    seen[index] = true;
    const key = index == 0 or index == 3 or index == 6;
    try std.testing.expectEqual(key, packet.key);
    var at: usize = 0;
    var idr = false;
    while (at < packet.data.len) {
        try std.testing.expect(packet.data.len - at >= 4);
        const n = std.mem.readInt(u32, packet.data[at..][0..4], .big);
        at += 4;
        try std.testing.expect(n > 0 and n <= packet.data.len - at);
        const kind = if (codec == 1) packet.data[at] & 31 else (packet.data[at] >> 1) & 63;
        idr = idr or (if (codec == 1) kind == 5 else kind == 19 or kind == 20);
        at += n;
    }
    try std.testing.expectEqual(key, idr);
}
test "requested IDRs override long GOP without losing delayed AVC frames" {
    const y: [128 * 96]u8 = @splat(64);
    const uv: [64 * 48]u8 = @splat(128);
    for ([_]u32{ 1, 2 }) |codec| {
        var encoder = try native.Encoder.init(.{ .codec = codec, .width = 128, .height = 96, .fps_num = 24, .fps_den = 1, .bitrate = 0, .quality = 90, .gop = 100 });
        defer encoder.deinit();
        var seen: [8]bool = @splat(false);
        for (0..8) |i| {
            if (i == 3 or i == 6) try encoder.requestKeyframe();
            if (try encoder.encode(.{ &y, &uv, &uv }, .{ 128, 64, 64 }, 128, 96, @intCast(i * 41667))) |packet| try observe(packet, codec, &seen);
        }
        while (try encoder.flush()) |packet| try observe(packet, codec, &seen);
        for (seen) |value| try std.testing.expect(value);
        try std.testing.expectError(error.EncoderFailed, encoder.requestKeyframe());
    }
}
