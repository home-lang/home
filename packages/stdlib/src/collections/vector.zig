const std = @import("std");

/// Dynamic array implementation (Vec<T>)
/// Provides automatic memory management and dynamic sizing
pub fn Vector(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        capacity: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .items = &[_]T{},
                .capacity = 0,
                .allocator = allocator,
            };
        }

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
            const items = try allocator.alloc(T, capacity);
            return .{
                .items = items[0..0],
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.capacity > 0) {
                self.allocator.free(self.items.ptr[0..self.capacity]);
            }
        }

        pub fn push(self: *Self, item: T) !void {
            if (self.items.len >= self.capacity) {
                try self.grow();
            }
            self.items.ptr[self.items.len] = item;
            self.items.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.items.len == 0) return null;
            self.items.len -= 1;
            return self.items.ptr[self.items.len];
        }

        pub fn get(self: *const Self, index: usize) ?T {
            if (index >= self.items.len) return null;
            return self.items[index];
        }

        pub fn set(self: *Self, index: usize, value: T) !void {
            if (index >= self.items.len) return error.IndexOutOfBounds;
            self.items[index] = value;
        }

        pub fn len(self: *const Self) usize {
            return self.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.items.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.items.len = 0;
        }

        pub fn contains(self: *const Self, item: T) bool {
            for (self.items) |elem| {
                if (elem == item) return true;
            }
            return false;
        }

        pub fn indexOf(self: *const Self, item: T) ?usize {
            for (self.items, 0..) |elem, i| {
                if (elem == item) return i;
            }
            return null;
        }

        pub fn remove(self: *Self, index: usize) !T {
            if (index >= self.items.len) return error.IndexOutOfBounds;
            const item = self.items[index];

            // Shift elements left
            var i = index;
            while (i < self.items.len - 1) : (i += 1) {
                self.items[i] = self.items[i + 1];
            }

            self.items.len -= 1;
            return item;
        }

        pub fn insert(self: *Self, index: usize, item: T) !void {
            if (index > self.items.len) return error.IndexOutOfBounds;

            if (self.items.len >= self.capacity) {
                try self.grow();
            }

            // Shift elements right
            var i = self.items.len;
            while (i > index) : (i -= 1) {
                self.items.ptr[i] = self.items[i - 1];
            }

            self.items.ptr[index] = item;
            self.items.len += 1;
        }

        pub fn reverse(self: *Self) void {
            if (self.items.len <= 1) return;

            var left: usize = 0;
            var right: usize = self.items.len - 1;

            while (left < right) {
                const temp = self.items[left];
                self.items[left] = self.items[right];
                self.items[right] = temp;
                left += 1;
                right -= 1;
            }
        }

        pub fn slice(self: *const Self, start: usize, end: usize) ![]const T {
            if (start > end or end > self.items.len) return error.InvalidRange;
            return self.items[start..end];
        }

        fn grow(self: *Self) !void {
            const new_capacity = if (self.capacity == 0) 8 else self.capacity * 2;
            const new_items = try self.allocator.alloc(T, new_capacity);

            if (self.items.len > 0) {
                @memcpy(new_items[0..self.items.len], self.items);
            }

            if (self.capacity > 0) {
                self.allocator.free(self.items.ptr[0..self.capacity]);
            }

            self.items = new_items[0..self.items.len];
            self.capacity = new_capacity;
        }

        pub fn clone(self: *const Self) !Self {
            var new_vec = try Self.initCapacity(self.allocator, self.capacity);
            if (self.items.len > 0) {
                @memcpy(new_vec.items.ptr[0..self.items.len], self.items);
                new_vec.items.len = self.items.len;
            }
            return new_vec;
        }

        pub fn extend(self: *Self, other: []const T) !void {
            for (other) |item| {
                try self.push(item);
            }
        }
    };
}
