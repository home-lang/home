// Set Implementation for Home Language
// A set is a collection of unique elements with no duplicates
// Backed by a HashMap for O(1) lookups, insertions, and deletions

const std = @import("std");
const Allocator = std.mem.Allocator;
const HashMap = @import("hash_map.zig").HashMap;

/// Generic Set implementation with type-safe elements
/// Uses HashMap internally for efficient operations
pub fn Set(comptime T: type) type {
    return struct {
        const Self = @This();
        const Map = HashMap(T, void);

        map: Map,
        allocator: Allocator,

        /// Initialize an empty Set
        pub fn init(allocator: Allocator) Self {
            return Self{
                .map = Map.init(allocator),
                .allocator = allocator,
            };
        }

        /// Initialize with a specific capacity
        pub fn initWithCapacity(allocator: Allocator, capacity: usize) !Self {
            return Self{
                .map = try Map.initWithCapacity(allocator, capacity),
                .allocator = allocator,
            };
        }

        /// Clean up allocated memory
        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        /// Add an element to the set
        /// Returns true if the element was added (wasn't already present)
        pub fn add(self: *Self, element: T) !bool {
            const existed = self.map.contains(element);
            try self.map.put(element, {});
            return !existed;
        }

        /// Remove an element from the set
        /// Returns true if the element was removed (was present)
        pub fn remove(self: *Self, element: T) bool {
            return self.map.remove(element);
        }

        /// Check if an element exists in the set
        pub fn contains(self: *const Self, element: T) bool {
            return self.map.contains(element);
        }

        /// Get the number of elements in the set
        pub fn count(self: *const Self) usize {
            return self.map.count;
        }

        /// Check if the set is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.map.count == 0;
        }

        /// Remove all elements from the set
        pub fn clear(self: *Self) void {
            self.map.clear();
        }

        /// Create a new set with elements from this set and another
        /// Returns the union of both sets
        pub fn unionWith(self: *const Self, other: *const Self) !Self {
            var result = try Self.initWithCapacity(self.allocator, self.count() + other.count());
            errdefer result.deinit();

            // Add all elements from this set
            var iter = self.iterator();
            while (iter.next()) |element| {
                _ = try result.add(element);
            }

            // Add all elements from other set
            var other_iter = other.iterator();
            while (other_iter.next()) |element| {
                _ = try result.add(element);
            }

            return result;
        }

        /// Create a new set with elements common to both sets
        /// Returns the intersection of both sets
        pub fn intersectionWith(self: *const Self, other: *const Self) !Self {
            var result = Self.init(self.allocator);
            errdefer result.deinit();

            // Iterate through the smaller set for efficiency
            const smaller = if (self.count() < other.count()) self else other;
            const larger = if (self.count() < other.count()) other else self;

            var iter = smaller.iterator();
            while (iter.next()) |element| {
                if (larger.contains(element)) {
                    _ = try result.add(element);
                }
            }

            return result;
        }

        /// Create a new set with elements in this set but not in another
        /// Returns the difference of both sets
        pub fn differenceWith(self: *const Self, other: *const Self) !Self {
            var result = Self.init(self.allocator);
            errdefer result.deinit();

            var iter = self.iterator();
            while (iter.next()) |element| {
                if (!other.contains(element)) {
                    _ = try result.add(element);
                }
            }

            return result;
        }

        /// Check if this set is a subset of another
        /// Returns true if all elements of this set are in the other set
        pub fn isSubsetOf(self: *const Self, other: *const Self) bool {
            if (self.count() > other.count()) return false;

            var iter = self.iterator();
            while (iter.next()) |element| {
                if (!other.contains(element)) return false;
            }

            return true;
        }

        /// Check if this set is a superset of another
        /// Returns true if this set contains all elements of the other set
        pub fn isSupersetOf(self: *const Self, other: *const Self) bool {
            return other.isSubsetOf(self);
        }

        /// Check if this set has no elements in common with another
        /// Returns true if the sets are disjoint
        pub fn isDisjointWith(self: *const Self, other: *const Self) bool {
            const smaller = if (self.count() < other.count()) self else other;
            const larger = if (self.count() < other.count()) other else self;

            var iter = smaller.iterator();
            while (iter.next()) |element| {
                if (larger.contains(element)) return false;
            }

            return true;
        }

        /// Create an iterator over the set elements
        pub fn iterator(self: *const Self) Iterator {
            return Iterator{
                .map_iter = self.map.iterator(),
            };
        }

        /// Convert set to a slice (caller owns the memory)
        pub fn toSlice(self: *const Self) ![]T {
            const slice = try self.allocator.alloc(T, self.count());
            var iter = self.iterator();
            var i: usize = 0;
            while (iter.next()) |element| {
                slice[i] = element;
                i += 1;
            }
            return slice;
        }

        /// Iterator over set elements
        pub const Iterator = struct {
            map_iter: Map.Iterator,

            pub fn next(self: *Iterator) ?T {
                if (self.map_iter.next()) |entry| {
                    return entry.key;
                }
                return null;
            }
        };
    };
}

