const std = @import("std");
const ast = @import("ast");
const Interpreter = @import("interpreter").Interpreter;
const test_discovery = @import("test_discovery.zig");

/// Result of executing a single test
pub const TestExecutionResult = struct {
    name: []const u8,
    success: bool,
    duration_ms: u64,
    error_message: ?[]const u8 = null,
    file_path: []const u8,
    line: u32,

    pub fn deinit(self: *TestExecutionResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
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
            .results = std.ArrayList(TestExecutionResult).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestSuiteResult) void {
        for (self.results.items) |*result| {
            result.deinit(self.allocator);
        }
        self.results.deinit();
    }

    pub fn addResult(self: *TestSuiteResult, result: TestExecutionResult) !void {
        self.total += 1;
        if (result.success) {
            self.passed += 1;
        } else {
            self.failed += 1;
        }
        self.duration_ms += result.duration_ms;
        try self.results.append(result);
    }
};

/// Executes discovered tests using the interpreter
pub fn executeTests(
    allocator: std.mem.Allocator,
    program: *ast.Program,
    discovered_tests: *test_discovery.TestDiscoveryResult,
) !TestSuiteResult {
    var suite_result = TestSuiteResult.init(allocator);
    errdefer suite_result.deinit();

    for (discovered_tests.tests.items) |test_item| {
        const result = try executeTest(allocator, program, test_item);
        try suite_result.addResult(result);
    }

    return suite_result;
}

fn executeTest(
    allocator: std.mem.Allocator,
    program: *ast.Program,
    test_item: test_discovery.DiscoveredTest,
) !TestExecutionResult {
    const start_time = std.time.milliTimestamp();

    // Validate test function
    test_discovery.validateTestFunction(test_item.fn_decl) catch |err| {
        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Invalid test function: {s}",
            .{@errorName(err)},
        );
        return .{
            .name = test_item.name,
            .success = false,
            .duration_ms = duration,
            .error_message = error_msg,
            .file_path = test_item.file_path,
            .line = test_item.line,
        };
    };

    // Create interpreter instance
    var interpreter = Interpreter.init(allocator);
    defer interpreter.deinit();

    // Execute the program to register all functions
    interpreter.interpret(program) catch |err| {
        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Failed to initialize: {s}",
            .{@errorName(err)},
        );
        return .{
            .name = test_item.name,
            .success = false,
            .duration_ms = duration,
            .error_message = error_msg,
            .file_path = test_item.file_path,
            .line = test_item.line,
        };
    };

    // Call the test function
    const call_expr = try ast.CallExpr.init(
        allocator,
        try createIdentifierExpr(allocator, test_item.name),
        &.{},
        test_item.fn_decl.node.loc,
    );
    defer allocator.destroy(call_expr);

    const expr = try allocator.create(ast.Expr);
    defer allocator.destroy(expr);
    expr.* = .{ .CallExpr = call_expr };

    // Execute the test
    _ = interpreter.visitExpr(expr) catch |err| {
        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Test failed: {s}",
            .{@errorName(err)},
        );
        return .{
            .name = test_item.name,
            .success = false,
            .duration_ms = duration,
            .error_message = error_msg,
            .file_path = test_item.file_path,
            .line = test_item.line,
        };
    };

    const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
    return .{
        .name = test_item.name,
        .success = true,
        .duration_ms = duration,
        .error_message = null,
        .file_path = test_item.file_path,
        .line = test_item.line,
    };
}

fn createIdentifierExpr(allocator: std.mem.Allocator, name: []const u8) !*ast.Expr {
    const ident = try ast.Identifier.init(allocator, name, .{ .line = 0, .column = 0 });
    const expr = try allocator.create(ast.Expr);
    expr.* = .{ .Identifier = ident };
    return expr;
}

/// Prints test execution results
pub fn printResults(suite_result: *TestSuiteResult, writer: anytype) !void {
    try writer.print("\n{s}Test Results{s}\n", .{ "\x1b[1;36m", "\x1b[0m" });
    try writer.print("{s}━{s}\n", .{ "\x1b[36m", "\x1b[0m" }) catch {};

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
    try writer.print("{s}━{s}\n", .{ "\x1b[36m", "\x1b[0m" }) catch {};

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
