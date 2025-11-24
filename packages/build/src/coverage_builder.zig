// Home Programming Language - Coverage-Aware Build System
// Integrates zig-test-framework coverage with incremental compilation and testing

const std = @import("std");
const coverage = @import("coverage.zig");
const parallel_build = @import("parallel_build.zig");

// ============================================================================
// Coverage Build Configuration
// ============================================================================

pub const CoverageBuildConfig = struct {
    /// Base build configuration
    build_config: parallel_build.ParallelBuilder,
    /// Coverage options from zig-test-framework
    coverage_options: coverage.BuildCoverageOptions,
    /// Test files to run with coverage
    test_files: []const []const u8 = &[_][]const u8{},
    /// Whether to fail build if coverage thresholds not met
    fail_on_threshold: bool = true,
    /// Aggregate results across all test runs
    aggregate_coverage: bool = true,
};

// ============================================================================
// Coverage-Aware Builder
// ============================================================================

pub const CoverageBuilder = struct {
    allocator: std.mem.Allocator,
    builder: *parallel_build.ParallelBuilder,
    coverage_options: coverage.BuildCoverageOptions,
    test_files: []const []const u8,
    aggregate_coverage: bool,
    fail_on_threshold: bool,

    /// Aggregated coverage results
    results: std.ArrayList(coverage.CoverageResult),

    pub fn init(
        allocator: std.mem.Allocator,
        builder: *parallel_build.ParallelBuilder,
        coverage_options: coverage.BuildCoverageOptions,
        test_files: []const []const u8,
    ) !CoverageBuilder {
        return .{
            .allocator = allocator,
            .builder = builder,
            .coverage_options = coverage_options,
            .test_files = test_files,
            .aggregate_coverage = true,
            .fail_on_threshold = coverage_options.fail_on_threshold,
            .results = .{},
        };
    }

    pub fn deinit(self: *CoverageBuilder) void {
        self.results.deinit(self.allocator);
    }

    /// Build with coverage tracking
    pub fn buildWithCoverage(self: *CoverageBuilder) !void {
        // Phase 1: Build all sources
        if (self.coverage_options.base.enabled and self.coverage_options.verbose) {
            std.debug.print("\n=== Phase 1: Building Sources ===\n", .{});
        }

        try self.builder.build();

        // Phase 2: Run tests with coverage
        if (self.coverage_options.base.enabled) {
            if (self.coverage_options.verbose) {
                std.debug.print("\n=== Phase 2: Running Tests with Coverage ===\n", .{});
            }

            try self.runTestsWithCoverage();

            // Phase 3: Aggregate and report coverage
            if (self.coverage_options.verbose) {
                std.debug.print("\n=== Phase 3: Coverage Report ===\n", .{});
            }

            try self.reportCoverage();
        }
    }

    /// Run all test files with coverage using zig-test-framework
    fn runTestsWithCoverage(self: *CoverageBuilder) !void {
        for (self.test_files, 0..) |test_file, i| {
            if (self.coverage_options.verbose) {
                std.debug.print("  [{d}/{d}] Testing: {s}\n", .{ i + 1, self.test_files.len, test_file });
            }

            // Build test executable first
            const test_exe = try self.buildTestExecutable(test_file);
            defer self.allocator.free(test_exe);

            // Run with coverage using zig-test-framework
            const success = try coverage.runWithCoverage(
                self.allocator,
                test_exe,
                &[_][]const u8{}, // No additional test args
                self.coverage_options.base,
            );

            if (!success) {
                std.debug.print("Warning: Test failed: {s}\n", .{test_file});
            }

            // Parse coverage results
            const result = try coverage.parseCoverageReport(
                self.allocator,
                self.coverage_options.base.output_dir,
            );

            try self.results.append(self.allocator, result);
        }
    }

    /// Build a test executable
    fn buildTestExecutable(self: *CoverageBuilder, test_file: []const u8) ![]const u8 {
        // Generate output path
        const test_name = std.fs.path.stem(test_file);
        const exe_name = try std.fmt.allocPrint(
            self.allocator,
            "zig-out/test/{s}",
            .{test_name},
        );

        // Build the test executable
        var argv: std.ArrayList([]const u8) = .{};
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "zig");
        try argv.append(self.allocator, "test");
        try argv.append(self.allocator, test_file);
        try argv.append(self.allocator, "-femit-bin");
        try argv.append(self.allocator, "-fno-emit-bin");
        try argv.append(self.allocator, "--test-no-exec");

        var child = std.process.Child.init(argv.items, self.allocator);
        const term = try child.spawnAndWait();

        if (term != .Exited or term.Exited != 0) {
            return error.TestBuildFailed;
        }

        return exe_name;
    }

    /// Aggregate and report coverage results
    fn reportCoverage(self: *CoverageBuilder) !void {
        if (self.results.items.len == 0) {
            std.debug.print("No coverage results to report\n", .{});
            return;
        }

        // Aggregate results if enabled
        const final_result = if (self.aggregate_coverage and self.results.items.len > 1)
            try self.aggregateResults()
        else
            self.results.items[0];

        // Print coverage summary using build-system extensions
        coverage.printDetailedSummary(final_result, self.coverage_options);

        // Check thresholds
        if (!coverage.meetsThresholds(final_result, self.coverage_options)) {
            if (self.fail_on_threshold) {
                return error.CoverageThresholdNotMet;
            }
        }

        // Generate additional reports
        if (self.coverage_options.json_report) {
            try self.generateJsonReport(final_result);
        }

        if (self.coverage_options.lcov_report) {
            try self.generateLcovReport(final_result);
        }
    }

    /// Aggregate coverage results from multiple test runs
    fn aggregateResults(self: *CoverageBuilder) !coverage.CoverageResult {
        var aggregated = coverage.CoverageResult{
            .total_lines = 0,
            .covered_lines = 0,
            .total_functions = 0,
            .covered_functions = 0,
            .total_branches = 0,
            .covered_branches = 0,
            .report_dir = self.coverage_options.base.output_dir,
        };

        for (self.results.items) |result| {
            aggregated.total_lines += result.total_lines;
            aggregated.covered_lines += result.covered_lines;
            aggregated.total_functions += result.total_functions;
            aggregated.covered_functions += result.covered_functions;
            aggregated.total_branches += result.total_branches;
            aggregated.covered_branches += result.covered_branches;
        }

        return aggregated;
    }

    /// Generate JSON coverage report
    fn generateJsonReport(self: *CoverageBuilder, result: coverage.CoverageResult) !void {
        const json_path = try std.fs.path.join(
            self.allocator,
            &.{ self.coverage_options.base.output_dir, "coverage.json" },
        );
        defer self.allocator.free(json_path);

        try coverage.generateJsonReport(self.allocator, result, json_path);

        if (self.coverage_options.verbose) {
            std.debug.print("Generated JSON report: {s}\n", .{json_path});
        }
    }

    /// Generate LCOV coverage report for CI integration
    fn generateLcovReport(self: *CoverageBuilder, result: coverage.CoverageResult) !void {
        const lcov_path = try std.fs.path.join(
            self.allocator,
            &.{ self.coverage_options.base.output_dir, "coverage.lcov" },
        );
        defer self.allocator.free(lcov_path);

        try coverage.generateLcovReport(self.allocator, result, lcov_path);

        if (self.coverage_options.verbose) {
            std.debug.print("Generated LCOV report: {s}\n", .{lcov_path});
        }
    }
};

