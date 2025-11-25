// Vec<T> - Dynamic array implementation for Home Language
// Generic growable array with automatic reallocation

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic dynamic array (vector) with automatic growth
pub fn Vec(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        data: []T,
        len: usize,
        capacity: usize,

        /// Create a new empty Vec
        pub fn new(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .data = &[_]T{},
                .len = 0,
                .capacity = 0,
            };
        }

        /// Create a Vec with pre-allocated capacity
        pub fn withCapacity(allocator: Allocator, cap: usize) !Self {
            if (cap == 0) {
                return new(allocator);
            }

            const data = try allocator.alloc(T, cap);
            return Self{
                .allocator = allocator,
                .data = data,
                .len = 0,
                .capacity = cap,
            };
        }

        /// Free all allocated memory
        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.data);
            }
            self.* = undefined;
        }

        /// Get the number of elements
        pub fn length(self: *const Self) usize {
            return self.len;
        }

        /// Get the current capacity
        pub fn getCapacity(self: *const Self) usize {
            return self.capacity;
        }

        /// Check if the vector is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        /// Reserve additional capacity
        pub fn reserve(self: *Self, additional: usize) !void {
            const required = self.len + additional;
            if (required <= self.capacity) return;

            try self.grow(required);
        }

        /// Grow capacity to at least new_cap
        fn grow(self: *Self, new_cap: usize) !void {
            var better_cap = self.capacity;
            if (better_cap == 0) {
                better_cap = 8;
            }

            while (better_cap < new_cap) {
                better_cap = better_cap * 2;
            }

            const new_data = try self.allocator.alloc(T, better_cap);
            if (self.len > 0) {
                @memcpy(new_data[0..self.len], self.data[0..self.len]);
            }

            if (self.capacity > 0) {
                self.allocator.free(self.data);
            }

            self.data = new_data;
            self.capacity = better_cap;
        }

        /// Add an element to the end
        pub fn push(self: *Self, item: T) !void {
            if (self.len >= self.capacity) {
                try self.grow(self.len + 1);
            }

            self.data[self.len] = item;
            self.len += 1;
        }

        /// Remove and return the last element
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;

            self.len -= 1;
            return self.data[self.len];
        }

        /// Get element at index (with bounds checking)
        pub fn get(self: *const Self, index: usize) ?T {
            if (index >= self.len) return null;
            return self.data[index];
        }

        /// Set element at index (with bounds checking)
        pub fn set(self: *Self, index: usize, value: T) !void {
            if (index >= self.len) return error.IndexOutOfBounds;
            self.data[index] = value;
        }

        /// Get pointer to element at index (unsafe, no bounds check)
        pub fn getPtr(self: *Self, index: usize) *T {
            return &self.data[index];
        }

        /// Insert element at index, shifting subsequent elements right
        pub fn insert(self: *Self, index: usize, item: T) !void {
            if (index > self.len) return error.IndexOutOfBounds;

            if (self.len >= self.capacity) {
                try self.grow(self.len + 1);
            }

            // Shift elements right
            if (index < self.len) {
                var i: usize = self.len;
                while (i > index) : (i -= 1) {
                    self.data[i] = self.data[i - 1];
                }
            }

            self.data[index] = item;
            self.len += 1;
        }

        /// Remove element at index, shifting subsequent elements left
        pub fn remove(self: *Self, index: usize) !T {
            if (index >= self.len) return error.IndexOutOfBounds;

            const item = self.data[index];

            // Shift elements left
            var i: usize = index;
            while (i < self.len - 1) : (i += 1) {
                self.data[i] = self.data[i + 1];
            }

            self.len -= 1;
            return item;
        }

        /// Remove all elements
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Truncate to specified length
        pub fn truncate(self: *Self, new_len: usize) void {
            if (new_len < self.len) {
                self.len = new_len;
            }
        }

        /// Extend from a slice
        pub fn extendFromSlice(self: *Self, slice: []const T) !void {
            if (slice.len == 0) return;

            try self.reserve(slice.len);

            @memcpy(self.data[self.len..][0..slice.len], slice);
            self.len += slice.len;
        }

        /// Get a slice of all elements
        pub fn items(self: *const Self) []const T {
            return self.data[0..self.len];
        }

        /// Get a mutable slice of all elements
        pub fn itemsMut(self: *Self) []T {
            return self.data[0..self.len];
        }

        /// Iterator for Vec
        pub const Iterator = struct {
            vec: *const Self,
            index: usize,

            pub fn next(it: *Iterator) ?T {
                if (it.index >= it.vec.len) return null;

                const item = it.vec.data[it.index];
                it.index += 1;
                return item;
            }
        };

        /// Get an iterator
        pub fn iterator(self: *const Self) Iterator {
            return Iterator{
                .vec = self,
                .index = 0,
            };
        }
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "Vec - new and basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    try testing.expectEqual(@as(usize, 0), vec.length());
    try testing.expect(vec.isEmpty());
    try testing.expectEqual(@as(usize, 0), vec.getCapacity());
}

