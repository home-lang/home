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

test "Collection: sort and sortDesc" {
    const items = [_]i32{ 5, 2, 8, 1, 9, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    col.sort();
    try testing.expectEqual(@as(i32, 1), col.first().?);
    try testing.expectEqual(@as(i32, 9), col.last().?);

    col.sortDesc();
    try testing.expectEqual(@as(i32, 9), col.first().?);
    try testing.expectEqual(@as(i32, 1), col.last().?);
}

test "Collection: sorted and sortedDesc" {
    const items = [_]i32{ 5, 2, 8, 1, 9, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var asc = try col.sorted();
    defer asc.deinit();

    try testing.expectEqual(@as(i32, 1), asc.first().?);
    try testing.expectEqual(@as(i32, 9), asc.last().?);

    // Original unchanged
    try testing.expectEqual(@as(i32, 5), col.first().?);

    var desc = try col.sortedDesc();
    defer desc.deinit();

    try testing.expectEqual(@as(i32, 9), desc.first().?);
    try testing.expectEqual(@as(i32, 1), desc.last().?);
}

test "Collection: sum" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(i32, 15), col.sum());
}

test "Collection: avg" {
    const items = [_]i32{ 2, 4, 6, 8, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(f64, 6.0), col.avg());
}

test "Collection: min and max" {
    const items = [_]i32{ 5, 2, 8, 1, 9, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(i32, 1), col.min().?);
    try testing.expectEqual(@as(i32, 9), col.max().?);
}

test "Collection: median" {
    // Odd count
    const items_odd = [_]i32{ 1, 3, 5, 7, 9 };
    var col_odd = try Collection(i32).fromSlice(testing.allocator, &items_odd);
    defer col_odd.deinit();

    try testing.expectEqual(@as(i32, 5), col_odd.median().?);

    // Even count
    const items_even = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var col_even = try Collection(i32).fromSlice(testing.allocator, &items_even);
    defer col_even.deinit();

    try testing.expectEqual(@as(i32, 3), col_even.median().?);
}

test "Collection: product" {
    const items = [_]i32{ 2, 3, 4 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(i32, 24), col.product());
}

test "Collection: flatten" {
    const items = [_][]const i32{
        &[_]i32{ 1, 2 },
        &[_]i32{ 3, 4 },
        &[_]i32{ 5, 6 },
    };
    var col = try Collection([]const i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var flattened = try col.flatten(i32);
    defer flattened.deinit();

    try testing.expectEqual(@as(usize, 6), flattened.count());
    try testing.expectEqual(@as(i32, 1), flattened.first().?);
    try testing.expectEqual(@as(i32, 6), flattened.last().?);
}

test "Collection: windows" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var wins = try col.windows(3);
    defer wins.deinit();

    try testing.expectEqual(@as(usize, 3), wins.count());

    const first_window = wins.get(0).?;
    try testing.expectEqual(@as(usize, 3), first_window.len);
    try testing.expectEqual(@as(i32, 1), first_window[0]);
    try testing.expectEqual(@as(i32, 3), first_window[2]);
}

test "Collection: partition" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var parts = try col.partition(struct {
        fn call(item: i32) bool {
            return @mod(item, 2) == 0;
        }
    }.call);
    defer parts.pass.deinit();
    defer parts.fail.deinit();

    try testing.expectEqual(@as(usize, 5), parts.pass.count());
    try testing.expectEqual(@as(usize, 5), parts.fail.count());
    try testing.expectEqual(@as(i32, 2), parts.pass.first().?);
    try testing.expectEqual(@as(i32, 1), parts.fail.first().?);
}

test "Collection: zip" {
    const items1 = [_]i32{ 1, 2, 3 };
    var col1 = try Collection(i32).fromSlice(testing.allocator, &items1);
    defer col1.deinit();

    const items2 = [_][]const u8{ "a", "b", "c" };
    var col2 = try Collection([]const u8).fromSlice(testing.allocator, &items2);
    defer col2.deinit();

    var zipped = try col1.zip([]const u8, &col2);
    defer zipped.deinit();

    try testing.expectEqual(@as(usize, 3), zipped.count());

    const first_pair = zipped.first().?;
    try testing.expectEqual(@as(i32, 1), first_pair[0]);
    try testing.expectEqualStrings("a", first_pair[1]);
}

test "Collection: splitInto" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var groups = try col.splitInto(3);
    defer groups.deinit();

    try testing.expectEqual(@as(usize, 3), groups.count());

    // First group should have ceil(10/3) = 4 items
    const first_group = groups.get(0).?;
    try testing.expectEqual(@as(usize, 4), first_group.len);
}

test "Collection: join and implode" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const joined = try col.join(testing.allocator, ", ");
    defer testing.allocator.free(joined);

    try testing.expectEqualStrings("1, 2, 3, 4, 5", joined);

    const imploded = try col.implode(testing.allocator, "-");
    defer testing.allocator.free(imploded);

    try testing.expectEqualStrings("1-2-3-4-5", imploded);
}

test "Collection: takeWhile and takeUntil" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 1, 2 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var taken_while = try col.takeWhile(struct {
        fn call(n: i32) bool {
            return n < 4;
        }
    }.call);
    defer taken_while.deinit();

    try testing.expectEqual(@as(usize, 3), taken_while.count());
    try testing.expectEqual(@as(i32, 3), taken_while.last().?);

    var taken_until = try col.takeUntil(struct {
        fn call(n: i32) bool {
            return n == 4;
        }
    }.call);
    defer taken_until.deinit();

    try testing.expectEqual(@as(usize, 3), taken_until.count());
}

test "Collection: skipWhile and skipUntil" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var skipped_while = try col.skipWhile(struct {
        fn call(n: i32) bool {
            return n < 4;
        }
    }.call);
    defer skipped_while.deinit();

    try testing.expectEqual(@as(usize, 3), skipped_while.count());
    try testing.expectEqual(@as(i32, 4), skipped_while.first().?);

    var skipped_until = try col.skipUntil(struct {
        fn call(n: i32) bool {
            return n >= 4;
        }
    }.call);
    defer skipped_until.deinit();

    try testing.expectEqual(@as(usize, 3), skipped_until.count());
    try testing.expectEqual(@as(i32, 4), skipped_until.first().?);
}

