//! Allocation-free validation for immutable recording session settings.
//! Codec IDs: 1=AVC, 2=HEVC, 3=MJPEG. Container/backend support is caller policy.
const std = @import("std");

/// Accepts Home/native or caller ABI structures with these named scalar fields.
/// Validate before allocating replacement encoders or invoking output hooks.
pub fn validateVideo(cfg: anytype) !void {
    if (cfg.codec < 1 or cfg.codec > 3) return error.Unsupported;
    if (cfg.width == 0 or cfg.height == 0 or cfg.width > 16384 or cfg.height > 16384 or cfg.quality == 0 or cfg.quality > 100 or cfg.fps_num == 0 or cfg.fps_den == 0 or cfg.fps_num > 1000000 or cfg.fps_den > 1000000) return error.InvalidConfiguration;
    const interval = @as(u64, 1000000) * cfg.fps_den / cfg.fps_num;
    if (interval == 0 or interval > std.math.maxInt(u32)) return error.InvalidConfiguration;
    if (cfg.codec == 3) {
        if (cfg.bitrate != 0 or cfg.gop != 0) return error.InvalidConfiguration;
    } else {
        if (cfg.width < 16 or cfg.height < 16 or cfg.width > 8192 or cfg.height > 8192 or (cfg.width | cfg.height) & 1 != 0 or cfg.gop > std.math.maxInt(i32) or (cfg.bitrate != 0 and cfg.bitrate < 1000)) return error.InvalidConfiguration;
    }
}

pub fn validateAudio(rate: u32, channels: u32, frames: usize, blocks: usize, bitrate: u32) !void {
    if (bitrate != 0 and (rate == 0 or bitrate < 16000 or bitrate > 320000)) return error.InvalidConfiguration;
    if (rate == 0) return; // Disabled; no PCM allocation or encoder.
    if (rate < 8000 or rate > 192000 or channels < 1 or channels > 2 or frames == 0 or frames > rate * 10 or blocks == 0 or blocks > 4096) return error.InvalidConfiguration;
}

test "session settings validate independently of codec/container allocation" {
    const Config = struct { codec: u32, width: u32, height: u32, fps_num: u32, fps_den: u32, bitrate: u32, quality: u32, gop: u32 };
    var cfg: Config = .{ .codec = @as(u32, 3), .width = @as(u32, 32), .height = @as(u32, 24), .fps_num = @as(u32, 25), .fps_den = @as(u32, 1), .bitrate = @as(u32, 0), .quality = @as(u32, 90), .gop = @as(u32, 0) };
    try validateVideo(cfg);
    cfg.bitrate = 1000;
    try std.testing.expectError(error.InvalidConfiguration, validateVideo(cfg));
    for ([_]u32{ 1, 2 }) |codec| {
        cfg.codec = codec;
        cfg.gop = 30;
        try validateVideo(cfg);
        cfg.height = 23;
        try std.testing.expectError(error.InvalidConfiguration, validateVideo(cfg));
        cfg.height = 24;
    }
    cfg.gop = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidConfiguration, validateVideo(cfg));
    cfg.gop = 0;
    cfg.fps_den = 1000000;
    cfg.fps_num = 1;
    try std.testing.expectError(error.InvalidConfiguration, validateVideo(cfg));
    cfg.codec = 4;
    try std.testing.expectError(error.Unsupported, validateVideo(cfg));
}
test "audio settings reject impossible queue bounds and stale bitrate on disable" {
    try validateAudio(48000, 2, 96000, 256, 128000);
    try validateAudio(44100, 1, 44100, 128, 64000);
    try validateAudio(0, 1, 0, 0, 0);
    try std.testing.expectError(error.InvalidConfiguration, validateAudio(0, 1, 0, 0, 64000));
    try std.testing.expectError(error.InvalidConfiguration, validateAudio(48000, 3, 96000, 256, 0));
    try std.testing.expectError(error.InvalidConfiguration, validateAudio(48000, 2, 480001, 256, 0));
    try std.testing.expectError(error.InvalidConfiguration, validateAudio(48000, 2, 1, 4097, 0));
    try std.testing.expectError(error.InvalidConfiguration, validateAudio(48000, 2, 1, 1, 320001));
}
