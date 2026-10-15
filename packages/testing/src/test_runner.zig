const std = @import("std");
const ast = @import("ast");
const interpreter = @import("interpreter");
const Io = std.Io;

/// Test execution framework
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    tests: std.ArrayList(TestCase),
    results: std.ArrayList(TestResult),
    config: Config,
    io: Io,
    program: *const ast.Program,

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
        message_allocator: ?std.mem.Allocator = null,

        pub const Status = enum {
            Passed,
            Failed,
            Skipped,
            Timeout,
        };

        pub fn deinit(self: *TestResult) void {
            if (self.message) |message| self.message_allocator.?.free(message);
            self.* = undefined;
        }
    };

    const ThreadContext = struct {
        runner: *TestRunner,
        worker_allocator: std.mem.Allocator,
        next_index: usize = 0,
        first_error: ?anyerror = null,
        mutex: Io.Mutex = .init,
    };

    pub fn init(allocator: std.mem.Allocator, io: Io, program: *const ast.Program, config: Config) TestRunner {
        return .{
            .allocator = allocator,
            .tests = .empty,
            .results = .empty,
            .config = config,
            .io = io,
            .program = program,
        };
    }

    pub fn deinit(self: *TestRunner) void {
        self.tests.deinit(self.allocator);
        for (self.results.items) |*result| {
            result.deinit();
        }
        self.results.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add test case
    pub fn addTest(self: *TestRunner, test_case: TestCase) !void {
        // Check filter
        if (self.config.filter) |filter| {
            if (std.mem.indexOf(u8, test_case.name, filter) == null) {
                return; // Skip filtered test
            }
        }

        try self.tests.append(self.allocator, test_case);
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
            var result = try self.runSingleTest(self.allocator, test_case);
            errdefer result.deinit();
            try self.results.append(self.allocator, result);

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
        if (self.tests.items.len == 0) return;
        if (self.config.max_threads == 0) return error.InvalidThreadCount;

        const thread_count = @min(self.config.max_threads, self.tests.items.len);
        const threads = try self.allocator.alloc(std.Thread, thread_count);
        defer self.allocator.free(threads);

        var ctx = ThreadContext{
            .runner = self,
            .worker_allocator = std.heap.smp_allocator,
        };

        var spawned: usize = 0;
        var joined = false;
        errdefer if (!joined) for (threads[0..spawned]) |thread| thread.join();
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, runTestWorker, .{&ctx});
            spawned += 1;
        }

        for (threads) |thread| {
            thread.join();
        }
        joined = true;

        if (ctx.first_error) |err| return err;
    }

    fn runTestWorker(context: *ThreadContext) void {
        while (true) {
            context.mutex.lockUncancelable(context.runner.io);
            if (context.first_error != null) {
                context.mutex.unlock(context.runner.io);
                return;
            }

            const index = context.next_index;
            if (index >= context.runner.tests.items.len) {
                context.mutex.unlock(context.runner.io);
                return;
            }
            context.next_index += 1;
            context.mutex.unlock(context.runner.io);

            const test_case = context.runner.tests.items[index];
            var result = context.runner.runSingleTest(context.worker_allocator, test_case) catch |err| {
                context.mutex.lockUncancelable(context.runner.io);
                if (context.first_error == null) context.first_error = err;
                context.mutex.unlock(context.runner.io);
                return;
            };

            context.mutex.lockUncancelable(context.runner.io);
            context.runner.results.append(context.runner.allocator, result) catch |err| {
                result.deinit();
                if (context.first_error == null) context.first_error = err;
                context.mutex.unlock(context.runner.io);
                return;
            };
            context.mutex.unlock(context.runner.io);
        }
    }

    /// Run a single test
    fn runSingleTest(self: *TestRunner, work_allocator: std.mem.Allocator, test_case: TestCase) !TestResult {
        const start_time = Io.Clock.awake.now(self.io);

        // Create interpreter instance for test execution
        const interp = try interpreter.Interpreter.init(work_allocator, self.program);
        defer interp.deinit();
        interp.setVerboseTests(false);
        try interp.interpret();

        // Execute test function
        _ = interp.executeFunction(test_case.fn_decl, &.{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            const message = try std.fmt.allocPrint(
                work_allocator,
                "Test failed with error: {s}",
                .{@errorName(err)},
            );
            return .{
                .test_case = test_case,
                .status = .Failed,
                .duration_ms = elapsedMilliseconds(self.io, start_time),
                .message = message,
                .message_allocator = work_allocator,
            };
        };

        const duration_ms = elapsedMilliseconds(self.io, start_time);

        return .{
            .test_case = test_case,
            .status = if (duration_ms > self.config.timeout_ms) .Timeout else .Passed,
            .duration_ms = duration_ms,
        };
    }

    fn elapsedMilliseconds(io: Io, start: Io.Timestamp) u64 {
        return @intCast(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds());
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
        self.* = undefined;
    }

    pub fn fail(self: *TestContext, message: []const u8) void {
        const owned = self.allocator.dupe(u8, message) catch {
            self.failed = true;
            return;
        };
        if (self.failure_message) |previous| self.allocator.free(previous);
        self.failed = true;
        self.failure_message = owned;
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

    pub fn expectError(expected_error: anyerror, result: anytype) !void {
        if (result) |_| {
            return error.AssertionFailed;
        } else |err| {
            if (err != expected_error) {
                return error.AssertionFailed;
            }
        }
    }
};

test "TestRunner basic" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const program = ast.Program{ .statements = &.{} };

    var runner = TestRunner.init(allocator, testing.io, &program, .{});
    defer runner.deinit();

    // Test would add test cases and run them
}