test "Collection: countBy" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const even_count = col.countBy(struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call);

    try testing.expectEqual(@as(usize, 5), even_count);
}

test "Collection: only and except" {
    const items = [_]i32{ 10, 20, 30, 40, 50 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const indices = [_]usize{ 0, 2, 4 };
    var only_items = try col.only(&indices);
    defer only_items.deinit();

    try testing.expectEqual(@as(usize, 3), only_items.count());
    try testing.expectEqual(@as(i32, 10), only_items.get(0).?);
    try testing.expectEqual(@as(i32, 30), only_items.get(1).?);
    try testing.expectEqual(@as(i32, 50), only_items.get(2).?);

    var except_items = try col.except(&indices);
    defer except_items.deinit();

    try testing.expectEqual(@as(usize, 2), except_items.count());
    try testing.expectEqual(@as(i32, 20), except_items.get(0).?);
    try testing.expectEqual(@as(i32, 40), except_items.get(1).?);
}

test "Collection: slice" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var sliced = try col.slice(2, 5);
    defer sliced.deinit();

    try testing.expectEqual(@as(usize, 3), sliced.count());
    try testing.expectEqual(@as(i32, 3), sliced.first().?);
    try testing.expectEqual(@as(i32, 5), sliced.last().?);

    // Negative indices
    var sliced_neg = try col.slice(-3, -1);
    defer sliced_neg.deinit();

    try testing.expectEqual(@as(usize, 2), sliced_neg.count());
    try testing.expectEqual(@as(i32, 8), sliced_neg.first().?);
}

test "Collection: prepend and shift" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(2);
    try col.push(3);
    try col.prepend(1);

    try testing.expectEqual(@as(usize, 3), col.count());
    try testing.expectEqual(@as(i32, 1), col.first().?);

    const shifted = col.shift().?;
    try testing.expectEqual(@as(i32, 1), shifted);
    try testing.expectEqual(@as(usize, 2), col.count());
    try testing.expectEqual(@as(i32, 2), col.first().?);
}

test "Collection: unshift" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(3);
    try col.unshift(2);
    try col.unshift(1);

    try testing.expectEqual(@as(usize, 3), col.count());
    try testing.expectEqual(@as(i32, 1), col.first().?);
    try testing.expectEqual(@as(i32, 3), col.last().?);
}

