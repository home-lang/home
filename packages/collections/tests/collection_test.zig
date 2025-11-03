const std = @import("std");
const testing = std.testing;
const collection = @import("collection");
const Collection = collection.Collection;
const collect = collection.collect;
const range = collection.range;
const times = collection.times;
const wrap = collection.wrap;
const empty = collection.empty;

test "Collection: init and basic operations" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try testing.expectEqual(@as(usize, 0), col.count());
    try testing.expect(col.isEmpty());
    try testing.expect(!col.isNotEmpty());
}

test "Collection: push and pop" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    try testing.expectEqual(@as(usize, 3), col.count());
    try testing.expect(col.isNotEmpty());

    try testing.expectEqual(@as(i32, 3), col.pop().?);
    try testing.expectEqual(@as(usize, 2), col.count());
}

test "Collection: fromSlice" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(usize, 5), col.count());
    try testing.expectEqual(@as(i32, 1), col.first().?);
    try testing.expectEqual(@as(i32, 5), col.last().?);
}

test "Collection: get and getOr" {
    const items = [_]i32{ 10, 20, 30 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(i32, 10), col.get(0).?);
    try testing.expectEqual(@as(i32, 20), col.get(1).?);
    try testing.expectEqual(@as(i32, 30), col.get(2).?);
    try testing.expectEqual(@as(?i32, null), col.get(3));

    try testing.expectEqual(@as(i32, 99), col.getOr(10, 99));
}

test "Collection: first and last" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(i32, 1), col.first().?);
    try testing.expectEqual(@as(i32, 5), col.last().?);
    try testing.expectEqual(@as(i32, 1), col.firstOr(99));
    try testing.expectEqual(@as(i32, 5), col.lastOr(99));

    var empty_col = Collection(i32).init(testing.allocator);
    defer empty_col.deinit();

    try testing.expectEqual(@as(?i32, null), empty_col.first());
    try testing.expectEqual(@as(i32, 99), empty_col.firstOr(99));
}

test "Collection: contains" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expect(col.contains(3));
    try testing.expect(col.contains(1));
    try testing.expect(col.contains(5));
    try testing.expect(!col.contains(10));
}

test "Collection: clear" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    try testing.expectEqual(@as(usize, 3), col.count());
    col.clear();
    try testing.expectEqual(@as(usize, 0), col.count());
    try testing.expect(col.isEmpty());
}

test "Collection: clone" {
    const items = [_]i32{ 1, 2, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var cloned = try col.clone();
    defer cloned.deinit();

    try testing.expectEqual(col.count(), cloned.count());
    try testing.expectEqual(col.first().?, cloned.first().?);
    try testing.expectEqual(col.last().?, cloned.last().?);
}

test "Collection: reverse and reversed" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var rev = try col.reversed();
    defer rev.deinit();

    try testing.expectEqual(@as(i32, 5), rev.first().?);
    try testing.expectEqual(@as(i32, 1), rev.last().?);

    // Original unchanged
    try testing.expectEqual(@as(i32, 1), col.first().?);

    // In-place reverse
    col.reverse();
    try testing.expectEqual(@as(i32, 5), col.first().?);
}

test "Collection: each" {
    const items = [_]i32{ 1, 2, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var sum: i32 = 0;
    col.each(struct {
        fn call(item: i32) void {
            _ = item;
        }
    }.call);

    // Test with closure that captures
    const Ctx = struct {
        sum: *i32,
    };
    const ctx = Ctx{ .sum = &sum };
    _ = ctx;

    // Note: Zig doesn't have closures, so we test the basic functionality
    for (col.all()) |item| {
        sum += item;
    }
    try testing.expectEqual(@as(i32, 6), sum);
}

test "Collection: map" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var doubled = try col.map(i32, struct {
        fn call(item: i32) i32 {
            return item * 2;
        }
    }.call);
    defer doubled.deinit();

    try testing.expectEqual(@as(usize, 5), doubled.count());
    try testing.expectEqual(@as(i32, 2), doubled.first().?);
    try testing.expectEqual(@as(i32, 10), doubled.last().?);
}

test "Collection: filter" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var evens = try col.filter(struct {
        fn call(item: i32) bool {
            return @mod(item, 2) == 0;
        }
    }.call);
    defer evens.deinit();

    try testing.expectEqual(@as(usize, 5), evens.count());
    try testing.expectEqual(@as(i32, 2), evens.first().?);
    try testing.expectEqual(@as(i32, 10), evens.last().?);
}

test "Collection: reject" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var odds = try col.reject(struct {
        fn call(item: i32) bool {
            return @mod(item, 2) == 0;
        }
    }.call);
    defer odds.deinit();

    try testing.expectEqual(@as(usize, 5), odds.count());
    try testing.expectEqual(@as(i32, 1), odds.first().?);
    try testing.expectEqual(@as(i32, 9), odds.last().?);
}

test "Collection: reduce" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const sum = col.reduce(i32, 0, struct {
        fn call(acc: i32, item: i32) i32 {
            return acc + item;
        }
    }.call);

    try testing.expectEqual(@as(i32, 15), sum);

    const product = col.reduce(i32, 1, struct {
        fn call(acc: i32, item: i32) i32 {
            return acc * item;
        }
    }.call);

    try testing.expectEqual(@as(i32, 120), product);
}

test "Collection: find" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const found = col.find(struct {
        fn call(item: i32) bool {
            return item > 3;
        }
    }.call);

    try testing.expectEqual(@as(i32, 4), found.?);

    const not_found = col.find(struct {
        fn call(item: i32) bool {
            return item > 10;
        }
    }.call);

    try testing.expectEqual(@as(?i32, null), not_found);
}

