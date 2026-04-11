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

        // ----------------------------------------------------------------
        // Functional combinators
        // ----------------------------------------------------------------
        //
        // These return a *new* Vec rather than mutating in place. They use
        // the same allocator the source Vec was constructed with so the
        // ownership story is "result lives as long as you keep it; call
        // deinit when done".

        /// Apply `func` to every element and collect the results into a new Vec.
        /// `U` is the element type of the result vector. Use `mapInPlace` if
        /// the type doesn't change and you want to avoid the allocation.
        pub fn map(self: *const Self, comptime U: type, func: fn (T) U) !Vec(U) {
            var out = try Vec(U).withCapacity(self.allocator, self.len);
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                try out.push(func(self.data[i]));
            }
            return out;
        }

        /// Return a new Vec containing only the elements for which `predicate` is true.
        pub fn filter(self: *const Self, predicate: fn (T) bool) !Vec(T) {
            var out = Vec(T).new(self.allocator);
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (predicate(self.data[i])) try out.push(self.data[i]);
            }
            return out;
        }

        /// Left fold: apply `func(acc, element)` repeatedly, starting from `init`.
        /// Mirrors Rust's `Iterator::fold`. Returns the final accumulator.
        pub fn fold(self: *const Self, comptime Acc: type, init: Acc, func: fn (Acc, T) Acc) Acc {
            var acc = init;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                acc = func(acc, self.data[i]);
            }
            return acc;
        }

        /// Sum the elements; only valid for numeric T. Implemented in terms of
        /// `fold` to demonstrate composability.
        pub fn sum(self: *const Self) T {
            return self.fold(T, 0, struct {
                fn add(a: T, b: T) T {
                    return a + b;
                }
            }.add);
        }

        /// True if any element matches the predicate.
        pub fn any(self: *const Self, predicate: fn (T) bool) bool {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (predicate(self.data[i])) return true;
            }
            return false;
        }

        /// True if every element matches the predicate. Vacuously true on empty.
        pub fn all(self: *const Self, predicate: fn (T) bool) bool {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (!predicate(self.data[i])) return false;
            }
            return true;
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

// =================================================================================
//                            COMBINATOR TESTS
// =================================================================================

test "Vec.map type-preserving" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var v = Vec(i32).new(allocator);
    defer v.deinit();
    try v.push(1);
    try v.push(2);
    try v.push(3);

    var doubled = try v.map(i32, struct {
        fn dbl(x: i32) i32 {
            return x * 2;
        }
    }.dbl);
    defer doubled.deinit();

    try testing.expectEqual(@as(usize, 3), doubled.length());
    try testing.expectEqual(@as(?i32, 2), doubled.get(0));
    try testing.expectEqual(@as(?i32, 4), doubled.get(1));
    try testing.expectEqual(@as(?i32, 6), doubled.get(2));
}

test "Vec.map type-changing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var v = Vec(i32).new(allocator);
    defer v.deinit();
    try v.push(0);
    try v.push(5);
    try v.push(-3);

    var as_bool = try v.map(bool, struct {
        fn nonzero(x: i32) bool {
            return x != 0;
        }
    }.nonzero);
    defer as_bool.deinit();

    try testing.expectEqual(@as(?bool, false), as_bool.get(0));
    try testing.expectEqual(@as(?bool, true), as_bool.get(1));
    try testing.expectEqual(@as(?bool, true), as_bool.get(2));
}

test "Vec.filter" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var v = Vec(i32).new(allocator);
    defer v.deinit();
    var i: i32 = 1;
    while (i <= 6) : (i += 1) try v.push(i);

    var evens = try v.filter(struct {
        fn even(x: i32) bool {
            return @rem(x, 2) == 0;
        }
    }.even);
    defer evens.deinit();

    try testing.expectEqual(@as(usize, 3), evens.length());
    try testing.expectEqual(@as(?i32, 2), evens.get(0));
    try testing.expectEqual(@as(?i32, 4), evens.get(1));
    try testing.expectEqual(@as(?i32, 6), evens.get(2));
}

test "Vec.fold sum and product" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var v = Vec(i32).new(allocator);
    defer v.deinit();
    try v.push(1);
    try v.push(2);
    try v.push(3);
    try v.push(4);

    const total = v.fold(i32, 0, struct {
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
    }.add);
    try testing.expectEqual(@as(i32, 10), total);

    const product = v.fold(i32, 1, struct {
        fn mul(a: i32, b: i32) i32 {
            return a * b;
        }
    }.mul);
    try testing.expectEqual(@as(i32, 24), product);
}

test "Vec.sum convenience" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var v = Vec(i32).new(allocator);
    defer v.deinit();
    try v.push(10);
    try v.push(20);
    try v.push(30);

    try testing.expectEqual(@as(i32, 60), v.sum());
}

test "Vec.any and Vec.all" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Pred = struct {
        fn isPositive(x: i32) bool {
            return x > 0;
        }
        fn isNegative(x: i32) bool {
            return x < 0;
        }
    };

    var v = Vec(i32).new(allocator);
    defer v.deinit();
    try v.push(1);
    try v.push(-2);
    try v.push(3);

    try testing.expect(v.any(Pred.isNegative));
    try testing.expect(!v.all(Pred.isPositive));
    try testing.expect(v.any(Pred.isPositive));

    // All positive: empty list is vacuously true.
    var empty = Vec(i32).new(allocator);
    defer empty.deinit();
    try testing.expect(empty.all(Pred.isPositive));
    try testing.expect(!empty.any(Pred.isPositive));
}
