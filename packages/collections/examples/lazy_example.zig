const std = @import("std");
const lazy_collection = @import("../src/lazy_collection.zig");
const LazyCollection = lazy_collection.LazyCollection;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lazy Collection Example ===\n\n", .{});

    // Create a large dataset
    const size = 1000;
    var large_dataset = try allocator.alloc(i32, size);
    defer allocator.free(large_dataset);

    for (large_dataset, 0..) |*item, i| {
        item.* = @intCast(i + 1);
    }

    std.debug.print("Dataset size: {d} items\n\n", .{size});

    // Using lazy evaluation - no intermediate collections created!
    const filter_fn = struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0; // even numbers only
        }
    }.call;

    const map_fn = struct {
        fn call(n: i32) i32 {
            return n * 3;
        }
    }.call;

    const lzy = LazyCollection(i32).fromSlice(allocator, large_dataset);
    const filtered = lzy.filter(&filter_fn);
    const mapped = filtered.map(&map_fn);

    // Only take first 10 - short-circuits, doesn't process entire dataset!
    var result = try mapped.take(10);
    defer result.deinit();

    std.debug.print("First 10 results (even numbers * 3):\n", .{});
    for (result.all(), 0..) |item, i| {
        std.debug.print("  [{d}] = {d}\n", .{ i, item });
    }

    std.debug.print("\n=== Performance Benefits ===\n", .{});
    std.debug.print("- No intermediate collections created\n", .{});
    std.debug.print("- Short-circuit evaluation (stopped after 10 items)\n", .{});
    std.debug.print("- Memory efficient for large datasets\n", .{});
    std.debug.print("- Lazy chains can be reused multiple times\n", .{});
}
