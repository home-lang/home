const std = @import("std");
const testing = std.testing;
const lazy_collection = @import("lazy_collection");
const LazyCollection = lazy_collection.LazyCollection;
const lazy = lazy_collection.lazy;
const Collection = @import("collection").Collection;

test "LazyCollection: fromSlice and collect" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };

    const lzy = LazyCollection(i32).fromSlice(testing.allocator, &items);

    var result = try lzy.collect();
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.count());
    try testing.expectEqual(@as(i32, 1), result.get(0).?);
    try testing.expectEqual(@as(i32, 5), result.get(4).?);
}

test "LazyCollection: lazy map" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };

    const mapper = struct {
        fn call(n: i32) i32 {
            return n * 2;
        }
    }.call;

    const lzy = LazyCollection(i32).fromSlice(testing.allocator, &items);
    const mapped = lzy.map(&mapper);

    var result = try mapped.collect();
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.count());
    try testing.expectEqual(@as(i32, 2), result.get(0).?);
    try testing.expectEqual(@as(i32, 10), result.get(4).?);
}

test "LazyCollection: lazy filter" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    const predicate = struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call;

    const lzy = LazyCollection(i32).fromSlice(testing.allocator, &items);
    const filtered = lzy.filter(&predicate);

    var result = try filtered.collect();
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.count());
    try testing.expectEqual(@as(i32, 2), result.get(0).?);
    try testing.expectEqual(@as(i32, 10), result.get(4).?);
}

test "LazyCollection: chained operations" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    const predicate = struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call;

    const mapper = struct {
        fn call(n: i32) i32 {
            return n * 3;
        }
    }.call;

    const lzy = LazyCollection(i32).fromSlice(testing.allocator, &items);
    const filtered = lzy.filter(&predicate);
    const mapped = filtered.map(&mapper);

    var result = try mapped.collect();
    defer result.deinit();

    try testing.expectEqual(@as(usize, 5), result.count());
    try testing.expectEqual(@as(i32, 6), result.get(0).?);   // 2 * 3
    try testing.expectEqual(@as(i32, 12), result.get(1).?);  // 4 * 3
    try testing.expectEqual(@as(i32, 30), result.get(4).?);  // 10 * 3
}

test "LazyCollection: take (short-circuit)" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    const mapper = struct {
        fn call(n: i32) i32 {
            return n * 2;
        }
    }.call;

    const lzy = LazyCollection(i32).fromSlice(testing.allocator, &items);
    const mapped = lzy.map(&mapper);

    var result = try mapped.take(3);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.count());
    try testing.expectEqual(@as(i32, 2), result.get(0).?);
    try testing.expectEqual(@as(i32, 4), result.get(1).?);
    try testing.expectEqual(@as(i32, 6), result.get(2).?);
}

test "LazyCollection: count" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };

    const lzy = LazyCollection(i32).fromSlice(testing.allocator, &items);

    try testing.expectEqual(@as(usize, 5), lzy.count());
}

test "LazyCollection: helper function" {
    const items = [_]i32{ 1, 2, 3 };

    const lzy = lazy(i32, testing.allocator, &items);

    var result = try lzy.collect();
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.count());
}