test "Collection: nth" {
    const items = [_]i32{ 10, 20, 30, 40, 50 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expectEqual(@as(i32, 10), col.nth(1).?);
    try testing.expectEqual(@as(i32, 30), col.nth(3).?);
    try testing.expectEqual(@as(i32, 50), col.nth(-1).?);
    try testing.expectEqual(@as(i32, 40), col.nth(-2).?);
    try testing.expectEqual(@as(?i32, null), col.nth(0));
}

test "Collection: hasDuplicates" {
    const items_no_dup = [_]i32{ 1, 2, 3, 4, 5 };
    var col_no_dup = try Collection(i32).fromSlice(testing.allocator, &items_no_dup);
    defer col_no_dup.deinit();

    try testing.expect(!col_no_dup.hasDuplicates());

    const items_with_dup = [_]i32{ 1, 2, 3, 2, 4 };
    var col_with_dup = try Collection(i32).fromSlice(testing.allocator, &items_with_dup);
    defer col_with_dup.deinit();

    try testing.expect(col_with_dup.hasDuplicates());
}

test "Collection: duplicates" {
    const items = [_]i32{ 1, 2, 3, 2, 4, 3, 5, 2 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var dups = try col.duplicates();
    defer dups.deinit();

    try testing.expectEqual(@as(usize, 2), dups.count());
    try testing.expect(dups.contains(2));
    try testing.expect(dups.contains(3));
}

test "Collection: repeat" {
    const items = [_]i32{ 1, 2, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var repeated = try col.repeat(3);
    defer repeated.deinit();

    try testing.expectEqual(@as(usize, 9), repeated.count());
    try testing.expectEqual(@as(i32, 1), repeated.get(0).?);
    try testing.expectEqual(@as(i32, 1), repeated.get(3).?);
    try testing.expectEqual(@as(i32, 1), repeated.get(6).?);
}

test "Collection: pad" {
    const items = [_]i32{ 1, 2, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var padded = try col.pad(6, 0);
    defer padded.deinit();

    try testing.expectEqual(@as(usize, 6), padded.count());
    try testing.expectEqual(@as(i32, 1), padded.get(0).?);
    try testing.expectEqual(@as(i32, 0), padded.get(3).?);
    try testing.expectEqual(@as(i32, 0), padded.get(5).?);
}
// ==================== Where Clause Tests ====================

test "Collection: whereIn" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const allowed = [_]i32{ 2, 4, 6, 8 };
    var filtered = try col.whereIn(&allowed);
    defer filtered.deinit();

    try testing.expectEqual(@as(usize, 4), filtered.count());
    try testing.expectEqual(@as(i32, 2), filtered.get(0).?);
    try testing.expectEqual(@as(i32, 4), filtered.get(1).?);
    try testing.expectEqual(@as(i32, 6), filtered.get(2).?);
    try testing.expectEqual(@as(i32, 8), filtered.get(3).?);
}

test "Collection: whereNotIn" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const excluded = [_]i32{ 2, 4, 6, 8 };
    var filtered = try col.whereNotIn(&excluded);
    defer filtered.deinit();

    try testing.expectEqual(@as(usize, 6), filtered.count());
    try testing.expectEqual(@as(i32, 1), filtered.get(0).?);
    try testing.expectEqual(@as(i32, 3), filtered.get(1).?);
    try testing.expectEqual(@as(i32, 5), filtered.get(2).?);
    try testing.expectEqual(@as(i32, 7), filtered.get(3).?);
    try testing.expectEqual(@as(i32, 9), filtered.get(4).?);
    try testing.expectEqual(@as(i32, 10), filtered.get(5).?);
}

test "Collection: whereBetween" {
    const items = [_]i32{ 1, 5, 10, 15, 20, 25, 30 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var filtered = try col.whereBetween(10, 25);
    defer filtered.deinit();

    try testing.expectEqual(@as(usize, 4), filtered.count());
    try testing.expectEqual(@as(i32, 10), filtered.get(0).?);
    try testing.expectEqual(@as(i32, 15), filtered.get(1).?);
    try testing.expectEqual(@as(i32, 20), filtered.get(2).?);
    try testing.expectEqual(@as(i32, 25), filtered.get(3).?);
}

test "Collection: whereNotBetween" {
    const items = [_]i32{ 1, 5, 10, 15, 20, 25, 30 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var filtered = try col.whereNotBetween(10, 25);
    defer filtered.deinit();

    try testing.expectEqual(@as(usize, 3), filtered.count());
    try testing.expectEqual(@as(i32, 1), filtered.get(0).?);
    try testing.expectEqual(@as(i32, 5), filtered.get(1).?);
    try testing.expectEqual(@as(i32, 30), filtered.get(2).?);
}

// ==================== Grouping Tests ====================

test "Collection: frequencies" {
    const items = [_]i32{ 1, 2, 2, 3, 3, 3, 4, 4, 4, 4 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    var counts = try col.frequencies();
    defer counts.deinit();

    try testing.expectEqual(@as(usize, 1), counts.get(1).?);
    try testing.expectEqual(@as(usize, 2), counts.get(2).?);
    try testing.expectEqual(@as(usize, 3), counts.get(3).?);
    try testing.expectEqual(@as(usize, 4), counts.get(4).?);
}

test "Collection: groupBy" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Group by even/odd (0 = even, 1 = odd)
    var groups = try col.groupBy(i32, struct {
        fn call(item: i32) i32 {
            return @mod(item, 2);
        }
    }.call);
    defer {
        var it = groups.valueIterator();
        while (it.next()) |group| {
            group.deinit();
        }
        groups.deinit();
    }

    const evens = groups.get(0).?;
    const odds = groups.get(1).?;

    try testing.expectEqual(@as(usize, 5), evens.count());
    try testing.expectEqual(@as(usize, 5), odds.count());
    try testing.expectEqual(@as(i32, 2), evens.get(0).?);
    try testing.expectEqual(@as(i32, 1), odds.get(0).?);
}

// ==================== Extraction Tests ====================

test "Collection: pluck" {
    const User = struct {
        name: []const u8,
        age: i32,
    };

    const users = [_]User{
        .{ .name = "Alice", .age = 30 },
        .{ .name = "Bob", .age = 25 },
        .{ .name = "Charlie", .age = 35 },
    };

    var col = try Collection(User).fromSlice(testing.allocator, &users);
    defer col.deinit();

    // Pluck names
    var names = try col.pluck([]const u8, struct {
        fn call(user: User) []const u8 {
            return user.name;
        }
    }.call);
    defer names.deinit();

    try testing.expectEqual(@as(usize, 3), names.count());
    try testing.expectEqualStrings("Alice", names.get(0).?);
    try testing.expectEqualStrings("Bob", names.get(1).?);
    try testing.expectEqualStrings("Charlie", names.get(2).?);

    // Pluck ages
    var ages = try col.pluck(i32, struct {
        fn call(user: User) i32 {
            return user.age;
        }
    }.call);
    defer ages.deinit();

    try testing.expectEqual(@as(usize, 3), ages.count());
    try testing.expectEqual(@as(i32, 30), ages.get(0).?);
    try testing.expectEqual(@as(i32, 25), ages.get(1).?);
    try testing.expectEqual(@as(i32, 35), ages.get(2).?);
}

// ==================== Combination Tests ====================

test "Collection: merge" {
    const items1 = [_]i32{ 1, 2, 3 };
    const items2 = [_]i32{ 4, 5, 6 };

    var col1 = try Collection(i32).fromSlice(testing.allocator, &items1);
    defer col1.deinit();

    var col2 = try Collection(i32).fromSlice(testing.allocator, &items2);
    defer col2.deinit();

    var merged = try col1.merge(&col2);
    defer merged.deinit();

    try testing.expectEqual(@as(usize, 6), merged.count());
    try testing.expectEqual(@as(i32, 1), merged.get(0).?);
    try testing.expectEqual(@as(i32, 3), merged.get(2).?);
    try testing.expectEqual(@as(i32, 4), merged.get(3).?);
    try testing.expectEqual(@as(i32, 6), merged.get(5).?);
}

test "Collection: unionWith" {
    const items1 = [_]i32{ 1, 2, 3, 4 };
    const items2 = [_]i32{ 3, 4, 5, 6 };

    var col1 = try Collection(i32).fromSlice(testing.allocator, &items1);
    defer col1.deinit();

    var col2 = try Collection(i32).fromSlice(testing.allocator, &items2);
    defer col2.deinit();

    var union_result = try col1.unionWith(&col2);
    defer union_result.deinit();

    try testing.expectEqual(@as(usize, 6), union_result.count());
    try testing.expect(union_result.contains(1));
    try testing.expect(union_result.contains(2));
    try testing.expect(union_result.contains(3));
    try testing.expect(union_result.contains(4));
    try testing.expect(union_result.contains(5));
    try testing.expect(union_result.contains(6));
}

test "Collection: intersect" {
    const items1 = [_]i32{ 1, 2, 3, 4, 5 };
    const items2 = [_]i32{ 3, 4, 5, 6, 7 };

    var col1 = try Collection(i32).fromSlice(testing.allocator, &items1);
    defer col1.deinit();

    var col2 = try Collection(i32).fromSlice(testing.allocator, &items2);
    defer col2.deinit();

    var intersection = try col1.intersect(&col2);
    defer intersection.deinit();

    try testing.expectEqual(@as(usize, 3), intersection.count());
    try testing.expect(intersection.contains(3));
    try testing.expect(intersection.contains(4));
    try testing.expect(intersection.contains(5));
    try testing.expect(!intersection.contains(1));
    try testing.expect(!intersection.contains(7));
}

test "Collection: diff" {
    const items1 = [_]i32{ 1, 2, 3, 4, 5 };
    const items2 = [_]i32{ 3, 4, 5, 6, 7 };

    var col1 = try Collection(i32).fromSlice(testing.allocator, &items1);
    defer col1.deinit();

    var col2 = try Collection(i32).fromSlice(testing.allocator, &items2);
    defer col2.deinit();

    var difference = try col1.diff(&col2);
    defer difference.deinit();

    try testing.expectEqual(@as(usize, 2), difference.count());
    try testing.expect(difference.contains(1));
    try testing.expect(difference.contains(2));
    try testing.expect(!difference.contains(3));
    try testing.expect(!difference.contains(6));
}

test "Collection: symmetricDiff" {
    const items1 = [_]i32{ 1, 2, 3, 4 };
    const items2 = [_]i32{ 3, 4, 5, 6 };

    var col1 = try Collection(i32).fromSlice(testing.allocator, &items1);
    defer col1.deinit();

    var col2 = try Collection(i32).fromSlice(testing.allocator, &items2);
    defer col2.deinit();

    var sym_diff = try col1.symmetricDiff(&col2);
    defer sym_diff.deinit();

    try testing.expectEqual(@as(usize, 4), sym_diff.count());
    try testing.expect(sym_diff.contains(1));
    try testing.expect(sym_diff.contains(2));
    try testing.expect(sym_diff.contains(5));
    try testing.expect(sym_diff.contains(6));
    try testing.expect(!sym_diff.contains(3));
    try testing.expect(!sym_diff.contains(4));
}

// ==================== Mode Test ====================

test "Collection: mode" {
    const items = [_]i32{ 1, 2, 2, 3, 3, 3, 4, 4, 4, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const mode_value = col.mode();
    try testing.expectEqual(@as(i32, 4), mode_value.?);

    // Test with all unique values
    const unique_items = [_]i32{ 1, 2, 3, 4, 5 };
    var unique_col = try Collection(i32).fromSlice(testing.allocator, &unique_items);
    defer unique_col.deinit();

    const unique_mode = unique_col.mode();
    try testing.expect(unique_mode != null); // Should return one of the values

    // Test empty collection
    var empty_col = Collection(i32).init(testing.allocator);
    defer empty_col.deinit();

    try testing.expect(empty_col.mode() == null);
}

// ==================== Conditional Method Tests ====================

test "Collection: when" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);

    // When condition is true, callback should execute
    _ = try col.when(true, struct {
        fn call(c: *Collection(i32)) !void {
            try c.push(3);
        }
    }.call);

    try testing.expectEqual(@as(usize, 3), col.count());
    try testing.expectEqual(@as(i32, 3), col.last().?);

    // When condition is false, callback should NOT execute
    _ = try col.when(false, struct {
        fn call(c: *Collection(i32)) !void {
            try c.push(4);
        }
    }.call);

    try testing.expectEqual(@as(usize, 3), col.count());
}

test "Collection: unless" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);

    // Unless condition is false, callback should execute
    _ = try col.unless(false, struct {
        fn call(c: *Collection(i32)) !void {
            try c.push(3);
        }
    }.call);

    try testing.expectEqual(@as(usize, 3), col.count());
    try testing.expectEqual(@as(i32, 3), col.last().?);

    // Unless condition is true, callback should NOT execute
    _ = try col.unless(true, struct {
        fn call(c: *Collection(i32)) !void {
            try c.push(4);
        }
    }.call);

    try testing.expectEqual(@as(usize, 3), col.count());
}

test "Collection: whenElse" {
    var col1 = Collection(i32).init(testing.allocator);
    defer col1.deinit();

    try col1.push(1);

    // When true, execute true callback
    _ = try col1.whenElse(
        true,
        struct {
            fn call(c: *Collection(i32)) !void {
                try c.push(2);
            }
        }.call,
        struct {
            fn call(c: *Collection(i32)) !void {
                try c.push(99);
            }
        }.call,
    );

    try testing.expectEqual(@as(usize, 2), col1.count());
    try testing.expectEqual(@as(i32, 2), col1.last().?);

    var col2 = Collection(i32).init(testing.allocator);
    defer col2.deinit();

    try col2.push(1);

    // When false, execute false callback
    _ = try col2.whenElse(
        false,
        struct {
            fn call(c: *Collection(i32)) !void {
                try c.push(2);
            }
        }.call,
        struct {
            fn call(c: *Collection(i32)) !void {
                try c.push(99);
            }
        }.call,
    );

    try testing.expectEqual(@as(usize, 2), col2.count());
    try testing.expectEqual(@as(i32, 99), col2.last().?);
}

// ==================== Higher-Order Method Tests ====================

test "Collection: flatMap" {
    const items = [_]i32{ 1, 2, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // FlatMap each number to [n, n*2] using static arrays
    var result = try col.flatMap(i32, struct {
        const a1 = [_]i32{ 1, 2 };
        const a2 = [_]i32{ 2, 4 };
        const a3 = [_]i32{ 3, 6 };

        fn call(n: i32) []const i32 {
            return switch (n) {
                1 => &a1,
                2 => &a2,
                3 => &a3,
                else => &[_]i32{},
            };
        }
    }.call);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 6), result.count());
    try testing.expectEqual(@as(i32, 1), result.get(0).?);
    try testing.expectEqual(@as(i32, 2), result.get(1).?);
    try testing.expectEqual(@as(i32, 2), result.get(2).?);
    try testing.expectEqual(@as(i32, 4), result.get(3).?);
    try testing.expectEqual(@as(i32, 3), result.get(4).?);
    try testing.expectEqual(@as(i32, 6), result.get(5).?);
}

