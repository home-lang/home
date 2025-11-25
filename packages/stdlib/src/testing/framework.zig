const std = @import("std");

/// Comprehensive testing framework for Home language
///
/// Features:
/// - Unit testing with assertions
/// - Property-based testing
/// - Benchmark suite
/// - Mocking and stubbing
/// - Test fixtures
/// - Parameterized tests

pub const TestFramework = struct {
    allocator: std.mem.Allocator,
    tests: std.ArrayList(TestCase),
    benchmarks: std.ArrayList(Benchmark),
    failed_count: usize,
    passed_count: usize,
    skipped_count: usize,

    pub fn init(allocator: std.mem.Allocator) TestFramework {
        return .{
            .allocator = allocator,
            .tests = std.ArrayList(TestCase).init(allocator),
            .benchmarks = std.ArrayList(Benchmark).init(allocator),
            .failed_count = 0,
            .passed_count = 0,
            .skipped_count = 0,
        };
    }

    pub fn deinit(self: *TestFramework) void {
        for (self.tests.items) |*test_case| {
            test_case.deinit();
        }
        self.tests.deinit();

        for (self.benchmarks.items) |*bench| {
            self.allocator.free(bench.name);
        }
        self.benchmarks.deinit();
    }

    /// Register a test case
    pub fn addTest(
        self: *TestFramework,
        name: []const u8,
        test_fn: *const fn (*TestContext) anyerror!void,
    ) !void {
        try self.tests.append(.{
            .name = try self.allocator.dupe(u8, name),
            .test_fn = test_fn,
            .skip = false,
            .timeout_ms = null,
        });
    }

    /// Register a benchmark
    pub fn addBenchmark(
        self: *TestFramework,
        name: []const u8,
        bench_fn: *const fn (*BenchContext) anyerror!void,
    ) !void {
        try self.benchmarks.append(.{
            .name = try self.allocator.dupe(u8, name),
            .bench_fn = bench_fn,
        });
    }

    /// Run all tests
    pub fn runTests(self: *TestFramework) !TestResults {
        std.debug.print("\n=== Running Tests ===\n\n", .{});

        for (self.tests.items) |*test_case| {
            if (test_case.skip) {
                std.debug.print("˜ SKIP: {s}\n", .{test_case.name});
                self.skipped_count += 1;
                continue;
            }

            var ctx = TestContext.init(self.allocator, test_case.name);
            defer ctx.deinit();

            const start_time = std.time.milliTimestamp();

            test_case.test_fn(&ctx) catch |err| {
                const duration = std.time.milliTimestamp() - start_time;
                std.debug.print(" FAIL: {s} ({d}ms) - {}\n", .{ test_case.name, duration, err });
                self.failed_count += 1;

                if (ctx.failure_message) |msg| {
                    std.debug.print("  Message: {s}\n", .{msg});
                }
                continue;
            };

            const duration = std.time.milliTimestamp() - start_time;
            std.debug.print(" PASS: {s} ({d}ms)\n", .{ test_case.name, duration });
            self.passed_count += 1;
        }

        std.debug.print("\n=== Test Summary ===\n", .{});
        std.debug.print("Passed:  {d}\n", .{self.passed_count});
        std.debug.print("Failed:  {d}\n", .{self.failed_count});
        std.debug.print("Skipped: {d}\n", .{self.skipped_count});
        std.debug.print("Total:   {d}\n\n", .{self.tests.items.len});

        return TestResults{
            .total = self.tests.items.len,
            .passed = self.passed_count,
            .failed = self.failed_count,
            .skipped = self.skipped_count,
        };
    }

    /// Run all benchmarks
    pub fn runBenchmarks(self: *TestFramework) !void {
        std.debug.print("\n=== Running Benchmarks ===\n\n", .{});

        for (self.benchmarks.items) |*bench| {
            var ctx = BenchContext.init(self.allocator);
            defer ctx.deinit();

            try bench.bench_fn(&ctx);

            const avg_time = if (ctx.iterations > 0)
                @as(f64, @floatFromInt(ctx.total_time)) / @as(f64, @floatFromInt(ctx.iterations))
            else
                0.0;

            std.debug.print("Benchmark: {s}\n", .{bench.name});
            std.debug.print("  Iterations: {d}\n", .{ctx.iterations});
            std.debug.print("  Total time: {d}ms\n", .{ctx.total_time});
            std.debug.print("  Avg time:   {d:.3}ms\n", .{avg_time});
            std.debug.print("  Ops/sec:    {d:.0}\n\n", .{1000.0 / avg_time});
        }
    }
};

