const std = @import("std");

/// Comprehensive testing framework with coverage, benchmarking, and property testing
pub const TestFramework = struct {
    allocator: std.mem.Allocator,
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
        start_time: i64,

        pub const Failure = struct {
            message: []const u8,
            file: []const u8,
            line: u32,
        };

        pub fn init(allocator: std.mem.Allocator, name: []const u8) TestContext {
            return .{
                .allocator = allocator,
                .name = name,
                .failures = std.ArrayList(Failure).init(allocator),
                .start_time = std.time.milliTimestamp(),
            };
        }

        pub fn deinit(self: *TestContext) void {
            self.failures.deinit();
        }

        /// Assert that condition is true
        pub fn assert(self: *TestContext, condition: bool, message: []const u8) !void {
            self.assertions += 1;
            if (!condition) {
                self.failed = true;
                try self.failures.append(.{
                    .message = message,
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
                try self.failures.append(.{
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
                try self.failures.append(.{
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
                try self.failures.append(.{
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
                    try self.failures.append(.{
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
            try self.failures.append(.{
                .message = message,
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
            self.files.deinit();
        }

        pub fn recordLine(self: *Coverage, file: []const u8, line: u32) !void {
            var file_cov = try self.files.getOrPut(file);
            if (!file_cov.found_existing) {
                file_cov.value_ptr.* = FileCoverage{
                    .path = file,
                    .lines = std.AutoHashMap(u32, u32).init(self.allocator),
                    .branches = std.ArrayList(FileCoverage.BranchCoverage).init(self.allocator),
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
            _ = allocator;

            var timer = try std.time.Timer.start();

            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                func();
            }

            const elapsed = timer.read();

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
        return .{
            .allocator = allocator,
            .tests = std.ArrayList(TestCase).init(allocator),
            .suites = std.ArrayList(TestSuite).init(allocator),
            .coverage = Coverage.init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *TestFramework) void {
        self.tests.deinit();
        self.suites.deinit();
        self.coverage.deinit();
    }

    pub fn registerTest(self: *TestFramework, test_case: TestCase) !void {
        try self.tests.append(test_case);
    }

    pub fn registerSuite(self: *TestFramework, suite: TestSuite) !void {
        try self.suites.append(suite);
    }

    pub fn run(self: *TestFramework) !TestResults {
        var results = TestResults{
            .total = 0,
            .passed = 0,
            .failed = 0,
            .skipped = 0,
            .duration_ms = 0,
        };

        const start_time = std.time.milliTimestamp();

        // Run standalone tests
        for (self.tests.items) |test_case| {
            if (test_case.skip) {
                results.skipped += 1;
                continue;
            }

            results.total += 1;
            var ctx = TestContext.init(self.allocator, test_case.name);
            defer ctx.deinit();

            test_case.func(&ctx) catch |err| {
                ctx.failed = true;
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Test threw error: {s}",
                    .{@errorName(err)},
                );
                try ctx.failures.append(.{
                    .message = msg,
                    .file = "unknown",
                    .line = 0,
                });
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
                var ctx = TestContext.init(self.allocator, test_case.name);
                defer ctx.deinit();

                // Run setup
                if (suite.setup) |setup| {
                    setup(&ctx) catch |err| {
                        ctx.failed = true;
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Setup threw error: {s}",
                            .{@errorName(err)},
                        );
                        try ctx.failures.append(.{
                            .message = msg,
                            .file = "unknown",
                            .line = 0,
                        });
                    };
                }

                // Run test
                if (!ctx.failed) {
                    test_case.func(&ctx) catch |err| {
                        ctx.failed = true;
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "Test threw error: {s}",
                            .{@errorName(err)},
                        );
                        try ctx.failures.append(.{
                            .message = msg,
                            .file = "unknown",
                            .line = 0,
                        });
                    };
                }

                // Run teardown
                if (suite.teardown) |teardown| {
                    teardown(&ctx) catch {};
                }

                if (ctx.failed) {
                    results.failed += 1;
                } else {
                    results.passed += 1;
                }
            }
        }

        results.duration_ms = @intCast(std.time.milliTimestamp() - start_time);

        return results;
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
