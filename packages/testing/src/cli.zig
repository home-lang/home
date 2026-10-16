const std = @import("std");
const ast = @import("ast");
const cached_runner = @import("cached_test_runner");
const test_discovery = @import("test_discovery");
const test_executor = @import("test_executor");
const test_file_discovery = @import("test_file_discovery");
const Lexer = @import("lexer").Lexer;
const Parser = @import("parser").Parser;

const Io = std.Io;

pub const Options = struct {
    verbose: bool = false,
    benchmark: bool = false,
    max_parallel: ?usize = null,
    use_cache: bool = true,
    discover_tests: bool = false,
    discovery_path: []const u8 = ".",
    help: bool = false,
};

pub const RunnerConfig = struct {
    suites: []const cached_runner.TestSuite = &cached_runner.HOME_TEST_SUITES,
    cache_path: ?[]const u8 = null,
    executor_context: ?*anyopaque = null,
    executor: ?cached_runner.TestRunner.ExecuteFn = null,
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cli_args = try init.arena.allocator().alloc([]const u8, args.len -| 1);
    for (args[1..], cli_args) |arg, *destination| destination.* = arg;
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    const exit_code = run(init.gpa, init.io, cli_args, &stdout.interface) catch |err| code: {
        try stdout.interface.print("home-test: {s}\n", .{@errorName(err)});
        break :code 1;
    };
    try stdout.interface.flush();
    return exit_code;
}

pub fn parseOptions(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "--benchmark") or std.mem.eql(u8, arg, "-b")) {
            options.benchmark = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            options.use_cache = false;
        } else if (std.mem.eql(u8, arg, "--parallel") or std.mem.eql(u8, arg, "-j")) {
            index += 1;
            if (index >= args.len) return error.MissingParallelValue;
            options.max_parallel = std.fmt.parseInt(usize, args[index], 10) catch return error.InvalidParallelValue;
            if (options.max_parallel.? == 0) return error.InvalidParallelValue;
        } else if (std.mem.eql(u8, arg, "--discover") or std.mem.eql(u8, arg, "-d")) {
            options.discover_tests = true;
            if (index + 1 < args.len and !std.mem.startsWith(u8, args[index + 1], "-")) {
                index += 1;
                options.discovery_path = args[index];
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8, writer: *Io.Writer) !u8 {
    return runWithConfig(allocator, io, args, writer, .{});
}

pub fn runWithConfig(
    allocator: std.mem.Allocator,
    io: Io,
    args: []const []const u8,
    writer: *Io.Writer,
    config: RunnerConfig,
) !u8 {
    const options = parseOptions(args) catch |err| {
        try writer.print("Error: {s}\n\n", .{switch (err) {
            error.MissingParallelValue => "--parallel requires a positive integer",
            error.InvalidParallelValue => "--parallel must be a positive integer",
            error.UnknownArgument => "unknown argument",
        }});
        try printHelp(writer);
        return 2;
    };

    if (options.help) {
        try printHelp(writer);
        return 0;
    }
    if (options.discover_tests) return runDiscoveredTests(allocator, io, options, writer);
    return runCachedSuites(allocator, io, options, writer, config);
}

fn runDiscoveredTests(allocator: std.mem.Allocator, io: Io, options: Options, writer: *Io.Writer) !u8 {
    var files = test_file_discovery.TestFileDiscovery.initWithIo(allocator, io);
    defer files.deinit();
    try files.discoverInDirectory(options.discovery_path);
    try test_file_discovery.printDiscoveredFiles(&files, writer);

    if (files.test_files.items.len == 0) {
        try writer.writeAll("No test files found matching patterns: *.test.home, *.test.hm\n");
        return 0;
    }

    try writer.print("Running {d} discovered test file(s)...\n", .{files.test_files.items.len});
    var total_tests: usize = 0;
    var total_passed: usize = 0;
    var total_failed: usize = 0;

    for (files.test_files.items) |file_path| {
        try writer.print("\nRunning tests in: {s}\n", .{file_path});
        const source = Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
            if (err == error.OutOfMemory) return err;
            try reportFileError(writer, file_path, "read", err);
            total_tests += 1;
            total_failed += 1;
            continue;
        };
        defer allocator.free(source);

        var lexer = Lexer.init(allocator, source);
        var tokens = lexer.tokenize() catch |err| {
            if (err == error.OutOfMemory) return err;
            try reportFileError(writer, file_path, "lex", err);
            total_tests += 1;
            total_failed += 1;
            continue;
        };
        defer tokens.deinit(allocator);

        var parser = Parser.init(allocator, tokens.items) catch |err| {
            if (err == error.OutOfMemory) return err;
            try reportFileError(writer, file_path, "initialize parser", err);
            total_tests += 1;
            total_failed += 1;
            continue;
        };
        defer parser.deinit();
        const program: *ast.Program = parser.parse() catch |err| {
            if (err == error.OutOfMemory) return err;
            try reportFileError(writer, file_path, "parse", err);
            total_tests += 1;
            total_failed += 1;
            continue;
        };
        defer program.deinit(allocator);
        if (parser.errors.items.len > 0) {
            try writer.print("  Failed to parse {s}: {d} syntax error(s)\n", .{ file_path, parser.errors.items.len });
            total_tests += 1;
            total_failed += 1;
            continue;
        }

        var discovered = test_discovery.discoverTests(allocator, program, file_path) catch |err| {
            if (err == error.OutOfMemory) return err;
            try reportFileError(writer, file_path, "discover", err);
            total_tests += 1;
            total_failed += 1;
            continue;
        };
        defer discovered.deinit();
        if (options.verbose) try test_discovery.printDiscoverySummary(&discovered, writer);

        var result = try test_executor.executeTestsWithIo(allocator, io, program, &discovered);
        defer result.deinit();
        try test_executor.printResults(&result, writer);
        total_tests += result.total;
        total_passed += result.passed;
        total_failed += result.failed;
    }

    try writer.print(
        "\nTest Summary:\n  Total files: {d}\n  Total tests: {d}\n  Total passed: {d}\n  Total failed: {d}\n",
        .{ files.test_files.items.len, total_tests, total_passed, total_failed },
    );
    return if (total_failed == 0) 0 else 1;
}

