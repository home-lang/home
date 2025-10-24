const std = @import("std");

/// HashMap similar to Rust's HashMap<K, V>
pub fn HashMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            key: K,
            value: V,
            occupied: bool,
        };

        entries: []Entry,
        len: usize,
        capacity: usize,
        allocator: std.mem.Allocator,

        const INITIAL_CAPACITY = 16;
        const LOAD_FACTOR = 0.75;

        pub fn init(allocator: std.mem.Allocator) !Self {
            const entries = try allocator.alloc(Entry, INITIAL_CAPACITY);
            for (entries) |*entry| {
                entry.occupied = false;
            }

            return .{
                .entries = entries,
                .len = 0,
                .capacity = INITIAL_CAPACITY,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.entries);
        }

        /// Insert or update a key-value pair
        pub fn insert(self: *Self, key: K, value: V) !void {
            // Check load factor and resize if needed
            const load = @as(f64, @floatFromInt(self.len + 1)) / @as(f64, @floatFromInt(self.capacity));
            if (load > LOAD_FACTOR) {
                try self.resize();
            }

            const index = self.findSlot(key);
            if (!self.entries[index].occupied) {
                self.len += 1;
            }

            self.entries[index] = .{
                .key = key,
                .value = value,
                .occupied = true,
            };
        }

        /// Get value by key
        pub fn get(self: *Self, key: K) ?V {
            const index = self.findSlot(key);
            if (self.entries[index].occupied and self.keysEqual(self.entries[index].key, key)) {
                return self.entries[index].value;
            }
            return null;
        }

        /// Remove a key-value pair
        pub fn remove(self: *Self, key: K) ?V {
            const index = self.findSlot(key);
            if (self.entries[index].occupied and self.keysEqual(self.entries[index].key, key)) {
                const value = self.entries[index].value;
                self.entries[index].occupied = false;
                self.len -= 1;
                return value;
            }
            return null;
        }

        /// Check if key exists
        pub fn contains(self: *Self, key: K) bool {
            const index = self.findSlot(key);
            return self.entries[index].occupied and self.keysEqual(self.entries[index].key, key);
        }

        /// Get the number of entries
        pub fn length(self: *Self) usize {
            return self.len;
        }

        /// Check if empty
        pub fn isEmpty(self: *Self) bool {
            return self.len == 0;
        }

        /// Clear all entries
        pub fn clear(self: *Self) void {
            for (self.entries) |*entry| {
                entry.occupied = false;
            }
            self.len = 0;
        }

        /// Iterate over key-value pairs
        pub fn iter(self: *Self) Iterator {
            return Iterator{
                .entries = self.entries,
                .index = 0,
            };
        }

        pub const Iterator = struct {
            entries: []Entry,
            index: usize,

            pub fn next(it: *Iterator) ?struct { key: K, value: V } {
                while (it.index < it.entries.len) {
                    const entry = it.entries[it.index];
                    it.index += 1;
                    if (entry.occupied) {
                        return .{ .key = entry.key, .value = entry.value };
                    }
                }
                return null;
            }
        };

        fn findSlot(self: *Self, key: K) usize {
            var hash = self.hashKey(key);
            var index = hash % self.capacity;
            var probe = 0;

            while (probe < self.capacity) : (probe += 1) {
                if (!self.entries[index].occupied or self.keysEqual(self.entries[index].key, key)) {
                    return index;
                }
                index = (index + 1) % self.capacity;
            }

            return index;
        }

        fn hashKey(self: *Self, key: K) usize {
            _ = self;
            // Simple hash for different types
            return switch (@typeInfo(K)) {
                .Int => @as(usize, @intCast(key)),
                .Pointer => |ptr_info| {
                    if (ptr_info.child == u8) {
                        // String hashing
                        const str: []const u8 = @ptrCast(key);
                        var hash: usize = 5381;
                        for (str) |c| {
                            hash = ((hash << 5) +% hash) +% c;
                        }
                        return hash;
                    }
                    return @intFromPtr(key);
                },
                else => @intFromPtr(&key),
            };
        }

        fn keysEqual(self: *Self, a: K, b: K) bool {
            _ = self;
            return switch (@typeInfo(K)) {
                .Int, .Float, .Bool => a == b,
                .Pointer => |ptr_info| {
                    if (ptr_info.child == u8) {
                        const str_a: []const u8 = @ptrCast(a);
                        const str_b: []const u8 = @ptrCast(b);
                        return std.mem.eql(u8, str_a, str_b);
                    }
                    return a == b;
                },
                else => a == b,
            };
        }

        fn resize(self: *Self) !void {
            const new_capacity = self.capacity * 2;
            const new_entries = try self.allocator.alloc(Entry, new_capacity);

            for (new_entries) |*entry| {
                entry.occupied = false;
            }

            const old_entries = self.entries;
            const old_capacity = self.capacity;

            self.entries = new_entries;
            self.capacity = new_capacity;
            self.len = 0;

            // Rehash all entries
            for (old_entries[0..old_capacity]) |entry| {
                if (entry.occupied) {
                    try self.insert(entry.key, entry.value);
                }
            }

            self.allocator.free(old_entries);
        }
    };
}