test "Collection: mapWithIndex" {
    const items = [_]i32{ 10, 20, 30 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Map each value + its index
    var result = try col.mapWithIndex(i32, struct {
        fn call(n: i32, idx: usize) i32 {
            return n + @as(i32, @intCast(idx));
        }
    }.call);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.count());
    try testing.expectEqual(@as(i32, 10), result.get(0).?); // 10 + 0
    try testing.expectEqual(@as(i32, 21), result.get(1).?); // 20 + 1
    try testing.expectEqual(@as(i32, 32), result.get(2).?); // 30 + 2
}

test "Collection: mapToDictionary" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const KVPair = Collection(i32).KeyValuePair(i32, i32);

    // Map to dictionary where key=value, value=value*2
    var dict = try col.mapToDictionary(i32, i32, struct {
        fn call(n: i32) KVPair {
            return .{ .key = n, .value = n * 2 };
        }
    }.call);
    defer dict.deinit();

    try testing.expectEqual(@as(i32, 2), dict.get(1).?);
    try testing.expectEqual(@as(i32, 4), dict.get(2).?);
    try testing.expectEqual(@as(i32, 10), dict.get(5).?);
}

test "Collection: mapSpread" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Spread all items to a sum function
    const result = try col.mapSpread(i32, struct {
        fn call(nums: []const i32) i32 {
            var sum: i32 = 0;
            for (nums) |n| sum += n;
            return sum;
        }
    }.call);

    try testing.expectEqual(@as(i32, 15), result);
}

