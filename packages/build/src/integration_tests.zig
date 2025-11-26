const std = @import("std");
const Allocator = std.mem.Allocator;

/// Integration test configuration
pub const IntegrationTestConfig = struct {
    name: []const u8,
    timeout_ms: u64 = 30_000, // 30 seconds default
    working_dir: ?[]const u8 = null,
    env_vars: std.StringHashMap([]const u8),
    cleanup_on_success: bool = true,
    cleanup_on_failure: bool = false,

    pub fn init(allocator: Allocator, name: []const u8) IntegrationTestConfig {
        return .{
            .name = name,
            .env_vars = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *IntegrationTestConfig) void {
        var it = self.env_vars.iterator();
        while (it.next()) |entry| {
            self.env_vars.allocator.free(entry.key_ptr.*);
            self.env_vars.allocator.free(entry.value_ptr.*);
        }
        self.env_vars.deinit();
    }
};

/// Integration test result
pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    duration_ms: u64,
    output: []const u8,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *TestResult, allocator: Allocator) void {
        allocator.free(self.output);
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

/// Integration test runner
pub const IntegrationTestRunner = struct {
    allocator: Allocator,
    tests: std.ArrayList(IntegrationTest),
    results: std.ArrayList(TestResult),
    temp_dir: ?[]const u8 = null,

    pub const IntegrationTest = struct {
        config: IntegrationTestConfig,
        setup_fn: ?*const fn (*IntegrationTestRunner) anyerror!void = null,
        test_fn: *const fn (*IntegrationTestRunner) anyerror!void,
        teardown_fn: ?*const fn (*IntegrationTestRunner) anyerror!void = null,
    };

    pub fn init(allocator: Allocator) IntegrationTestRunner {
        return .{
            .allocator = allocator,
            .tests = std.ArrayList(IntegrationTest).init(allocator),
            .results = std.ArrayList(TestResult).init(allocator),
        };
    }

    pub fn deinit(self: *IntegrationTestRunner) void {
        for (self.tests.items) |*test_case| {
            test_case.config.deinit();
        }
        self.tests.deinit();

        for (self.results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.results.deinit();

        if (self.temp_dir) |dir| {
            std.fs.cwd().deleteTree(dir) catch {};
            self.allocator.free(dir);
        }
    }

    /// Add an integration test
    pub fn addTest(
        self: *IntegrationTestRunner,
        config: IntegrationTestConfig,
        test_fn: *const fn (*IntegrationTestRunner) anyerror!void,
    ) !void {
        try self.tests.append(.{
            .config = config,
            .test_fn = test_fn,
        });
    }

    /// Run all integration tests
    pub fn runAll(self: *IntegrationTestRunner) !void {
        // Create temporary directory for tests
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-integration-tests-{d}",
            .{std.time.timestamp()},
        );
        self.temp_dir = temp_dir;
        try std.fs.cwd().makePath(temp_dir);

        std.debug.print("\n=== Running Integration Tests ===\n", .{});
        std.debug.print("Test directory: {s}\n\n", .{temp_dir});

        for (self.tests.items) |test_case| {
            try self.runTest(test_case);
        }

        try self.printSummary();
    }

    fn runTest(self: *IntegrationTestRunner, test_case: IntegrationTest) !void {
        const start = std.time.milliTimestamp();

        std.debug.print("Running: {s}...", .{test_case.config.name});

        var output = std.ArrayList(u8).init(self.allocator);
        var error_msg: ?[]const u8 = null;
        var passed = false;

        // Run setup if provided
        if (test_case.setup_fn) |setup| {
            setup(self) catch |err| {
                error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Setup failed: {s}",
                    .{@errorName(err)},
                );
                const duration = @as(u64, @intCast(std.time.milliTimestamp() - start));
                try self.recordResult(test_case.config.name, false, duration, output.toOwnedSlice(), error_msg);
                std.debug.print(" FAILED (setup)\n", .{});
                return;
            };
        }

        // Run test
        test_case.test_fn(self) catch |err| {
            error_msg = try std.fmt.allocPrint(
                self.allocator,
                "Test failed: {s}",
                .{@errorName(err)},
            );
            const duration = @as(u64, @intCast(std.time.milliTimestamp() - start));
            try self.recordResult(test_case.config.name, false, duration, output.toOwnedSlice(), error_msg);
            std.debug.print(" FAILED\n", .{});

            // Run teardown even on failure
            if (test_case.teardown_fn) |teardown| {
                teardown(self) catch {};
            }
            return;
        };

        passed = true;

        // Run teardown if provided
        if (test_case.teardown_fn) |teardown| {
            teardown(self) catch |err| {
                error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Teardown failed: {s}",
                    .{@errorName(err)},
                );
                passed = false;
            };
        }

        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start));
        try self.recordResult(test_case.config.name, passed, duration, output.toOwnedSlice(), error_msg);

        if (passed) {
            std.debug.print(" PASSED ({d}ms)\n", .{duration});
        } else {
            std.debug.print(" FAILED (teardown)\n", .{});
        }
    }

    fn recordResult(
        self: *IntegrationTestRunner,
        name: []const u8,
        passed: bool,
        duration_ms: u64,
        output: []const u8,
        error_message: ?[]const u8,
    ) !void {
        try self.results.append(.{
            .name = name,
            .passed = passed,
            .duration_ms = duration_ms,
            .output = output,
            .error_message = error_message,
        });
    }

    fn printSummary(self: *IntegrationTestRunner) !void {
        var passed: usize = 0;
        var failed: usize = 0;
        var total_duration: u64 = 0;

        for (self.results.items) |result| {
            if (result.passed) {
                passed += 1;
            } else {
                failed += 1;
            }
            total_duration += result.duration_ms;
        }

        std.debug.print("\n=== Integration Test Summary ===\n", .{});
        std.debug.print("Total:  {d}\n", .{self.results.items.len});
        std.debug.print("Passed: {d}\n", .{passed});
        std.debug.print("Failed: {d}\n", .{failed});
        std.debug.print("Duration: {d}ms\n", .{total_duration});

        if (failed > 0) {
            std.debug.print("\nFailed tests:\n", .{});
            for (self.results.items) |result| {
                if (!result.passed) {
                    std.debug.print("  - {s}", .{result.name});
                    if (result.error_message) |msg| {
                        std.debug.print(": {s}", .{msg});
                    }
                    std.debug.print("\n", .{});
                }
            }
        }
    }

    /// Helper: Execute a command and return output
    pub fn executeCommand(self: *IntegrationTestRunner, argv: []const []const u8) ![]const u8 {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
            .cwd = self.temp_dir,
        });

        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            self.allocator.free(result.stdout);
            return error.CommandFailed;
        }

        return result.stdout;
    }

    /// Helper: Create a temporary file with content
    pub fn createTempFile(self: *IntegrationTestRunner, name: []const u8, content: []const u8) ![]const u8 {
        const temp_dir = self.temp_dir orelse return error.NoTempDir;

        const file_path = try std.fs.path.join(self.allocator, &.{ temp_dir, name });

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll(content);

        return file_path;
    }

    /// Helper: Read file content
    pub fn readFile(self: *IntegrationTestRunner, path: []const u8) ![]const u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        return try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
    }

    /// Helper: Assert file exists
    pub fn assertFileExists(self: *IntegrationTestRunner, path: []const u8) !void {
        _ = self;
        std.fs.cwd().access(path, .{}) catch {
            return error.FileDoesNotExist;
        };
    }

    /// Helper: Assert command succeeds
    pub fn assertCommandSucceeds(self: *IntegrationTestRunner, argv: []const []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
            .cwd = self.temp_dir,
        });

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Command failed: {s}\n", .{result.stderr});
            return error.CommandFailed;
        }
    }

    /// Helper: Assert command fails
    pub fn assertCommandFails(self: *IntegrationTestRunner, argv: []const []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
            .cwd = self.temp_dir,
        });

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            return error.CommandShouldHaveFailed;
        }
    }
};

