const std = @import("std");
const ast = @import("ast");

/// Discovered test function information
pub const DiscoveredTest = struct {
    name: []const u8,
    fn_decl: *ast.FnDecl,
    file_path: []const u8,
    line: u32,

    pub fn deinit(self: *DiscoveredTest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.file_path);
    }
};

/// Test discovery result
pub const TestDiscoveryResult = struct {
    tests: std.ArrayList(DiscoveredTest),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestDiscoveryResult {
        return .{
            .tests = std.ArrayList(DiscoveredTest).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestDiscoveryResult) void {
        for (self.tests.items) |*test_item| {
            test_item.deinit(self.allocator);
        }
        self.tests.deinit();
    }

    pub fn addTest(self: *TestDiscoveryResult, test_item: DiscoveredTest) !void {
        try self.tests.append(test_item);
    }
};

/// Discovers all @test annotated functions in a parsed AST
pub fn discoverTests(
    allocator: std.mem.Allocator,
    program: *ast.Program,
    file_path: []const u8,
) !TestDiscoveryResult {
    var result = TestDiscoveryResult.init(allocator);
    errdefer result.deinit();

    for (program.statements) |stmt| {
        try discoverTestsInStatement(allocator, stmt, file_path, &result);
    }

    return result;
}

fn discoverTestsInStatement(
    allocator: std.mem.Allocator,
    stmt: ast.Stmt,
    file_path: []const u8,
    result: *TestDiscoveryResult,
) !void {
    switch (stmt) {
        .FnDecl => |fn_decl| {
            if (fn_decl.is_test) {
                const name_copy = try allocator.dupe(u8, fn_decl.name);
                errdefer allocator.free(name_copy);

                const file_path_copy = try allocator.dupe(u8, file_path);
                errdefer allocator.free(file_path_copy);

                try result.addTest(.{
                    .name = name_copy,
                    .fn_decl = fn_decl,
                    .file_path = file_path_copy,
                    .line = fn_decl.node.loc.line,
                });
            }
        },
        // Could extend to discover tests in other contexts if needed
        else => {},
    }
}

/// Validates that test functions follow best practices
pub fn validateTestFunction(fn_decl: *ast.FnDecl) !void {
    // Test functions should have no parameters
    if (fn_decl.params.len > 0) {
        return error.TestFunctionHasParameters;
    }

    // Test functions should not be generic
    if (fn_decl.type_params.len > 0) {
        return error.TestFunctionIsGeneric;
    }

    // Test functions should not be async
    if (fn_decl.is_async) {
        return error.TestFunctionIsAsync;
    }
}

/// Prints a summary of discovered tests
pub fn printDiscoverySummary(result: *TestDiscoveryResult, writer: anytype) !void {
    try writer.print("\n{s}Test Discovery Summary{s}\n", .{ "\x1b[1;36m", "\x1b[0m" });
    try writer.print("{s}Found {d} test(s){s}\n\n", .{
        "\x1b[32m",
        result.tests.items.len,
        "\x1b[0m",
    });

    if (result.tests.items.len > 0) {
        for (result.tests.items, 0..) |test_item, i| {
            try writer.print("  {d}. {s}{s}{s} ({s}:{d})\n", .{
                i + 1,
                "\x1b[33m",
                test_item.name,
                "\x1b[0m",
                test_item.file_path,
                test_item.line,
            });
        }
        try writer.print("\n", .{});
    }
}