// ==================== Conversion Method Tests ====================

test "Collection: toOwnedSlice" {
    var col = Collection(i32).init(testing.allocator);
    // Note: we don't defer col.deinit() because toOwnedSlice takes ownership

    try col.push(1);
    try col.push(2);
    try col.push(3);

    const owned = try col.toOwnedSlice();
    defer testing.allocator.free(owned);

    try testing.expectEqual(@as(usize, 3), owned.len);
    try testing.expectEqual(@as(i32, 1), owned[0]);
    try testing.expectEqual(@as(i32, 2), owned[1]);
    try testing.expectEqual(@as(i32, 3), owned[2]);
}

test "Collection: toJson" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const json = try col.toJson(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("[1,2,3,4,5]", json);
}

test "Collection: toJsonPretty" {
    const items = [_]i32{ 1, 2, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const json = try col.toJsonPretty(testing.allocator);
    defer testing.allocator.free(json);

    // Should contain newlines and indentation
    try testing.expect(std.mem.indexOf(u8, json, "\n") != null);
}

test "Collection: fromJson" {
    const json_str = "[10,20,30,40,50]";

    var col = try Collection(i32).fromJson(testing.allocator, json_str);
    defer col.deinit();

    try testing.expectEqual(@as(usize, 5), col.count());
    try testing.expectEqual(@as(i32, 10), col.get(0).?);
    try testing.expectEqual(@as(i32, 30), col.get(2).?);
    try testing.expectEqual(@as(i32, 50), col.get(4).?);
}

// ==================== Additional Structural Transformation Tests ====================

test "Collection: collapse" {
    const arr1 = [_]i32{ 1, 2 };
    const arr2 = [_]i32{ 3, 4 };
    const arr3 = [_]i32{ 5, 6 };
    const nested = [_][]const i32{ &arr1, &arr2, &arr3 };

    var col = try Collection([]const i32).fromSlice(testing.allocator, &nested);
    defer col.deinit();

    var collapsed = try col.collapse(i32);
    defer collapsed.deinit();

    try testing.expectEqual(@as(usize, 6), collapsed.count());
    try testing.expectEqual(@as(i32, 1), collapsed.get(0).?);
    try testing.expectEqual(@as(i32, 6), collapsed.get(5).?);
}

test "Collection: sliding" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Sliding window size 3, step 2
    var windows = try col.sliding(3, 2);
    defer windows.deinit();

    try testing.expectEqual(@as(usize, 2), windows.count());

    const win1 = windows.get(0).?;
    try testing.expectEqual(@as(usize, 3), win1.len);
    try testing.expectEqual(@as(i32, 1), win1[0]);
    try testing.expectEqual(@as(i32, 3), win1[2]);

    const win2 = windows.get(1).?;
    try testing.expectEqual(@as(i32, 3), win2[0]);
    try testing.expectEqual(@as(i32, 5), win2[2]);
}

// ==================== Advanced Sorting Tests ====================

test "Collection: sortBy" {
    const items = [_]i32{ 5, 1, 4, 2, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Sort by absolute value
    col.sortBy(i32, struct {
        fn call(n: i32) i32 {
            return if (n < 0) -n else n;
        }
    }.call);

    try testing.expectEqual(@as(i32, 1), col.get(0).?);
    try testing.expectEqual(@as(i32, 2), col.get(1).?);
    try testing.expectEqual(@as(i32, 5), col.get(4).?);
}

test "Collection: sortByDesc" {
    const items = [_]i32{ 5, 1, 4, 2, 3 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    col.sortByDesc(i32, struct {
        fn call(n: i32) i32 {
            return n;
        }
    }.call);

    try testing.expectEqual(@as(i32, 5), col.get(0).?);
    try testing.expectEqual(@as(i32, 4), col.get(1).?);
    try testing.expectEqual(@as(i32, 1), col.get(4).?);
}

// ==================== Aggregation Tests ====================

test "Collection: minMax" {
    const items = [_]i32{ 5, 1, 9, 3, 7 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const result = col.minMax();
    try testing.expect(result != null);
    try testing.expectEqual(@as(i32, 1), result.?.min);
    try testing.expectEqual(@as(i32, 9), result.?.max);

    // Test empty collection
    var empty_col = Collection(i32).init(testing.allocator);
    defer empty_col.deinit();
    try testing.expect(empty_col.minMax() == null);
}

// ==================== Utility Method Tests ====================

test "Collection: has and hasAny" {
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    try testing.expect(col.has(0));
    try testing.expect(col.has(4));
    try testing.expect(!col.has(5));
    try testing.expect(!col.has(10));

    const indices1 = [_]usize{ 10, 20, 30 };
    try testing.expect(!col.hasAny(&indices1));

    const indices2 = [_]usize{ 10, 2, 30 };
    try testing.expect(col.hasAny(&indices2));
}

test "Collection: pipeThrough" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);

    const fn1: *const fn (col: *const Collection(i32)) anyerror!void = &struct {
        fn call(_: *const Collection(i32)) !void {
            // First callback
        }
    }.call;

    const fn2: *const fn (col: *const Collection(i32)) anyerror!void = &struct {
        fn call(_: *const Collection(i32)) !void {
            // Second callback
        }
    }.call;

    const callbacks = [_]*const fn (col: *const Collection(i32)) anyerror!void{ fn1, fn2 };

    _ = try col.pipeThrough(&callbacks);
    try testing.expectEqual(@as(usize, 1), col.count());
}

// ==================== Integration Tests: Method Chaining ====================

test "Integration: complex filter-map-reduce chain" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Filter evens, map to squares, reduce to sum
    var filtered = try col.filter(struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call);
    defer filtered.deinit();

    var mapped = try filtered.map(i32, struct {
        fn call(n: i32) i32 {
            return n * n;
        }
    }.call);
    defer mapped.deinit();

    const sum = mapped.reduce(i32, 0, struct {
        fn call(acc: i32, n: i32) i32 {
            return acc + n;
        }
    }.call);

    // 2^2 + 4^2 + 6^2 + 8^2 + 10^2 = 4 + 16 + 36 + 64 + 100 = 220
    try testing.expectEqual(@as(i32, 220), sum);
}

