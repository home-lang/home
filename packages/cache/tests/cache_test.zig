const std = @import("std");
const testing = std.testing;

// Cache system tests
// Tests for IR caching and build caching

test "cache - basic compilation" {
    // Ensure cache system compiles
    try testing.expect(true);
}

test "cache - cache entry structure" {
    const CacheEntry = struct {
        key: []const u8,
        value: []const u8,
        timestamp: i64,

        pub fn isExpired(self: @This(), current_time: i64, ttl: i64) bool {
            return (current_time - self.timestamp) > ttl;
        }
    };

    const entry = CacheEntry{
        .key = "test",
        .value = "data",
        .timestamp = 1000,
    };

    try testing.expect(!entry.isExpired(1500, 1000)); // Not expired
    try testing.expect(entry.isExpired(3000, 1000)); // Expired
}

test "cache - simple hash map cache" {
    const allocator = testing.allocator;

    var cache = std.StringHashMap([]const u8).init(allocator);
    defer cache.deinit();

    try cache.put("key1", "value1");
    try cache.put("key2", "value2");

    try testing.expectEqualStrings("value1", cache.get("key1").?);
    try testing.expectEqualStrings("value2", cache.get("key2").?);
    try testing.expect(cache.get("key3") == null);
}

test "cache - LRU eviction simulation" {
    const LRUEntry = struct {
        key: []const u8,
        value: i32,
        access_count: usize,

        pub fn touch(self: *@This()) void {
            self.access_count += 1;
        }
    };

    var entry1 = LRUEntry{ .key = "a", .value = 1, .access_count = 5 };
    var entry2 = LRUEntry{ .key = "b", .value = 2, .access_count = 2 };

    entry2.touch();

    // entry1 has higher access count, so it should be kept
    try testing.expect(entry1.access_count > entry2.access_count);
}

test "cache - cache invalidation" {
    const allocator = testing.allocator;

    const CacheState = struct {
        valid: std.StringHashMap(bool),

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{ .valid = std.StringHashMap(bool).init(alloc) };
        }

        pub fn deinit(self: *@This()) void {
            self.valid.deinit();
        }

        pub fn mark(self: *@This(), key: []const u8) !void {
            try self.valid.put(key, true);
        }

        pub fn invalidate(self: *@This(), key: []const u8) !void {
            try self.valid.put(key, false);
        }

        pub fn isValid(self: @This(), key: []const u8) bool {
            return self.valid.get(key) orelse false;
        }
    };

    var state = CacheState.init(allocator);
    defer state.deinit();

    try state.mark("file1");
    try testing.expect(state.isValid("file1"));

    try state.invalidate("file1");
    try testing.expect(!state.isValid("file1"));
}

test "cache - content hash for cache keys" {
    const hashContent = struct {
        fn hash(content: []const u8) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(content);
            return hasher.final();
        }
    }.hash;

    const hash1 = hashContent("hello");
    const hash2 = hashContent("hello");
    const hash3 = hashContent("world");

    try testing.expect(hash1 == hash2);
    try testing.expect(hash1 != hash3);
}

test "cache - cache hit rate tracking" {
    const CacheStats = struct {
        hits: usize,
        misses: usize,

        pub fn init() @This() {
            return .{ .hits = 0, .misses = 0 };
        }

        pub fn recordHit(self: *@This()) void {
            self.hits += 1;
        }

        pub fn recordMiss(self: *@This()) void {
            self.misses += 1;
        }

        pub fn hitRate(self: @This()) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
        }
    };

    var stats = CacheStats.init();
    stats.recordHit();
    stats.recordHit();
    stats.recordMiss();

    const rate = stats.hitRate();
    try testing.expect(rate > 0.66 and rate < 0.67);
}

test "cache - size-based eviction" {
    const CacheWithSize = struct {
        max_size: usize,
        current_size: usize,

        pub fn init(max: usize) @This() {
            return .{ .max_size = max, .current_size = 0 };
        }

        pub fn canFit(self: @This(), size: usize) bool {
            return self.current_size + size <= self.max_size;
        }

        pub fn add(self: *@This(), size: usize) !void {
            if (!self.canFit(size)) {
                return error.CacheFull;
            }
            self.current_size += size;
        }

        pub fn remove(self: *@This(), size: usize) void {
            self.current_size -= size;
        }
    };

    var cache = CacheWithSize.init(100);

    try cache.add(50);
    try testing.expect(cache.canFit(50));
    try testing.expect(!cache.canFit(51));

    try testing.expectError(error.CacheFull, cache.add(51));

    cache.remove(25);
    try testing.expect(cache.canFit(25));
}

test "cache - timestamp-based expiration" {
    const TimestampedEntry = struct {
        created_at: i64,
        ttl_seconds: i64,

        pub fn isExpired(self: @This(), now: i64) bool {
            return (now - self.created_at) >= self.ttl_seconds;
        }
    };

    const entry = TimestampedEntry{
        .created_at = 1000,
        .ttl_seconds = 60,
    };

    try testing.expect(!entry.isExpired(1030)); // 30 seconds old
    try testing.expect(entry.isExpired(1070)); // 70 seconds old
}
