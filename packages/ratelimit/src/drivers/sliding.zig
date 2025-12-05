const std = @import("std");
const posix = std.posix;
const ratelimit = @import("../ratelimit.zig");

/// Helper to get current timestamp in milliseconds
fn getTimestampMs() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Helper to get current timestamp
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// Sliding window rate limit store
/// More accurate than fixed window, prevents burst at window boundaries
pub const SlidingWindowStore = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(WindowEntry),
    mutex: std.Thread.Mutex,

    const Self = @This();

    const WindowEntry = struct {
        current_count: u32,
        previous_count: u32,
        current_window_start: i64,
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .entries = std.StringHashMap(WindowEntry).init(allocator),
            .mutex = .{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
        self.allocator.destroy(self);
    }

    pub fn store(self: *Self) ratelimit.RateLimitStore {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn calculateWeight(now: i64, window_start: i64, window_seconds: i64) f64 {
        const elapsed = now - window_start;
        const progress = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(window_seconds));
        return @max(0.0, 1.0 - progress);
    }

    fn hit(ptr: *anyopaque, key: []const u8, config: ratelimit.RateLimitConfig) anyerror!ratelimit.RateLimitResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = getTimestamp();
        const window_seconds = config.window_seconds;
        const current_window_start = now - @mod(now, window_seconds);
        const reset_at = current_window_start + window_seconds;

        var entry: WindowEntry = undefined;
        var key_owned: []const u8 = undefined;

        if (self.entries.get(key)) |existing| {
            entry = existing;
            key_owned = key;

            // Check if we've moved to a new window
            if (entry.current_window_start < current_window_start - window_seconds) {
                // Two or more windows have passed, reset everything
                entry = WindowEntry{
                    .current_count = 0,
                    .previous_count = 0,
                    .current_window_start = current_window_start,
                };
            } else if (entry.current_window_start < current_window_start) {
                // Moved to next window, shift counts
                entry = WindowEntry{
                    .current_count = 0,
                    .previous_count = entry.current_count,
                    .current_window_start = current_window_start,
                };
            }
        } else {
            // New key
            key_owned = try self.allocator.dupe(u8, key);
            entry = WindowEntry{
                .current_count = 0,
                .previous_count = 0,
                .current_window_start = current_window_start,
            };
        }

        // Calculate weighted count using sliding window
        const weight = calculateWeight(now, current_window_start, window_seconds);
        const weighted_previous = @as(f64, @floatFromInt(entry.previous_count)) * weight;
        const estimated_count = weighted_previous + @as(f64, @floatFromInt(entry.current_count));

        // Check if limit exceeded
        if (estimated_count >= @as(f64, @floatFromInt(config.max_requests))) {
            const retry_after = reset_at - now;
            try self.entries.put(key_owned, entry);
            return ratelimit.RateLimitResult.deny(config.max_requests, reset_at, retry_after);
        }

        // Increment and allow
        entry.current_count += 1;
        try self.entries.put(key_owned, entry);

        const new_estimated = weighted_previous + @as(f64, @floatFromInt(entry.current_count));
        const remaining_float = @as(f64, @floatFromInt(config.max_requests)) - new_estimated;
        const remaining: u32 = if (remaining_float > 0) @intFromFloat(remaining_float) else 0;

        return ratelimit.RateLimitResult.allow(remaining, config.max_requests, reset_at);
    }

    fn reset(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
        }
    }

    fn getRemaining(ptr: *anyopaque, key: []const u8, config: ratelimit.RateLimitConfig) anyerror!u32 {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = getTimestamp();
        const window_seconds = config.window_seconds;
        const current_window_start = now - @mod(now, window_seconds);

        if (self.entries.get(key)) |entry| {
            var current = entry.current_count;
            var previous = entry.previous_count;

            if (entry.current_window_start < current_window_start - window_seconds) {
                return config.max_requests;
            } else if (entry.current_window_start < current_window_start) {
                previous = current;
                current = 0;
            }

            const weight = calculateWeight(now, current_window_start, window_seconds);
            const weighted_previous = @as(f64, @floatFromInt(previous)) * weight;
            const estimated_count = weighted_previous + @as(f64, @floatFromInt(current));

            const remaining_float = @as(f64, @floatFromInt(config.max_requests)) - estimated_count;
            return if (remaining_float > 0) @intFromFloat(remaining_float) else 0;
        }

        return config.max_requests;
    }

    fn clear(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = ratelimit.RateLimitStore.VTable{
        .hit = hit,
        .reset = reset,
        .getRemaining = getRemaining,
        .clear = clear,
        .deinit = deinitFn,
    };
};

// Tests
test "sliding window basic" {
    const allocator = std.testing.allocator;

    const sliding_store = try SlidingWindowStore.init(allocator);
    defer sliding_store.deinit();

    var store = sliding_store.store();

    const config = ratelimit.RateLimitConfig.perMinute(5);

    // First request should succeed
    const r1 = try store.hit("test-key", config);
    try std.testing.expect(r1.allowed);

    // Use up remaining requests
    _ = try store.hit("test-key", config);
    _ = try store.hit("test-key", config);
    _ = try store.hit("test-key", config);
    const r5 = try store.hit("test-key", config);
    try std.testing.expect(r5.allowed);

    // Next request should be denied
    const r6 = try store.hit("test-key", config);
    try std.testing.expect(!r6.allowed);
}

test "sliding window reset" {
    const allocator = std.testing.allocator;

    const sliding_store = try SlidingWindowStore.init(allocator);
    defer sliding_store.deinit();

    var store = sliding_store.store();

    const config = ratelimit.RateLimitConfig.perMinute(2);

    // Use up requests
    _ = try store.hit("test-key", config);
    _ = try store.hit("test-key", config);

    // Should be denied
    const r1 = try store.hit("test-key", config);
    try std.testing.expect(!r1.allowed);

    // Reset
    try store.reset("test-key");

    // Should be allowed again
    const r2 = try store.hit("test-key", config);
    try std.testing.expect(r2.allowed);
}

test "sliding window remaining" {
    const allocator = std.testing.allocator;

    const sliding_store = try SlidingWindowStore.init(allocator);
    defer sliding_store.deinit();

    var store = sliding_store.store();

    const config = ratelimit.RateLimitConfig.perMinute(10);

    // Initially should have full limit
    const remaining1 = try store.getRemaining("test-key", config);
    try std.testing.expectEqual(@as(u32, 10), remaining1);

    // After one hit
    _ = try store.hit("test-key", config);
    const remaining2 = try store.getRemaining("test-key", config);
    try std.testing.expectEqual(@as(u32, 9), remaining2);
}
