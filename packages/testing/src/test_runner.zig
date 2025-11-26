const std = @import("std");
const ast = @import("ast");
const interpreter = @import("interpreter");

/// Test execution framework
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    tests: std.ArrayList(TestCase),
    results: std.ArrayList(TestResult),
    config: Config,

    pub const Config = struct {
        parallel: bool = false,
        max_threads: usize = 4,
        timeout_ms: u64 = 5000,
        verbose: bool = false,
        fail_fast: bool = false,
        filter: ?[]const u8 = null,
    };

    pub const TestCase = struct {
        name: []const u8,
        fn_decl: *ast.FnDecl,
        file_path: []const u8,
        line: usize,
    };

    pub const TestResult = struct {
        test_case: TestCase,
        status: Status,
        duration_ms: u64,
        message: ?[]const u8 = null,

        pub const Status = enum {
            Passed,
            Failed,
            Skipped,
            Timeout,
        };
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) TestRunner {
        return .{
            .allocator = allocator,
            .tests = std.ArrayList(TestCase).init(allocator),
            .results = std.ArrayList(TestResult).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *TestRunner) void {
        self.tests.deinit();
        for (self.results.items) |*result| {
            if (result.message) |msg| {
                self.allocator.free(msg);
            }
        }
        self.results.deinit();
    }

    /// Add test case
    pub fn addTest(self: *TestRunner, test_case: TestCase) !void {
        // Check filter
        if (self.config.filter) |filter| {
            if (std.mem.indexOf(u8, test_case.name, filter) == null) {
                return; // Skip filtered test
            }
        }

        try self.tests.append(test_case);
    }

    /// Run all tests
    pub fn runAll(self: *TestRunner) !void {
        if (self.config.parallel) {
            try self.runParallel();
        } else {
            try self.runSequential();
        }
    }

    /// Run tests sequentially
    fn runSequential(self: *TestRunner) !void {
        for (self.tests.items) |test_case| {
            const result = try self.runSingleTest(test_case);
            try self.results.append(result);

            if (self.config.verbose) {
                self.printTestResult(&result);
            }

            if (self.config.fail_fast and result.status == .Failed) {
                break;
            }
        }
    }

    /// Run tests in parallel
    fn runParallel(self: *TestRunner) !void {
        const thread_count = @min(self.config.max_threads, self.tests.items.len);
        var threads = try self.allocator.alloc(std.Thread, thread_count);
        defer self.allocator.free(threads);

        var test_index: usize = 0;
        var test_mutex = std.Thread.Mutex{};

        const ThreadContext = struct {
            runner: *TestRunner,
            test_index: *usize,
            mutex: *std.Thread.Mutex,
        };

        var ctx = ThreadContext{
            .runner = self,
            .test_index = &test_index,
            .mutex = &test_mutex,
        };

        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, runTestWorker, .{&ctx});
        }

        for (threads) |thread| {
            thread.join();
        }
    }

    fn runTestWorker(ctx: *const anyopaque) void {
        const context: *ThreadContext = @ptrCast(@alignCast(ctx));

        while (true) {
            context.mutex.lock();
            const index = context.test_index.*;
            if (index >= context.runner.tests.items.len) {
                context.mutex.unlock();
                break;
            }
            context.test_index.* += 1;
            context.mutex.unlock();

            const test_case = context.runner.tests.items[index];
            const result = context.runner.runSingleTest(test_case) catch continue;

            context.mutex.lock();
            context.runner.results.append(result) catch {};
            context.mutex.unlock();
        }
    }

    /// Run a single test
    fn runSingleTest(self: *TestRunner, test_case: TestCase) !TestResult {
        const start_time = std.time.milliTimestamp();

        // Create interpreter instance for test execution
        var interp = interpreter.Interpreter.init(self.allocator);
        defer interp.deinit();

        // Execute test function
        const status = blk: {
            // Set timeout
            var timeout_timer = try std.time.Timer.start();

            // Create test context
            const test_ctx = TestContext.init(self.allocator);
            defer test_ctx.deinit();

            // Execute the test function
            const result = interp.executeFunction(test_case.fn_decl, &.{}) catch |err| {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Test failed with error: {}",
                    .{err},
                );
                return TestResult{
                    .test_case = test_case,
                    .status = .Failed,
                    .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
                    .message = msg,
                };
            };

            _ = result;

            // Check timeout
            if (timeout_timer.read() > self.config.timeout_ms * std.time.ns_per_ms) {
                break :blk .Timeout;
            }

            // Check assertions
            if (test_ctx.failed) {
                const msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Assertion failed: {s}",
                    .{test_ctx.failure_message orelse "unknown"},
                );
                return TestResult{
                    .test_case = test_case,
                    .status = .Failed,
                    .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
                    .message = msg,
                };
            }

            break :blk .Passed;
        };

        const duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));

        return TestResult{
            .test_case = test_case,
            .status = status,
            .duration_ms = duration_ms,
            .message = null,
        };
    }

    /// Print test result
    fn printTestResult(self: *TestRunner, result: *const TestResult) void {
        _ = self;
        const status_str = switch (result.status) {
            .Passed => "\x1b[32mPASSED\x1b[0m",
            .Failed => "\x1b[31mFAILED\x1b[0m",
            .Skipped => "\x1b[33mSKIPPED\x1b[0m",
            .Timeout => "\x1b[31mTIMEOUT\x1b[0m",
        };

        std.debug.print("[{s}] {s} ({d}ms)\n", .{
            status_str,
            result.test_case.name,
            result.duration_ms,
        });

        if (result.message) |msg| {
            std.debug.print("  {s}\n", .{msg});
        }
    }

    /// Print summary
    pub fn printSummary(self: *TestRunner) void {
        var passed: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;
        var timeout: usize = 0;

        for (self.results.items) |result| {
            switch (result.status) {
                .Passed => passed += 1,
                .Failed => failed += 1,
                .Skipped => skipped += 1,
                .Timeout => timeout += 1,
            }
        }

        std.debug.print("\n", .{});
        std.debug.print("Test Results:\n", .{});
        std.debug.print("=============\n", .{});
        std.debug.print("  Passed:  {d}\n", .{passed});
        std.debug.print("  Failed:  {d}\n", .{failed});
        std.debug.print("  Skipped: {d}\n", .{skipped});
        std.debug.print("  Timeout: {d}\n", .{timeout});
        std.debug.print("  Total:   {d}\n", .{self.results.items.len});
        std.debug.print("\n", .{});

        if (failed == 0 and timeout == 0) {
            std.debug.print("\x1b[32mAll tests passed!\x1b[0m\n", .{});
        } else {
            std.debug.print("\x1b[31m{d} test(s) failed\x1b[0m\n", .{failed + timeout});
        }
    }

    /// Get exit code (0 for success, 1 for failure)
    pub fn getExitCode(self: *TestRunner) u8 {
        for (self.results.items) |result| {
            if (result.status == .Failed or result.status == .Timeout) {
                return 1;
            }
        }
        return 0;
    }
};

/// Test context for assertions
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    failed: bool = false,
    failure_message: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestContext) void {
        if (self.failure_message) |msg| {
            self.allocator.free(msg);
        }
    }

    pub fn fail(self: *TestContext, message: []const u8) void {
        self.failed = true;
        self.failure_message = self.allocator.dupe(u8, message) catch null;
    }
};

/// Assertion helpers
pub const Assertions = struct {
    pub fn expectEqual(comptime T: type, expected: T, actual: T) !void {
        if (!std.meta.eql(expected, actual)) {
            return error.AssertionFailed;
        }
    }

    pub fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
        if (!std.mem.eql(u8, expected, actual)) {
            return error.AssertionFailed;
        }
    }

    pub fn expect(condition: bool) !void {
        if (!condition) {
            return error.AssertionFailed;
        }
    }

    pub fn expectError(comptime E: type, result: anytype) !void {
        if (result) |_| {
            return error.AssertionFailed;
        } else |err| {
            if (@TypeOf(err) != E) {
                return error.AssertionFailed;
            }
        }
    }
};

test "TestRunner basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runner = TestRunner.init(allocator, .{});
    defer runner.deinit();

    // Test would add test cases and run them
}