fn reportFileError(writer: *Io.Writer, file_path: []const u8, operation: []const u8, err: anyerror) !void {
    try writer.print("  Failed to {s} {s}: {s}\n", .{ operation, file_path, @errorName(err) });
}

fn runCachedSuites(
    allocator: std.mem.Allocator,
    io: Io,
    options: Options,
    writer: *Io.Writer,
    config: RunnerConfig,
) !u8 {
    var runner = if (!options.use_cache)
        try cached_runner.TestRunner.initWithoutCache(allocator, io, config.suites, options.max_parallel)
    else if (config.cache_path) |cache_path|
        try cached_runner.TestRunner.initWithCachePath(allocator, io, config.suites, options.max_parallel, cache_path)
    else
        try cached_runner.TestRunner.initWithIo(allocator, io, config.suites, options.max_parallel);
    defer runner.deinit();
    runner.verbose = options.verbose;
    runner.benchmark = options.benchmark;
    if (config.executor) |executor| runner.setExecutor(config.executor_context, executor);

    if (options.verbose or options.benchmark) {
        try writer.print(
            "Home Test Runner\n  Test suites: {d}\n  Max parallel: {d}\n  Cache: {s}\n  Verbose: {s}\n\n",
            .{
                config.suites.len,
                runner.max_parallel,
                if (options.use_cache) "enabled" else "disabled",
                if (options.verbose) "yes" else "no",
            },
        );
    }

    const results = try runner.runAll();
    defer {
        for (results) |*result| result.deinit(allocator);
        allocator.free(results);
    }
    if (options.benchmark) try printBenchmark(results, writer);
    for (results) |result| if (!result.success) return 1;
    return 0;
}

pub fn printHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Home Test Runner - parallel test execution with caching
        \\
        \\Usage: home-test [OPTIONS]
        \\
        \\Options:
        \\  -v, --verbose          Print detailed test execution info
        \\  -b, --benchmark        Print detailed benchmark results
        \\  -j, --parallel N       Set maximum parallel test jobs
        \\  -d, --discover [PATH]  Discover and execute *.test.home and *.test.hm
        \\  --no-cache             Bypass cache reads and writes
        \\  -h, --help             Show this help message
        \\
    );
}

fn printBenchmark(results: []const cached_runner.TestResult, writer: *Io.Writer) !void {
    try writer.writeAll(
        "\n================== Benchmark Results ==================\n" ++
            "Suite                   Time (ms)    Status    Cached\n" ++
            "-------------------------------------------------------\n",
    );

    var total_time: u64 = 0;
    for (results) |result| {
        try writer.print("{s:<20}  {d:>8}     {s}      {s}\n", .{
            result.suite_name,
            result.duration_ms,
            if (result.success) "PASS" else "FAIL",
            if (result.cached) "yes" else "no ",
        });
        total_time += result.duration_ms;
    }
    try writer.print("-------------------------------------------------------\nTotal                {d:>8}ms\n", .{total_time});
    if (results.len == 0) {
        try writer.writeAll("No suites were selected.\n=======================================================\n");
        return;
    }

    const times = try std.heap.page_allocator.alloc(u64, results.len);
    defer std.heap.page_allocator.free(times);
    for (results, 0..) |result, index| times[index] = result.duration_ms;
    std.mem.sort(u64, times, {}, comptime std.sort.asc(u64));
    const median = if (times.len % 2 == 0)
        (times[times.len / 2 - 1] + times[times.len / 2]) / 2
    else
        times[times.len / 2];
    try writer.print(
        "=======================================================\n\nStatistics:\n  Min:    {d}ms\n  Max:    {d}ms\n  Mean:   {d}ms\n  Median: {d}ms\n",
        .{ times[0], times[times.len - 1], total_time / results.len, median },
    );
}

test {
    std.testing.refAllDecls(@This());
}
