const std = @import("std");

/// Hash map implementation (HashMap<K, V>)
/// Provides O(1) average case lookup, insertion, and deletion
pub fn HashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            key: K,
            value: V,
            hash: u64,
            next: ?*Entry,
        };

        const Bucket = struct {
            head: ?*Entry,
        };

        buckets: []Bucket,
        size: usize,
        capacity: usize,
        allocator: std.mem.Allocator,
        load_factor: f64,

        const DEFAULT_CAPACITY = 16;
        const MAX_LOAD_FACTOR = 0.75;

        pub fn init(allocator: std.mem.Allocator) !Self {
            return try initCapacity(allocator, DEFAULT_CAPACITY);
        }

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
            const buckets = try allocator.alloc(Bucket, capacity);
            for (buckets) |*bucket| {
                bucket.* = .{ .head = null };
            }

            return .{
                .buckets = buckets,
                .size = 0,
                .capacity = capacity,
                .allocator = allocator,
                .load_factor = 0.0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.buckets) |*bucket| {
                var current = bucket.head;
                while (current) |entry| {
                    const next = entry.next;
                    self.allocator.destroy(entry);
                    current = next;
                }
            }
            self.allocator.free(self.buckets);
        }

        fn hash(key: K) u64 {
            // Simple FNV-1a hash for demonstration
            // In production, would use proper hash function
            const bytes = std.mem.asBytes(&key);
            var h: u64 = 0xcbf29ce484222325;
            for (bytes) |byte| {
                h ^= byte;
                h *%= 0x100000001b3;
            }
            return h;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            const h = hash(key);
            const index = h % self.capacity;

            // Check if key exists
            var current = self.buckets[index].head;
            while (current) |entry| {
                if (entry.hash == h and std.meta.eql(entry.key, key)) {
                    entry.value = value;
                    return;
                }
                current = entry.next;
            }

            // Create new entry
            const entry = try self.allocator.create(Entry);
            entry.* = .{
                .key = key,
                .value = value,
                .hash = h,
                .next = self.buckets[index].head,
            };

            self.buckets[index].head = entry;
            self.size += 1;
            self.load_factor = @as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(self.capacity));

            // Rehash if load factor exceeded
            if (self.load_factor > MAX_LOAD_FACTOR) {
                try self.rehash();
            }
        }

        pub fn get(self: *const Self, key: K) ?V {
            const h = hash(key);
            const index = h % self.capacity;

            var current = self.buckets[index].head;
            while (current) |entry| {
                if (entry.hash == h and std.meta.eql(entry.key, key)) {
                    return entry.value;
                }
                current = entry.next;
            }

            return null;
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        pub fn remove(self: *Self, key: K) ?V {
            const h = hash(key);
            const index = h % self.capacity;

            var prev: ?*Entry = null;
            var current = self.buckets[index].head;

            while (current) |entry| {
                if (entry.hash == h and std.meta.eql(entry.key, key)) {
                    const value = entry.value;

                    if (prev) |p| {
                        p.next = entry.next;
                    } else {
                        self.buckets[index].head = entry.next;
                    }

                    self.allocator.destroy(entry);
                    self.size -= 1;
                    self.load_factor = @as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(self.capacity));
                    return value;
                }

                prev = entry;
                current = entry.next;
            }

            return null;
        }

        pub fn clear(self: *Self) void {
            for (self.buckets) |*bucket| {
                var current = bucket.head;
                while (current) |entry| {
                    const next = entry.next;
                    self.allocator.destroy(entry);
                    current = next;
                }
                bucket.head = null;
            }
            self.size = 0;
            self.load_factor = 0.0;
        }

        pub fn len(self: *const Self) usize {
            return self.size;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.size == 0;
        }

        fn rehash(self: *Self) !void {
            const new_capacity = self.capacity * 2;
            const new_buckets = try self.allocator.alloc(Bucket, new_capacity);

            for (new_buckets) |*bucket| {
                bucket.* = .{ .head = null };
            }

            // Reinsert all entries
            for (self.buckets) |*bucket| {
                var current = bucket.head;
                while (current) |entry| {
                    const next = entry.next;
                    const index = entry.hash % new_capacity;

                    entry.next = new_buckets[index].head;
                    new_buckets[index].head = entry;

                    current = next;
                }
            }

            self.allocator.free(self.buckets);
            self.buckets = new_buckets;
            self.capacity = new_capacity;
            self.load_factor = @as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(self.capacity));
        }

        pub const Iterator = struct {
            map: *const Self,
            bucket_index: usize,
            current: ?*Entry,

            pub fn next(self: *Iterator) ?struct { key: K, value: V } {
                while (self.bucket_index < self.map.capacity) {
                    if (self.current) |entry| {
                        self.current = entry.next;
                        return .{ .key = entry.key, .value = entry.value };
                    }

                    self.bucket_index += 1;
                    if (self.bucket_index < self.map.capacity) {
                        self.current = self.map.buckets[self.bucket_index].head;
                    }
                }

                return null;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .map = self,
                .bucket_index = 0,
                .current = if (self.capacity > 0) self.buckets[0].head else null,
            };
        }
    };
}
