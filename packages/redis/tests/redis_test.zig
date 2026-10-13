const std = @import("std");
const redis = @import("redis");

test "public Redis declarations compile" {
    std.testing.refAllDecls(redis);
    std.testing.refAllDecls(redis.Redis);
    std.testing.refAllDecls(redis.RedisPool);
    try std.testing.expect(@sizeOf(redis.RedisPool) > 0);
}

test "public configuration and RESP helpers remain usable" {
    const config = try redis.RedisConfig.fromUrl(std.testing.io, "redis://user:pass@example.com:6380/4");
    try std.testing.expectEqualStrings("example.com", config.host);
    try std.testing.expectEqual(@as(u16, 6380), config.port);
    try std.testing.expectEqualStrings("user", config.username.?);
    try std.testing.expectEqualStrings("pass", config.password.?);
    try std.testing.expectEqual(@as(u8, 4), config.database);

    const response: redis.RespValue = .{ .bulk_string = "value" };
    try std.testing.expectEqualStrings("value", response.asString().?);
}
