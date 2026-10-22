//! Named capture-encoder quality policy. Allocation-free, integer/rational math.
//! Software AVC follows Picamera2's 1080p30 bitrate reference and square-root
//! complexity scaling. HEVC deliberately shares that Home heuristic; it is not
//! an upstream HEVC table. MJPEG uses the software JPEG quantizer-quality table.
const std = @import("std");
const session = @import("session_config.zig");
pub const Tier = enum(u32) { very_low, low, medium, high, very_high };
pub fn fromName(name: []const u8) !Tier {
    const names = [_][]const u8{ "very-low", "low", "medium", "high", "very-high" };
    for (names, 0..) |value, index| if (std.mem.eql(u8, name, value)) return @enumFromInt(index);
    return error.InvalidQualityTier;
}
pub fn jpeg(tier: Tier) u32 {
    return ([_]u32{ 25, 35, 50, 65, 80 })[@intFromEnum(tier)];
}
/// Exact floor of the square-root estimate, then a 1000 bit/sec floor/quantum
/// matching the native bridge's kbit units. Overflow rejects rather than wraps.
/// Config validation belongs to apply(); this function validates its own shape.
pub fn bitrate(tier: Tier, width: u32, height: u32, fps_num: u32, fps_den: u32) !u32 {
    if (width < 16 or height < 16 or width > 8192 or height > 8192 or (width | height) & 1 != 0 or fps_num == 0 or fps_den == 0 or fps_num > 1000000 or fps_den > 1000000) return error.InvalidConfiguration;
    const reference: u128 = ([_]u32{ 3000000, 4000000, 7000000, 10000000, 14000000 })[@intFromEnum(tier)];
    const numerator = reference * reference * width * height * fps_num;
    const denominator = @as(u128, 1920 * 1080 * 30) * fps_den;
    const estimate = std.math.sqrt(numerator / denominator);
    const result = @max(@as(u64, 1000), estimate / 1000 * 1000);
    if (result > std.math.maxInt(u32)) return error.InvalidConfiguration;
    return @intCast(result);
}
/// Return an immutable resolved recipe with the caller's remaining fields intact.
/// Explicit tier overrides AVC/HEVC target bitrate. JPEG has no rate control:
/// a nonzero MJPEG bitrate/GOP remains invalid. No codec/sink is opened here.
pub fn apply(cfg: anytype, tier: Tier) !@TypeOf(cfg) {
    var next = cfg;
    if (next.codec == 3) {
        next.quality = jpeg(tier);
    } else if (next.codec == 1 or next.codec == 2) {
        next.bitrate = try bitrate(tier, cfg.width, cfg.height, cfg.fps_num, cfg.fps_den);
        next.quality = 90; // Ignored by ABR, preserves the legacy scalar recipe.
    } else return error.Unsupported;
    try session.validateVideo(next);
    return next;
}

test "software capture tiers have exact reference rates and JPEG qualities" {
    const t = std.testing;
    const rates = [_]u32{ 3000000, 4000000, 7000000, 10000000, 14000000 };
    const qualities = [_]u32{ 25, 35, 50, 65, 80 };
    for (std.enums.values(Tier), rates, qualities) |tier, rate, quality| {
        try t.expectEqual(rate, try bitrate(tier, 1920, 1080, 30, 1));
        try t.expectEqual(rate / 2, try bitrate(tier, 960, 540, 30, 1));
        try t.expectEqual(rate * 2, try bitrate(tier, 3840, 2160, 30, 1));
        try t.expectEqual(rate * 2, try bitrate(tier, 1920, 1080, 120, 1));
        try t.expectEqual(quality, jpeg(tier));
    }
}
test "fractional rates have deterministic integer estimates and vendor units" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 6996000), try bitrate(.medium, 1920, 1080, 30000, 1001));
    try t.expectEqual(@as(u32, 481000), try bitrate(.medium, 128, 96, 24, 1));
    try t.expectEqual(@as(u32, 1000), try bitrate(.very_low, 16, 16, 1, 1000000));
    for (std.enums.values(Tier)) |tier| {
        var previous: u32 = 0;
        for (1..241) |fps| {
            const rate = try bitrate(tier, 1280, 720, @intCast(fps), 1);
            try t.expect(rate >= previous and rate % 1000 == 0);
            previous = rate;
        }
    }
}
test "bad shape, rates, overflow and unknown names reject without changing recipes" {
    const t = std.testing;
    for ([_][4]u32{ .{ 0, 16, 30, 1 }, .{ 17, 16, 30, 1 }, .{ 16, 8194, 30, 1 }, .{ 16, 16, 0, 1 }, .{ 16, 16, 1, 0 }, .{ 16, 16, 1000001, 1 }, .{ 16, 16, 1, 1000001 }, .{ 8192, 8192, 1000000, 1 } }) |shape| try t.expectError(error.InvalidConfiguration, bitrate(.very_high, shape[0], shape[1], shape[2], shape[3]));
    for ([_][]const u8{ "", "VERY_HIGH", "lossless", "Very-high" }) |name| try t.expectError(error.InvalidQualityTier, fromName(name));
    try t.expectEqual(Tier.very_high, try fromName("very-high"));
    const Config = struct { codec: u32 = 1, width: u32 = 1920, height: u32 = 1080, fps_num: u32 = 30, fps_den: u32 = 1, bitrate: u32 = 123000, quality: u32 = 17, gop: u32 = 30 };
    const cfg: Config = .{};
    const next = try apply(cfg, .high);
    try t.expectEqual(@as(u32, 10000000), next.bitrate);
    try t.expectEqual(@as(u32, 123000), cfg.bitrate);
    try t.expectEqual(cfg.gop, next.gop);
    try t.expectError(error.Unsupported, apply(Config{ .codec = 0 }, .high));
    try t.expectError(error.InvalidConfiguration, apply(Config{ .codec = 3 }, .high));
    const image = try apply(Config{ .codec = 3, .width = 33, .height = 25, .bitrate = 0, .gop = 0 }, .very_low);
    try t.expectEqual(@as(u32, 25), image.quality);
    try t.expectEqual(@as(u32, 0), image.bitrate);
}
