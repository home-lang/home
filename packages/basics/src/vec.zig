const std = @import("std");

/// Dynamic array (vector) similar to Rust's Vec<T>
pub fn Vec(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        len: usize,
        capacity: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .items = &[_]T{},
                .len = 0,
                .capacity = 0,
                .allocator = allocator,
            };
        }

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
            const items = try allocator.alloc(T, capacity);
            return .{
                .items = items,
                .len = 0,
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.items);
            }
        }

        /// Push a value to the end
        pub fn push(self: *Self, value: T) !void {
            if (self.len >= self.capacity) {
                try self.grow();
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        /// Pop a value from the end
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }

        /// Get element at index
        pub fn get(self: *Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.items[index];
        }

        /// Set element at index
        pub fn set(self: *Self, index: usize, value: T) !void {
            if (index >= self.len) return error.IndexOutOfBounds;
            self.items[index] = value;
        }

        /// Insert at index, shifting elements right
        pub fn insert(self: *Self, index: usize, value: T) !void {
            if (index > self.len) return error.IndexOutOfBounds;

            if (self.len >= self.capacity) {
                try self.grow();
            }

            // Shift elements right
            var i = self.len;
            while (i > index) : (i -= 1) {
                self.items[i] = self.items[i - 1];
            }

            self.items[index] = value;
            self.len += 1;
        }

        /// Remove at index, shifting elements left
        pub fn remove(self: *Self, index: usize) !T {
            if (index >= self.len) return error.IndexOutOfBounds;

            const value = self.items[index];

            // Shift elements left
            var i = index;
            while (i < self.len - 1) : (i += 1) {
                self.items[i] = self.items[i + 1];
            }

            self.len -= 1;
            return value;
        }

        /// Clear all elements
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Get the length
        pub fn length(self: *Self) usize {
            return self.len;
        }

        /// Check if empty
        pub fn isEmpty(self: *Self) bool {
            return self.len == 0;
        }

        /// Reserve capacity
        pub fn reserve(self: *Self, additional: usize) !void {
            const required = self.len + additional;
            if (required <= self.capacity) return;

            const new_capacity = @max(required, self.capacity * 2);
            try self.resize(new_capacity);
        }

        /// Get a slice of the current items
        pub fn slice(self: *Self) []T {
            return self.items[0..self.len];
        }

        /// Iterate over elements
        pub fn iter(self: *Self) Iterator {
            return Iterator{
                .items = self.items,
                .len = self.len,
                .index = 0,
            };
        }

        pub const Iterator = struct {
            items: []T,
            len: usize,
            index: usize,

            pub fn next(it: *Iterator) ?T {
                if (it.index >= it.len) return null;
                const value = it.items[it.index];
                it.index += 1;
                return value;
            }
        };

        fn grow(self: *Self) !void {
            const new_capacity = if (self.capacity == 0) 8 else self.capacity * 2;
            try self.resize(new_capacity);
        }

        fn resize(self: *Self, new_capacity: usize) !void {
            const new_items = try self.allocator.alloc(T, new_capacity);

            if (self.len > 0) {
                @memcpy(new_items[0..self.len], self.items[0..self.len]);
            }

            if (self.capacity > 0) {
                self.allocator.free(self.items);
            }

            self.items = new_items;
            self.capacity = new_capacity;
        }
    };
}