/// Test case definition
pub const TestCase = struct {
    name: []const u8,
    test_fn: *const fn (*TestContext) anyerror!void,
    skip: bool,
    timeout_ms: ?i64,

    pub fn deinit(self: *TestCase) void {
        _ = self;
    }
};

/// Benchmark definition
pub const Benchmark = struct {
    name: []const u8,
    bench_fn: *const fn (*BenchContext) anyerror!void,
};

/// Test execution context
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    test_name: []const u8,
    failure_message: ?[]const u8,
    assertions: usize,

    pub fn init(allocator: std.mem.Allocator, test_name: []const u8) TestContext {
        return .{
            .allocator = allocator,
            .test_name = test_name,
            .failure_message = null,
            .assertions = 0,
        };
    }

    pub fn deinit(self: *TestContext) void {
        if (self.failure_message) |msg| {
            self.allocator.free(msg);
        }
    }

    /// Assert that condition is true
    pub fn assertTrue(self: *TestContext, condition: bool, message: []const u8) !void {
        self.assertions += 1;
        if (!condition) {
            self.failure_message = try self.allocator.dupe(u8, message);
            return error.AssertionFailed;
        }
    }

    /// Assert that condition is false
    pub fn assertFalse(self: *TestContext, condition: bool, message: []const u8) !void {
        try self.assertTrue(!condition, message);
    }

    /// Assert equality
    pub fn assertEqual(self: *TestContext, comptime T: type, expected: T, actual: T) !void {
        self.assertions += 1;
        if (!std.meta.eql(expected, actual)) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Expected {any}, got {any}",
                .{ expected, actual },
            );
            self.failure_message = msg;
            return error.AssertionFailed;
        }
    }

    /// Assert not equal
    pub fn assertNotEqual(self: *TestContext, comptime T: type, not_expected: T, actual: T) !void {
        self.assertions += 1;
        if (std.meta.eql(not_expected, actual)) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Expected value to not equal {any}",
                .{not_expected},
            );
            self.failure_message = msg;
            return error.AssertionFailed;
        }
    }

    /// Assert that function throws error
    pub fn assertError(
        self: *TestContext,
        expected_error: anyerror,
        func: *const fn () anyerror!void,
    ) !void {
        self.assertions += 1;
        func() catch |err| {
            if (err == expected_error) {
                return;
            }
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Expected error {}, got {}",
                .{ expected_error, err },
            );
            self.failure_message = msg;
            return error.AssertionFailed;
        };

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Expected error {}, but no error was thrown",
            .{expected_error},
        );
        self.failure_message = msg;
        return error.AssertionFailed;
    }

    /// Assert null
    pub fn assertNull(self: *TestContext, comptime T: type, value: ?T) !void {
        self.assertions += 1;
        if (value != null) {
            self.failure_message = try self.allocator.dupe(u8, "Expected null value");
            return error.AssertionFailed;
        }
    }

    /// Assert not null
    pub fn assertNotNull(self: *TestContext, comptime T: type, value: ?T) !void {
        self.assertions += 1;
        if (value == null) {
            self.failure_message = try self.allocator.dupe(u8, "Expected non-null value");
            return error.AssertionFailed;
        }
    }
};