/// Common integration test scenarios
pub const Scenarios = struct {
    /// Test that a program compiles and runs
    pub fn compileAndRun(
        runner: *IntegrationTestRunner,
        source_code: []const u8,
        expected_output: []const u8,
    ) !void {
        // Create source file
        const source_path = try runner.createTempFile("main.home", source_code);
        defer runner.allocator.free(source_path);

        // Compile
        try runner.assertCommandSucceeds(&.{ "home", "build", source_path });

        // Run
        const output = try runner.executeCommand(&.{"./main"});
        defer runner.allocator.free(output);

        if (!std.mem.eql(u8, output, expected_output)) {
            std.debug.print("Expected: {s}\n", .{expected_output});
            std.debug.print("Got: {s}\n", .{output});
            return error.OutputMismatch;
        }
    }

    /// Test that invalid code produces an error
    pub fn expectCompileError(
        runner: *IntegrationTestRunner,
        source_code: []const u8,
        expected_error: []const u8,
    ) !void {
        const source_path = try runner.createTempFile("main.home", source_code);
        defer runner.allocator.free(source_path);

        const result = std.process.Child.run(.{
            .allocator = runner.allocator,
            .argv = &.{ "home", "build", source_path },
            .cwd = runner.temp_dir,
        }) catch return error.CompilationShouldFail;

        defer runner.allocator.free(result.stdout);
        defer runner.allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            return error.ShouldHaveFailedToCompile;
        }

        if (std.mem.indexOf(u8, result.stderr, expected_error) == null) {
            std.debug.print("Expected error containing: {s}\n", .{expected_error});
            std.debug.print("Got: {s}\n", .{result.stderr});
            return error.WrongError;
        }
    }
};

test "IntegrationTestRunner - basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runner = IntegrationTestRunner.init(allocator);
    defer runner.deinit();

    try testing.expect(runner.tests.items.len == 0);
}
