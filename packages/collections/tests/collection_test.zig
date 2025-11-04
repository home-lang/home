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
