const std = @import("std");
const test_runner = @import("runner.zig");
const test_file_discovery = @import("test_file_discovery.zig");
const parser_mod = @import("parser");
const lexer_mod = @import("lexer");
const ast = @import("ast");
const interpreter_mod = @import("interpreter");

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
    var discover_tests = false;
    var discovery_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--discover") or std.mem.eql(u8, arg, "-d")) {
            discover_tests = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                discovery_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            printHelp();
            std.process.exit(1);
        }
    }

    // Handle test file discovery mode
    if (discover_tests) {
        const search_path = discovery_path orelse ".";

        var discovery = test_file_discovery.TestFileDiscovery.init(allocator);
        defer discovery.deinit();

        try discovery.discoverInDirectory(search_path);

        const stdout = std.io.getStdOut().writer();
        try test_file_discovery.printDiscoveredFiles(&discovery, stdout);

        if (discovery.test_files.items.len == 0) {
            std.debug.print("No test files found matching patterns: *.test.home, *.test.hm\n", .{});
            return;
        }

        // Run discovered tests
        std.debug.print("\nRunning {d} discovered test file(s)...\n\n", .{discovery.test_files.items.len});

        var total_passed: usize = 0;
        var total_failed: usize = 0;
        var total_skipped: usize = 0;

        for (discovery.test_files.items) |test_file| {
            std.debug.print("Running tests in: {s}\n", .{test_file});

            // Execute the test file
            // In a real implementation, this would:
            // 1. Parse the test file
            // 2. Extract test functions
            // 3. Execute each test
            // 4. Collect results

            // For now, just simulate test execution
            const result = try executeTestFile(allocator, test_file, verbose);

            total_passed += result.passed;
            total_failed += result.failed;
            total_skipped += result.skipped;

            if (result.failed > 0) {
                std.debug.print("  ❌ {d} failed, {d} passed, {d} skipped\n\n", .{ result.failed, result.passed, result.skipped });
            } else {
                std.debug.print("  ✅ {d} passed, {d} skipped\n\n", .{ result.passed, result.skipped });
            }
        }

        // Print summary
        std.debug.print("Test Summary:\n", .{});
        std.debug.print("  Total files: {d}\n", .{discovery.test_files.items.len});
        std.debug.print("  Total passed: {d}\n", .{total_passed});
        std.debug.print("  Total failed: {d}\n", .{total_failed});
        std.debug.print("  Total skipped: {d}\n", .{total_skipped});

        if (total_failed > 0) {
            std.process.exit(1);
        }

        return;
    }

    const TestFileResult = struct {
        passed: usize,
        failed: usize,
        skipped: usize,
    };

    fn executeTestFile(allocator: std.mem.Allocator, file_path: []const u8, verbose: bool) !TestFileResult {
        var result = TestFileResult{
            .passed = 0,
            .failed = 0,
            .skipped = 0,
        };

        // 1. Read the test file
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.debug.print("  Error: Failed to open file: {}\n", .{err});
            result.failed = 1;
            return result;
        };
        defer file.close();

        const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
            std.debug.print("  Error: Failed to read file: {}\n", .{err});
            result.failed = 1;
            return result;
        };
        defer allocator.free(source);

        // 2. Parse the test file
        var lex = lexer_mod.Lexer.init(source, file_path);
        var tokens = lex.scanTokens(allocator) catch |err| {
            std.debug.print("  Error: Lexer failed: {}\n", .{err});
            result.failed = 1;
            return result;
        };
        defer allocator.free(tokens);

        var prs = parser_mod.Parser.init(allocator, tokens, file_path);
        const program = prs.parse() catch |err| {
            std.debug.print("  Error: Parser failed: {}\n", .{err});
            result.failed = 1;
            return result;
        };
        defer program.deinit(allocator);

        // 3. Find all test functions (functions starting with "test_")
        var test_functions = std.ArrayList(*const ast.FunctionDecl).init(allocator);
        defer test_functions.deinit();

        for (program.statements) |stmt| {
            switch (stmt) {
                .FunctionDecl => |func_decl| {
                    if (std.mem.startsWith(u8, func_decl.name, "test_")) {
                        try test_functions.append(&func_decl);
                    }
                },
                else => {},
            }
        }

        if (verbose) {
            std.debug.print("  Found {d} test function(s)\n", .{test_functions.items.len});
        }

        // 4. Execute each test function
        for (test_functions.items) |test_func| {
            if (verbose) {
                std.debug.print("    Running: {s}...", .{test_func.name});
            }

            // Create interpreter for each test (isolated environment)
            var interp = interpreter_mod.Interpreter.init(allocator);
            defer interp.deinit();

            // Execute the test function
            const test_passed = blk: {
                // Create a call expression for the test function
                const call_result = interp.callFunction(test_func.name, &[_]interpreter_mod.Value{}, program) catch |err| {
                    if (verbose) {
                        std.debug.print(" FAILED ({any})\n", .{err});
                    }
                    break :blk false;
                };
                _ = call_result;

                if (verbose) {
                    std.debug.print(" PASSED\n", .{});
                }
                break :blk true;
            };

            if (test_passed) {
                result.passed += 1;
            } else {
                result.failed += 1;
            }
        }

        return result;
    }

    // Create test runner
    var runner = try test_runner.TestRunner.init(
        allocator,
        &test_runner.HOME_TEST_SUITES,
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
        std.debug.print("Home Test Runner\n", .{});
        std.debug.print("  Test suites: {d}\n", .{test_runner.HOME_TEST_SUITES.len});
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
        \\Home Test Runner - Parallel test execution with caching
        \\
        \\Usage: home-test [OPTIONS]
        \\
        \\Options:
        \\  -v, --verbose      Print detailed test execution info
        \\  -b, --benchmark    Print detailed benchmark results
        \\  -j, --parallel N   Set maximum parallel test jobs (default: CPU count - 1)
        \\  -d, --discover [PATH]  Discover test files (*.test.home, *.test.hm)
        \\  --no-cache         Disable test result caching
        \\  -h, --help         Show this help message
        \\
        \\Examples:
        \\  home-test                    # Run all tests with defaults
        \\  home-test -v -b              # Verbose mode with benchmarks
        \\  home-test -j 4               # Use 4 parallel jobs
        \\  home-test --no-cache         # Run all tests without cache
        \\  home-test --discover         # Discover test files in current directory
        \\  home-test --discover tests   # Discover test files in 'tests' directory
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