// ============================================================================
// Coverage-Guided Test Selection
// ============================================================================

/// Select tests to run based on coverage gaps
pub const CoverageGuidedTesting = struct {
    allocator: std.mem.Allocator,
    previous_coverage: ?coverage.CoverageResult = null,

    pub fn init(allocator: std.mem.Allocator) CoverageGuidedTesting {
        return .{ .allocator = allocator };
    }

    /// Analyze coverage gaps and suggest tests to improve coverage
    pub fn suggestTests(
        self: *CoverageGuidedTesting,
        current_coverage: coverage.CoverageResult,
    ) ![]const []const u8 {
        var suggestions = std.ArrayList([]const u8).init(self.allocator);

        // Analyze uncovered lines
        const line_coverage_pct = current_coverage.linePercentage();
        if (line_coverage_pct < 80.0) {
            const uncovered_lines = current_coverage.lines_total - current_coverage.lines_covered;
            const suggestion = try std.fmt.allocPrint(
                self.allocator,
                "Line coverage is {d:.1}%. Add tests to cover {d} uncovered lines.",
                .{ line_coverage_pct, uncovered_lines },
            );
            try suggestions.append(suggestion);
        }

        // Analyze untested functions
        const func_coverage_pct = current_coverage.functionPercentage();
        if (func_coverage_pct < 90.0) {
            const uncovered_funcs = current_coverage.functions_total - current_coverage.functions_covered;
            if (uncovered_funcs > 0) {
                const suggestion = try std.fmt.allocPrint(
                    self.allocator,
                    "Function coverage is {d:.1}%. Add tests for {d} untested functions.",
                    .{ func_coverage_pct, uncovered_funcs },
                );
                try suggestions.append(suggestion);
            }
        }

        // Analyze untested branches
        const branch_coverage_pct = current_coverage.branchPercentage();
        if (branch_coverage_pct < 75.0) {
            const uncovered_branches = current_coverage.branches_total - current_coverage.branches_covered;
            if (uncovered_branches > 0) {
                const suggestion = try std.fmt.allocPrint(
                    self.allocator,
                    "Branch coverage is {d:.1}%. Add tests for edge cases to cover {d} untested branches.",
                    .{ branch_coverage_pct, uncovered_branches },
                );
                try suggestions.append(suggestion);
            }
        }

        // Suggest focusing on complex untested code
        if (suggestions.items.len > 0) {
            const priority_suggestion = try std.fmt.allocPrint(
                self.allocator,
                "Priority: Focus on high-complexity functions with low coverage to maximize test effectiveness.",
                .{},
            );
            try suggestions.append(priority_suggestion);
        }

        // If coverage is good, acknowledge it
        if (line_coverage_pct >= 80.0 and func_coverage_pct >= 90.0 and branch_coverage_pct >= 75.0) {
            const good_coverage = try std.fmt.allocPrint(
                self.allocator,
                "Coverage goals met! Line: {d:.1}%, Function: {d:.1}%, Branch: {d:.1}%",
                .{ line_coverage_pct, func_coverage_pct, branch_coverage_pct },
            );
            try suggestions.append(good_coverage);
        }

        return try suggestions.toOwnedSlice();
    }

    /// Compare current coverage with previous to show improvements
    pub fn showCoverageDelta(
        self: *CoverageGuidedTesting,
        current: coverage.CoverageResult,
    ) void {
        if (self.previous_coverage) |prev| {
            const line_delta = current.linePercentage() - prev.linePercentage();
            const func_delta = current.functionPercentage() - prev.functionPercentage();
            const branch_delta = current.branchPercentage() - prev.branchPercentage();

            std.debug.print("\n", .{});
            std.debug.print("Coverage Delta:\n", .{});
            printDelta("  Lines:    ", line_delta);
            printDelta("  Functions:", func_delta);
            printDelta("  Branches: ", branch_delta);
            std.debug.print("\n", .{});
        }

        self.previous_coverage = current;
    }

    fn printDelta(label: []const u8, delta: f64) void {
        if (delta > 0) {
            std.debug.print("{s} \x1b[32m+{d:.2}%\x1b[0m\n", .{ label, delta });
        } else if (delta < 0) {
            std.debug.print("{s} \x1b[31m{d:.2}%\x1b[0m\n", .{ label, delta });
        } else {
            std.debug.print("{s} {d:.2}%\n", .{ label, delta });
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "coverage builder initialization" {
    const allocator = std.testing.allocator;

    var builder = try parallel_build.ParallelBuilder.init(
        allocator,
        2,
        ".test-cache",
        "0.1.0",
    );
    defer builder.deinit();

    const cov_options = coverage.BuildCoverageOptions{
        .base = .{
            .enabled = true,
            .output_dir = "test-coverage",
        },
    };

    const test_files = [_][]const u8{"test1.zig"};

    var cov_builder = try CoverageBuilder.init(
        allocator,
        &builder,
        cov_options,
        &test_files,
    );
    defer cov_builder.deinit();

    try std.testing.expectEqual(@as(usize, 1), cov_builder.test_files.len);
}