test "Collection: some, every, none" {
    const items = [_]i32{ 2, 4, 6, 8, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // some
    try testing.expect(col.some(struct {
        fn call(item: i32) bool {
            return item > 5;
        }
    }.call));

    try testing.expect(!col.some(struct {
        fn call(item: i32) bool {
            return item > 20;
        }
    }.call));

    // every
    try testing.expect(col.every(struct {
        fn call(item: i32) bool {
            return @mod(item, 2) == 0;
        }
    }.call));

    try testing.expect(!col.every(struct {
        fn call(item: i32) bool {
            return item > 5;
        }
    }.call));

    // none
    try testing.expect(col.none(struct {
        fn call(item: i32) bool {
            return item > 20;
        }
    }.call));

    try testing.expect(!col.none(struct {
        fn call(item: i32) bool {
            return item == 6;
        }
    }.call));
}

test "Collection: take and skip" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var first_three = try col.take(3);
    defer first_three.deinit();

    try testing.expectEqual(@as(usize, 3), first_three.count());
    try testing.expectEqual(@as(i32, 1), first_three.first().?);
    try testing.expectEqual(@as(i32, 3), first_three.last().?);

    var skip_three = try col.skip(3);
    defer skip_three.deinit();

    try testing.expectEqual(@as(usize, 7), skip_three.count());
    try testing.expectEqual(@as(i32, 4), skip_three.first().?);
    try testing.expectEqual(@as(i32, 10), skip_three.last().?);
}

test "Collection: chunk" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var chunks = try col.chunk(3);
    defer chunks.deinit();

    try testing.expectEqual(@as(usize, 4), chunks.count());

    const first_chunk = chunks.get(0).?;
    try testing.expectEqual(@as(usize, 3), first_chunk.len);
    try testing.expectEqual(@as(i32, 1), first_chunk[0]);

    const last_chunk = chunks.get(3).?;
    try testing.expectEqual(@as(usize, 1), last_chunk.len);
    try testing.expectEqual(@as(i32, 10), last_chunk[0]);
}

test "Collection: concat" {
    const items1 = [_]i32{ 1, 2, 3 };
    var col1 = try Collection(i32).fromSlice(testing.allocator, &items1);
    defer col1.deinit();

    const items2 = [_]i32{ 4, 5, 6 };
    var col2 = try Collection(i32).fromSlice(testing.allocator, &items2);
    defer col2.deinit();

    var combined = try col1.concat(&col2);
    defer combined.deinit();

    try testing.expectEqual(@as(usize, 6), combined.count());
    try testing.expectEqual(@as(i32, 1), combined.first().?);
    try testing.expectEqual(@as(i32, 6), combined.last().?);
}

test "Collection: unique" {
    const items = [_]i32{ 1, 2, 2, 3, 3, 3, 4, 5, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var uniq = try col.unique();
    defer uniq.deinit();

    try testing.expectEqual(@as(usize, 5), uniq.count());
    try testing.expectEqual(@as(i32, 1), uniq.get(0).?);
    try testing.expectEqual(@as(i32, 5), uniq.get(4).?);
}

test "Collection: collect builder" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try collect(i32, testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(usize, 5), col.count());
    try testing.expectEqual(@as(i32, 1), col.first().?);
}

test "Collection: range builder" {
    var col = try range(testing.allocator, 1, 5);
    defer col.deinit();

    try testing.expectEqual(@as(usize, 5), col.count());
    try testing.expectEqual(@as(i64, 1), col.first().?);
    try testing.expectEqual(@as(i64, 5), col.last().?);

    // Reverse range
    var rev = try range(testing.allocator, 5, 1);
    defer rev.deinit();

    try testing.expectEqual(@as(usize, 5), rev.count());
    try testing.expectEqual(@as(i64, 5), rev.first().?);
    try testing.expectEqual(@as(i64, 1), rev.last().?);
}

test "Collection: times builder" {
    var col = try times(i32, testing.allocator, 5, struct {
        fn call(index: usize) i32 {
            return @as(i32, @intCast(index)) * 2;
        }
    }.call);
    defer col.deinit();

    try testing.expectEqual(@as(usize, 5), col.count());
    try testing.expectEqual(@as(i32, 0), col.first().?);
    try testing.expectEqual(@as(i32, 8), col.last().?);
}

test "Collection: wrap builder" {
    var col = try wrap(i32, testing.allocator, 42);
    defer col.deinit();

    try testing.expectEqual(@as(usize, 1), col.count());
    try testing.expectEqual(@as(i32, 42), col.first().?);
}

test "Collection: empty builder" {
    var col = empty(i32, testing.allocator);
    defer col.deinit();

    try testing.expectEqual(@as(usize, 0), col.count());
    try testing.expect(col.isEmpty());
}

test "Collection: method chaining" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Filter evens, double them, take first 3
    var evens = try col.filter(struct {
        fn call(item: i32) bool {
            return @mod(item, 2) == 0;
        }
    }.call);
    defer evens.deinit();

    var doubled = try evens.map(i32, struct {
        fn call(item: i32) i32 {
            return item * 2;
        }
    }.call);
    defer doubled.deinit();

    var first_three = try doubled.take(3);
    defer first_three.deinit();

    try testing.expectEqual(@as(usize, 3), first_three.count());
    try testing.expectEqual(@as(i32, 4), first_three.first().?);
    try testing.expectEqual(@as(i32, 12), first_three.last().?);
}