/// Benchmark execution context
pub const BenchContext = struct {
    allocator: std.mem.Allocator,
    iterations: usize,
    total_time: i64,
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator) BenchContext {
        return .{
            .allocator = allocator,
            .iterations = 0,
            .total_time = 0,
            .start_time = 0,
        };
    }

    pub fn deinit(self: *BenchContext) void {
        _ = self;
    }

    /// Start timing
    pub fn startTimer(self: *BenchContext) void {
        self.start_time = std.time.milliTimestamp();
    }

    /// Stop timing
    pub fn stopTimer(self: *BenchContext) void {
        const end_time = std.time.milliTimestamp();
        self.total_time += end_time - self.start_time;
        self.iterations += 1;
    }

    /// Run function N times and measure
    pub fn runN(self: *BenchContext, n: usize, func: *const fn () void) void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.startTimer();
            func();
            self.stopTimer();
        }
    }

    /// Run function for specified duration
    pub fn runFor(self: *BenchContext, duration_ms: i64, func: *const fn () void) void {
        const start = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start < duration_ms) {
            self.startTimer();
            func();
            self.stopTimer();
        }
    }
};

/// Test results
pub const TestResults = struct {
    total: usize,
    passed: usize,
    failed: usize,
    skipped: usize,

    pub fn success(self: *const TestResults) bool {
        return self.failed == 0;
    }
};

/// Property-based testing
pub const PropertyTest = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    num_tests: usize,

    pub fn init(allocator: std.mem.Allocator, seed: u64) PropertyTest {
        return .{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(seed),
            .num_tests = 100,
        };
    }

    /// Test a property with random inputs
    pub fn forAll(
        self: *PropertyTest,
        comptime T: type,
        generator: *const fn (*std.Random) T,
        property: *const fn (T) bool,
    ) !void {
        var i: usize = 0;
        while (i < self.num_tests) : (i += 1) {
            const value = generator(&self.rng.random());
            if (!property(value)) {
                std.debug.print("Property failed for value: {any}\n", .{value});
                return error.PropertyFailed;
            }
        }
    }
};

/// Test fixture for setup/teardown
pub const TestFixture = struct {
    allocator: std.mem.Allocator,
    setup_fn: ?*const fn (*TestFixture) anyerror!void,
    teardown_fn: ?*const fn (*TestFixture) anyerror!void,
    data: ?*anyopaque,

    pub fn init(allocator: std.mem.Allocator) TestFixture {
        return .{
            .allocator = allocator,
            .setup_fn = null,
            .teardown_fn = null,
            .data = null,
        };
    }

    pub fn setup(self: *TestFixture) !void {
        if (self.setup_fn) |func| {
            try func(self);
        }
    }

    pub fn teardown(self: *TestFixture) !void {
        if (self.teardown_fn) |func| {
            try func(self);
        }
    }

    pub fn run(self: *TestFixture, test_fn: *const fn (*TestFixture) anyerror!void) !void {
        try self.setup();
        defer self.teardown() catch {};
        try test_fn(self);
    }
};

/// Mock object system
pub fn Mock(comptime Interface: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        call_log: std.ArrayList(Call),

        const Call = struct {
            method_name: []const u8,
            args: []const u8,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .call_log = std.ArrayList(Call).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.call_log.items) |call| {
                self.allocator.free(call.method_name);
                self.allocator.free(call.args);
            }
            self.call_log.deinit();
        }

        pub fn recordCall(self: *Self, method_name: []const u8, args: []const u8) !void {
            try self.call_log.append(.{
                .method_name = try self.allocator.dupe(u8, method_name),
                .args = try self.allocator.dupe(u8, args),
            });
        }

        pub fn wasCalledWith(self: *Self, method_name: []const u8, expected_args: []const u8) bool {
            for (self.call_log.items) |call| {
                if (std.mem.eql(u8, call.method_name, method_name) and
                    std.mem.eql(u8, call.args, expected_args))
                {
                    return true;
                }
            }
            return false;
        }

        pub fn callCount(self: *Self, method_name: []const u8) usize {
            var count: usize = 0;
            for (self.call_log.items) |call| {
                if (std.mem.eql(u8, call.method_name, method_name)) {
                    count += 1;
                }
            }
            return count;
        }
    };
}
