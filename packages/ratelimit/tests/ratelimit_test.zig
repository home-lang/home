const std = @import("std");
const ratelimit = @import("ratelimit");

test "public rate-limit declarations compile" {
    std.testing.refAllDecls(ratelimit);
    std.testing.refAllDecls(ratelimit.RateLimiter);
    std.testing.refAllDecls(ratelimit.TokenBucket);
    std.testing.refAllDecls(ratelimit.drivers.memory.MemoryStore);
    std.testing.refAllDecls(ratelimit.drivers.sliding.SlidingWindowStore);
}

test "public fixed-window store enforces its limit" {
    const memory = try ratelimit.drivers.memory.MemoryStore.init(std.testing.allocator, std.testing.io);
    var limiter = ratelimit.RateLimiter.init(
        std.testing.allocator,
        memory.store(),
        ratelimit.RateLimitConfig.perMinute(1),
    );
    defer limiter.deinit();

    try std.testing.expect((try limiter.check("client")).allowed);
    try std.testing.expect(!(try limiter.check("client")).allowed);
}
