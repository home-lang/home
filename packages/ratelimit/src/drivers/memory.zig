const std = @import("std");
const posix = std.posix;
const ratelimit = @import("../ratelimit.zig");

/// Helper to get current timestamp
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// In-memory rate limit store using fixed window
pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),
    mutex: std.Thread.Mutex,

    const Self = @This();

    const Entry = struct {
        count: u32,
        window_start: i64,
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
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

    fn hit(ptr: *anyopaque, key: []const u8, config: ratelimit.RateLimitConfig) anyerror!ratelimit.RateLimitResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = getTimestamp();
        const window_start = now - @mod(now, config.window_seconds);
        const reset_at = window_start + config.window_seconds;

        // Get or create entry
        if (self.entries.get(key)) |entry| {
            // Check if we're in a new window
            if (entry.window_start < window_start) {
                // New window, reset count
                const new_entry = Entry{ .count = 1, .window_start = window_start };
                try self.entries.put(try self.allocator.dupe(u8, key), new_entry);
                return ratelimit.RateLimitResult.allow(config.max_requests - 1, config.max_requests, reset_at);
            }

            // Same window, check limit
            if (entry.count >= config.max_requests) {
                const retry_after = reset_at - now;
                return ratelimit.RateLimitResult.deny(config.max_requests, reset_at, retry_after);
            }

            // Increment count
            var updated = entry;
            updated.count += 1;
            try self.entries.put(try self.allocator.dupe(u8, key), updated);

            const remaining = config.max_requests - updated.count;
            return ratelimit.RateLimitResult.allow(remaining, config.max_requests, reset_at);
        }

        // First request
        const new_key = try self.allocator.dupe(u8, key);
        try self.entries.put(new_key, Entry{ .count = 1, .window_start = window_start });
        return ratelimit.RateLimitResult.allow(config.max_requests - 1, config.max_requests, reset_at);
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
        const window_start = now - @mod(now, config.window_seconds);

        if (self.entries.get(key)) |entry| {
            if (entry.window_start >= window_start) {
                if (entry.count >= config.max_requests) return 0;
                return config.max_requests - entry.count;
            }
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
test "memory store basic" {
    const allocator = std.testing.allocator;

    const mem_store = try MemoryStore.init(allocator);
    defer mem_store.deinit();

    var store = mem_store.store();

    const config = ratelimit.RateLimitConfig.perMinute(5);

    // First request should succeed
    const r1 = try store.hit("test-key", config);
    try std.testing.expect(r1.allowed);
    try std.testing.expectEqual(@as(u32, 4), r1.remaining);

    // Use up remaining requests
    _ = try store.hit("test-key", config);
    _ = try store.hit("test-key", config);
    _ = try store.hit("test-key", config);
    const r5 = try store.hit("test-key", config);
    try std.testing.expect(r5.allowed);
    try std.testing.expectEqual(@as(u32, 0), r5.remaining);

    // Next request should be denied
    const r6 = try store.hit("test-key", config);
    try std.testing.expect(!r6.allowed);
    try std.testing.expect(r6.retry_after != null);
}

test "memory store reset" {
    const allocator = std.testing.allocator;

    const mem_store = try MemoryStore.init(allocator);
    defer mem_store.deinit();

    var store = mem_store.store();

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

test "memory store different keys" {
    const allocator = std.testing.allocator;

    const mem_store = try MemoryStore.init(allocator);
    defer mem_store.deinit();

    var store = mem_store.store();

    const config = ratelimit.RateLimitConfig.perMinute(1);

    // Key 1 uses its limit
    const r1 = try store.hit("key1", config);
    try std.testing.expect(r1.allowed);

    const r2 = try store.hit("key1", config);
    try std.testing.expect(!r2.allowed);

    // Key 2 should still have its own limit
    const r3 = try store.hit("key2", config);
    try std.testing.expect(r3.allowed);
}
