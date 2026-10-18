const std = @import("std");
const Encoder = @import("native_aac.zig").Encoder;
test "AAC-LC partial PCM, exact configuration, delayed drain and state checks" {
    var encoder = try Encoder.init(.{ .sample_rate = 48000, .channels = 2, .bitrate = 128000 });
    defer encoder.deinit();
    try std.testing.expectEqual(@as(u32, 1024), encoder.info.frame_length);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x90 }, encoder.info.config[0..2]);
    try std.testing.expect(encoder.info.delay > 0);
    var samples: [4096]u8 = undefined;
    @memset(&samples, 0);
    try std.testing.expectError(error.InvalidPcm, encoder.encode(samples[0..3]));
    var frames: usize = 0;
    var packets: usize = 0;
    while (frames < 2500) {
        const count: usize = @min(@as(usize, 137), 2500 - frames);
        const result = try encoder.encode(samples[0 .. count * 4]);
        frames += result.consumed_frames;
        if (result.data.len != 0) packets += 1;
    }
    while (try encoder.flush()) |_| packets += 1;
    try std.testing.expect(packets * 1024 >= 2500 + encoder.info.delay);
    try std.testing.expectError(error.EncoderFailed, encoder.encode(samples[0..4]));
    try std.testing.expect((try encoder.flush()) == null);
    try std.testing.expectError(error.InvalidConfiguration, Encoder.init(.{ .sample_rate = 12345, .channels = 1, .bitrate = 64000 }));
}