test "Vec - withCapacity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = try Vec(i32).withCapacity(allocator, 10);
    defer vec.deinit();

    try testing.expectEqual(@as(usize, 0), vec.length());
    try testing.expectEqual(@as(usize, 10), vec.getCapacity());
    try testing.expect(vec.isEmpty());
}

test "Vec - push and pop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);
    try vec.push(3);

    try testing.expectEqual(@as(usize, 3), vec.length());
    try testing.expectEqual(@as(?i32, 3), vec.pop());
    try testing.expectEqual(@as(?i32, 2), vec.pop());
    try testing.expectEqual(@as(?i32, 1), vec.pop());
    try testing.expectEqual(@as(?i32, null), vec.pop());
}

test "Vec - get and set" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    try vec.push(10);
    try vec.push(20);
    try vec.push(30);

    try testing.expectEqual(@as(?i32, 10), vec.get(0));
    try testing.expectEqual(@as(?i32, 20), vec.get(1));
    try testing.expectEqual(@as(?i32, 30), vec.get(2));
    try testing.expectEqual(@as(?i32, null), vec.get(3));

    try vec.set(1, 25);
    try testing.expectEqual(@as(?i32, 25), vec.get(1));
}

test "Vec - insert and remove" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(3);
    try vec.insert(1, 2);

    try testing.expectEqual(@as(usize, 3), vec.length());
    try testing.expectEqual(@as(?i32, 1), vec.get(0));
    try testing.expectEqual(@as(?i32, 2), vec.get(1));
    try testing.expectEqual(@as(?i32, 3), vec.get(2));

    const removed = try vec.remove(1);
    try testing.expectEqual(@as(i32, 2), removed);
    try testing.expectEqual(@as(usize, 2), vec.length());
    try testing.expectEqual(@as(?i32, 1), vec.get(0));
    try testing.expectEqual(@as(?i32, 3), vec.get(1));
}

test "Vec - clear and truncate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);
    try vec.push(3);
    try vec.push(4);
    try vec.push(5);

    vec.truncate(3);
    try testing.expectEqual(@as(usize, 3), vec.length());

    vec.clear();
    try testing.expectEqual(@as(usize, 0), vec.length());
    try testing.expect(vec.isEmpty());
}

test "Vec - extendFromSlice" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);

    const slice = [_]i32{ 3, 4, 5 };
    try vec.extendFromSlice(&slice);

    try testing.expectEqual(@as(usize, 5), vec.length());
    try testing.expectEqual(@as(?i32, 1), vec.get(0));
    try testing.expectEqual(@as(?i32, 5), vec.get(4));
}

test "Vec - reserve" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    try vec.reserve(100);
    try testing.expect(vec.getCapacity() >= 100);
    try testing.expectEqual(@as(usize, 0), vec.length());
}

test "Vec - iterator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);
    try vec.push(3);

    var iter = vec.iterator();
    try testing.expectEqual(@as(?i32, 1), iter.next());
    try testing.expectEqual(@as(?i32, 2), iter.next());
    try testing.expectEqual(@as(?i32, 3), iter.next());
    try testing.expectEqual(@as(?i32, null), iter.next());
}

test "Vec - automatic growth" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).new(allocator);
    defer vec.deinit();

    // Push many elements to test automatic growth
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try vec.push(i);
    }

    try testing.expectEqual(@as(usize, 100), vec.length());
    try testing.expect(vec.getCapacity() >= 100);

    // Verify all elements
    i = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(@as(?i32, i), vec.get(@intCast(i)));
    }
}
