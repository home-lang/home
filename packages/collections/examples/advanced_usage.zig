// Advanced Collections Usage Examples
// Demonstrates lazy collections, macros, and complex operations

const std = @import("std");
const collections = @import("collections");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ==================== Lazy Collections ====================

    std.debug.print("=== Lazy Collections ===\n", .{});

    // Create lazy collection - operations are deferred
    var lazy = try collections.rangeLazy(i32, 0, 1000000, allocator);
    defer lazy.deinit();

    // Take only first 10 after filtering
    var filtered = try lazy.filter(struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call);
    defer filtered.deinit();

    var taken = try filtered.take(10);
    defer taken.deinit();

    // Force evaluation
    var result = try taken.collect();
    defer result.deinit();

    std.debug.print("First 10 even numbers from lazy range: {any}\n", .{result.all()});

    // ==================== Collection Macros ====================

    std.debug.print("\n=== Collection Macros ===\n", .{});

    var macro_data = try collections.collect(i32, &[_]i32{ 1, 2, 3, 4, 5 }, allocator);
    defer macro_data.deinit();

    // Built-in macro: double
    const double_fn = collections.macros.doubleMacro(i32);
    _ = macro_data.macro(double_fn);
    std.debug.print("After double macro: {any}\n", .{macro_data.all()});

    // Custom inline macro
    _ = macro_data.macro(struct {
        fn call(item: *i32) void {
            item.* += 10;
        }
    }.call);
    std.debug.print("After +10 macro: {any}\n", .{macro_data.all()});

    // ==================== Grouping & Partitioning ====================

    std.debug.print("\n=== Grouping & Partitioning ===\n", .{});

    var partition_data = try collections.collect(i32, &[_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, allocator);
    defer partition_data.deinit();

    // Partition into even and odd
    var parts = try partition_data.partition(struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call);
    defer parts[0].deinit();
    defer parts[1].deinit();

    std.debug.print("Evens: {any}\n", .{parts[0].all()});
    std.debug.print("Odds: {any}\n", .{parts[1].all()});

    // Chunk
    var chunk_data = try collections.collect(i32, &[_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 }, allocator);
    defer chunk_data.deinit();

    var chunks = try chunk_data.chunk(3);
    defer {
        for (chunks.all()) |*chunk| {
            chunk.deinit();
        }
        chunks.deinit();
    }

    std.debug.print("Chunks of 3:\n", .{});
    for (chunks.all()) |chunk| {
        std.debug.print("  {any}\n", .{chunk.all()});
    }

    // ==================== Sorting ====================

    std.debug.print("\n=== Sorting ===\n", .{});

    var unsorted = try collections.collect(i32, &[_]i32{ 5, 2, 8, 1, 9, 3 }, allocator);
    defer unsorted.deinit();

    var sorted = try unsorted.sort();
    defer sorted.deinit();
    std.debug.print("Sorted ascending: {any}\n", .{sorted.all()});

    var sorted_desc = try unsorted.sortDesc();
    defer sorted_desc.deinit();
    std.debug.print("Sorted descending: {any}\n", .{sorted_desc.all()});

    // ==================== Unique & Duplicates ====================

    std.debug.print("\n=== Unique & Duplicates ===\n", .{});

    var dupes = try collections.collect(i32, &[_]i32{ 1, 2, 2, 3, 3, 3, 4, 5, 5 }, allocator);
    defer dupes.deinit();

    var unique = try dupes.unique();
    defer unique.deinit();
    std.debug.print("Unique values: {any}\n", .{unique.all()});

    var duplicates = try dupes.duplicates();
    defer duplicates.deinit();
    std.debug.print("Duplicate values: {any}\n", .{duplicates.all()});

    // ==================== Skip & Take ====================

    std.debug.print("\n=== Skip & Take ===\n", .{});

    var skip_take = try collections.range(i32, 0, 20, allocator);
    defer skip_take.deinit();

    var skipped = try skip_take.skip(5);
    defer skipped.deinit();

    var taken2 = try skipped.take(10);
    defer taken2.deinit();

    std.debug.print("Skip 5, take 10: {any}\n", .{taken2.all()});

    // ==================== Flatten ====================

    std.debug.print("\n=== Flatten ===\n", .{});

    var inner1 = try collections.collect(i32, &[_]i32{ 1, 2 }, allocator);
    var inner2 = try collections.collect(i32, &[_]i32{ 3, 4 }, allocator);
    var inner3 = try collections.collect(i32, &[_]i32{ 5, 6 }, allocator);

    var nested = collections.Collection(collections.Collection(i32)).init(allocator);
    defer nested.deinit();
    try nested.push(inner1);
    try nested.push(inner2);
    try nested.push(inner3);

    var flattened = try nested.flatten();
    defer flattened.deinit();

    std.debug.print("Flattened: {any}\n", .{flattened.all()});

    // ==================== FlatMap ====================

    std.debug.print("\n=== FlatMap ===\n", .{});

    var flatmap_data = try collections.collect(i32, &[_]i32{ 1, 2, 3 }, allocator);
    defer flatmap_data.deinit();

    // Map each number to a collection of [n, n*10]
    var flatmapped = try flatmap_data.flatMap(i32, struct {
        fn call(n: i32, alloc: std.mem.Allocator) !collections.Collection(i32) {
            var col = collections.Collection(i32).init(alloc);
            try col.push(n);
            try col.push(n * 10);
            return col;
        }
    }.call);
    defer flatmapped.deinit();

    std.debug.print("FlatMapped: {any}\n", .{flatmapped.all()});

    // ==================== Tap & Pipe ====================

    std.debug.print("\n=== Tap & Pipe ===\n", .{});

    var tap_data = try collections.collect(i32, &[_]i32{ 1, 2, 3 }, allocator);
    defer tap_data.deinit();

    // Tap allows inspection without modification
    _ = tap_data.tap(struct {
        fn call(col: *const collections.Collection(i32)) void {
            std.debug.print("Tapped - count: {}\n", .{col.count()});
        }
    }.call);

    // Pipe allows transformation
    var piped = try tap_data.pipe(struct {
        fn call(col: *const collections.Collection(i32), alloc: std.mem.Allocator) !collections.Collection(i32) {
            var new = collections.Collection(i32).init(alloc);
            for (col.all()) |item| {
                try new.push(item * 100);
            }
            return new;
        }
    }.call);
    defer piped.deinit();

    std.debug.print("Piped (*100): {any}\n", .{piped.all()});

    std.debug.print("\n=== Done ===\n", .{});
}