test "Integration: filter-sort-take-pluck chain" {
    const items = [_]i32{ 15, 3, 9, 1, 22, 7, 18, 5, 12, 30 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Filter items > 10, sort, take first 3
    var filtered = try col.filter(struct {
        fn call(n: i32) bool {
            return n > 10;
        }
    }.call);
    defer filtered.deinit();

    filtered.sort();

    var top3 = try filtered.take(3);
    defer top3.deinit();

    try testing.expectEqual(@as(usize, 3), top3.count());
    try testing.expectEqual(@as(i32, 12), top3.get(0).?);
    try testing.expectEqual(@as(i32, 15), top3.get(1).?);
    try testing.expectEqual(@as(i32, 18), top3.get(2).?);
}

test "Integration: chunk-map-sum chain" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Chunk into pairs
    var chunks = try col.chunk(2);
    defer chunks.deinit();

    // Manually compute sums from each chunk (slice)
    var sums = Collection(i32).init(testing.allocator);
    defer sums.deinit();

    for (chunks.all()) |chunk_slice| {
        var sum: i32 = 0;
        for (chunk_slice) |n| {
            sum += n;
        }
        try sums.push(sum);
    }

    // Chunks: [1,2], [3,4], [5,6] -> Sums: [3, 7, 11]
    try testing.expectEqual(@as(usize, 3), sums.count());
    try testing.expectEqual(@as(i32, 3), sums.get(0).?);
    try testing.expectEqual(@as(i32, 7), sums.get(1).?);
    try testing.expectEqual(@as(i32, 11), sums.get(2).?);
}

test "Integration: whereIn-unique-sortDesc chain" {
    const items = [_]i32{ 5, 2, 8, 2, 9, 5, 3, 8, 7, 1 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    const allowed = [_]i32{ 2, 5, 8, 9, 12 };
    var filtered = try col.whereIn(&allowed);
    defer filtered.deinit();

    var unique_items = try filtered.unique();
    defer unique_items.deinit();

    unique_items.sortDesc();

    try testing.expectEqual(@as(usize, 4), unique_items.count());
    try testing.expectEqual(@as(i32, 9), unique_items.get(0).?);
    try testing.expectEqual(@as(i32, 8), unique_items.get(1).?);
    try testing.expectEqual(@as(i32, 5), unique_items.get(2).?);
    try testing.expectEqual(@as(i32, 2), unique_items.get(3).?);
}

test "Integration: partition-map-merge chain" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Partition into evens and odds
    var result = try col.partition(struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call);
    defer result.pass.deinit();
    defer result.fail.deinit();

    // Map evens to *2, odds to *3
    var evens_doubled = try result.pass.map(i32, struct {
        fn call(n: i32) i32 {
            return n * 2;
        }
    }.call);
    defer evens_doubled.deinit();

    var odds_tripled = try result.fail.map(i32, struct {
        fn call(n: i32) i32 {
            return n * 3;
        }
    }.call);
    defer odds_tripled.deinit();

    // Merge back
    var merged = try evens_doubled.merge(&odds_tripled);
    defer merged.deinit();

    try testing.expectEqual(@as(usize, 10), merged.count());
    // Contains both doubled evens and tripled odds
    try testing.expect(merged.contains(4));   // 2 * 2
    try testing.expect(merged.contains(3));   // 1 * 3
    try testing.expect(merged.contains(20));  // 10 * 2
    try testing.expect(merged.contains(27));  // 9 * 3
}

test "Integration: groupBy-aggregate chain" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Group by remainder when divided by 3 (using u8 instead of string)
    var grouped = try col.groupBy(u8, struct {
        fn call(n: i32) u8 {
            return @intCast(@mod(n, 3));
        }
    }.call);
    defer {
        var it = grouped.valueIterator();
        while (it.next()) |group| {
            group.deinit();
        }
        grouped.deinit();
    }

    // Check group 0 (3, 6, 9)
    if (grouped.get(0)) |zero_group| {
        try testing.expectEqual(@as(usize, 3), zero_group.count());
        const sum = zero_group.sum();
        try testing.expectEqual(@as(i32, 18), sum); // 3 + 6 + 9 = 18
    }

    // Check group 1 (1, 4, 7, 10)
    if (grouped.get(1)) |one_group| {
        try testing.expectEqual(@as(usize, 4), one_group.count());
        const avg = one_group.avg();
        try testing.expectEqual(@as(f64, 5.5), avg); // (1+4+7+10)/4 = 5.5
    }
}

test "Integration: sliding-filter-flatMap chain" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var col = try Collection(i32).fromSlice(testing.allocator, &items);
    defer col.deinit();

    // Create sliding windows of size 3
    var windows = try col.sliding(3, 1);
    defer windows.deinit();

    // Filter windows where sum > 10
    var filtered_windows = try windows.filter(struct {
        fn call(window: []const i32) bool {
            var sum: i32 = 0;
            for (window) |n| sum += n;
            return sum > 10;
        }
    }.call);
    defer filtered_windows.deinit();

    // Count should be windows with sum > 10
    // [1,2,3]=6, [2,3,4]=9, [3,4,5]=12✓, [4,5,6]=15✓, [5,6,7]=18✓, [6,7,8]=21✓
    try testing.expectEqual(@as(usize, 4), filtered_windows.count());
}

