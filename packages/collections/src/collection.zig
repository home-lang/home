const std = @import("std");
const Allocator = std.mem.Allocator;

/// A fluent, convenient wrapper for working with arrays of data.
/// Inspired by Laravel's Collection API, providing chainable methods
/// for data transformation, filtering, sorting, and aggregation.
///
/// Example:
/// ```zig
/// var collection = try Collection(i32).init(allocator);
/// try collection.push(1);
/// try collection.push(2);
/// try collection.push(3);
///
/// const doubled = try collection.map(i32, struct {
///     fn call(item: i32) i32 { return item * 2; }
/// }.call);
/// ```
pub fn Collection(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Internal storage for collection items
        items: std.ArrayList(T),

        /// Allocator used for memory management
        allocator: Allocator,

        /// Initialize an empty collection
        pub fn init(allocator: Allocator) Self {
            return .{
                .items = std.ArrayList(T).init(allocator),
                .allocator = allocator,
            };
        }

        /// Initialize collection from existing array
        pub fn fromSlice(allocator: Allocator, slice: []const T) !Self {
            var self = Self.init(allocator);
            try self.items.appendSlice(allocator, slice);
            return self;
        }

        /// Initialize collection with initial capacity
        pub fn withCapacity(allocator: Allocator, capacity: usize) !Self {
            var items = try std.ArrayList(T).initCapacity(allocator, capacity);
            return .{
                .items = items,
                .allocator = allocator,
            };
        }

        /// Free collection memory
        pub fn deinit(self: *Self) void {
            self.items.deinit();
        }

        /// Get the number of items in the collection
        pub fn count(self: *const Self) usize {
            return self.items.items.len;
        }

        /// Check if the collection is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.items.items.len == 0;
        }

        /// Check if the collection is not empty
        pub fn isNotEmpty(self: *const Self) bool {
            return self.items.items.len > 0;
        }

        /// Add an item to the end of the collection
        pub fn push(self: *Self, item: T) !void {
            try self.items.append(self.allocator, item);
        }

        /// Remove and return the last item
        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) return null;
            return self.items.pop();
        }

        /// Get item at index (returns null if out of bounds)
        pub fn get(self: *const Self, index: usize) ?T {
            if (index >= self.count()) return null;
            return self.items.items[index];
        }

        /// Get item at index or return default value
        pub fn getOr(self: *const Self, index: usize, default: T) T {
            return self.get(index) orelse default;
        }

        /// Get all items as a slice
        pub fn all(self: *const Self) []const T {
            return self.items.items;
        }

        /// Convert collection to owned slice (caller must free)
        pub fn toOwnedSlice(self: *Self) ![]T {
            return try self.items.toOwnedSlice();
        }

        /// Get first item in collection
        pub fn first(self: *const Self) ?T {
            if (self.isEmpty()) return null;
            return self.items.items[0];
        }

        /// Get first item or default
        pub fn firstOr(self: *const Self, default: T) T {
            return self.first() orelse default;
        }

        /// Get last item in collection
        pub fn last(self: *const Self) ?T {
            if (self.isEmpty()) return null;
            return self.items.items[self.count() - 1];
        }

        /// Get last item or default
        pub fn lastOr(self: *const Self, default: T) T {
            return self.last() orelse default;
        }

        /// Check if collection contains a value
        pub fn contains(self: *const Self, value: T) bool {
            for (self.items.items) |item| {
                if (std.meta.eql(item, value)) return true;
            }
            return false;
        }

        /// Clear all items from the collection
        pub fn clear(self: *Self) void {
            self.items.clearRetainingCapacity();
        }

        /// Clone the collection (deep copy)
        pub fn clone(self: *const Self) !Self {
            var new_collection = Self.init(self.allocator);
            try new_collection.items.appendSlice(self.allocator, self.items.items);
            return new_collection;
        }

        /// Reverse the collection in place
        pub fn reverse(self: *Self) void {
            std.mem.reverse(T, self.items.items);
        }

        /// Create a reversed copy of the collection
        pub fn reversed(self: *const Self) !Self {
            var new_collection = try self.clone();
            new_collection.reverse();
            return new_collection;
        }

        // ==================== Iteration Methods ====================

        /// Execute callback for each item (does not modify collection)
        pub fn each(self: *const Self, callback: fn (item: T) void) void {
            for (self.items.items) |item| {
                callback(item);
            }
        }

        /// Execute callback for each item with index
        pub fn eachWithIndex(self: *const Self, callback: fn (item: T, index: usize) void) void {
            for (self.items.items, 0..) |item, i| {
                callback(item, i);
            }
        }

        /// Map collection to new type
        pub fn map(self: *const Self, comptime U: type, callback: fn (item: T) U) !Collection(U) {
            var result = Collection(U).init(self.allocator);
            try result.items.ensureTotalCapacity(self.allocator, self.count());

            for (self.items.items) |item| {
                try result.push(callback(item));
            }

            return result;
        }

        /// Filter collection by predicate
        pub fn filter(self: *const Self, predicate: fn (item: T) bool) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (predicate(item)) {
                    try result.push(item);
                }
            }

            return result;
        }

        /// Filter and reject items matching predicate
        pub fn reject(self: *const Self, predicate: fn (item: T) bool) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (!predicate(item)) {
                    try result.push(item);
                }
            }

            return result;
        }

        /// Reduce collection to single value
        pub fn reduce(self: *const Self, comptime U: type, initial: U, callback: fn (acc: U, item: T) U) U {
            var accumulator = initial;
            for (self.items.items) |item| {
                accumulator = callback(accumulator, item);
            }
            return accumulator;
        }

        /// Find first item matching predicate
        pub fn find(self: *const Self, predicate: fn (item: T) bool) ?T {
            for (self.items.items) |item| {
                if (predicate(item)) return item;
            }
            return null;
        }

        /// Check if any item matches predicate
        pub fn some(self: *const Self, predicate: fn (item: T) bool) bool {
            for (self.items.items) |item| {
                if (predicate(item)) return true;
            }
            return false;
        }

        /// Check if all items match predicate
        pub fn every(self: *const Self, predicate: fn (item: T) bool) bool {
            for (self.items.items) |item| {
                if (!predicate(item)) return false;
            }
            return true;
        }

        /// Check if no items match predicate
        pub fn none(self: *const Self, predicate: fn (item: T) bool) bool {
            return !self.some(predicate);
        }

        // ==================== Transformation Methods ====================

        /// Take first n items
        pub fn take(self: *const Self, n: usize) !Self {
            const take_count = @min(n, self.count());
            return Self.fromSlice(self.allocator, self.items.items[0..take_count]);
        }

        /// Skip first n items
        pub fn skip(self: *const Self, n: usize) !Self {
            if (n >= self.count()) return Self.init(self.allocator);
            return Self.fromSlice(self.allocator, self.items.items[n..]);
        }

        /// Split collection into chunks of given size
        pub fn chunk(self: *const Self, size: usize) !Collection([]const T) {
            var result = Collection([]const T).init(self.allocator);

            var i: usize = 0;
            while (i < self.count()) {
                const end = @min(i + size, self.count());
                const chunk_slice = self.items.items[i..end];
                try result.push(chunk_slice);
                i = end;
            }

            return result;
        }

        /// Concatenate with another collection
        pub fn concat(self: *const Self, other: *const Self) !Self {
            var result = try self.clone();
            try result.items.appendSlice(result.allocator, other.items.items);
            return result;
        }

        /// Get unique items (requires items to be comparable)
        pub fn unique(self: *const Self) !Self {
            var result = Self.init(self.allocator);
            var seen = std.ArrayList(T).init(self.allocator);
            defer seen.deinit();

            for (self.items.items) |item| {
                var found = false;
                for (seen.items) |seen_item| {
                    if (std.meta.eql(item, seen_item)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try result.push(item);
                    try seen.append(self.allocator, item);
                }
            }

            return result;
        }

        // ==================== Utility Methods ====================

        /// Tap into the collection (for debugging/side effects)
        pub fn tap(self: *Self, callback: fn (collection: *Self) void) *Self {
            callback(self);
            return self;
        }

        /// Pipe collection through a function
        pub fn pipe(self: *const Self, comptime U: type, callback: fn (collection: *const Self) U) U {
            return callback(self);
        }

        /// Dump collection contents (debugging)
        pub fn dump(self: *const Self) void {
            std.debug.print("Collection({s}) [{d} items]:\n", .{ @typeName(T), self.count() });
            for (self.items.items, 0..) |item, i| {
                std.debug.print("  [{d}] = {any}\n", .{ i, item });
            }
        }

        /// Dump and return collection (for chaining)
        pub fn dd(self: *const Self) *const Self {
            self.dump();
            return self;
        }
    };
}

