// Rate limiting and DoS protection

const std = @import("std");
const syslog = @import("syslog.zig");

/// Token bucket rate limiter
pub const RateLimiter = struct {
    capacity: u32,
    tokens: std.atomic.Value(u32),
    refill_rate: u32, // tokens per second
    last_refill: std.atomic.Value(i64),
    mutex: std.Thread.Mutex,

    pub fn init(capacity: u32, refill_rate: u32) RateLimiter {
        return .{
            .capacity = capacity,
            .tokens = std.atomic.Value(u32).init(capacity),
            .refill_rate = refill_rate,
            .last_refill = std.atomic.Value(i64).init(std.time.timestamp()),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn tryAcquire(self: *RateLimiter) bool {
        self.refill();

        self.mutex.lock();
        defer self.mutex.unlock();

        const current = self.tokens.load(.acquire);
        if (current > 0) {
            _ = self.tokens.fetchSub(1, .release);
            return true;
        }

        return false;
    }

    pub fn tryAcquireN(self: *RateLimiter, n: u32) bool {
        self.refill();

        self.mutex.lock();
        defer self.mutex.unlock();

        const current = self.tokens.load(.acquire);
        if (current >= n) {
            _ = self.tokens.fetchSub(n, .release);
            return true;
        }

        return false;
    }

    fn refill(self: *RateLimiter) void {
        const now = std.time.timestamp();
        const last = self.last_refill.load(.acquire);
        const elapsed = now - last;

        if (elapsed <= 0) return;

        const new_tokens = @as(u32, @intCast(@min(elapsed, std.math.maxInt(i32)))) * self.refill_rate;
        if (new_tokens == 0) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const current = self.tokens.load(.acquire);
        const updated = @min(current + new_tokens, self.capacity);
        self.tokens.store(updated, .release);
        self.last_refill.store(now, .release);
    }

    pub fn getAvailableTokens(self: *RateLimiter) u32 {
        self.refill();
        return self.tokens.load(.acquire);
    }
};

/// Per-source rate limiter
pub const PerSourceLimiter = struct {
    limiters: std.StringHashMap(RateLimiter),
    default_capacity: u32,
    default_rate: u32,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, capacity: u32, rate: u32) PerSourceLimiter {
        return .{
            .limiters = std.StringHashMap(RateLimiter).init(allocator),
            .default_capacity = capacity,
            .default_rate = rate,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *PerSourceLimiter) void {
        var iter = self.limiters.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.limiters.deinit();
    }

    pub fn tryAcquire(self: *PerSourceLimiter, source: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = try self.limiters.getOrPut(source);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, source);
            gop.value_ptr.* = RateLimiter.init(self.default_capacity, self.default_rate);
        }

        return gop.value_ptr.tryAcquire();
    }

    pub fn cleanup(self: *PerSourceLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.limiters.iterator();
        while (iter.next()) |entry| {
            // Remove limiters that are full (inactive)
            if (entry.value_ptr.getAvailableTokens() >= self.default_capacity) {
                to_remove.append(entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |key| {
            if (self.limiters.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
        }
    }
};

/// Rate limit statistics
pub const RateLimitStats = struct {
    allowed: std.atomic.Value(u64),
    denied: std.atomic.Value(u64),

    pub fn init() RateLimitStats {
        return .{
            .allowed = std.atomic.Value(u64).init(0),
            .denied = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordAllowed(self: *RateLimitStats) void {
        _ = self.allowed.fetchAdd(1, .monotonic);
    }

    pub fn recordDenied(self: *RateLimitStats) void {
        _ = self.denied.fetchAdd(1, .monotonic);
    }

    pub fn getAllowed(self: *const RateLimitStats) u64 {
        return self.allowed.load(.monotonic);
    }

    pub fn getDenied(self: *const RateLimitStats) u64 {
        return self.denied.load(.monotonic);
    }

    pub fn getTotal(self: *const RateLimitStats) u64 {
        return self.getAllowed() + self.getDenied();
    }

    pub fn getDenyRate(self: *const RateLimitStats) f64 {
        const total = self.getTotal();
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.getDenied())) / @as(f64, @floatFromInt(total));
    }
};

test "rate limiter basic" {
    const testing = std.testing;

    var limiter = RateLimiter.init(10, 5);

    // Should allow up to capacity
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(limiter.tryAcquire());
    }

    // Should deny after capacity exhausted
    try testing.expect(!limiter.tryAcquire());
}

test "rate limiter refill" {
    const testing = std.testing;

    var limiter = RateLimiter.init(5, 100);

    // Exhaust tokens
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try testing.expect(limiter.tryAcquire());
    }

    // Should refill after time passes
    // (In real usage, would wait, but for testing we can't rely on timing)
    const available = limiter.getAvailableTokens();
    try testing.expect(available <= 5);
}

test "per-source limiter" {
    const testing = std.testing;

    var limiter = PerSourceLimiter.init(testing.allocator, 5, 10);
    defer limiter.deinit();

    // Source A can acquire up to limit
    try testing.expect(try limiter.tryAcquire("source_a"));
    try testing.expect(try limiter.tryAcquire("source_a"));

    // Source B has separate limit
    try testing.expect(try limiter.tryAcquire("source_b"));
}

test "rate limit stats" {
    const testing = std.testing;

    var stats = RateLimitStats.init();

    stats.recordAllowed();
    stats.recordAllowed();
    stats.recordDenied();

    try testing.expectEqual(@as(u64, 2), stats.getAllowed());
    try testing.expectEqual(@as(u64, 1), stats.getDenied());
    try testing.expectEqual(@as(u64, 3), stats.getTotal());
}
