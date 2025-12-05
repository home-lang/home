const std = @import("std");
const posix = std.posix;

// Re-export drivers
pub const drivers = struct {
    pub const memory = @import("drivers/memory.zig");
    pub const sliding = @import("drivers/sliding.zig");
};

/// Helper to get current timestamp in milliseconds
fn getTimestampMs() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Helper to get current timestamp in seconds
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// Rate limit result
pub const RateLimitResult = struct {
    allowed: bool,
    remaining: u32,
    limit: u32,
    reset_at: i64, // Unix timestamp when the limit resets
    retry_after: ?i64, // Seconds to wait before retrying (if not allowed)

    pub fn allow(remaining: u32, limit: u32, reset_at: i64) RateLimitResult {
        return .{
            .allowed = true,
            .remaining = remaining,
            .limit = limit,
            .reset_at = reset_at,
            .retry_after = null,
        };
    }

    pub fn deny(limit: u32, reset_at: i64, retry_after: i64) RateLimitResult {
        return .{
            .allowed = false,
            .remaining = 0,
            .limit = limit,
            .reset_at = reset_at,
            .retry_after = retry_after,
        };
    }
};

/// Rate limit configuration
pub const RateLimitConfig = struct {
    max_requests: u32, // Maximum requests allowed
    window_seconds: i64, // Time window in seconds
    burst: ?u32 = null, // Optional burst allowance

    pub fn perSecond(count: u32) RateLimitConfig {
        return .{ .max_requests = count, .window_seconds = 1 };
    }

    pub fn perMinute(count: u32) RateLimitConfig {
        return .{ .max_requests = count, .window_seconds = 60 };
    }

    pub fn perHour(count: u32) RateLimitConfig {
        return .{ .max_requests = count, .window_seconds = 3600 };
    }

    pub fn perDay(count: u32) RateLimitConfig {
        return .{ .max_requests = count, .window_seconds = 86400 };
    }

    pub fn custom(max_requests: u32, window_seconds: i64) RateLimitConfig {
        return .{ .max_requests = max_requests, .window_seconds = window_seconds };
    }

    pub fn withBurst(self: RateLimitConfig, burst_count: u32) RateLimitConfig {
        var config = self;
        config.burst = burst_count;
        return config;
    }
};

/// Rate limiter store interface
pub const RateLimitStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        hit: *const fn (ptr: *anyopaque, key: []const u8, config: RateLimitConfig) anyerror!RateLimitResult,
        reset: *const fn (ptr: *anyopaque, key: []const u8) anyerror!void,
        getRemaining: *const fn (ptr: *anyopaque, key: []const u8, config: RateLimitConfig) anyerror!u32,
        clear: *const fn (ptr: *anyopaque) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn hit(self: RateLimitStore, key: []const u8, config: RateLimitConfig) !RateLimitResult {
        return self.vtable.hit(self.ptr, key, config);
    }

    pub fn reset(self: RateLimitStore, key: []const u8) !void {
        return self.vtable.reset(self.ptr, key);
    }

    pub fn getRemaining(self: RateLimitStore, key: []const u8, config: RateLimitConfig) !u32 {
        return self.vtable.getRemaining(self.ptr, key, config);
    }

    pub fn clear(self: RateLimitStore) !void {
        return self.vtable.clear(self.ptr);
    }

    pub fn deinit(self: RateLimitStore) void {
        return self.vtable.deinit(self.ptr);
    }
};

/// Rate limiter
pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    store: RateLimitStore,
    default_config: RateLimitConfig,
    key_prefix: []const u8,
    route_configs: std.StringHashMap(RateLimitConfig),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, store: RateLimitStore, default_config: RateLimitConfig) Self {
        return .{
            .allocator = allocator,
            .store = store,
            .default_config = default_config,
            .key_prefix = "ratelimit",
            .route_configs = std.StringHashMap(RateLimitConfig).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.route_configs.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.route_configs.deinit();
        self.store.deinit();
    }

    /// Set a custom rate limit for a specific route
    pub fn forRoute(self: *Self, route: []const u8, config: RateLimitConfig) !void {
        const key = try self.allocator.dupe(u8, route);
        try self.route_configs.put(key, config);
    }

    /// Check rate limit for a key (e.g., IP address, user ID)
    pub fn check(self: *Self, key: []const u8) !RateLimitResult {
        return self.checkWithConfig(key, self.default_config);
    }

    /// Check rate limit with specific config
    pub fn checkWithConfig(self: *Self, key: []const u8, config: RateLimitConfig) !RateLimitResult {
        var full_key_buf: [512]u8 = undefined;
        const full_key = try std.fmt.bufPrint(&full_key_buf, "{s}:{s}", .{ self.key_prefix, key });

        return self.store.hit(full_key, config);
    }

    /// Check rate limit for a route + identifier combination
    pub fn checkRoute(self: *Self, route: []const u8, identifier: []const u8) !RateLimitResult {
        const config = self.route_configs.get(route) orelse self.default_config;

        var key_buf: [512]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}:{s}:{s}", .{ self.key_prefix, route, identifier });

        return self.store.hit(key, config);
    }

    /// Reset rate limit for a key
    pub fn reset(self: *Self, key: []const u8) !void {
        var full_key_buf: [512]u8 = undefined;
        const full_key = try std.fmt.bufPrint(&full_key_buf, "{s}:{s}", .{ self.key_prefix, key });

        return self.store.reset(full_key);
    }

    /// Get remaining requests for a key
    pub fn remaining(self: *Self, key: []const u8) !u32 {
        var full_key_buf: [512]u8 = undefined;
        const full_key = try std.fmt.bufPrint(&full_key_buf, "{s}:{s}", .{ self.key_prefix, key });

        return self.store.getRemaining(full_key, self.default_config);
    }

    /// Create a key from IP address
    pub fn keyFromIp(ip: []const u8) []const u8 {
        return ip;
    }

    /// Create a key from user ID
    pub fn keyFromUser(allocator: std.mem.Allocator, user_id: u64) ![]const u8 {
        return std.fmt.allocPrint(allocator, "user:{d}", .{user_id});
    }
};

