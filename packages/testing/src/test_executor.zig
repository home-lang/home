const std = @import("std");
const ast = @import("ast");
const Interpreter = @import("interpreter").Interpreter;
const test_discovery = @import("test_discovery");
const Io = std.Io;

/// Result of executing a single test
pub const TestExecutionResult = struct {
    name: []const u8,
    success: bool,
    duration_ms: u64,
    error_message: ?[]const u8 = null,
    file_path: []const u8,
    line: usize,

    pub fn deinit(self: *TestExecutionResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        self.* = undefined;
    }
};

/// Results of executing a test suite
pub const TestSuiteResult = struct {
    total: usize,
    passed: usize,
    failed: usize,
    duration_ms: u64,
    results: std.ArrayList(TestExecutionResult),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestSuiteResult {
        return .{
            .total = 0,
            .passed = 0,
            .failed = 0,
            .duration_ms = 0,
            .results = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestSuiteResult) void {
        for (self.results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.results.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addResult(self: *TestSuiteResult, result: TestExecutionResult) !void {
        try self.results.append(self.allocator, result);
        self.total += 1;
        if (result.success) {
            self.passed += 1;
        } else {
            self.failed += 1;
        }
        self.duration_ms += result.duration_ms;
    }
};

/// Executes discovered tests using the interpreter
pub fn executeTests(
    allocator: std.mem.Allocator,
    program: *ast.Program,
    discovered_tests: *test_discovery.TestDiscoveryResult,
) !TestSuiteResult {
    return executeTestsWithIo(
        allocator,
        Io.Threaded.global_single_threaded.io(),
        program,
        discovered_tests,
    );
}

pub fn executeTestsWithIo(
    allocator: std.mem.Allocator,
    io: Io,
    program: *ast.Program,
    discovered_tests: *test_discovery.TestDiscoveryResult,
) !TestSuiteResult {
    var suite_result = TestSuiteResult.init(allocator);
    errdefer suite_result.deinit();

    for (discovered_tests.tests.items) |test_item| {
        var result = try executeTest(allocator, io, program, test_item);
        // If append fails, free result's owned error message rather
        // than dropping it on the floor.
        errdefer result.deinit(allocator);
        try suite_result.addResult(result);
    }

    return suite_result;
}

fn executeTest(
    allocator: std.mem.Allocator,
    io: Io,
    program: *ast.Program,
    test_item: test_discovery.DiscoveredTest,
) !TestExecutionResult {
    const start_time = Io.Clock.awake.now(io);

    // Validate test function if it's a FnDecl
    switch (test_item.decl) {
        .fn_decl => |fn_decl| {
            test_discovery.validateTestFunction(fn_decl) catch |err| {
                return failedResult(allocator, io, start_time, test_item, "Invalid test function", err);
            };
        },
        .it_decl => {
            // it() tests don't need validation
        },
    }

    // Create interpreter instance
    const runtime = try Interpreter.init(allocator, program);
    defer runtime.deinit();
    runtime.setVerboseTests(false);

    // Register declarations while deliberately leaving every inline test body
    // untouched. Each discovered test must execute in isolation below.
    runtime.prepare() catch |err| {
        if (err == error.OutOfMemory) return err;
        return failedResult(allocator, io, start_time, test_item, "Failed to initialize", err);
    };

    // Execute the test based on its type
    switch (test_item.decl) {
        .fn_decl => |fn_decl| {
            _ = runtime.executeFunction(fn_decl, &.{}) catch |err| {
                if (err == error.OutOfMemory) return err;
                return failedResult(allocator, io, start_time, test_item, "Test failed", err);
            };
        },
        .it_decl => |it_decl| {
            runtime.executeTestBlock(it_decl.body) catch |err| {
                if (err == error.OutOfMemory) return err;
                return failedResult(allocator, io, start_time, test_item, "Test failed", err);
            };
        },
    }

    return .{
        .name = test_item.name,
        .success = true,
        .duration_ms = elapsedMilliseconds(io, start_time),
        .error_message = null,
        .file_path = test_item.file_path,
        .line = test_item.line,
    };
}

fn failedResult(
    allocator: std.mem.Allocator,
    io: Io,
    start_time: Io.Timestamp,
    test_item: test_discovery.DiscoveredTest,
    prefix: []const u8,
    err: anyerror,
) !TestExecutionResult {
    return .{
        .name = test_item.name,
        .success = false,
        .duration_ms = elapsedMilliseconds(io, start_time),
        .error_message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, @errorName(err) }),
        .file_path = test_item.file_path,
        .line = test_item.line,
    };
}

fn elapsedMilliseconds(io: Io, start_time: Io.Timestamp) u64 {
    return @intCast(start_time.durationTo(Io.Clock.awake.now(io)).toMilliseconds());
}

/// Prints test execution results
pub fn printResults(suite_result: *TestSuiteResult, writer: anytype) !void {
    try writer.print("\n{s}Test Results{s}\n", .{ "\x1b[1;36m", "\x1b[0m" });
    try writer.print("{s}━{s}\n", .{ "\x1b[36m", "\x1b[0m" });

    for (suite_result.results.items) |result| {
        if (result.success) {
            try writer.print("  {s}✓{s} {s} ({d}ms)\n", .{
                "\x1b[32m",
                "\x1b[0m",
                result.name,
                result.duration_ms,
            });
        } else {
            try writer.print("  {s}✗{s} {s} ({d}ms)\n", .{
                "\x1b[31m",
                "\x1b[0m",
                result.name,
                result.duration_ms,
            });
            if (result.error_message) |msg| {
                try writer.print("    {s}Error:{s} {s}\n", .{
                    "\x1b[31m",
                    "\x1b[0m",
                    msg,
                });
                try writer.print("    {s}at {s}:{d}{s}\n", .{
                    "\x1b[90m",
                    result.file_path,
                    result.line,
                    "\x1b[0m",
                });
            }
        }
    }

    try writer.print("\n{s}Summary{s}\n", .{ "\x1b[1;36m", "\x1b[0m" });
    try writer.print("{s}━{s}\n", .{ "\x1b[36m", "\x1b[0m" });

    const pass_color = if (suite_result.passed == suite_result.total) "\x1b[32m" else "\x1b[33m";
    try writer.print("  Tests:    {s}{d} passed{s}, {d} total\n", .{
        pass_color,
        suite_result.passed,
        "\x1b[0m",
        suite_result.total,
    });

    if (suite_result.failed > 0) {
        try writer.print("  Failed:   {s}{d}{s}\n", .{
            "\x1b[31m",
            suite_result.failed,
            "\x1b[0m",
        });
    }

    try writer.print("  Duration: {d}ms\n", .{suite_result.duration_ms});

    if (suite_result.failed > 0) {
        try writer.print("\n{s}Tests failed.{s}\n", .{ "\x1b[31m", "\x1b[0m" });
    } else {
        try writer.print("\n{s}All tests passed!{s}\n", .{ "\x1b[32m", "\x1b[0m" });
    }
}

test {
    std.testing.refAllDecls(@This());
}
