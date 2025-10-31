// Home Programming Language - Test with Coverage Example
// Demonstrates using zig-test-framework coverage across the workspace

const std = @import("std");
const test_framework = @import("zig-test-framework");

/// Example showing how to run tests with coverage enabled
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure coverage options
    const coverage_options = test_framework.CoverageOptions{
        .enabled = true,
        .output_dir = "coverage/workspace",
        .html_report = true,
        .clean = true,
    };

    std.debug.print("\n", .{});
    std.debug.print("===========================================\n", .{});
    std.debug.print("  Home Workspace Coverage Test Runner\n", .{});
    std.debug.print("===========================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Coverage tool available: {}\n", .{
        try test_framework.isCoverageToolAvailable(allocator, coverage_options.tool),
    });
    std.debug.print("Output directory: {s}\n", .{coverage_options.output_dir});
    std.debug.print("HTML reports: {}\n", .{coverage_options.html_report});
    std.debug.print("\n", .{});

    // Example: You would run your test executable with coverage
    // const success = try test_framework.runWithCoverage(
    //     allocator,
    //     "./zig-out/bin/your_test",
    //     &[_][]const u8{},
    //     coverage_options,
    // );

    std.debug.print("✓ Coverage system initialized successfully\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("To run tests with coverage:\n", .{});
    std.debug.print("  1. Build your test: zig build test\n", .{});
    std.debug.print("  2. All packages now have zig-test-framework available\n", .{});
    std.debug.print("  3. Use CoverageOptions in any test file\n", .{});
    std.debug.print("\n", .{});
}

test "workspace has zig-test-framework" {
    // Verify the framework is accessible
    const coverage_opts = test_framework.CoverageOptions{
        .enabled = true,
        .output_dir = "test-coverage",
    };

    try std.testing.expect(coverage_opts.enabled);
    try std.testing.expectEqualStrings("test-coverage", coverage_opts.output_dir);
}

test "can create coverage result" {
    const result = test_framework.CoverageResult{
        .total_lines = 100,
        .covered_lines = 85,
        .total_functions = 20,
        .covered_functions = 18,
        .total_branches = 50,
        .covered_branches = 40,
        .report_dir = "test",
    };

    try std.testing.expectApproxEqAbs(@as(f64, 85.0), result.linePercentage(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), result.functionPercentage(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), result.branchPercentage(), 0.01);
}
