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

        /// Get the capacity
        pub fn getCapacity(self: *Self) usize {
            return self.capacity;
        }

        /// Check if empty
        pub fn isEmpty(self: *Self) bool {
            return self.len == 0;
        }

        /// Truncate to specified length
        pub fn truncate(self: *Self, new_len: usize) void {
            if (new_len < self.len) {
                self.len = new_len;
            }
        }

        /// Extend from a slice
        pub fn extendFromSlice(self: *Self, items: []const T) !void {
            if (items.len == 0) return;

            const required = self.len + items.len;
            if (required > self.capacity) {
                const new_capacity = @max(required, self.capacity * 2);
                try self.resize(new_capacity);
            }

            @memcpy(self.items[self.len..self.len + items.len], items);
            self.len += items.len;
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

// =================================================================================
//                                    TESTS
// =================================================================================

test "Vec - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try testing.expectEqual(@as(usize, 0), vec.length());
    try testing.expectEqual(@as(usize, 0), vec.getCapacity());
    try testing.expect(vec.isEmpty());
}

test "Vec - push and pop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);
    try vec.push(3);

    try testing.expectEqual(@as(usize, 3), vec.length());
    try testing.expect(!vec.isEmpty());

    try testing.expectEqual(@as(i32, 3), vec.pop().?);
    try testing.expectEqual(@as(i32, 2), vec.pop().?);
    try testing.expectEqual(@as(i32, 1), vec.pop().?);
    try testing.expect(vec.pop() == null);
}

test "Vec - get and set" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.push(10);
    try vec.push(20);
    try vec.push(30);

    try testing.expectEqual(@as(i32, 10), vec.get(0).?);
    try testing.expectEqual(@as(i32, 20), vec.get(1).?);
    try testing.expectEqual(@as(i32, 30), vec.get(2).?);
    try testing.expect(vec.get(3) == null);

    try vec.set(1, 42);
    try testing.expectEqual(@as(i32, 42), vec.get(1).?);
}

test "Vec - insert and remove" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(3);
    try vec.insert(1, 2);

    try testing.expectEqual(@as(usize, 3), vec.length());
    try testing.expectEqual(@as(i32, 1), vec.get(0).?);
    try testing.expectEqual(@as(i32, 2), vec.get(1).?);
    try testing.expectEqual(@as(i32, 3), vec.get(2).?);

    const removed = try vec.remove(1);
    try testing.expectEqual(@as(i32, 2), removed);
    try testing.expectEqual(@as(usize, 2), vec.length());
    try testing.expectEqual(@as(i32, 1), vec.get(0).?);
    try testing.expectEqual(@as(i32, 3), vec.get(1).?);
}

test "Vec - clear" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);
    try vec.push(3);

    vec.clear();
    try testing.expectEqual(@as(usize, 0), vec.length());
    try testing.expect(vec.isEmpty());
}

test "Vec - truncate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);
    try vec.push(3);
    try vec.push(4);
    try vec.push(5);

    vec.truncate(3);
    try testing.expectEqual(@as(usize, 3), vec.length());
    try testing.expectEqual(@as(i32, 1), vec.get(0).?);
    try testing.expectEqual(@as(i32, 2), vec.get(1).?);
    try testing.expectEqual(@as(i32, 3), vec.get(2).?);
}

test "Vec - extendFromSlice" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);

    const slice = [_]i32{ 3, 4, 5 };
    try vec.extendFromSlice(&slice);

    try testing.expectEqual(@as(usize, 5), vec.length());
    try testing.expectEqual(@as(i32, 1), vec.get(0).?);
    try testing.expectEqual(@as(i32, 2), vec.get(1).?);
    try testing.expectEqual(@as(i32, 3), vec.get(2).?);
    try testing.expectEqual(@as(i32, 4), vec.get(3).?);
    try testing.expectEqual(@as(i32, 5), vec.get(4).?);
}

test "Vec - reserve capacity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.reserve(100);
    try testing.expect(vec.getCapacity() >= 100);

    try vec.push(1);
    try testing.expectEqual(@as(usize, 1), vec.length());
}

test "Vec - automatic growth" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    // Push many elements to trigger growth
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try vec.push(i);
    }

    try testing.expectEqual(@as(usize, 100), vec.length());
    try testing.expect(vec.getCapacity() >= 100);

    // Verify all elements
    i = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(i, vec.get(@intCast(i)).?);
    }
}

test "Vec - iterator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.push(10);
    try vec.push(20);
    try vec.push(30);

    var it = vec.iter();
    try testing.expectEqual(@as(i32, 10), it.next().?);
    try testing.expectEqual(@as(i32, 20), it.next().?);
    try testing.expectEqual(@as(i32, 30), it.next().?);
    try testing.expect(it.next() == null);
}

test "Vec - slice" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = Vec(i32).init(allocator);
    defer vec.deinit();

    try vec.push(1);
    try vec.push(2);
    try vec.push(3);

    const s = vec.slice();
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(i32, 1), s[0]);
    try testing.expectEqual(@as(i32, 2), s[1]);
    try testing.expectEqual(@as(i32, 3), s[2]);
}

test "Vec - with capacity" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var vec = try Vec(i32).initCapacity(allocator, 50);
    defer vec.deinit();

    try testing.expectEqual(@as(usize, 50), vec.getCapacity());
    try testing.expectEqual(@as(usize, 0), vec.length());

    try vec.push(42);
    try testing.expectEqual(@as(usize, 1), vec.length());
    try testing.expectEqual(@as(i32, 42), vec.get(0).?);
}
