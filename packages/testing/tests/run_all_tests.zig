const std = @import("std");

/// Master test runner - runs all test suites
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  ION MODERN TESTING FRAMEWORK - COMPREHENSIVE TEST SUITE\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("\n", .{});

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var suite_count: usize = 0;

    // Test Suite 1: Matchers
    std.debug.print("📦 Running Test Suite 1: Matchers\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    const matcher_result = try runTestSuite("test_matchers", allocator);
    total_passed += matcher_result.passed;
    total_failed += matcher_result.failed;
    suite_count += 1;
    printSuiteResult("Matchers", matcher_result);

    // Test Suite 2: Framework
    std.debug.print("\n📦 Running Test Suite 2: Framework\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    const framework_result = try runTestSuite("test_framework", allocator);
    total_passed += framework_result.passed;
    total_failed += framework_result.failed;
    suite_count += 1;
    printSuiteResult("Framework", framework_result);

    // Test Suite 3: Mocks
    std.debug.print("\n📦 Running Test Suite 3: Mocks\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    const mock_result = try runTestSuite("test_mocks", allocator);
    total_passed += mock_result.passed;
    total_failed += mock_result.failed;
    suite_count += 1;
    printSuiteResult("Mocks", mock_result);

    // Test Suite 4: Snapshots
    std.debug.print("\n📦 Running Test Suite 4: Snapshots\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    const snapshot_result = try runTestSuite("test_snapshots", allocator);
    total_passed += snapshot_result.passed;
    total_failed += snapshot_result.failed;
    suite_count += 1;
    printSuiteResult("Snapshots", snapshot_result);

    // Print final summary
    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  FINAL RESULTS\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Test Suites: {d} total, {d} passed, {d} failed\n", .{
        suite_count,
        suite_count - (if (total_failed > 0) @as(usize, 1) else @as(usize, 0)),
        if (total_failed > 0) @as(usize, 1) else @as(usize, 0),
    });
    std.debug.print("Tests:       {d} total, {d} passed, {d} failed\n", .{
        total_passed + total_failed,
        total_passed,
        total_failed,
    });

    if (total_failed > 0) {
        std.debug.print("\n❌ TEST SUITE FAILED\n", .{});
        std.debug.print("\nSome tests failed. Please review the output above.\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n✅ TEST SUITE PASSED\n", .{});
        std.debug.print("\nAll {d} tests across {d} suites passed successfully!\n", .{
            total_passed,
            suite_count,
        });
    }
}

const TestResult = struct {
    passed: usize,
    failed: usize,
};

fn runTestSuite(name: []const u8, allocator: std.mem.Allocator) !TestResult {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    // Build path to test executable
    var path_buffer: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "./zig-out/bin/{s}", .{name});

    try argv.append(path);

    // Try to execute the test
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();

    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                return TestResult{ .passed = 1, .failed = 0 };
            } else {
                return TestResult{ .passed = 0, .failed = 1 };
            }
        },
        else => {
            return TestResult{ .passed = 0, .failed = 1 };
        },
    }
}

fn printSuiteResult(name: []const u8, result: TestResult) void {
    if (result.failed > 0) {
        std.debug.print("❌ {s}: FAILED\n", .{name});
    } else {
        std.debug.print("✅ {s}: PASSED\n", .{name});
    }
}
