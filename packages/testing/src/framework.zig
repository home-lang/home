const std = @import("std");
const Io = std.Io;

/// Comprehensive testing framework with coverage, benchmarking, and property testing
pub const TestFramework = struct {
    allocator: std.mem.Allocator,
    io: Io,
    tests: std.ArrayList(TestCase),
    suites: std.ArrayList(TestSuite),
    coverage: Coverage,
    config: Config,

    pub const Config = struct {
        parallel: bool = true,
        timeout_ms: u64 = 30000,
        retry_failed: u8 = 0,
        collect_coverage: bool = true,
        verbose: bool = false,
    };

    pub const TestCase = struct {
        name: []const u8,
        suite: ?[]const u8,
        func: *const fn (*TestContext) anyerror!void,
        skip: bool = false,
        timeout_ms: ?u64 = null,
    };

    pub const TestSuite = struct {
        name: []const u8,
        setup: ?*const fn (*TestContext) anyerror!void = null,
        teardown: ?*const fn (*TestContext) anyerror!void = null,
        tests: std.ArrayList(TestCase),
    };

    pub const TestContext = struct {
        allocator: std.mem.Allocator,
        name: []const u8,
        failed: bool = false,
        assertions: usize = 0,
        failures: std.ArrayList(Failure),
        start_time: Io.Timestamp,

        pub const Failure = struct {
            message: []const u8,
            file: []const u8,
            line: u32,
        };

        pub fn init(allocator: std.mem.Allocator, name: []const u8) TestContext {
            return TestContext.initWithIo(allocator, Io.Threaded.global_single_threaded.io(), name);
        }

        pub fn initWithIo(allocator: std.mem.Allocator, io: Io, name: []const u8) TestContext {
            return .{
                .allocator = allocator,
                .name = name,
                .failures = .empty,
                .start_time = Io.Clock.awake.now(io),
            };
        }

        pub fn deinit(self: *TestContext) void {
            // All Failure.message fields are owned (duped on append) so
            // we can free them uniformly here.
            for (self.failures.items) |f| {
                self.allocator.free(f.message);
            }
            self.failures.deinit(self.allocator);
            self.* = undefined;
        }

        /// Assert that condition is true
        pub fn assert(self: *TestContext, condition: bool, message: []const u8) !void {
            self.assertions += 1;
            if (!condition) {
                self.failed = true;
                // Dupe so all Failure.message values share the same
                // ownership semantics (freed by deinit).
                const msg = try self.allocator.dupe(u8, message);
                errdefer self.allocator.free(msg);
                try self.failures.append(self.allocator, .{
                    .message = msg,
                    .file = "unknown",
                    .line = 0,
                });
            }
        }

        /// Assert equality
        pub fn assertEqual(self: *TestContext, expected: anytype, actual: anytype) !void {
            self.assertions += 1;
            if (!std.meta.eql(expected, actual)) {
                self.failed = true;
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Expected {any}, got {any}",
                    .{ expected, actual },
                );
                errdefer self.allocator.free(msg);
                try self.failures.append(self.allocator, .{
                    .message = msg,
                    .file = "unknown",
                    .line = 0,
                });
            }
        }

        /// Assert not equal
        pub fn assertNotEqual(self: *TestContext, expected: anytype, actual: anytype) !void {
            self.assertions += 1;
            if (std.meta.eql(expected, actual)) {
                self.failed = true;
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Expected values to be different, but both were {any}",
                    .{expected},
                );
                errdefer self.allocator.free(msg);
                try self.failures.append(self.allocator, .{
                    .message = msg,
                    .file = "unknown",
                    .line = 0,
                });
            }
        }

        /// Assert error
        pub fn assertError(
            self: *TestContext,
            expected_error: anyerror,
            result: anyerror!void,
        ) !void {
            self.assertions += 1;
            if (result) |_| {
                self.failed = true;
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Expected error {s}, but succeeded",
                    .{@errorName(expected_error)},
                );
                errdefer self.allocator.free(msg);
                try self.failures.append(self.allocator, .{
                    .message = msg,
                    .file = "unknown",
                    .line = 0,
                });
            } else |err| {
                if (err != expected_error) {
                    self.failed = true;
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Expected error {s}, got {s}",
                        .{ @errorName(expected_error), @errorName(err) },
                    );
                    errdefer self.allocator.free(msg);
                    try self.failures.append(self.allocator, .{
                        .message = msg,
                        .file = "unknown",
                        .line = 0,
                    });
                }
            }
        }

        /// Fail with message
        pub fn fail(self: *TestContext, message: []const u8) !void {
            self.failed = true;
            // Dupe for consistent ownership — deinit frees all messages.
            const msg = try self.allocator.dupe(u8, message);
            errdefer self.allocator.free(msg);
            try self.failures.append(self.allocator, .{
                .message = msg,
                .file = "unknown",
                .line = 0,
            });
        }
    };

    /// Coverage tracking
    pub const Coverage = struct {
        allocator: std.mem.Allocator,
        files: std.StringHashMap(FileCoverage),

        pub const FileCoverage = struct {
            path: []const u8,
            lines: std.AutoHashMap(u32, u32), // line -> execution count
            branches: std.ArrayList(BranchCoverage),

            pub const BranchCoverage = struct {
                line: u32,
                taken: bool,
            };
        };

        pub fn init(allocator: std.mem.Allocator) Coverage {
            return .{
                .allocator = allocator,
                .files = std.StringHashMap(FileCoverage).init(allocator),
            };
        }

        pub fn deinit(self: *Coverage) void {
            // Each FileCoverage owns a lines map and branches list that
            // also need to be released — deiniting just `files` leaks
            // them.
            var it = self.files.valueIterator();
            while (it.next()) |fc| {
                fc.lines.deinit();
                fc.branches.deinit(self.allocator);
            }
            self.files.deinit();
            self.* = undefined;
        }

        pub fn recordLine(self: *Coverage, file: []const u8, line: u32) !void {
            var file_cov = try self.files.getOrPut(file);
            if (!file_cov.found_existing) {
                file_cov.value_ptr.* = FileCoverage{
                    .path = file,
                    .lines = std.AutoHashMap(u32, u32).init(self.allocator),
                    .branches = .empty,
                };
            }

            const entry = try file_cov.value_ptr.lines.getOrPut(line);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
        }

        pub fn generateReport(self: *Coverage, writer: anytype) !void {
            try writer.writeAll("Coverage Report:\n");
            try writer.writeAll("================\n\n");

            var total_lines: u32 = 0;
            var covered_lines: u32 = 0;

            var it = self.files.iterator();
            while (it.next()) |entry| {
                const file_cov = entry.value_ptr.*;
                try writer.print("File: {s}\n", .{file_cov.path});

                var line_it = file_cov.lines.iterator();
                while (line_it.next()) |line_entry| {
                    total_lines += 1;
                    if (line_entry.value_ptr.* > 0) {
                        covered_lines += 1;
                    }
                    try writer.print("  Line {d}: executed {d} times\n", .{
                        line_entry.key_ptr.*,
                        line_entry.value_ptr.*,
                    });
                }

                try writer.writeAll("\n");
            }

            const coverage_percent = if (total_lines > 0)
                @as(f64, @floatFromInt(covered_lines)) / @as(f64, @floatFromInt(total_lines)) * 100.0
            else
                0.0;

            try writer.print("Total Coverage: {d:.2}% ({d}/{d} lines)\n", .{
                coverage_percent,
                covered_lines,
                total_lines,
            });
        }
    };

    /// Benchmark support
    pub const Benchmark = struct {
        name: []const u8,
        iterations: usize,
        duration_ns: u64,

        pub fn run(
            allocator: std.mem.Allocator,
            name: []const u8,
            iterations: usize,
            func: *const fn () void,
        ) !Benchmark {
            return runWithIo(
                allocator,
                Io.Threaded.global_single_threaded.io(),
                name,
                iterations,
                func,
            );
        }

        pub fn runWithIo(
            allocator: std.mem.Allocator,
            io: Io,
            name: []const u8,
            iterations: usize,
            func: *const fn () void,
        ) !Benchmark {
            _ = allocator;
            if (iterations == 0) return error.InvalidIterations;

            const start = Io.Clock.awake.now(io);

            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                func();
            }

            const elapsed: u64 = @intCast(start.durationTo(Io.Clock.awake.now(io)).toNanoseconds());

            return Benchmark{
                .name = name,
                .iterations = iterations,
                .duration_ns = elapsed,
            };
        }

        pub fn nsPerOp(self: Benchmark) u64 {
            return self.duration_ns / self.iterations;
        }

        pub fn opsPerSec(self: Benchmark) f64 {
            const ns_per_op = @as(f64, @floatFromInt(self.nsPerOp()));
            return 1_000_000_000.0 / ns_per_op;
        }

        pub fn print(self: Benchmark, writer: anytype) !void {
            try writer.print("{s}:\n", .{self.name});
            try writer.print("  {d} iterations\n", .{self.iterations});
            try writer.print("  {d} ns/op\n", .{self.nsPerOp()});
            try writer.print("  {d:.2} ops/sec\n", .{self.opsPerSec()});
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) TestFramework {
        return TestFramework.initWithIo(allocator, Io.Threaded.global_single_threaded.io(), config);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: Io, config: Config) TestFramework {
        return .{
            .allocator = allocator,
            .io = io,
            .tests = .empty,
            .suites = .empty,
            .coverage = Coverage.init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *TestFramework) void {
        for (self.suites.items) |*suite| suite.tests.deinit(self.allocator);
        self.tests.deinit(self.allocator);
        self.suites.deinit(self.allocator);
        self.coverage.deinit();
        self.* = undefined;
    }

    pub fn registerTest(self: *TestFramework, test_case: TestCase) !void {
        try self.tests.append(self.allocator, test_case);
    }

    /// Takes ownership of `suite.tests` after a successful append.
    pub fn registerSuite(self: *TestFramework, suite: TestSuite) !void {
        try self.suites.append(self.allocator, suite);
    }

    pub fn run(self: *TestFramework) !TestResults {
        var results = TestResults{
            .total = 0,
            .passed = 0,
            .failed = 0,
            .skipped = 0,
            .duration_ms = 0,
        };

        const start_time = Io.Clock.awake.now(self.io);

        // Run standalone tests
        for (self.tests.items) |test_case| {
            if (test_case.skip) {
                results.skipped += 1;
                continue;
            }

            results.total += 1;
            var ctx = TestContext.initWithIo(self.allocator, self.io, test_case.name);
            defer ctx.deinit();

            test_case.func(&ctx) catch |err| {
                if (err == error.OutOfMemory) return err;
                ctx.failed = true;
                try appendError(&ctx, "Test threw error", err);
            };

            if (ctx.failed) {
                results.failed += 1;
                if (self.config.verbose) {
                    std.debug.print("FAIL: {s}\n", .{test_case.name});
                    for (ctx.failures.items) |failure| {
                        std.debug.print("  {s}\n", .{failure.message});
                    }
                }
            } else {
                results.passed += 1;
                if (self.config.verbose) {
                    std.debug.print("PASS: {s}\n", .{test_case.name});
                }
            }
        }

        // Run test suites
        for (self.suites.items) |suite| {
            for (suite.tests.items) |test_case| {
                if (test_case.skip) {
                    results.skipped += 1;
                    continue;
                }

                results.total += 1;
                var ctx = TestContext.initWithIo(self.allocator, self.io, test_case.name);
                defer ctx.deinit();

                // Run setup
                if (suite.setup) |setup| {
                    setup(&ctx) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        ctx.failed = true;
                        try appendError(&ctx, "Setup threw error", err);
                    };
                }

                // Run test
                if (!ctx.failed) {
                    test_case.func(&ctx) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        ctx.failed = true;
                        try appendError(&ctx, "Test threw error", err);
                    };
                }

                // Run teardown
                if (suite.teardown) |teardown| {
                    teardown(&ctx) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        ctx.failed = true;
                        try appendError(&ctx, "Teardown threw error", err);
                    };
                }

                if (ctx.failed) {
                    results.failed += 1;
                } else {
                    results.passed += 1;
                }
            }
        }

        results.duration_ms = @intCast(start_time.durationTo(Io.Clock.awake.now(self.io)).toMilliseconds());

        return results;
    }

    fn appendError(ctx: *TestContext, prefix: []const u8, err: anyerror) !void {
        const message = try std.fmt.allocPrint(ctx.allocator, "{s}: {s}", .{ prefix, @errorName(err) });
        errdefer ctx.allocator.free(message);
        try ctx.failures.append(ctx.allocator, .{
            .message = message,
            .file = "unknown",
            .line = 0,
        });
    }

    pub const TestResults = struct {
        total: usize,
        passed: usize,
        failed: usize,
        skipped: usize,
        duration_ms: u64,

        pub fn print(self: TestResults, writer: anytype) !void {
            try writer.writeAll("\nTest Results:\n");
            try writer.writeAll("=============\n");
            try writer.print("Total:   {d}\n", .{self.total});
            try writer.print("Passed:  {d}\n", .{self.passed});
            try writer.print("Failed:  {d}\n", .{self.failed});
            try writer.print("Skipped: {d}\n", .{self.skipped});
            try writer.print("Duration: {d}ms\n", .{self.duration_ms});

            if (self.failed == 0) {
                try writer.writeAll("\n✓ All tests passed!\n");
            } else {
                try writer.print("\n✗ {d} test(s) failed\n", .{self.failed});
            }
        }
    };
};

test {
    std.testing.refAllDecls(@This());
}
