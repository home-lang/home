// HashMap Implementation for Home Language
// Based on Command & Conquer Generals' Dict.h structure
// Uses open addressing with linear probing for collision resolution

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic HashMap implementation with type-safe keys and values
/// This is the foundation for INI parsing and game data structures
pub fn HashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// Entry in the hash map
        const Entry = struct {
            key: K,
            value: V,
            hash: u64,
            occupied: bool,
        };

        allocator: Allocator,
        entries: []Entry,
        count: usize,
        capacity: usize,

        /// Maximum load factor before resize (75%)
        const LOAD_FACTOR = 0.75;
        /// Initial capacity
        const INITIAL_CAPACITY = 16;

        /// Initialize an empty HashMap
        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .entries = &[_]Entry{},
                .count = 0,
                .capacity = 0,
            };
        }

        /// Initialize with a specific capacity
        pub fn initWithCapacity(allocator: Allocator, capacity: usize) !Self {
            const actual_capacity = std.math.ceilPowerOfTwo(usize, capacity) catch return error.OutOfMemory;
            const entries = try allocator.alloc(Entry, actual_capacity);

            // Initialize all entries as unoccupied
            for (entries) |*entry| {
                entry.* = Entry{
                    .key = undefined,
                    .value = undefined,
                    .hash = 0,
                    .occupied = false,
                };
            }

            return Self{
                .allocator = allocator,
                .entries = entries,
                .count = 0,
                .capacity = actual_capacity,
            };
        }

        /// Clean up allocated memory
        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.entries);
            }
            self.* = undefined;
        }

        /// Hash function for the key
        fn hashKey(key: K) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, .Deep);
            return hasher.final();
        }

        /// Check if two keys are equal (handles string slices specially)
        fn keysEqual(a: K, b: K) bool {
            // Special case for []const u8 (strings)
            if (K == []const u8 or K == []u8) {
                return std.mem.eql(u8, a, b);
            }
            return std.meta.eql(a, b);
        }

        /// Find the slot for a given key (for insertion or lookup)
        fn findSlot(self: *const Self, key: K, hash: u64) usize {
            if (self.capacity == 0) return 0;

            var index = hash % self.capacity;
            var i: usize = 0;

            while (i < self.capacity) : (i += 1) {
                const entry = &self.entries[index];

                // Empty slot or matching key
                if (!entry.occupied or (entry.hash == hash and keysEqual(entry.key, key))) {
                    return index;
                }

                // Linear probing
                index = (index + 1) % self.capacity;
            }

            return index;
        }

        /// Resize the hash map to a new capacity
        fn resize(self: *Self, new_capacity: usize) !void {
            const old_entries = self.entries;
            const old_capacity = self.capacity;

            // Allocate new entries
            const new_entries = try self.allocator.alloc(Entry, new_capacity);
            for (new_entries) |*entry| {
                entry.* = Entry{
                    .key = undefined,
                    .value = undefined,
                    .hash = 0,
                    .occupied = false,
                };
            }

            // Update capacity
            self.entries = new_entries;
            self.capacity = new_capacity;
            self.count = 0;

            // Rehash all existing entries
            if (old_capacity > 0) {
                for (old_entries) |*entry| {
                    if (entry.occupied) {
                        try self.putNoResize(entry.key, entry.value, entry.hash);
                    }
                }
                self.allocator.free(old_entries);
            }
        }

        /// Insert without resizing (used during resize)
        fn putNoResize(self: *Self, key: K, value: V, hash: u64) !void {
            const index = self.findSlot(key, hash);
            const entry = &self.entries[index];

            if (!entry.occupied) {
                self.count += 1;
            }

            entry.* = Entry{
                .key = key,
                .value = value,
                .hash = hash,
                .occupied = true,
            };
        }

        /// Check if we need to resize
        fn needsResize(self: *const Self) bool {
            if (self.capacity == 0) return true;
            const load = @as(f64, @floatFromInt(self.count + 1)) / @as(f64, @floatFromInt(self.capacity));
            return load > LOAD_FACTOR;
        }

        /// Insert or update a key-value pair
        pub fn put(self: *Self, key: K, value: V) !void {
            // Resize if necessary
            if (self.needsResize()) {
                const new_capacity = if (self.capacity == 0) INITIAL_CAPACITY else self.capacity * 2;
                try self.resize(new_capacity);
            }

            const hash = hashKey(key);
            try self.putNoResize(key, value, hash);
        }

        /// Get a value by key, returns null if not found
        pub fn get(self: *const Self, key: K) ?V {
            if (self.capacity == 0) return null;

            const hash = hashKey(key);
            const index = self.findSlot(key, hash);
            const entry = &self.entries[index];

            if (entry.occupied and entry.hash == hash and keysEqual(entry.key, key)) {
                return entry.value;
            }

            return null;
        }

        /// Get a pointer to the value (allows in-place modification)
        pub fn getPtr(self: *Self, key: K) ?*V {
            if (self.capacity == 0) return null;

            const hash = hashKey(key);
            const index = self.findSlot(key, hash);
            const entry = &self.entries[index];

            if (entry.occupied and entry.hash == hash and keysEqual(entry.key, key)) {
                return &entry.value;
            }

            return null;
        }

        /// Check if a key exists
        pub fn contains(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        /// Remove a key-value pair
        pub fn remove(self: *Self, key: K) bool {
            if (self.capacity == 0) return false;

            const hash = hashKey(key);
            const index = self.findSlot(key, hash);
            const entry = &self.entries[index];

            if (entry.occupied and entry.hash == hash and keysEqual(entry.key, key)) {
                entry.occupied = false;
                self.count -= 1;
                return true;
            }

            return false;
        }

        /// Clear all entries
        pub fn clear(self: *Self) void {
            for (self.entries) |*entry| {
                entry.occupied = false;
            }
            self.count = 0;
        }

        /// Get the number of entries
        pub fn size(self: *const Self) usize {
            return self.count;
        }

        /// Check if the map is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Iterator for key-value pairs
        pub const Iterator = struct {
            map: *const Self,
            index: usize,

            pub fn next(it: *Iterator) ?struct { key: K, value: V } {
                while (it.index < it.map.capacity) {
                    const entry = &it.map.entries[it.index];
                    it.index += 1;

                    if (entry.occupied) {
                        return .{ .key = entry.key, .value = entry.value };
                    }
                }
                return null;
            }
        };

        /// Get an iterator over all key-value pairs
        pub fn iterator(self: *const Self) Iterator {
            return Iterator{
                .map = self,
                .index = 0,
            };
        }

        /// Get all keys (caller owns the memory)
        pub fn keys(self: *const Self, allocator: Allocator) ![]K {
            const result = try allocator.alloc(K, self.count);
            var i: usize = 0;

            for (self.entries) |*entry| {
                if (entry.occupied) {
                    result[i] = entry.key;
                    i += 1;
                }
            }

            return result;
        }

        /// Get all values (caller owns the memory)
        pub fn values(self: *const Self, allocator: Allocator) ![]V {
            const result = try allocator.alloc(V, self.count);
            var i: usize = 0;

            for (self.entries) |*entry| {
                if (entry.occupied) {
                    result[i] = entry.value;
                    i += 1;
                }
            }

            return result;
        }
    };
}