/// Throttle result for middleware use
pub const ThrottleResult = struct {
    allowed: bool,
    headers: ThrottleHeaders,
};

/// HTTP headers for rate limiting
pub const ThrottleHeaders = struct {
    limit: u32,
    remaining: u32,
    reset: i64,
    retry_after: ?i64,

    pub fn toHeaderValue(self: ThrottleHeaders, comptime header: []const u8) []const u8 {
        var buf: [64]u8 = undefined;
        if (std.mem.eql(u8, header, "X-RateLimit-Limit")) {
            return std.fmt.bufPrint(&buf, "{d}", .{self.limit}) catch "0";
        } else if (std.mem.eql(u8, header, "X-RateLimit-Remaining")) {
            return std.fmt.bufPrint(&buf, "{d}", .{self.remaining}) catch "0";
        } else if (std.mem.eql(u8, header, "X-RateLimit-Reset")) {
            return std.fmt.bufPrint(&buf, "{d}", .{self.reset}) catch "0";
        } else if (std.mem.eql(u8, header, "Retry-After")) {
            if (self.retry_after) |ra| {
                return std.fmt.bufPrint(&buf, "{d}", .{ra}) catch "0";
            }
            return "";
        }
        return "";
    }
};

/// Middleware-style throttle function
pub fn throttle(limiter: *RateLimiter, key: []const u8) !ThrottleResult {
    const result = try limiter.check(key);

    return .{
        .allowed = result.allowed,
        .headers = .{
            .limit = result.limit,
            .remaining = result.remaining,
            .reset = result.reset_at,
            .retry_after = result.retry_after,
        },
    };
}

/// Token bucket rate limiter entry
pub const TokenBucket = struct {
    tokens: f64,
    last_update: i64,
    max_tokens: f64,
    refill_rate: f64, // tokens per second

    pub fn init(max_tokens: u32, refill_rate: f64) TokenBucket {
        return .{
            .tokens = @floatFromInt(max_tokens),
            .last_update = getTimestampMs(),
            .max_tokens = @floatFromInt(max_tokens),
            .refill_rate = refill_rate,
        };
    }

    pub fn tryConsume(self: *TokenBucket, count: u32) bool {
        self.refill();

        const needed: f64 = @floatFromInt(count);
        if (self.tokens >= needed) {
            self.tokens -= needed;
            return true;
        }
        return false;
    }

    pub fn refill(self: *TokenBucket) void {
        const now = getTimestampMs();
        const elapsed_ms = now - self.last_update;
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        self.tokens = @min(self.max_tokens, self.tokens + (elapsed_seconds * self.refill_rate));
        self.last_update = now;
    }

    pub fn availableTokens(self: *TokenBucket) u32 {
        self.refill();
        return @intFromFloat(self.tokens);
    }
};

// Tests
test "rate limit config presets" {
    const per_second = RateLimitConfig.perSecond(10);
    try std.testing.expectEqual(@as(u32, 10), per_second.max_requests);
    try std.testing.expectEqual(@as(i64, 1), per_second.window_seconds);

    const per_minute = RateLimitConfig.perMinute(60);
    try std.testing.expectEqual(@as(u32, 60), per_minute.max_requests);
    try std.testing.expectEqual(@as(i64, 60), per_minute.window_seconds);

    const per_hour = RateLimitConfig.perHour(1000);
    try std.testing.expectEqual(@as(u32, 1000), per_hour.max_requests);
    try std.testing.expectEqual(@as(i64, 3600), per_hour.window_seconds);
}

test "rate limit result" {
    const allowed = RateLimitResult.allow(9, 10, 1234567890);
    try std.testing.expect(allowed.allowed);
    try std.testing.expectEqual(@as(u32, 9), allowed.remaining);
    try std.testing.expectEqual(@as(u32, 10), allowed.limit);

    const denied = RateLimitResult.deny(10, 1234567890, 30);
    try std.testing.expect(!denied.allowed);
    try std.testing.expectEqual(@as(u32, 0), denied.remaining);
    try std.testing.expectEqual(@as(?i64, 30), denied.retry_after);
}

test "token bucket" {
    var bucket = TokenBucket.init(10, 1.0);

    // Should have 10 tokens initially
    try std.testing.expect(bucket.tryConsume(5));
    try std.testing.expect(bucket.availableTokens() >= 4);

    // Consume remaining
    try std.testing.expect(bucket.tryConsume(5));

    // Should be empty now
    try std.testing.expect(!bucket.tryConsume(1));
}
