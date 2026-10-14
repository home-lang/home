const std = @import("std");
const Allocator = std.mem.Allocator;

fn milliTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

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
    io: std.Io,
    tests: std.ArrayList(IntegrationTest),
    results: std.ArrayList(TestResult),
    temp_dir: ?[]const u8 = null,

    pub const IntegrationTest = struct {
        config: IntegrationTestConfig,
        setup_fn: ?*const fn (*IntegrationTestRunner) anyerror!void = null,
        test_fn: *const fn (*IntegrationTestRunner) anyerror!void,
        teardown_fn: ?*const fn (*IntegrationTestRunner) anyerror!void = null,
    };

    pub fn init(allocator: Allocator, io: std.Io) IntegrationTestRunner {
        return .{
            .allocator = allocator,
            .io = io,
            .tests = .empty,
            .results = .empty,
        };
    }

    pub fn deinit(self: *IntegrationTestRunner) void {
        for (self.tests.items) |*test_case| {
            test_case.config.deinit();
        }
        self.tests.deinit(self.allocator);

        for (self.results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.results.deinit(self.allocator);

        if (self.temp_dir) |dir| {
            std.Io.Dir.cwd().deleteTree(self.io, dir) catch {};
            self.allocator.free(dir);
        }
    }

    /// Add an integration test
    pub fn addTest(
        self: *IntegrationTestRunner,
        config: IntegrationTestConfig,
        test_fn: *const fn (*IntegrationTestRunner) anyerror!void,
    ) !void {
        var owned_config = config;
        errdefer owned_config.deinit();
        try self.tests.append(self.allocator, .{
            .config = owned_config,
            .test_fn = test_fn,
        });
    }

    /// Run all integration tests
    pub fn runAll(self: *IntegrationTestRunner) !void {
        // Create temporary directory for tests
        const temp_dir = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/home-integration-tests-{d}",
            .{milliTimestamp(self.io)},
        );
        self.temp_dir = temp_dir;
        try std.Io.Dir.cwd().createDirPath(self.io, temp_dir);

        std.debug.print("\n=== Running Integration Tests ===\n", .{});
        std.debug.print("Test directory: {s}\n\n", .{temp_dir});

        for (self.tests.items) |test_case| {
            try self.runTest(test_case);
        }

        try self.printSummary();
    }

    fn runTest(self: *IntegrationTestRunner, test_case: IntegrationTest) !void {
        const start = milliTimestamp(self.io);

        std.debug.print("Running: {s}...", .{test_case.config.name});

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
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
                const duration = @as(u64, @intCast(milliTimestamp(self.io) - start));
                try self.recordResult(test_case.config.name, false, duration, try output.toOwnedSlice(self.allocator), error_msg);
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
            const duration = @as(u64, @intCast(milliTimestamp(self.io) - start));
            try self.recordResult(test_case.config.name, false, duration, try output.toOwnedSlice(self.allocator), error_msg);
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

        const duration = @as(u64, @intCast(milliTimestamp(self.io) - start));
        try self.recordResult(test_case.config.name, passed, duration, try output.toOwnedSlice(self.allocator), error_msg);

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
        errdefer {
            self.allocator.free(output);
            if (error_message) |message| self.allocator.free(message);
        }
        try self.results.append(self.allocator, .{
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

    fn runChild(self: *IntegrationTestRunner, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .cwd = if (self.temp_dir) |path| .{ .path = path } else .inherit,
        });
    }

    /// Helper: Execute a command and return output
    pub fn executeCommand(self: *IntegrationTestRunner, argv: []const []const u8) ![]const u8 {
        const result = try self.runChild(argv);

        defer self.allocator.free(result.stderr);

        if (!result.term.success()) {
            self.allocator.free(result.stdout);
            return error.CommandFailed;
        }

        return result.stdout;
    }

    /// Helper: Create a temporary file with content
    pub fn createTempFile(self: *IntegrationTestRunner, name: []const u8, content: []const u8) ![]const u8 {
        const temp_dir = self.temp_dir orelse return error.NoTempDir;

        const file_path = try std.fs.path.join(self.allocator, &.{ temp_dir, name });
        errdefer self.allocator.free(file_path);

        const file = try std.Io.Dir.cwd().createFile(self.io, file_path, .{});
        defer file.close(self.io);

        try file.writeStreamingAll(self.io, content);

        return file_path;
    }

    /// Helper: Read file content
    pub fn readFile(self: *IntegrationTestRunner, path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(10 * 1024 * 1024));
    }

    /// Helper: Assert file exists
    pub fn assertFileExists(self: *IntegrationTestRunner, path: []const u8) !void {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch {
            return error.FileDoesNotExist;
        };
    }

    /// Helper: Assert command succeeds
    pub fn assertCommandSucceeds(self: *IntegrationTestRunner, argv: []const []const u8) !void {
        const result = try self.runChild(argv);

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (!result.term.success()) {
            std.debug.print("Command failed: {s}\n", .{result.stderr});
            return error.CommandFailed;
        }
    }

    /// Helper: Assert command fails
    pub fn assertCommandFails(self: *IntegrationTestRunner, argv: []const []const u8) !void {
        const result = try self.runChild(argv);

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.success()) {
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

        const result = runner.runChild(&.{ "home", "build", source_path }) catch
            return error.CompilationShouldFail;

        defer runner.allocator.free(result.stdout);
        defer runner.allocator.free(result.stderr);

        if (result.term.success()) {
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

    var runner = IntegrationTestRunner.init(allocator, testing.io);
    defer runner.deinit();

    try testing.expect(runner.tests.items.len == 0);
}

test "IntegrationTestRunner - temporary file round trip" {
    const testing = std.testing;
    var runner = IntegrationTestRunner.init(testing.allocator, testing.io);
    defer runner.deinit();

    try runner.runAll();
    const path = try runner.createTempFile("round-trip.txt", "home");
    defer testing.allocator.free(path);
    try runner.assertFileExists(path);

    const contents = try runner.readFile(path);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("home", contents);
}