test "Integration: real-world data pipeline" {
    // Simulate processing user scores
    const scores = [_]i32{ 45, 67, 89, 92, 78, 85, 91, 73, 88, 95, 82, 76, 90, 68, 84 };
    var col = try Collection(i32).fromSlice(testing.allocator, &scores);
    defer col.deinit();

    // 1. Filter passing scores (>= 70)
    var passing = try col.filter(struct {
        fn call(score: i32) bool {
            return score >= 70;
        }
    }.call);
    defer passing.deinit();

    // 2. Sort descending
    passing.sortDesc();

    // 3. Take top 5
    var top5 = try passing.take(5);
    defer top5.deinit();

    // 4. Calculate statistics
    const avg = top5.avg();
    const min_val = top5.min();
    const max_val = top5.max();

    try testing.expectEqual(@as(usize, 5), top5.count());
    try testing.expectEqual(@as(i32, 95), max_val.?);
    try testing.expectEqual(@as(i32, 89), min_val.?); // Top 5: 95, 92, 91, 90, 89
    try testing.expect(avg > 90.0 and avg < 92.0); // Average of top 5 = 91.4
}

// ==================== Validation Helpers Tests ====================

test "Validation: validate with all valid items" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(20);
    try col.push(30);

    var result = try col.validate(struct {
        fn call(n: i32) bool {
            return n > 0;
        }
    }.call);
    defer result.deinit();

    try testing.expect(result.valid);
    try testing.expectEqual(@as(usize, 0), result.invalid_indices.items.len);
}

test "Validation: validate with some invalid items" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(-5);
    try col.push(30);
    try col.push(-2);

    var result = try col.validate(struct {
        fn call(n: i32) bool {
            return n > 0;
        }
    }.call);
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expectEqual(@as(usize, 2), result.invalid_indices.items.len);
    try testing.expectEqual(@as(usize, 1), result.invalid_indices.items[0]);
    try testing.expectEqual(@as(usize, 3), result.invalid_indices.items[1]);
}

test "Validation: assert success" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(20);
    try col.push(30);

    try col.assert(struct {
        fn call(n: i32) bool {
            return n > 0;
        }
    }.call);
}

test "Validation: assert failure" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(-5);
    try col.push(30);

    const result = col.assert(struct {
        fn call(n: i32) bool {
            return n > 0;
        }
    }.call);

    try testing.expectError(Collection(i32).ValidationError.ValidationFailed, result);
}

test "Validation: ensure success" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(20);
    try col.push(30);

    try col.ensure(struct {
        fn call(n: i32) bool {
            return n >= 10;
        }
    }.call, "All items must be >= 10");
}

test "Validation: ensure failure" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(5);
    try col.push(30);

    const result = col.ensure(struct {
        fn call(n: i32) bool {
            return n >= 10;
        }
    }.call, "All items must be >= 10");

    try testing.expectError(Collection(i32).ValidationError.ValidationFailed, result);
}

test "Validation: sanitize items" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(10);
    try col.push(-5);
    try col.push(30);
    try col.push(-2);

    // Sanitize by making all values positive
    _ = col.sanitize(struct {
        fn call(item: *i32) void {
            if (item.* < 0) {
                item.* = -item.*;
            }
        }
    }.call);

    try testing.expectEqual(@as(i32, 10), col.get(0).?);
    try testing.expectEqual(@as(i32, 5), col.get(1).?);
    try testing.expectEqual(@as(i32, 30), col.get(2).?);
    try testing.expectEqual(@as(i32, 2), col.get(3).?);
}

test "Validation: sanitize with clamping" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(5);
    try col.push(15);
    try col.push(25);
    try col.push(35);

    // Clamp values to [10, 30]
    _ = col.sanitize(struct {
        fn call(item: *i32) void {
            if (item.* < 10) item.* = 10;
            if (item.* > 30) item.* = 30;
        }
    }.call);

    try testing.expectEqual(@as(i32, 10), col.get(0).?);
    try testing.expectEqual(@as(i32, 15), col.get(1).?);
    try testing.expectEqual(@as(i32, 25), col.get(2).?);
    try testing.expectEqual(@as(i32, 30), col.get(3).?);
}

// ==================== Windowing & Batching Tests ====================

test "Windowing: batch processing" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);
    try col.push(4);
    try col.push(5);
    try col.push(6);
    try col.push(7);

    // Collect batch sizes
    var batch_sizes = Collection(usize).init(testing.allocator);
    defer batch_sizes.deinit();

    const Ctx = struct {
        var sizes: *Collection(usize) = undefined;
    };
    Ctx.sizes = &batch_sizes;

    try col.batch(3, struct {
        fn callback(batch: []const i32) !void {
            try Ctx.sizes.push(batch.len);
        }
    }.callback);

    // Should have 3 batches: [1,2,3], [4,5,6], [7]
    try testing.expectEqual(@as(usize, 3), batch_sizes.count());
    try testing.expectEqual(@as(usize, 3), batch_sizes.get(0).?);
    try testing.expectEqual(@as(usize, 3), batch_sizes.get(1).?);
    try testing.expectEqual(@as(usize, 1), batch_sizes.get(2).?);
}

test "Windowing: batch with callback" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    for (0..10) |i| {
        try col.push(@intCast(i));
    }

    // Process in batches of 3
    var batch_sums = Collection(i32).init(testing.allocator);
    defer batch_sums.deinit();

    const Ctx2 = struct {
        var sums: *Collection(i32) = undefined;
    };
    Ctx2.sums = &batch_sums;

    try col.batch(3, struct {
        fn callback(batch: []const i32) !void {
            var sum: i32 = 0;
            for (batch) |item| sum += item;
            try Ctx2.sums.push(sum);
        }
    }.callback);

    // Batches: [0,1,2]=3, [3,4,5]=12, [6,7,8]=21, [9]=9
    try testing.expectEqual(@as(usize, 4), batch_sums.count());
}