// ==================== Builder Functions ====================

/// Create a collection from an array
pub fn collect(comptime T: type, allocator: Allocator, items: []const T) !Collection(T) {
    return Collection(T).fromSlice(allocator, items);
}

/// Create a collection with a range of integers
pub fn range(allocator: Allocator, start: i64, end: i64) !Collection(i64) {
    var result = Collection(i64).init(allocator);

    if (start <= end) {
        var i = start;
        while (i <= end) : (i += 1) {
            try result.push(i);
        }
    } else {
        var i = start;
        while (i >= end) : (i -= 1) {
            try result.push(i);
        }
    }

    return result;
}

/// Create a collection by repeating a callback n times
pub fn times(comptime T: type, allocator: Allocator, n: usize, callback: fn (index: usize) T) !Collection(T) {
    var result = Collection(T).init(allocator);
    try result.items.ensureTotalCapacity(allocator, n);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        try result.push(callback(i));
    }

    return result;
}

/// Wrap a single value in a collection
pub fn wrap(comptime T: type, allocator: Allocator, value: T) !Collection(T) {
    var result = Collection(T).init(allocator);
    try result.push(value);
    return result;
}

/// Create an empty collection
pub fn empty(comptime T: type, allocator: Allocator) Collection(T) {
    return Collection(T).init(allocator);
}
