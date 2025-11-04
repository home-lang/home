const std = @import("std");
const collection = @import("collection");
const Collection = collection.Collection;
const lazy_collection = @import("lazy_collection");
const LazyCollection = lazy_collection.LazyCollection;

/// Simple benchmark helper
fn benchmark(
    comptime name: []const u8,
    comptime func: fn () anyerror!void,
    iterations: usize,
) !void {
    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try func();
    }

    const end = std.time.nanoTimestamp();
    const elapsed_ns = @as(u64, @intCast(end - start));
    const avg_ns = elapsed_ns / iterations;
    const ops_per_sec = (@as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(elapsed_ns))) * 1_000_000_000.0;

    std.debug.print("{s}:\n", .{name});
    std.debug.print("  Total: {d:.2}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0});
    std.debug.print("  Average: {d}ns\n", .{avg_ns});
    std.debug.print("  Ops/sec: {d:.0}\n\n", .{ops_per_sec});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Collections Performance Benchmarks ===\n\n", .{});

    const iterations = 10_000;

    // Benchmark: Push
    try benchmark("Push operations", struct {
        fn run() !void {
            var gpa_local = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa_local.deinit();
            const alloc = gpa_local.allocator();

            var col = Collection(i32).init(alloc);
            defer col.deinit();

            var i: i32 = 0;
            while (i < 100) : (i += 1) {
                try col.push(i);
            }
        }
    }.run, iterations);

    // Benchmark: Filter
    try benchmark("Filter operations", struct {
        fn run() !void {
            var gpa_local = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa_local.deinit();
            const alloc = gpa_local.allocator();

            const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } ** 10;
            var col = try Collection(i32).fromSlice(alloc, &items);
            defer col.deinit();

            var filtered = try col.filter(struct {
                fn call(n: i32) bool {
                    return @mod(n, 2) == 0;
                }
            }.call);
            defer filtered.deinit();
        }
    }.run, iterations);

    // Benchmark: Map
    try benchmark("Map operations", struct {
        fn run() !void {
            var gpa_local = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa_local.deinit();
            const alloc = gpa_local.allocator();

            const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } ** 10;
            var col = try Collection(i32).fromSlice(alloc, &items);
            defer col.deinit();

            var mapped = try col.map(i32, struct {
                fn call(n: i32) i32 {
                    return n * 2;
                }
            }.call);
            defer mapped.deinit();
        }
    }.run, iterations);

    // Benchmark: Reduce
    try benchmark("Reduce operations", struct {
        fn run() !void {
            var gpa_local = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa_local.deinit();
            const alloc = gpa_local.allocator();

            const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } ** 10;
            var col = try Collection(i32).fromSlice(alloc, &items);
            defer col.deinit();

            _ = col.reduce(i32, 0, struct {
                fn call(acc: i32, n: i32) i32 {
                    return acc + n;
                }
            }.call);
        }
    }.run, iterations);

    // Benchmark: Sort
    try benchmark("Sort operations", struct {
        fn run() !void {
            var gpa_local = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa_local.deinit();
            const alloc = gpa_local.allocator();

            const items = [_]i32{ 5, 2, 8, 1, 9, 3, 7, 4, 6, 10 } ** 10;
            var col = try Collection(i32).fromSlice(alloc, &items);
            defer col.deinit();

            col.sort();
        }
    }.run, iterations);

    // Benchmark: Lazy vs Eager
    std.debug.print("=== Lazy vs Eager Comparison ===\n\n", .{});

    try benchmark("Eager: filter + map + take", struct {
        fn run() !void {
            var gpa_local = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa_local.deinit();
            const alloc = gpa_local.allocator();

            const items = [_]i32{1} ** 1000;
            var col = try Collection(i32).fromSlice(alloc, &items);
            defer col.deinit();

            var filtered = try col.filter(struct {
                fn call(n: i32) bool {
                    return n > 0;
                }
            }.call);
            defer filtered.deinit();

            var mapped = try filtered.map(i32, struct {
                fn call(n: i32) i32 {
                    return n * 2;
                }
            }.call);
            defer mapped.deinit();

            var result = try mapped.take(10);
            defer result.deinit();
        }
    }.run, iterations);

    try benchmark("Lazy: filter + map + take", struct {
        fn run() !void {
            var gpa_local = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa_local.deinit();
            const alloc = gpa_local.allocator();

            const items = [_]i32{1} ** 1000;

            const filter_fn = struct {
                fn call(n: i32) bool {
                    return n > 0;
                }
            }.call;

            const map_fn = struct {
                fn call(n: i32) i32 {
                    return n * 2;
                }
            }.call;

            const lzy = LazyCollection(i32).fromSlice(alloc, &items);
            const filtered = lzy.filter(&filter_fn);
            const mapped = filtered.map(&map_fn);
            var result = try mapped.take(10);
            defer result.deinit();
        }
    }.run, iterations);

    std.debug.print("✓ Benchmarks completed\n", .{});
}
