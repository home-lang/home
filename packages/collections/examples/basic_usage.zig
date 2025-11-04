// Basic Collections Usage Examples
// Demonstrates fundamental collection operations

const std = @import("std");
const collections = @import("collections");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ==================== Creating Collections ====================

    std.debug.print("=== Creating Collections ===\n", .{});

    // From array
    var numbers = try collections.collect(i32, &[_]i32{ 1, 2, 3, 4, 5 }, allocator);
    defer numbers.deinit();
    std.debug.print("Numbers: {any}\n", .{numbers.all()});

    // From range
    var range_col = try collections.range(i32, 0, 10, allocator);
    defer range_col.deinit();
    std.debug.print("Range 0-10: {any}\n", .{range_col.all()});

    // Using times
    var squared = try collections.times(i32, 5, struct {
        fn call(i: usize) i32 {
            const n: i32 = @intCast(i);
            return n * n;
        }
    }.call, allocator);
    defer squared.deinit();
    std.debug.print("Squared: {any}\n", .{squared.all()});

    // ==================== Basic Operations ====================

    std.debug.print("\n=== Basic Operations ===\n", .{});

    var items = try collections.collect(i32, &[_]i32{ 10, 20, 30, 40, 50 }, allocator);
    defer items.deinit();

    std.debug.print("First: {?}\n", .{items.first()});
    std.debug.print("Last: {?}\n", .{items.last()});
    std.debug.print("Count: {}\n", .{items.count()});
    std.debug.print("IsEmpty: {}\n", .{items.isEmpty()});

    // ==================== Transformations ====================

    std.debug.print("\n=== Transformations ===\n", .{});

    var source = try collections.collect(i32, &[_]i32{ 1, 2, 3, 4, 5 }, allocator);
    defer source.deinit();

    // Map
    var doubled = try source.map(i32, struct {
        fn call(n: i32) i32 {
            return n * 2;
        }
    }.call);
    defer doubled.deinit();
    std.debug.print("Doubled: {any}\n", .{doubled.all()});

    // Filter
    var evens = try source.filter(struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call);
    defer evens.deinit();
    std.debug.print("Evens: {any}\n", .{evens.all()});

    // Reduce
    const sum = try source.reduce(i32, 0, struct {
        fn call(acc: i32, n: i32) i32 {
            return acc + n;
        }
    }.call);
    std.debug.print("Sum: {}\n", .{sum});

    // ==================== Chaining ====================

    std.debug.print("\n=== Method Chaining ===\n", .{});

    var data = try collections.collect(i32, &[_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }, allocator);
    defer data.deinit();

    var filtered = try data.filter(struct {
        fn call(n: i32) bool {
            return n > 5;
        }
    }.call);
    defer filtered.deinit();

    var mapped = try filtered.map(i32, struct {
        fn call(n: i32) i32 {
            return n * n;
        }
    }.call);
    defer mapped.deinit();

    std.debug.print("Numbers > 5, squared: {any}\n", .{mapped.all()});

    // ==================== Aggregation ====================

    std.debug.print("\n=== Aggregation ===\n", .{});

    var values = try collections.collect(i32, &[_]i32{ 10, 20, 30, 40, 50 }, allocator);
    defer values.deinit();

    const total = try values.sum();
    std.debug.print("Sum: {}\n", .{total});

    const average = try values.avg();
    std.debug.print("Average: {d:.2}\n", .{average});

    const minimum = values.min();
    std.debug.print("Min: {?}\n", .{minimum});

    const maximum = values.max();
    std.debug.print("Max: {?}\n", .{maximum});

    // ==================== Query Methods ====================

    std.debug.print("\n=== Query Methods ===\n", .{});

    var query_data = try collections.collect(i32, &[_]i32{ 1, 2, 3, 4, 5 }, allocator);
    defer query_data.deinit();

    const has_three = query_data.contains(3);
    std.debug.print("Contains 3: {}\n", .{has_three});

    const all_positive = query_data.every(struct {
        fn call(n: i32) bool {
            return n > 0;
        }
    }.call);
    std.debug.print("All positive: {}\n", .{all_positive});

    const has_even = query_data.some(struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call);
    std.debug.print("Has even: {}\n", .{has_even});

    std.debug.print("\n=== Done ===\n", .{});
}
