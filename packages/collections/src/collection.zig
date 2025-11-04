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
        const ArrayList = std.array_list.AlignedManaged(T, null);

        /// Internal storage for collection items
        items: ArrayList,

        /// Allocator used for memory management
        allocator: Allocator,

        /// Initialize an empty collection
        pub fn init(allocator: Allocator) Self {
            return .{
                .items = ArrayList.init(allocator),
                .allocator = allocator,
            };
        }

        /// Initialize collection from existing array
        pub fn fromSlice(allocator: Allocator, items_slice: []const T) !Self {
            var self = Self.init(allocator);
            try self.items.appendSlice(items_slice);
            return self;
        }

        /// Initialize collection with initial capacity
        pub fn withCapacity(allocator: Allocator, capacity: usize) !Self {
            const items = try ArrayList.initCapacity(allocator, capacity);
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
            try self.items.append(item);
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
            try new_collection.items.appendSlice(self.items.items);
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
            try result.items.ensureTotalCapacity(self.count());

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
            try result.items.appendSlice(other.items.items);
            return result;
        }

        /// Get unique items (requires items to be comparable)
        pub fn unique(self: *const Self) !Self {
            var result = Self.init(self.allocator);
            var seen = ArrayList.init(self.allocator);
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
                    try seen.append(item);
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

        // ==================== Sorting Methods ====================

        /// Sort collection in ascending order (requires T to be orderable)
        pub fn sort(self: *Self) void {
            std.mem.sort(T, self.items.items, {}, struct {
                fn lessThan(_: void, a: T, b: T) bool {
                    return a < b;
                }
            }.lessThan);
        }

        /// Sort collection in descending order
        pub fn sortDesc(self: *Self) void {
            std.mem.sort(T, self.items.items, {}, struct {
                fn lessThan(_: void, a: T, b: T) bool {
                    return a > b;
                }
            }.lessThan);
        }

        /// Create a sorted copy (ascending)
        pub fn sorted(self: *const Self) !Self {
            var result = try self.clone();
            result.sort();
            return result;
        }

        /// Create a sorted copy (descending)
        pub fn sortedDesc(self: *const Self) !Self {
            var result = try self.clone();
            result.sortDesc();
            return result;
        }

        /// Shuffle collection in place (random order)
        pub fn shuffle(self: *Self, random: std.Random) void {
            if (self.count() <= 1) return;
            var i: usize = self.count() - 1;
            while (i > 0) : (i -= 1) {
                const j = random.intRangeLessThan(usize, 0, i + 1);
                std.mem.swap(T, &self.items.items[i], &self.items.items[j]);
            }
        }

        // ==================== Aggregation Methods ====================

        /// Sum all numeric values (requires T to support addition)
        pub fn sum(self: *const Self) T {
            var total: T = 0;
            for (self.items.items) |item| {
                total += item;
            }
            return total;
        }

        /// Calculate average of numeric values (returns f64)
        pub fn avg(self: *const Self) f64 {
            if (self.isEmpty()) return 0.0;
            const total = self.sum();
            return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.count()));
        }

        /// Find minimum value (requires T to be orderable)
        pub fn min(self: *const Self) ?T {
            if (self.isEmpty()) return null;
            var minimum = self.items.items[0];
            for (self.items.items[1..]) |item| {
                if (item < minimum) minimum = item;
            }
            return minimum;
        }

        /// Find maximum value (requires T to be orderable)
        pub fn max(self: *const Self) ?T {
            if (self.isEmpty()) return null;
            var maximum = self.items.items[0];
            for (self.items.items[1..]) |item| {
                if (item > maximum) maximum = item;
            }
            return maximum;
        }

        /// Find mode (most frequently occurring value)
        pub fn mode(self: *const Self) ?T {
            if (self.isEmpty()) return null;

            var freq_map = std.AutoHashMap(T, usize).init(self.allocator);
            defer freq_map.deinit();

            // Count frequencies
            for (self.items.items) |item| {
                const entry = freq_map.getOrPut(item) catch return null;
                if (entry.found_existing) {
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                }
            }

            // Find item with maximum frequency
            var max_count: usize = 0;
            var mode_value: ?T = null;

            var it = freq_map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* > max_count) {
                    max_count = entry.value_ptr.*;
                    mode_value = entry.key_ptr.*;
                }
            }

            return mode_value;
        }

        /// Find median value (requires T to be orderable)
        pub fn median(self: *const Self) ?T {
            if (self.isEmpty()) return null;

            // Create sorted copy
            const sorted_items = self.allocator.alloc(T, self.count()) catch return null;
            defer self.allocator.free(sorted_items);

            @memcpy(sorted_items, self.items.items);
            std.mem.sort(T, sorted_items, {}, struct {
                fn lessThan(_: void, a: T, b: T) bool {
                    return a < b;
                }
            }.lessThan);

            const mid = self.count() / 2;
            if (self.count() % 2 == 0) {
                // Even count - average of two middle values
                return @divTrunc(sorted_items[mid - 1] + sorted_items[mid], 2);
            } else {
                // Odd count - middle value
                return sorted_items[mid];
            }
        }

        /// Product of all values
        pub fn product(self: *const Self) T {
            if (self.isEmpty()) return 0;
            var result: T = 1;
            for (self.items.items) |item| {
                result *= item;
            }
            return result;
        }

        // ==================== Additional Transform Methods ====================

        /// Flatten a collection of collections into a single collection
        pub fn flatten(self: *const Self, comptime U: type) !Collection(U) {
            var result = Collection(U).init(self.allocator);

            for (self.items.items) |nested_items| {
                try result.items.appendSlice(nested_items);
            }

            return result;
        }

        /// Create pairs of adjacent elements ([1,2,3,4] -> [(1,2), (2,3), (3,4)])
        pub fn windows(self: *const Self, size: usize) !Collection([]const T) {
            var result = Collection([]const T).init(self.allocator);

            if (size == 0 or size > self.count()) return result;

            var i: usize = 0;
            while (i <= self.count() - size) : (i += 1) {
                const window = self.items.items[i .. i + size];
                try result.push(window);
            }

            return result;
        }

        /// Partition collection into two based on predicate [passing, failing]
        pub fn partition(self: *const Self, predicate: fn (item: T) bool) !struct { pass: Self, fail: Self } {
            var pass = Self.init(self.allocator);
            var fail = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (predicate(item)) {
                    try pass.push(item);
                } else {
                    try fail.push(item);
                }
            }

            return .{ .pass = pass, .fail = fail };
        }

        /// Zip two collections together into tuples
        pub fn zip(self: *const Self, comptime U: type, other: *const Collection(U)) !Collection(struct { T, U }) {
            const Tuple = struct { T, U };
            var result = Collection(Tuple).init(self.allocator);

            const len = @min(self.count(), other.count());
            for (0..len) |i| {
                try result.push(.{ self.items.items[i], other.items.items[i] });
            }

            return result;
        }

        /// Split collection into groups of specified size
        pub fn splitInto(self: *const Self, groups: usize) !Collection([]const T) {
            if (groups == 0) return Collection([]const T).init(self.allocator);

            const items_per_group = (self.count() + groups - 1) / groups; // Ceiling division
            return self.chunk(items_per_group);
        }

        // ==================== String Methods ====================

        /// Join collection into string with delimiter (for collections of strings/numbers)
        pub fn join(self: *const Self, allocator: Allocator, delimiter: []const u8) ![]u8 {
            if (self.isEmpty()) return allocator.dupe(u8, "");

            var result = std.array_list.AlignedManaged(u8, null).init(allocator);
            errdefer result.deinit();

            for (self.items.items, 0..) |item, i| {
                if (i > 0) {
                    try result.appendSlice(delimiter);
                }

                // Convert item to string
                const str = try std.fmt.allocPrint(allocator, "{any}", .{item});
                defer allocator.free(str);
                try result.appendSlice(str);
            }

            return result.toOwnedSlice();
        }

        /// Alias for join
        pub fn implode(self: *const Self, allocator: Allocator, delimiter: []const u8) ![]u8 {
            return self.join(allocator, delimiter);
        }

        // ==================== Advanced Query Methods ====================

        /// Take items while predicate is true
        pub fn takeWhile(self: *const Self, predicate: fn (item: T) bool) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (!predicate(item)) break;
                try result.push(item);
            }

            return result;
        }

        /// Take items until predicate is true
        pub fn takeUntil(self: *const Self, predicate: fn (item: T) bool) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (predicate(item)) break;
                try result.push(item);
            }

            return result;
        }

        /// Skip items while predicate is true
        pub fn skipWhile(self: *const Self, predicate: fn (item: T) bool) !Self {
            var result = Self.init(self.allocator);
            var skipping = true;

            for (self.items.items) |item| {
                if (skipping and predicate(item)) continue;
                skipping = false;
                try result.push(item);
            }

            return result;
        }

        /// Skip items until predicate is true
        pub fn skipUntil(self: *const Self, predicate: fn (item: T) bool) !Self {
            var result = Self.init(self.allocator);
            var skipping = true;

            for (self.items.items) |item| {
                if (skipping and !predicate(item)) continue;
                skipping = false;
                try result.push(item);
            }

            return result;
        }

        /// Count items matching predicate
        pub fn countBy(self: *const Self, predicate: fn (item: T) bool) usize {
            var total: usize = 0;
            for (self.items.items) |item| {
                if (predicate(item)) total += 1;
            }
            return total;
        }

        /// Get items at specified indices
        pub fn only(self: *const Self, indices: []const usize) !Self {
            var result = Self.init(self.allocator);

            for (indices) |idx| {
                if (idx < self.count()) {
                    try result.push(self.items.items[idx]);
                }
            }

            return result;
        }

        /// Get all items except at specified indices
        pub fn except(self: *const Self, indices: []const usize) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items, 0..) |item, i| {
                var should_skip = false;
                for (indices) |idx| {
                    if (i == idx) {
                        should_skip = true;
                        break;
                    }
                }
                if (!should_skip) {
                    try result.push(item);
                }
            }

            return result;
        }

        /// Get first n items or last n items if negative
        pub fn slice(self: *const Self, start: isize, end: isize) !Self {
            const count_i = @as(isize, @intCast(self.count()));

            var actual_start = start;
            var actual_end = end;

            // Handle negative indices
            if (actual_start < 0) actual_start = count_i + actual_start;
            if (actual_end < 0) actual_end = count_i + actual_end;

            // Clamp to valid range
            actual_start = @max(0, @min(actual_start, count_i));
            actual_end = @max(0, @min(actual_end, count_i));

            if (actual_start >= actual_end) return Self.init(self.allocator);

            const start_idx = @as(usize, @intCast(actual_start));
            const end_idx = @as(usize, @intCast(actual_end));

            return Self.fromSlice(self.allocator, self.items.items[start_idx..end_idx]);
        }

        /// Prepend item to beginning
        pub fn prepend(self: *Self, item: T) !void {
            try self.items.insert(0, item);
        }

        /// Get and remove first item
        pub fn shift(self: *Self) ?T {
            if (self.isEmpty()) return null;
            return self.items.orderedRemove(0);
        }

        /// Add item to beginning
        pub fn unshift(self: *Self, item: T) !void {
            try self.prepend(item);
        }

        /// Get nth item (1-indexed, supports negative for from end)
        pub fn nth(self: *const Self, n: isize) ?T {
            if (n == 0) return null;

            if (n > 0) {
                const idx = @as(usize, @intCast(n - 1));
                return self.get(idx);
            } else {
                const count_i = @as(isize, @intCast(self.count()));
                const idx = @as(usize, @intCast(count_i + n));
                return self.get(idx);
            }
        }

        /// Check if collection has duplicate values
        pub fn hasDuplicates(self: *const Self) bool {
            if (self.count() <= 1) return false;

            for (self.items.items, 0..) |item, i| {
                for (self.items.items[i + 1 ..]) |other| {
                    if (std.meta.eql(item, other)) return true;
                }
            }

            return false;
        }

        /// Get duplicates only
        pub fn duplicates(self: *const Self) !Self {
            var result = Self.init(self.allocator);
            var seen = ArrayList.init(self.allocator);
            defer seen.deinit();
            var added = ArrayList.init(self.allocator);
            defer added.deinit();

            for (self.items.items) |item| {
                var found_in_seen = false;
                for (seen.items) |seen_item| {
                    if (std.meta.eql(item, seen_item)) {
                        found_in_seen = true;
                        break;
                    }
                }

                if (found_in_seen) {
                    // Check if not already added
                    var already_added = false;
                    for (added.items) |added_item| {
                        if (std.meta.eql(item, added_item)) {
                            already_added = true;
                            break;
                        }
                    }
                    if (!already_added) {
                        try result.push(item);
                        try added.append(item);
                    }
                } else {
                    try seen.append(item);
                }
            }

            return result;
        }

        /// Repeat collection n times
        pub fn repeat(self: *const Self, n: usize) !Self {
            var result = Self.init(self.allocator);
            try result.items.ensureTotalCapacity(self.count() * n);

            var i: usize = 0;
            while (i < n) : (i += 1) {
                try result.items.appendSlice(self.items.items);
            }

            return result;
        }

        /// Pad collection to specified length with value
        pub fn pad(self: *const Self, length: usize, value: T) !Self {
            if (self.count() >= length) return try self.clone();

            var result = try self.clone();
            const need = length - self.count();

            var i: usize = 0;
            while (i < need) : (i += 1) {
                try result.push(value);
            }

            return result;
        }

        // ==================== Where Clause Methods ====================

        /// Filter items that are in the provided values
        pub fn whereIn(self: *const Self, values: []const T) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                for (values) |value| {
                    if (item == value) {
                        try result.push(item);
                        break;
                    }
                }
            }

            return result;
        }

        /// Filter items that are NOT in the provided values
        pub fn whereNotIn(self: *const Self, values: []const T) !Self {
            var result = Self.init(self.allocator);

            outer: for (self.items.items) |item| {
                for (values) |value| {
                    if (item == value) {
                        continue :outer;
                    }
                }
                try result.push(item);
            }

            return result;
        }

        /// Filter items between min and max (inclusive)
        pub fn whereBetween(self: *const Self, min_val: T, max_val: T) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (item >= min_val and item <= max_val) {
                    try result.push(item);
                }
            }

            return result;
        }

        /// Filter items NOT between min and max
        pub fn whereNotBetween(self: *const Self, min_val: T, max_val: T) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (item < min_val or item > max_val) {
                    try result.push(item);
                }
            }

            return result;
        }

        // ==================== Grouping Methods ====================

        /// Count occurrences of each unique value (returns frequency map)
        pub fn frequencies(self: *const Self) !std.AutoHashMap(T, usize) {
            var counts = std.AutoHashMap(T, usize).init(self.allocator);
            errdefer counts.deinit();

            for (self.items.items) |item| {
                const entry = try counts.getOrPut(item);
                if (entry.found_existing) {
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                }
            }

            return counts;
        }

        /// Group items by a callback result
        pub fn groupBy(self: *const Self, comptime K: type, callback: fn (item: T) K) !std.AutoHashMap(K, Self) {
            var groups = std.AutoHashMap(K, Self).init(self.allocator);
            errdefer {
                var it = groups.valueIterator();
                while (it.next()) |group| {
                    group.deinit();
                }
                groups.deinit();
            }

            for (self.items.items) |item| {
                const key = callback(item);
                const entry = try groups.getOrPut(key);

                if (!entry.found_existing) {
                    entry.value_ptr.* = Self.init(self.allocator);
                }

                try entry.value_ptr.push(item);
            }

            return groups;
        }

        // ==================== Extraction Methods ====================

        /// Extract a single field from each item (like pluck in Laravel)
        /// Use a callback to extract the desired field
        pub fn pluck(self: *const Self, comptime U: type, extractor: fn (item: T) U) !Collection(U) {
            return try self.map(U, extractor);
        }

        // ==================== Combination Methods ====================

        /// Merge another collection into this one (appends all items)
        pub fn merge(self: *const Self, other: *const Self) !Self {
            var result = Self.init(self.allocator);
            try result.items.ensureTotalCapacity(self.count() + other.count());

            try result.items.appendSlice(self.items.items);
            try result.items.appendSlice(other.items.items);

            return result;
        }

        /// Union of two collections (unique items from both)
        pub fn unionWith(self: *const Self, other: *const Self) !Self {
            var result = try self.clone();

            for (other.items.items) |item| {
                if (!result.contains(item)) {
                    try result.push(item);
                }
            }

            return result;
        }

        /// Intersection of two collections (items present in both)
        pub fn intersect(self: *const Self, other: *const Self) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (other.contains(item) and !result.contains(item)) {
                    try result.push(item);
                }
            }

            return result;
        }

        /// Difference (items in this collection but not in other)
        pub fn diff(self: *const Self, other: *const Self) !Self {
            var result = Self.init(self.allocator);

            for (self.items.items) |item| {
                if (!other.contains(item)) {
                    try result.push(item);
                }
            }

            return result;
        }

        /// Symmetric difference (items in either collection but not both)
        pub fn symmetricDiff(self: *const Self, other: *const Self) !Self {
            var result = Self.init(self.allocator);

            // Items in self but not in other
            for (self.items.items) |item| {
                if (!other.contains(item)) {
                    try result.push(item);
                }
            }

            // Items in other but not in self
            for (other.items.items) |item| {
                if (!self.contains(item)) {
                    try result.push(item);
                }
            }

            return result;
        }

        // ==================== Conditional Methods ====================

        /// Execute callback when condition is true, return self for chaining
        pub fn when(self: *Self, condition: bool, callback: fn (col: *Self) anyerror!void) !*Self {
            if (condition) {
                try callback(self);
            }
            return self;
        }

        /// Execute callback when condition is false, return self for chaining
        pub fn unless(self: *Self, condition: bool, callback: fn (col: *Self) anyerror!void) !*Self {
            if (!condition) {
                try callback(self);
            }
            return self;
        }

        /// Execute one of two callbacks based on condition
        pub fn whenElse(
            self: *Self,
            condition: bool,
            true_callback: fn (col: *Self) anyerror!void,
            false_callback: fn (col: *Self) anyerror!void,
        ) !*Self {
            if (condition) {
                try true_callback(self);
            } else {
                try false_callback(self);
            }
            return self;
        }

        // ==================== Higher-Order Methods ====================

        /// Map and flatten in one operation
        pub fn flatMap(self: *const Self, comptime U: type, callback: fn (item: T) []const U) !Collection(U) {
            var result = Collection(U).init(self.allocator);

            for (self.items.items) |item| {
                const mapped = callback(item);
                try result.items.appendSlice(mapped);
            }

            return result;
        }

        /// Map with index information
        pub fn mapWithIndex(self: *const Self, comptime U: type, callback: fn (item: T, index: usize) U) !Collection(U) {
            var result = Collection(U).init(self.allocator);
            try result.items.ensureTotalCapacity(self.count());

            for (self.items.items, 0..) |item, index| {
                try result.push(callback(item, index));
            }

            return result;
        }

        /// Key-Value pair for mapToDictionary
        pub fn KeyValuePair(comptime K: type, comptime V: type) type {
            return struct {
                key: K,
                value: V,
            };
        }

        /// Map to dictionary/hashmap with custom keys and values
        pub fn mapToDictionary(
            self: *const Self,
            comptime K: type,
            comptime V: type,
            callback: fn (item: T) KeyValuePair(K, V),
        ) !std.AutoHashMap(K, V) {
            var result = std.AutoHashMap(K, V).init(self.allocator);
            errdefer result.deinit();

            for (self.items.items) |item| {
                const pair = callback(item);
                try result.put(pair.key, pair.value);
            }

            return result;
        }

        /// Map and spread results (like mapSpread in Laravel)
        pub fn mapSpread(
            self: *const Self,
            comptime U: type,
            callback: fn (items: []const T) U,
        ) !U {
            return callback(self.items.items);
        }

        // ==================== Conversion Methods ====================

        /// Convert collection to JSON string (requires T to support formatting)
        /// For simple number types, uses fmt to create JSON-compatible output
        pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            var string = std.array_list.AlignedManaged(u8, null).init(allocator);
            errdefer string.deinit();

            const writer = string.writer();
            try writer.writeByte('[');

            for (self.items.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.print("{any}", .{item});
            }

            try writer.writeByte(']');
            return try string.toOwnedSlice();
        }

        /// Convert collection to pretty JSON string
        pub fn toJsonPretty(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            var string = std.array_list.AlignedManaged(u8, null).init(allocator);
            errdefer string.deinit();

            const writer = string.writer();
            try writer.writeAll("[\n");

            for (self.items.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(",\n");
                try writer.print("  {any}", .{item});
            }

            try writer.writeAll("\n]");
            return try string.toOwnedSlice();
        }

        /// Create collection from JSON string (basic implementation for numeric types)
        pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !Self {
            const parsed = try std.json.parseFromSlice([]T, allocator, json_str, .{});
            defer parsed.deinit();

            return try Self.fromSlice(allocator, parsed.value);
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
    try result.items.ensureTotalCapacity(n);

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
