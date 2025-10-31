// Home Programming Language - Code Coverage Integration
// Uses zig-test-framework for comprehensive code coverage analysis

const std = @import("std");

// Import zig-test-framework - this is the core coverage implementation
// Path: ~/Code/zig-test-framework
const test_framework = @import("zig-test-framework");

// ============================================================================
// Re-export Core Coverage Types from zig-test-framework
// ============================================================================

pub const CoverageOptions = test_framework.CoverageOptions;
pub const CoverageResult = test_framework.CoverageResult;
pub const CoverageTool = test_framework.CoverageTool;
pub const runWithCoverage = test_framework.runWithCoverage;
pub const runTestWithCoverage = test_framework.runTestWithCoverage;
pub const parseCoverageReport = test_framework.parseCoverageReport;
pub const printCoverageSummary = test_framework.printCoverageSummary;
pub const isCoverageToolAvailable = test_framework.isCoverageToolAvailable;

// ============================================================================
// Extended Build System Coverage Options
// ============================================================================

/// Extended coverage options for the Home build system
pub const BuildCoverageOptions = struct {
    /// Base coverage options from zig-test-framework
    base: CoverageOptions,

    /// Minimum line coverage threshold (fail build if below)
    min_line_coverage: ?f64 = null,

    /// Minimum function coverage threshold
    min_function_coverage: ?f64 = null,

    /// Minimum branch coverage threshold
    min_branch_coverage: ?f64 = null,

    /// Fail build on coverage threshold violation
    fail_on_threshold: bool = true,

    /// Generate JSON report
    json_report: bool = true,

    /// Generate LCOV report for CI integration
    lcov_report: bool = true,

    /// Verbose output
    verbose: bool = false,
};

// ============================================================================
// Coverage Result Extensions
// ============================================================================

/// Check if coverage result meets specified thresholds
pub fn meetsThresholds(result: CoverageResult, options: BuildCoverageOptions) bool {
    if (options.min_line_coverage) |threshold| {
        if (result.linePercentage() < threshold) return false;
    }

    if (options.min_function_coverage) |threshold| {
        if (result.functionPercentage() < threshold) return false;
    }

    if (options.min_branch_coverage) |threshold| {
        if (result.branchPercentage() < threshold) return false;
    }

    return true;
}

/// Get coverage level description
pub fn getCoverageLevel(result: CoverageResult) []const u8 {
    const line_pct = result.linePercentage();

    if (line_pct >= 90.0) return "Excellent";
    if (line_pct >= 80.0) return "Good";
    if (line_pct >= 70.0) return "Fair";
    return "Poor";
}

/// Print detailed coverage summary with color coding
pub fn printDetailedSummary(result: CoverageResult, options: BuildCoverageOptions) void {
    std.debug.print("\n", .{});
    std.debug.print("=== Code Coverage Summary ===\n", .{});

    const line_pct = result.linePercentage();
    const func_pct = result.functionPercentage();
    const branch_pct = result.branchPercentage();

    // Line coverage
    printCoverageBar("Lines:    ", result.covered_lines, result.total_lines, line_pct);

    // Function coverage
    printCoverageBar("Functions:", result.covered_functions, result.total_functions, func_pct);

    // Branch coverage
    printCoverageBar("Branches: ", result.covered_branches, result.total_branches, branch_pct);

    std.debug.print("\n", .{});
    std.debug.print("Coverage Level: {s}\n", .{getCoverageLevel(result)});

    // Check thresholds
    if (meetsThresholds(result, options)) {
        std.debug.print("\x1b[32m✓ Coverage thresholds met!\x1b[0m\n", .{});
    } else {
        std.debug.print("\x1b[31m✗ Coverage thresholds not met!\x1b[0m\n", .{});

        if (options.min_line_coverage) |threshold| {
            if (line_pct < threshold) {
                std.debug.print("  Line coverage: {d:.2}% < {d:.2}% (threshold)\n", .{
                    line_pct,
                    threshold,
                });
            }
        }

        if (options.min_function_coverage) |threshold| {
            if (func_pct < threshold) {
                std.debug.print("  Function coverage: {d:.2}% < {d:.2}% (threshold)\n", .{
                    func_pct,
                    threshold,
                });
            }
        }

        if (options.min_branch_coverage) |threshold| {
            if (branch_pct < threshold) {
                std.debug.print("  Branch coverage: {d:.2}% < {d:.2}% (threshold)\n", .{
                    branch_pct,
                    threshold,
                });
            }
        }
    }
}

fn printCoverageBar(label: []const u8, covered: usize, total: usize, percentage: f64) void {
    const bar_width = 20;
    const filled = @as(usize, @intFromFloat(percentage / 100.0 * @as(f64, @floatFromInt(bar_width))));

    std.debug.print("{s} {d}/{d}  ({d:.2}%) ", .{ label, covered, total, percentage });

    // Color based on percentage
    if (percentage >= 80.0) {
        std.debug.print("\x1b[32m", .{}); // Green
    } else if (percentage >= 70.0) {
        std.debug.print("\x1b[33m", .{}); // Yellow
    } else {
        std.debug.print("\x1b[31m", .{}); // Red
    }

    var i: usize = 0;
    while (i < bar_width) : (i += 1) {
        if (i < filled) {
            std.debug.print("█", .{});
        } else {
            std.debug.print("░", .{});
        }
    }

    std.debug.print("\x1b[0m\n", .{}); // Reset color
}

