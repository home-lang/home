const std = @import("std");
const Allocator = std.mem.Allocator;
const collection = @import("collection.zig");
const Collection = collection.Collection;

/// Lazy collection that defers execution until materialized
/// Useful for processing large datasets without creating intermediate collections
pub fn LazyCollection(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        source: Source,

        const Source = union(enum) {
            items: []const T,
            mapped: struct {
                base: *const Self,
                mapper: *const fn (T) T,
            },
            filtered: struct {
                base: *const Self,
                predicate: *const fn (T) bool,
            },
        };

        /// Create lazy collection from slice
        pub fn fromSlice(allocator: Allocator, items: []const T) Self {
            return .{
                .allocator = allocator,
                .source = .{ .items = items },
            };
        }

        /// Lazy map - doesn't execute until collect()
        pub fn map(self: *const Self, mapper: *const fn (T) T) Self {
            return .{
                .allocator = self.allocator,
                .source = .{
                    .mapped = .{
                        .base = self,
                        .mapper = mapper,
                    },
                },
            };
        }

        /// Lazy filter - doesn't execute until collect()
        pub fn filter(self: *const Self, predicate: *const fn (T) bool) Self {
            return .{
                .allocator = self.allocator,
                .source = .{
                    .filtered = .{
                        .base = self,
                        .predicate = predicate,
                    },
                },
            };
        }

        /// Materialize the lazy collection into a regular collection
        pub fn collect(self: *const Self) !Collection(T) {
            var result = Collection(T).init(self.allocator);

            // Recursively evaluate the lazy chain
            try self.evaluate(&result);

            return result;
        }

        /// Recursively evaluate lazy operations
        fn evaluate(self: *const Self, result: *Collection(T)) !void {
            switch (self.source) {
                .items => |items| {
                    for (items) |item| {
                        try result.push(item);
                    }
                },
                .mapped => |m| {
                    var temp = Collection(T).init(self.allocator);
                    defer temp.deinit();

                    try m.base.evaluate(&temp);

                    for (temp.items.items) |item| {
                        try result.push(m.mapper(item));
                    }
                },
                .filtered => |f| {
                    var temp = Collection(T).init(self.allocator);
                    defer temp.deinit();

                    try f.base.evaluate(&temp);

                    for (temp.items.items) |item| {
                        if (f.predicate(item)) {
                            try result.push(item);
                        }
                    }
                },
            }
        }

        /// Take first n items (short-circuits evaluation)
        pub fn take(self: *const Self, n: usize) !Collection(T) {
            var result = Collection(T).init(self.allocator);
            try result.items.ensureTotalCapacity(n);

            var item_count: usize = 0;
            try self.evaluateWhile(&result, &item_count, n);

            return result;
        }

        /// Helper for short-circuit evaluation
        fn evaluateWhile(self: *const Self, result: *Collection(T), item_count: *usize, limit: usize) !void {
            if (item_count.* >= limit) return;

            switch (self.source) {
                .items => |items| {
                    for (items) |item| {
                        if (item_count.* >= limit) return;
                        try result.push(item);
                        item_count.* += 1;
                    }
                },
                .mapped => |m| {
                    var temp = Collection(T).init(self.allocator);
                    defer temp.deinit();

                    var temp_count: usize = 0;
                    try m.base.evaluateWhile(&temp, &temp_count, limit);

                    for (temp.items.items) |item| {
                        if (item_count.* >= limit) return;
                        try result.push(m.mapper(item));
                        item_count.* += 1;
                    }
                },
                .filtered => |f| {
                    var temp = Collection(T).init(self.allocator);
                    defer temp.deinit();

                    // Get more items than limit to account for filtering
                    var temp_count: usize = 0;
                    try f.base.evaluateWhile(&temp, &temp_count, limit * 2);

                    for (temp.items.items) |item| {
                        if (item_count.* >= limit) return;
                        if (f.predicate(item)) {
                            try result.push(item);
                            item_count.* += 1;
                        }
                    }
                },
            }
        }

        /// Count items without materializing (if possible)
        pub fn count(self: *const Self) usize {
            switch (self.source) {
                .items => |items| return items.len,
                else => {
                    // Have to materialize to count filtered/mapped items
                    var temp = self.collect() catch return 0;
                    defer temp.deinit();
                    return temp.count();
                },
            }
        }
    };
}

/// Helper to create a lazy collection
pub fn lazy(comptime T: type, allocator: Allocator, items: []const T) LazyCollection(T) {
    return LazyCollection(T).fromSlice(allocator, items);
}
