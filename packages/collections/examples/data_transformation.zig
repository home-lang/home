const std = @import("std");
const collection = @import("../src/collection.zig");
const Collection = collection.Collection;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Data Transformation Pipeline Example ===\n\n", .{});

    // Sample data: user scores
    const scores = [_]i32{ 85, 92, 78, 90, 88, 95, 82, 89, 76, 91 };
    var col = try Collection(i32).fromSlice(allocator, &scores);
    defer col.deinit();

    std.debug.print("Original scores: ", .{});
    col.dump();

    // Filter scores above 80
    var filtered = try col.filter(struct {
        fn call(score: i32) bool {
            return score > 80;
        }
    }.call);
    defer filtered.deinit();

    std.debug.print("\nScores above 80: ", .{});
    filtered.dump();

    // Calculate statistics
    const average = filtered.avg();
    const minimum = filtered.min();
    const maximum = filtered.max();
    const median_val = filtered.median();

    std.debug.print("\n=== Statistics ===\n", .{});
    std.debug.print("Average: {d:.2}\n", .{average});
    std.debug.print("Min: {d}\n", .{minimum.?});
    std.debug.print("Max: {d}\n", .{maximum.?});
    std.debug.print("Median: {d}\n", .{median_val.?});

    // Group into letter grades
    var grouped = try col.groupBy([]const u8, struct {
        fn call(score: i32) []const u8 {
            if (score >= 90) return "A";
            if (score >= 80) return "B";
            if (score >= 70) return "C";
            return "D";
        }
    }.call);
    defer {
        var it = grouped.valueIterator();
        while (it.next()) |group| {
            group.deinit();
        }
        grouped.deinit();
    }

    std.debug.print("\n=== Grade Distribution ===\n", .{});
    if (grouped.get("A")) |a_grades| {
        std.debug.print("A grades: {d} students\n", .{a_grades.count()});
    }
    if (grouped.get("B")) |b_grades| {
        std.debug.print("B grades: {d} students\n", .{b_grades.count()});
    }
    if (grouped.get("C")) |c_grades| {
        std.debug.print("C grades: {d} students\n", .{c_grades.count()});
    }
}