// ==================== Tests ====================

test "Set - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var set = Set(i32).init(allocator);
    defer set.deinit();

    // Test empty set
    try testing.expect(set.isEmpty());
    try testing.expectEqual(@as(usize, 0), set.count());
    try testing.expect(!set.contains(1));

    // Test add
    try testing.expect(try set.add(1));
    try testing.expect(!set.isEmpty());
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expect(set.contains(1));

    // Test duplicate add
    try testing.expect(!try set.add(1));
    try testing.expectEqual(@as(usize, 1), set.count());

    // Test multiple adds
    try testing.expect(try set.add(2));
    try testing.expect(try set.add(3));
    try testing.expectEqual(@as(usize, 3), set.count());

    // Test remove
    try testing.expect(set.remove(2));
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expect(!set.contains(2));

    // Test remove non-existent
    try testing.expect(!set.remove(99));
}

test "Set - union" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var set1 = Set(i32).init(allocator);
    defer set1.deinit();
    var set2 = Set(i32).init(allocator);
    defer set2.deinit();

    _ = try set1.add(1);
    _ = try set1.add(2);
    _ = try set1.add(3);

    _ = try set2.add(3);
    _ = try set2.add(4);
    _ = try set2.add(5);

    var result = try set1.unionWith(&set2);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.count());
    try testing.expect(result.contains(1));
    try testing.expect(result.contains(2));
    try testing.expect(result.contains(3));
    try testing.expect(result.contains(4));
    try testing.expect(result.contains(5));
}

test "Set - intersection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var set1 = Set(i32).init(allocator);
    defer set1.deinit();
    var set2 = Set(i32).init(allocator);
    defer set2.deinit();

    _ = try set1.add(1);
    _ = try set1.add(2);
    _ = try set1.add(3);

    _ = try set2.add(2);
    _ = try set2.add(3);
    _ = try set2.add(4);

    var result = try set1.intersectionWith(&set2);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.count());
    try testing.expect(result.contains(2));
    try testing.expect(result.contains(3));
    try testing.expect(!result.contains(1));
    try testing.expect(!result.contains(4));
}

test "Set - difference" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var set1 = Set(i32).init(allocator);
    defer set1.deinit();
    var set2 = Set(i32).init(allocator);
    defer set2.deinit();

    _ = try set1.add(1);
    _ = try set1.add(2);
    _ = try set1.add(3);

    _ = try set2.add(2);
    _ = try set2.add(4);

    var result = try set1.differenceWith(&set2);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.count());
    try testing.expect(result.contains(1));
    try testing.expect(result.contains(3));
    try testing.expect(!result.contains(2));
    try testing.expect(!result.contains(4));
}

test "Set - subset/superset" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var set1 = Set(i32).init(allocator);
    defer set1.deinit();
    var set2 = Set(i32).init(allocator);
    defer set2.deinit();

    _ = try set1.add(1);
    _ = try set1.add(2);

    _ = try set2.add(1);
    _ = try set2.add(2);
    _ = try set2.add(3);

    try testing.expect(set1.isSubsetOf(&set2));
    try testing.expect(!set2.isSubsetOf(&set1));
    try testing.expect(set2.isSupersetOf(&set1));
    try testing.expect(!set1.isSupersetOf(&set2));
}

test "Set - disjoint" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var set1 = Set(i32).init(allocator);
    defer set1.deinit();
    var set2 = Set(i32).init(allocator);
    defer set2.deinit();

    _ = try set1.add(1);
    _ = try set1.add(2);

    _ = try set2.add(3);
    _ = try set2.add(4);

    try testing.expect(set1.isDisjointWith(&set2));

    _ = try set2.add(2);
    try testing.expect(!set1.isDisjointWith(&set2));
}

test "Set - iterator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var set = Set(i32).init(allocator);
    defer set.deinit();

    _ = try set.add(1);
    _ = try set.add(2);
    _ = try set.add(3);

    var count: usize = 0;
    var iter = set.iterator();
    while (iter.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}