// ==================== Tests ====================

test "HashMap: basic operations" {
    const allocator = std.testing.allocator;
    var map = HashMap([]const u8, i32).init(allocator);
    defer map.deinit();

    // Test put and get
    try map.put("health", 100);
    try map.put("armor", 50);
    try map.put("damage", 25);

    try std.testing.expectEqual(@as(?i32, 100), map.get("health"));
    try std.testing.expectEqual(@as(?i32, 50), map.get("armor"));
    try std.testing.expectEqual(@as(?i32, 25), map.get("damage"));
    try std.testing.expectEqual(@as(?i32, null), map.get("speed"));

    // Test size
    try std.testing.expectEqual(@as(usize, 3), map.size());

    // Test contains
    try std.testing.expect(map.contains("health"));
    try std.testing.expect(!map.contains("speed"));
}

test "HashMap: update values" {
    const allocator = std.testing.allocator;
    var map = HashMap([]const u8, i32).init(allocator);
    defer map.deinit();

    try map.put("score", 100);
    try std.testing.expectEqual(@as(?i32, 100), map.get("score"));

    // Update the value
    try map.put("score", 200);
    try std.testing.expectEqual(@as(?i32, 200), map.get("score"));
    try std.testing.expectEqual(@as(usize, 1), map.size());
}

test "HashMap: remove" {
    const allocator = std.testing.allocator;
    var map = HashMap([]const u8, i32).init(allocator);
    defer map.deinit();

    try map.put("a", 1);
    try map.put("b", 2);
    try map.put("c", 3);

    try std.testing.expectEqual(@as(usize, 3), map.size());

    // Remove existing key
    try std.testing.expect(map.remove("b"));
    try std.testing.expectEqual(@as(usize, 2), map.size());
    try std.testing.expectEqual(@as(?i32, null), map.get("b"));

    // Remove non-existing key
    try std.testing.expect(!map.remove("d"));
    try std.testing.expectEqual(@as(usize, 2), map.size());
}

test "HashMap: iterator" {
    const allocator = std.testing.allocator;
    var map = HashMap([]const u8, i32).init(allocator);
    defer map.deinit();

    try map.put("one", 1);
    try map.put("two", 2);
    try map.put("three", 3);

    var sum: i32 = 0;
    var iter = map.iterator();
    while (iter.next()) |entry| {
        sum += entry.value;
    }

    try std.testing.expectEqual(@as(i32, 6), sum);
}

test "HashMap: resize" {
    const allocator = std.testing.allocator;
    var map = HashMap(i32, i32).init(allocator);
    defer map.deinit();

    // Insert many items to trigger resize
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try map.put(i, i * 2);
    }

    try std.testing.expectEqual(@as(usize, 100), map.size());

    // Verify all values are still correct
    i = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(@as(?i32, i * 2), map.get(i));
    }
}

test "HashMap: clear" {
    const allocator = std.testing.allocator;
    var map = HashMap(i32, i32).init(allocator);
    defer map.deinit();

    try map.put(1, 10);
    try map.put(2, 20);
    try map.put(3, 30);

    try std.testing.expectEqual(@as(usize, 3), map.size());

    map.clear();

    try std.testing.expectEqual(@as(usize, 0), map.size());
    try std.testing.expect(map.isEmpty());
    try std.testing.expectEqual(@as(?i32, null), map.get(1));
}
