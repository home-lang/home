const std = @import("std");
const test_runner = @import("runner.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var verbose = false;
    var benchmark = false;
    var max_parallel: ?usize = null;
    var use_cache = true;

    // Parse command line arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--benchmark") or std.mem.eql(u8, arg, "-b")) {
            benchmark = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            use_cache = false;
        } else if (std.mem.eql(u8, arg, "--parallel") or std.mem.eql(u8, arg, "-j")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --parallel requires a number argument\n", .{});
                std.process.exit(1);
            }
            i += 1;
            max_parallel = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            printHelp();
            std.process.exit(1);
        }
    }

    // Create test runner
    var runner = try test_runner.TestRunner.init(
        allocator,
        &test_runner.ION_TEST_SUITES,
        max_parallel,
    );
    defer runner.deinit();

    runner.verbose = verbose;
    runner.benchmark = benchmark;

    if (!use_cache) {
        // Clear cache
        runner.cache.entries.clearRetainingCapacity();
    }

    // Print configuration
    if (verbose or benchmark) {
        std.debug.print("Ion Test Runner\n", .{});
        std.debug.print("  Test suites: {d}\n", .{test_runner.ION_TEST_SUITES.len});
        std.debug.print("  Max parallel: {d}\n", .{runner.max_parallel});
        std.debug.print("  Cache: {s}\n", .{if (use_cache) "enabled" else "disabled"});
        std.debug.print("  Verbose: {s}\n", .{if (verbose) "yes" else "no"});
        std.debug.print("\n", .{});
    }

    // Run all tests
    const results = try runner.runAll();
    defer {
        for (results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(results);
    }

    // Print detailed benchmark if requested
    if (benchmark) {
        try printBenchmark(results);
    }

    // Exit with error code if any tests failed
    for (results) |result| {
        if (!result.success) {
            std.process.exit(1);
        }
    }
}

fn printHelp() void {
    std.debug.print(
        \\Ion Test Runner - Parallel test execution with caching
        \\
        \\Usage: ion-test [OPTIONS]
        \\
        \\Options:
        \\  -v, --verbose      Print detailed test execution info
        \\  -b, --benchmark    Print detailed benchmark results
        \\  -j, --parallel N   Set maximum parallel test jobs (default: CPU count - 1)
        \\  --no-cache         Disable test result caching
        \\  -h, --help         Show this help message
        \\
        \\Examples:
        \\  ion-test                    # Run all tests with defaults
        \\  ion-test -v -b              # Verbose mode with benchmarks
        \\  ion-test -j 4               # Use 4 parallel jobs
        \\  ion-test --no-cache         # Run all tests without cache
        \\
    , .{});
}

fn printBenchmark(results: []test_runner.TestResult) !void {
    std.debug.print("\n", .{});
    std.debug.print("================== Benchmark Results ==================\n", .{});
    std.debug.print("Suite                   Time (ms)    Status    Cached\n", .{});
    std.debug.print("-------------------------------------------------------\n", .{});

    var total_time: u64 = 0;
    for (results) |result| {
        const status = if (result.success) "PASS" else "FAIL";
        const cached = if (result.cached) "yes" else "no ";
        std.debug.print("{s:<20}  {d:>8}     {s}      {s}\n", .{
            result.suite_name,
            result.duration_ms,
            status,
            cached,
        });
        total_time += result.duration_ms;
    }

    std.debug.print("-------------------------------------------------------\n", .{});
    std.debug.print("Total                {d:>8}ms\n", .{total_time});
    std.debug.print("=======================================================\n", .{});

    // Calculate statistics
    var times = try std.heap.page_allocator.alloc(u64, results.len);
    defer std.heap.page_allocator.free(times);

    for (results, 0..) |result, i| {
        times[i] = result.duration_ms;
    }

    std.mem.sort(u64, times, {}, comptime std.sort.asc(u64));

    const min_time = times[0];
    const max_time = times[times.len - 1];
    const median_time = if (times.len % 2 == 0)
        (times[times.len / 2 - 1] + times[times.len / 2]) / 2
    else
        times[times.len / 2];

    const mean_time = total_time / results.len;

    std.debug.print("\nStatistics:\n", .{});
    std.debug.print("  Min:    {d}ms\n", .{min_time});
    std.debug.print("  Max:    {d}ms\n", .{max_time});
    std.debug.print("  Mean:   {d}ms\n", .{mean_time});
    std.debug.print("  Median: {d}ms\n", .{median_time});
}