// ============================================================================
// Report Generation
// ============================================================================

/// Generate JSON coverage report
pub fn generateJsonReport(
    allocator: std.mem.Allocator,
    result: CoverageResult,
    output_path: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    const json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "timestamp": {d},
        \\  "total_lines": {d},
        \\  "covered_lines": {d},
        \\  "line_percentage": {d:.2},
        \\  "total_functions": {d},
        \\  "covered_functions": {d},
        \\  "function_percentage": {d:.2},
        \\  "total_branches": {d},
        \\  "covered_branches": {d},
        \\  "branch_percentage": {d:.2},
        \\  "coverage_level": "{s}"
        \\}}
        \\
    , .{
        std.time.timestamp(),
        result.total_lines,
        result.covered_lines,
        result.linePercentage(),
        result.total_functions,
        result.covered_functions,
        result.functionPercentage(),
        result.total_branches,
        result.covered_branches,
        result.branchPercentage(),
        getCoverageLevel(result),
    });
    defer allocator.free(json);

    try file.writeAll(json);
}

/// Generate LCOV coverage report for CI integration
pub fn generateLcovReport(
    allocator: std.mem.Allocator,
    result: CoverageResult,
    output_path: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    const lcov = try std.fmt.allocPrint(allocator,
        \\TN:
        \\SF:{s}
        \\FNF:{d}
        \\FNH:{d}
        \\LF:{d}
        \\LH:{d}
        \\BRF:{d}
        \\BRH:{d}
        \\end_of_record
        \\
    , .{
        result.report_dir,
        result.total_functions,
        result.covered_functions,
        result.total_lines,
        result.covered_lines,
        result.total_branches,
        result.covered_branches,
    });
    defer allocator.free(lcov);

    try file.writeAll(lcov);
}

// ============================================================================
// Tests
// ============================================================================

test "coverage percentages" {
    const result = CoverageResult{
        .total_lines = 100,
        .covered_lines = 85,
        .total_functions = 20,
        .covered_functions = 18,
        .total_branches = 50,
        .covered_branches = 40,
        .report_dir = "test-coverage",
    };

    try std.testing.expectApproxEqAbs(@as(f64, 85.0), result.linePercentage(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), result.functionPercentage(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), result.branchPercentage(), 0.01);
}

test "coverage level calculation" {
    const excellent = CoverageResult{
        .total_lines = 100,
        .covered_lines = 95,
        .total_functions = 0,
        .covered_functions = 0,
        .total_branches = 0,
        .covered_branches = 0,
        .report_dir = "test",
    };
    try std.testing.expectEqualStrings("Excellent", getCoverageLevel(excellent));

    const good = CoverageResult{
        .total_lines = 100,
        .covered_lines = 85,
        .total_functions = 0,
        .covered_functions = 0,
        .total_branches = 0,
        .covered_branches = 0,
        .report_dir = "test",
    };
    try std.testing.expectEqualStrings("Good", getCoverageLevel(good));

    const fair = CoverageResult{
        .total_lines = 100,
        .covered_lines = 75,
        .total_functions = 0,
        .covered_functions = 0,
        .total_branches = 0,
        .covered_branches = 0,
        .report_dir = "test",
    };
    try std.testing.expectEqualStrings("Fair", getCoverageLevel(fair));

    const poor = CoverageResult{
        .total_lines = 100,
        .covered_lines = 60,
        .total_functions = 0,
        .covered_functions = 0,
        .total_branches = 0,
        .covered_branches = 0,
        .report_dir = "test",
    };
    try std.testing.expectEqualStrings("Poor", getCoverageLevel(poor));
}

test "coverage thresholds" {
    const result = CoverageResult{
        .total_lines = 100,
        .covered_lines = 85,
        .total_functions = 20,
        .covered_functions = 18,
        .total_branches = 50,
        .covered_branches = 40,
        .report_dir = "test",
    };

    const strict_options = BuildCoverageOptions{
        .base = .{ .enabled = true, .output_dir = "coverage" },
        .min_line_coverage = 90.0,
        .min_function_coverage = 95.0,
        .min_branch_coverage = 85.0,
    };
    try std.testing.expect(!meetsThresholds(result, strict_options));

    const relaxed_options = BuildCoverageOptions{
        .base = .{ .enabled = true, .output_dir = "coverage" },
        .min_line_coverage = 80.0,
        .min_function_coverage = 85.0,
        .min_branch_coverage = 75.0,
    };
    try std.testing.expect(meetsThresholds(result, relaxed_options));
}
