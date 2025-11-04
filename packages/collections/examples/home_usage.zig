// Home Collections Usage Example
// This demonstrates how to use collections in the Home programming language

const std = @import("std");
const collection_module = @import("../src/collection.zig");
const lazy_collection_module = @import("../src/lazy_collection.zig");
const Collection = collection_module.Collection;
const LazyCollection = lazy_collection_module.LazyCollection;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Home Collections Example ===\n\n", .{});

    // Example 1: Basic Collection Operations
    std.debug.print("1. Basic Operations:\n", .{});
    {
        var numbers = Collection(i32).init(allocator);
        defer numbers.deinit();

        try numbers.push(5);
        try numbers.push(2);
        try numbers.push(8);
        try numbers.push(1);
        try numbers.push(9);

        std.debug.print("   Original: ", .{});
        numbers.dump();

        numbers.sort();
        std.debug.print("   Sorted: ", .{});
        numbers.dump();

        const sum = numbers.sum();
        const avg = numbers.avg();
        const max_val = numbers.max().?;

        std.debug.print("   Sum: {d}, Average: {d:.1}, Max: {d}\n\n", .{ sum, avg, max_val });
    }

    // Example 2: Data Transformation Pipeline
    std.debug.print("2. Data Transformation:\n", .{});
    {
        const scores = [_]i32{ 85, 92, 78, 65, 90, 88, 72, 95, 81, 69 };
        var col = try Collection(i32).fromSlice(allocator, &scores);
        defer col.deinit();

        // Filter passing scores (>= 70)
        var passing = try col.filter(struct {
            fn call(score: i32) bool {
                return score >= 70;
            }
        }.call);
        defer passing.deinit();

        std.debug.print("   Passing scores ({d} students): ", .{passing.count()});
        passing.dump();

        // Get top 3
        passing.sortDesc();
        var top3 = try passing.take(3);
        defer top3.deinit();

        std.debug.print("   Top 3 scores: ", .{});
        top3.dump();
    }

    // Example 3: Using Builder Functions
    std.debug.print("\n3. Builder Functions:\n", .{});
    {
        // range() - Create sequence
        var nums = try collection_module.range(allocator, 1, 10);
        defer nums.deinit();
        std.debug.print("   Range 1-10: ", .{});
        nums.dump();

        // times() - Repeat callback
        var doubled = try collection_module.times(i32, allocator, 5, struct {
            fn call(i: usize) i32 {
                return @intCast(i * 2);
            }
        }.call);
        defer doubled.deinit();
        std.debug.print("   Times (i*2): ", .{});
        doubled.dump();

        // wrap() - Single value
        var wrapped = try collection_module.wrap(i32, allocator, 42);
        defer wrapped.deinit();
        std.debug.print("   Wrapped value: {d}\n", .{wrapped.first().?});
    }

    // Example 4: Lazy Collections for Performance
    std.debug.print("\n4. Lazy Collections (Performance):\n", .{});
    {
        // Simulate large dataset
        const large_data = try allocator.alloc(i32, 1000);
        defer allocator.free(large_data);

        for (large_data, 0..) |*item, i| {
            item.* = @intCast(i + 1);
        }

        std.debug.print("   Processing 1000 items lazily...\n", .{});

        const filter_fn = struct {
            fn call(n: i32) bool {
                return @mod(n, 3) == 0; // multiples of 3
            }
        }.call;

        const map_fn = struct {
            fn call(n: i32) i32 {
                return n * n; // square
            }
        }.call;

        // Lazy: Only processes ~30 items to get 10 results!
        const lzy = LazyCollection(i32).fromSlice(allocator, large_data);
        const filtered = lzy.filter(&filter_fn);
        const mapped = filtered.map(&map_fn);

        var result = try mapped.take(10);
        defer result.deinit();

        std.debug.print("   First 10 results (multiples of 3, squared): ", .{});
        result.dump();
        std.debug.print("   (Only processed ~30 items, not 1000!)\n", .{});
    }

    // Example 5: Advanced Operations
    std.debug.print("\n5. Advanced Operations:\n", .{});
    {
        const data = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        var col = try Collection(i32).fromSlice(allocator, &data);
        defer col.deinit();

        // Partition into evens and odds
        var result = try col.partition(struct {
            fn call(n: i32) bool {
                return @mod(n, 2) == 0;
            }
        }.call);
        defer result.pass.deinit();
        defer result.fail.deinit();

        std.debug.print("   Evens: ", .{});
        result.pass.dump();
        std.debug.print("   Odds: ", .{});
        result.fail.dump();

        // Chunk into groups
        var chunks = try col.chunk(3);
        defer chunks.deinit();

        std.debug.print("   Chunked by 3:\n", .{});
        for (chunks.all(), 0..) |chunk, i| {
            std.debug.print("     Chunk {d}: ", .{i});
            for (chunk) |val| {
                std.debug.print("{d} ", .{val});
            }
            std.debug.print("\n", .{});
        }
    }

    // Example 6: Real-World: Processing User Data
    std.debug.print("\n6. Real-World Example - User Age Analysis:\n", .{});
    {
        const ages = [_]i32{ 25, 32, 18, 45, 28, 33, 19, 42, 29, 35, 21, 38, 27, 41, 30 };
        var col = try Collection(i32).fromSlice(allocator, &ages);
        defer col.deinit();

        // Group by generation
        var grouped = try col.groupBy(u8, struct {
            fn call(age: i32) u8 {
                if (age < 25) return 0; // Gen Z
                if (age < 35) return 1; // Millennial
                return 2; // Gen X
            }
        }.call);
        defer {
            var it = grouped.valueIterator();
            while (it.next()) |group| {
                group.deinit();
            }
            grouped.deinit();
        }

        const gen_names = [_][]const u8{ "Gen Z", "Millennial", "Gen X" };
        std.debug.print("   Age Distribution:\n", .{});

        var i: u8 = 0;
        while (i < 3) : (i += 1) {
            if (grouped.get(i)) |group| {
                const avg_age = group.avg();
                std.debug.print("     {s}: {d} users (avg age: {d:.1})\n", .{ gen_names[i], group.count(), avg_age });
            }
        }
    }

    std.debug.print("\n✓ Collections example completed!\n", .{});
}
