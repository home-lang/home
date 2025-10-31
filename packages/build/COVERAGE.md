# Code Coverage for Home Programming Language

Comprehensive code coverage tracking and reporting for the Home build system, powered by **zig-test-framework** - a zero-dependency, pure-Zig coverage solution.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Integration with Build System](#integration-with-build-system)
- [Report Formats](#report-formats)
- [Coverage Thresholds](#coverage-thresholds)
- [Coverage-Guided Testing](#coverage-guided-testing)
- [Best Practices](#best-practices)
- [API Reference](#api-reference)

## Overview

The Home build system provides comprehensive code coverage tracking through **zig-test-framework**, a powerful testing and coverage library developed specifically for the Home ecosystem. This integration provides:

- **Zero External Dependencies**: No need to install kcov, grindcov, or any other external tools
- **Pure Zig Implementation**: Native integration with Zig's toolchain
- **Identify untested code**: Find functions, branches, and lines that lack test coverage
- **Measure test quality**: Quantify how thoroughly your tests exercise your codebase
- **Enforce quality gates**: Set minimum coverage thresholds and fail builds when not met
- **Track improvements**: Monitor coverage trends over time
- **Generate reports**: Create HTML, JSON, and LCOV reports for various tools

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 Home Build System                            │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │   Build     │→ │ Run Tests    │→ │    Aggregate    │   │
│  │   Sources   │  │ with Coverage│  │ & Report Results│   │
│  └─────────────┘  └──────────────┘  └─────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            ↓
                ┌───────────┴───────────┐
                │  zig-test-framework   │
                │  (Zero Dependencies)  │
                └───────────┬───────────┘
                            ↓
    ┌──────────────────────────────────────────────┐
    │  Reports: HTML | JSON | LCOV | Console      │
    └──────────────────────────────────────────────┘
```

### Key Features

- **Zero External Dependencies**: Uses zig-test-framework's built-in coverage
- **Pure Zig Implementation**: No need for kcov, grindcov, or external tools
- **Three Coverage Metrics**: Line, function, and branch coverage
- **Flexible Reporting**: HTML (visual), JSON (machine-readable), LCOV (CI integration)
- **Quality Gates**: Configurable thresholds with build failure on violation
- **Aggregation**: Combine coverage results from multiple test suites
- **Incremental Analysis**: Track coverage deltas between runs
- **Color-Coded Output**: Easy-to-read console reporting with color indicators

## Quick Start

### 1. No Installation Required!

The Home build system comes with **zig-test-framework** integrated - there's nothing to install. Coverage tracking works out of the box.

### 2. Basic Coverage Example

```zig
const std = @import("std");
const coverage = @import("coverage.zig");
const parallel_build = @import("parallel_build.zig");
const CoverageBuilder = @import("coverage_builder.zig").CoverageBuilder;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup parallel builder
    var builder = try parallel_build.ParallelBuilder.init(
        allocator,
        4, // max_workers
        ".build-cache",
        "1.0.0",
    );
    defer builder.deinit();

    // Add your source files
    try builder.addSource("src/main.zig");
    try builder.addSource("src/parser.zig");
    try builder.addSource("src/codegen.zig");

    // Configure coverage with zig-test-framework
    const cov_options = coverage.BuildCoverageOptions{
        .base = .{
            .enabled = true,
            .output_dir = "coverage",
            .html_report = true,
        },
        .json_report = true,
        .lcov_report = true,
        .verbose = true,
    };

    // Test files to run
    const test_files = [_][]const u8{
        "tests/parser_test.zig",
        "tests/codegen_test.zig",
        "tests/integration_test.zig",
    };

    // Build and run tests with coverage
    var cov_builder = try CoverageBuilder.init(
        allocator,
        &builder,
        cov_options,
        &test_files,
    );
    defer cov_builder.deinit();

    try cov_builder.buildWithCoverage();
}
```

### 3. View Results

```bash
# Open HTML report
open coverage/index.html

# View JSON summary
cat coverage/coverage.json

# Check LCOV report
cat coverage/coverage.lcov
```

## Configuration

### BuildCoverageOptions Reference

```zig
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

// Base options from zig-test-framework
pub const CoverageOptions = struct {
    /// Enable coverage collection
    enabled: bool = false,

    /// Output directory for coverage reports
    output_dir: []const u8 = "coverage",

    /// Include pattern for files to cover
    include_pattern: ?[]const u8 = null,

    /// Exclude pattern for files to skip
    exclude_pattern: ?[]const u8 = null,

    /// Generate HTML report
    html_report: bool = true,

    /// Clean coverage directory before running
    clean: bool = true,
};
```

### Build Profile Integration

```zig
// Development profile - no coverage (fast iteration)
pub fn devProfile(allocator: std.mem.Allocator) BuildCoverageOptions {
    _ = allocator;
    return .{
        .base = .{ .enabled = false },
    };
}

// Test profile - full coverage with HTML reports
pub fn testProfile(allocator: std.mem.Allocator) BuildCoverageOptions {
    _ = allocator;
    return .{
        .base = .{
            .enabled = true,
            .output_dir = "coverage",
            .html_report = true,
        },
        .json_report = true,
        .verbose = true,
    };
}

// CI profile - LCOV only with strict thresholds
pub fn ciProfile(allocator: std.mem.Allocator) BuildCoverageOptions {
    _ = allocator;
    return .{
        .base = .{
            .enabled = true,
            .output_dir = "coverage",
            .html_report = false,
        },
        .json_report = false,
        .lcov_report = true,
        .min_line_coverage = 80.0,
        .min_function_coverage = 85.0,
        .min_branch_coverage = 75.0,
        .verbose = false,
    };
}
```

## Integration with Build System

### Three-Phase Build Pipeline

The `CoverageBuilder` integrates coverage into your build pipeline:

```zig
pub fn buildWithCoverage(self: *CoverageBuilder) !void {
    // Phase 1: Build all sources
    try self.builder.build();

    // Phase 2: Run tests with coverage
    try self.runTestsWithCoverage();

    // Phase 3: Aggregate and report coverage
    try self.reportCoverage();
}
```

### Incremental Coverage

Coverage respects incremental builds - only rebuild what changed:

```zig
var builder = try parallel_build.ParallelBuilder.init(
    allocator,
    4,
    ".build-cache", // Incremental cache
    "1.0.0",
);

// Only changed files will be recompiled
// Coverage runs only on affected tests
try cov_builder.buildWithCoverage();
```

### Parallel Test Execution

Multiple test files run in parallel while maintaining isolated coverage data:

```zig
const test_files = [_][]const u8{
    "tests/unit/parser_test.zig",
    "tests/unit/lexer_test.zig",
    "tests/integration/e2e_test.zig",
};

var cov_builder = try CoverageBuilder.init(
    allocator,
    &builder,
    cov_options,
    &test_files,
);

// Tests run in parallel, coverage aggregated at the end
try cov_builder.buildWithCoverage();
```

## Report Formats

### Console Report (Default)

```
=== Code Coverage Summary ===
Lines:     847/1024  (82.71%) ████████████████░░░░
Functions: 123/145   (84.83%) ████████████████░░░░
Branches:  412/568   (72.54%) ██████████████░░░░░░

Coverage Level: Good
✓ Coverage thresholds met!
```

**Color Coding**:
- 🟢 **Excellent** (≥90%): Green
- 🟡 **Good** (≥80%): Yellow
- 🟠 **Fair** (≥70%): Yellow
- 🔴 **Poor** (<70%): Red

### HTML Report

Interactive HTML report with source code highlighting:

```zig
const cov_options = coverage.CoverageOptions{
    .html_report = true,
    .output_dir = "coverage",
};
```

**Features**:
- Source code view with line-by-line coverage
- Clickable file tree
- Coverage percentage per file
- Search and filter capabilities
- Branch coverage visualization

**View**: `open coverage/index.html`

### JSON Report

Machine-readable format for programmatic access:

```json
{
  "timestamp": 1704067200,
  "total_lines": 1024,
  "covered_lines": 847,
  "line_percentage": 82.71,
  "total_functions": 145,
  "covered_functions": 123,
  "function_percentage": 84.83,
  "total_branches": 568,
  "covered_branches": 412,
  "branch_percentage": 72.54,
  "coverage_level": "Good"
}
```

**Use Cases**:
- Custom reporting dashboards
- Automated analysis scripts
- Coverage trend tracking
- Integration with monitoring systems

### LCOV Report

Standard format for CI/CD integration:

```
TN:
SF:coverage
FNF:145
FNH:123
LF:1024
LH:847
BRF:568
BRH:412
end_of_record
```

**Integrations**:
- Codecov
- Coveralls
- SonarQube
- GitLab CI
- GitHub Actions

## Coverage Thresholds

### Setting Thresholds

Enforce minimum coverage percentages and fail builds when not met:

```zig
const cov_options = coverage.CoverageOptions{
    .enabled = true,
    .min_line_coverage = 80.0,      // Require 80% line coverage
    .min_function_coverage = 85.0,  // Require 85% function coverage
    .min_branch_coverage = 75.0,    // Require 75% branch coverage
};

var cov_builder = try CoverageBuilder.init(
    allocator,
    &builder,
    cov_options,
    &test_files,
);

// Throws error.CoverageThresholdNotMet if thresholds not met
try cov_builder.buildWithCoverage();
```

### Threshold Failure Output

```
=== Code Coverage Summary ===
Lines:     720/1024  (70.31%) ██████████████░░░░░░
Functions: 118/145   (81.38%) ████████████████░░░░
Branches:  380/568   (66.90%) █████████████░░░░░░░

Coverage Level: Fair

✗ Coverage thresholds not met!
  Line coverage: 70.31% < 80.00% (threshold)
  Branch coverage: 66.90% < 75.00% (threshold)

error: CoverageThresholdNotMet
```

### Conditional Threshold Enforcement

```zig
var cov_builder = try CoverageBuilder.init(
    allocator,
    &builder,
    cov_options,
    &test_files,
);

// Only fail on thresholds in CI environment
cov_builder.fail_on_threshold = isCI();

try cov_builder.buildWithCoverage();
```

### Progressive Thresholds

Gradually increase coverage requirements:

```zig
// Version 1.0: Initial thresholds
const v1_thresholds = coverage.CoverageOptions{
    .min_line_coverage = 60.0,
    .min_function_coverage = 65.0,
    .min_branch_coverage = 55.0,
};

// Version 2.0: Stricter thresholds
const v2_thresholds = coverage.CoverageOptions{
    .min_line_coverage = 75.0,
    .min_function_coverage = 80.0,
    .min_branch_coverage = 70.0,
};

// Version 3.0: Production-grade thresholds
const v3_thresholds = coverage.CoverageOptions{
    .min_line_coverage = 85.0,
    .min_function_coverage = 90.0,
    .min_branch_coverage = 80.0,
};
```

## Coverage-Guided Testing

### Coverage Delta Tracking

Monitor coverage improvements over time:

```zig
const CoverageGuidedTesting = @import("coverage_builder.zig").CoverageGuidedTesting;

var guided = CoverageGuidedTesting.init(allocator);

// First run
const result1 = try coverage.parseCoverageReport(allocator, "coverage");
guided.showCoverageDelta(result1);

// Make improvements...

// Second run
const result2 = try coverage.parseCoverageReport(allocator, "coverage");
guided.showCoverageDelta(result2);
```

**Output**:
```
Coverage Delta:
  Lines:     +5.20%
  Functions: +3.15%
  Branches:  +7.80%
```

### Test Prioritization

Identify high-value tests to write based on coverage gaps:

```zig
pub fn suggestTests(
    self: *CoverageGuidedTesting,
    current_coverage: coverage.CoverageResult,
) ![]const []const u8 {
    // Analyze uncovered code
    // Prioritize based on:
    // - Complexity of uncovered functions
    // - Critical code paths (error handling)
    // - Public API surface area

    return suggested_tests;
}
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Coverage

on: [push, pull_request]

jobs:
  coverage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install kcov
        run: |
          sudo apt-get update
          sudo apt-get install -y kcov

      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.0

      - name: Run tests with coverage
        run: |
          zig build test-coverage

      - name: Upload to Codecov
        uses: codecov/codecov-action@v3
        with:
          files: ./coverage/coverage.lcov
          flags: unittests
          fail_ci_if_error: true
```

### GitLab CI

```yaml
coverage:
  stage: test
  image: ziglang/zig:0.15.0
  before_script:
    - apt-get update && apt-get install -y kcov
  script:
    - zig build test-coverage
  coverage: '/Lines:\s+\d+\/\d+\s+\((\d+\.\d+)%\)/'
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage/coverage.lcov
```

### Jenkins

```groovy
pipeline {
    agent any

    stages {
        stage('Test with Coverage') {
            steps {
                sh 'zig build test-coverage'
            }
        }

        stage('Publish Coverage') {
            steps {
                publishHTML([
                    reportDir: 'coverage',
                    reportFiles: 'index.html',
                    reportName: 'Coverage Report'
                ])
            }
        }

        stage('Check Thresholds') {
            steps {
                script {
                    def coverage = readJSON file: 'coverage/coverage.json'
                    if (coverage.line_percentage < 80.0) {
                        error("Coverage ${coverage.line_percentage}% below threshold 80%")
                    }
                }
            }
        }
    }
}
```

## Best Practices

### 1. Start with Reasonable Thresholds

Don't aim for 100% coverage immediately:

```zig
// Bad: Unrealistic initial thresholds
const bad_options = coverage.CoverageOptions{
    .min_line_coverage = 95.0,
    .min_function_coverage = 98.0,
    .min_branch_coverage = 90.0,
};

// Good: Achievable initial thresholds
const good_options = coverage.CoverageOptions{
    .min_line_coverage = 70.0,
    .min_function_coverage = 75.0,
    .min_branch_coverage = 65.0,
};
```

### 2. Focus on Critical Code Paths

Prioritize coverage for:
- Public APIs
- Error handling paths
- Complex algorithms
- Business logic
- Security-sensitive code

Use `include_pattern` to focus:

```zig
const cov_options = coverage.CoverageOptions{
    .include_pattern = "src/api/,src/core/,src/security/",
    .exclude_pattern = "src/vendor/,src/generated/",
};
```

### 3. Exclude Generated and Vendor Code

```zig
const cov_options = coverage.CoverageOptions{
    .exclude_pattern = "vendor/,generated/,proto/,*_test.zig",
};
```

### 4. Use Coverage to Find Gaps, Not as a Goal

High coverage ≠ Good tests

```zig
// This has 100% line coverage but tests nothing:
test "bad test" {
    const result = complexFunction();
    _ = result; // Used but not asserted
}

// This tests actual behavior:
test "good test" {
    const result = complexFunction();
    try std.testing.expectEqual(42, result);
    try std.testing.expect(result > 0);
}
```

### 5. Run Coverage Locally Before CI

```bash
# Quick local coverage check
zig build test-coverage

# Open HTML report
open coverage/index.html

# Check specific thresholds
zig build test-coverage --min-coverage=80
```

### 6. Track Coverage Trends

```bash
# Save coverage history
mkdir -p coverage-history
cp coverage/coverage.json "coverage-history/$(date +%Y%m%d).json"

# Generate trend report
python scripts/coverage-trends.py coverage-history/
```

### 7. Separate Unit and Integration Coverage

```zig
// Unit tests - high coverage expected
const unit_options = coverage.CoverageOptions{
    .output_dir = "coverage/unit",
    .min_line_coverage = 85.0,
};

// Integration tests - lower coverage expected (but more realistic)
const integration_options = coverage.CoverageOptions{
    .output_dir = "coverage/integration",
    .min_line_coverage = 60.0,
};
```

### 8. Use Verbose Mode During Development

```zig
const cov_options = coverage.CoverageOptions{
    .verbose = true, // See detailed progress
    .html_report = true, // Visual feedback
};
```

## Troubleshooting

### Issue: No Coverage Data Generated

**Symptoms**: Coverage report shows 0% coverage

**Solutions**:

1. Verify debug symbols are enabled:
```zig
// In build.zig
exe.setBuildMode(.Debug); // Required for kcov
```

2. Check kcov installation:
```bash
which kcov
kcov --version
```

3. Run kcov manually to see errors:
```bash
kcov --debug coverage/ ./zig-out/bin/test
```

### Issue: Coverage Tool Not Found

**Symptoms**: `error: Coverage tool 'kcov' not found in PATH`

**Solutions**:

1. Install coverage tool:
```bash
# macOS
brew install kcov

# Linux
sudo apt-get install kcov
```

2. Specify absolute path:
```zig
const cov_options = coverage.CoverageOptions{
    .tool_args = "/usr/local/bin/kcov",
};
```

### Issue: Coverage Thresholds Too Strict

**Symptoms**: Build fails with `error.CoverageThresholdNotMet`

**Solutions**:

1. Temporarily disable threshold failures:
```zig
cov_builder.fail_on_threshold = false;
```

2. Lower thresholds:
```zig
const cov_options = coverage.CoverageOptions{
    .min_line_coverage = 60.0, // Lowered from 80.0
};
```

3. Exclude problematic files:
```zig
const cov_options = coverage.CoverageOptions{
    .exclude_pattern = "src/legacy/,src/experimental/",
};
```

### Issue: Slow Coverage Execution

**Symptoms**: Coverage runs take too long

**Solutions**:

1. Use kcov instead of grindcov:
```zig
const cov_options = coverage.CoverageOptions{
    .tool = .kcov, // Much faster than grindcov
};
```

2. Reduce test scope:
```zig
// Only run unit tests for coverage
const test_files = [_][]const u8{
    "tests/unit/", // Fast
    // "tests/integration/", // Skip slow integration tests
};
```

3. Disable HTML report generation:
```zig
const cov_options = coverage.CoverageOptions{
    .html_report = false, // Faster, generate only LCOV
    .lcov_report = true,
};
```

### Issue: Out of Memory During Coverage

**Symptoms**: Process killed or OOM errors

**Solutions**:

1. Reduce parallel workers:
```zig
var builder = try parallel_build.ParallelBuilder.init(
    allocator,
    2, // Reduced from 4
    ".build-cache",
    "1.0.0",
);
```

2. Disable coverage aggregation:
```zig
cov_builder.aggregate_coverage = false;
```

3. Process tests individually:
```zig
for (test_files) |test_file| {
    var cov_builder = try CoverageBuilder.init(
        allocator,
        &builder,
        cov_options,
        &[_][]const u8{test_file},
    );
    defer cov_builder.deinit();
    try cov_builder.buildWithCoverage();
}
```

## API Reference

### Core Types

#### CoverageOptions
```zig
pub const CoverageOptions = struct {
    enabled: bool = false,
    output_dir: []const u8 = "coverage",
    tool: CoverageTool = .kcov,
    include_pattern: ?[]const u8 = null,
    exclude_pattern: ?[]const u8 = null,
    html_report: bool = true,
    json_report: bool = true,
    lcov_report: bool = true,
    min_line_coverage: ?f64 = null,
    min_function_coverage: ?f64 = null,
    min_branch_coverage: ?f64 = null,
    verbose: bool = false,
    tool_args: ?[]const u8 = null,
    valgrind_args: ?[]const u8 = null,
};
```

#### CoverageResult
```zig
pub const CoverageResult = struct {
    total_lines: usize,
    covered_lines: usize,
    total_functions: usize,
    covered_functions: usize,
    total_branches: usize,
    covered_branches: usize,
    timestamp: i64,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
    files: std.ArrayList(FileCoverage),

    pub fn linePercentage(self: CoverageResult) f64;
    pub fn functionPercentage(self: CoverageResult) f64;
    pub fn branchPercentage(self: CoverageResult) f64;
    pub fn getCoverageLevel(self: CoverageResult) []const u8;
    pub fn meetsThresholds(self: CoverageResult, options: CoverageOptions) bool;
};
```

#### CoverageBuilder
```zig
pub const CoverageBuilder = struct {
    allocator: std.mem.Allocator,
    builder: *parallel_build.ParallelBuilder,
    coverage_options: coverage.CoverageOptions,
    test_files: []const []const u8,
    aggregate_coverage: bool,
    fail_on_threshold: bool,
    results: std.ArrayList(coverage.CoverageResult),

    pub fn init(
        allocator: std.mem.Allocator,
        builder: *parallel_build.ParallelBuilder,
        coverage_options: coverage.CoverageOptions,
        test_files: []const []const u8,
    ) !CoverageBuilder;

    pub fn deinit(self: *CoverageBuilder) void;
    pub fn buildWithCoverage(self: *CoverageBuilder) !void;
};
```

### Functions

#### runTestWithCoverage
```zig
pub fn runTestWithCoverage(
    allocator: std.mem.Allocator,
    test_file_path: []const u8,
    options: CoverageOptions,
) !bool;
```

Run a single test file with coverage tracking.

**Parameters**:
- `allocator`: Memory allocator
- `test_file_path`: Path to test file
- `options`: Coverage configuration

**Returns**: `true` if tests passed, `false` otherwise

**Errors**: Returns error if coverage tool fails

#### parseCoverageReport
```zig
pub fn parseCoverageReport(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
) !CoverageResult;
```

Parse coverage data from output directory.

**Parameters**:
- `allocator`: Memory allocator
- `output_dir`: Directory containing coverage data

**Returns**: Parsed coverage results

#### printCoverageSummary
```zig
pub fn printCoverageSummary(result: CoverageResult) void;
```

Print formatted coverage summary to console with color coding.

---

## See Also

- [Parallel Build System](PARALLEL_BUILD.md) - Incremental compilation
- [LTO and Linker Scripts](LTO_AND_LINKER.md) - Optimization and linking
- [Testing Guide](TESTING.md) - Writing effective tests

## License

Part of the Home Programming Language build system.
Copyright © 2024 Home Contributors.