test "Windowing: sliding window" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);
    try col.push(4);
    try col.push(5);

    var window_count: usize = 0;
    var last_window_sum: i32 = 0;

    const Ctx3 = struct {
        var count: *usize = undefined;
        var last_sum: *i32 = undefined;
    };
    Ctx3.count = &window_count;
    Ctx3.last_sum = &last_window_sum;

    try col.window(3, struct {
        fn callback(w: []const i32) !void {
            Ctx3.count.* += 1;
            var sum: i32 = 0;
            for (w) |item| sum += item;
            Ctx3.last_sum.* = sum;
        }
    }.callback);

    // Windows: [1,2,3], [2,3,4], [3,4,5]
    try testing.expectEqual(@as(usize, 3), window_count);
    try testing.expectEqual(@as(i32, 12), last_window_sum); // Last window: 3+4+5=12
}

test "Windowing: throttle every nth" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    for (0..10) |i| {
        try col.push(@intCast(i));
    }

    var throttled = try col.throttle(3);
    defer throttled.deinit();

    // Should take indices 0, 3, 6, 9
    try testing.expectEqual(@as(usize, 4), throttled.count());
    try testing.expectEqual(@as(i32, 0), throttled.get(0).?);
    try testing.expectEqual(@as(i32, 3), throttled.get(1).?);
    try testing.expectEqual(@as(i32, 6), throttled.get(2).?);
    try testing.expectEqual(@as(i32, 9), throttled.get(3).?);
}

test "Windowing: debounce removes consecutive duplicates" {
    var col = Collection(i32).init(testing.allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(1);
    try col.push(2);
    try col.push(2);
    try col.push(2);
    try col.push(3);
    try col.push(1);
    try col.push(1);

    var debounced = try col.debounceDefault();
    defer debounced.deinit();

    // Should be: 1, 2, 3, 1
    try testing.expectEqual(@as(usize, 4), debounced.count());
    try testing.expectEqual(@as(i32, 1), debounced.get(0).?);
    try testing.expectEqual(@as(i32, 2), debounced.get(1).?);
    try testing.expectEqual(@as(i32, 3), debounced.get(2).?);
    try testing.expectEqual(@as(i32, 1), debounced.get(3).?);
}

test "Windowing: debounce with custom equality" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    var col = Collection(Point).init(testing.allocator);
    defer col.deinit();

    try col.push(.{ .x = 1, .y = 1 });
    try col.push(.{ .x = 1, .y = 2 }); // Different y, but same x
    try col.push(.{ .x = 2, .y = 1 });
    try col.push(.{ .x = 2, .y = 2 });

    // Debounce based on x coordinate only
    var debounced = try col.debounce(struct {
        fn equal(a: Point, b: Point) bool {
            return a.x == b.x;
        }
    }.equal);
    defer debounced.deinit();

    // Should keep: (1,1), (2,1)
    try testing.expectEqual(@as(usize, 2), debounced.count());
    try testing.expectEqual(@as(i32, 1), debounced.get(0).?.x);
    try testing.expectEqual(@as(i32, 2), debounced.get(1).?.x);
}

// ==================== Diff & Patch Tests ====================

test "Diff: compute diff between collections" {
    var col1 = Collection(i32).init(testing.allocator);
    defer col1.deinit();
    var col2 = Collection(i32).init(testing.allocator);
    defer col2.deinit();

    try col1.push(1);
    try col1.push(2);
    try col1.push(3);

    try col2.push(2);
    try col2.push(3);
    try col2.push(4);

    var diff_result = try col1.diffChangesDefault(&col2);
    defer diff_result.deinit();

    // Should have 1 deletion (1) and 1 addition (4)
    try testing.expectEqual(@as(usize, 2), diff_result.changes.items.len);
}

test "Diff: changes between collections" {
    var col1 = Collection(i32).init(testing.allocator);
    defer col1.deinit();
    var col2 = Collection(i32).init(testing.allocator);
    defer col2.deinit();

    try col1.push(1);
    try col1.push(2);
    try col1.push(3);

    try col2.push(2);
    try col2.push(3);
    try col2.push(4);
    try col2.push(5);

    var result = try col1.changesDefault(&col2);
    defer result.additions.deinit();
    defer result.deletions.deinit();

    // Additions: 4, 5
    try testing.expectEqual(@as(usize, 2), result.additions.count());
    try testing.expect(result.additions.contains(4));
    try testing.expect(result.additions.contains(5));

    // Deletions: 1
    try testing.expectEqual(@as(usize, 1), result.deletions.count());
    try testing.expect(result.deletions.contains(1));
}

test "Diff: patch collection" {
    var col1 = Collection(i32).init(testing.allocator);
    defer col1.deinit();
    var col2 = Collection(i32).init(testing.allocator);
    defer col2.deinit();

    try col1.push(1);
    try col1.push(2);
    try col1.push(3);

    try col2.push(2);
    try col2.push(3);
    try col2.push(4);

    var diff_result = try col1.diffChangesDefault(&col2);
    defer diff_result.deinit();

    try col1.patch(&diff_result);

    // After patching, col1 should contain: 2, 3, 4
    try testing.expectEqual(@as(usize, 3), col1.count());
    try testing.expect(col1.contains(2));
    try testing.expect(col1.contains(3));
    try testing.expect(col1.contains(4));
    try testing.expect(!col1.contains(1));
}

test "Diff: no changes when collections are equal" {
    var col1 = Collection(i32).init(testing.allocator);
    defer col1.deinit();
    var col2 = Collection(i32).init(testing.allocator);
    defer col2.deinit();

    try col1.push(1);
    try col1.push(2);
    try col1.push(3);

    try col2.push(1);
    try col2.push(2);
    try col2.push(3);

    var result = try col1.changesDefault(&col2);
    defer result.additions.deinit();
    defer result.deletions.deinit();

    try testing.expectEqual(@as(usize, 0), result.additions.count());
    try testing.expectEqual(@as(usize, 0), result.deletions.count());
}
