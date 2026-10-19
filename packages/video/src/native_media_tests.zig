//! Focused optional codec suite, independent of Home's broad video import graph.
const std = @import("std");
const native = @import("codecs/video/native_encoder.zig");
test {
    _ = @import("codecs/video/rgb_i420.zig");
    _ = @import("containers/mp4_stream.zig");
}
test "AVC/HEVC drain every frame with original timestamps and reject invalid lifecycle" {
    var y: [1024]u8 = undefined;
    @memset(&y, 90);
    var uv: [256]u8 = undefined;
    @memset(&uv, 128);
    for ([_]u32{ 1, 2 }) |codec| {
        var encoder = try native.Encoder.init(.{ .codec = codec, .width = 32, .height = 32, .fps_num = 24, .fps_den = 1, .quality = 90, .bitrate = 0, .gop = 4 });
        defer encoder.deinit();
        try std.testing.expect((try encoder.headers()).len > 8);
        var count: usize = 0;
        for (0..6) |i| {
            const pts: i64 = @intCast(i * 41667);
            if (try encoder.encode(.{ &y, &uv, &uv }, .{ 32, 16, 16 }, 32, 32, pts)) |packet| {
                try std.testing.expectEqual(@as(i64, @intCast(count * 41667)), packet.pts);
                count += 1;
            }
            try std.testing.expectError(error.InvalidTimestamp, encoder.encode(.{ &y, &uv, &uv }, .{ 32, 16, 16 }, 32, 32, pts));
        }
        while (try encoder.flush()) |packet| {
            try std.testing.expectEqual(@as(i64, @intCast(count * 41667)), packet.pts);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 6), count);
        try std.testing.expectError(error.EncoderFailed, encoder.encode(.{ &y, &uv, &uv }, .{ 32, 16, 16 }, 32, 32, 999999));
    }
}
test "codec configuration and plane bounds fail before vendor calls" {
    try std.testing.expectError(error.InvalidConfiguration, native.Encoder.init(.{ .codec = 1, .width = 17, .height = 16, .fps_num = 30, .fps_den = 1, .quality = 90, .bitrate = 0, .gop = 0 }));
    var encoder = try native.Encoder.init(.{ .codec = 1, .width = 32, .height = 32, .fps_num = 30, .fps_den = 1, .quality = 90, .bitrate = 0, .gop = 0 });
    defer encoder.deinit();
    try std.testing.expectError(error.InvalidFrame, encoder.encode(.{ &.{}, &.{}, &.{} }, .{ 32, 16, 16 }, 32, 32, 0));
}
test "quality endpoints preserve supported profiles" {
    for ([_]u32{ 1, 2 }) |codec| {
        for ([_]u32{ 1, 100 }) |quality| {
            var encoder = try native.Encoder.init(.{ .codec = codec, .width = 32, .height = 32, .fps_num = 30, .fps_den = 1, .quality = quality, .bitrate = 0, .gop = 0 });
            defer encoder.deinit();
            try std.testing.expect((try encoder.headers()).len > 8);
            try std.testing.expectEqual(@as(?native.Packet, null), try encoder.flush());
        }
    }
}
