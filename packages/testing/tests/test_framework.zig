const std = @import("std");
const testing = @import("../src/modern_test.zig");
const t = testing.t;

/// Tests for framework functionality: runner, lifecycle hooks, nested suites
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = testing.ModernTest.init(allocator, .{
        .reporter = .pretty,
        .verbose = false,
    });
    defer framework.deinit();

    testing.global_test_framework = &framework;

    // Test framework features
    try t.describe("Framework Runner", testRunner);
    try t.describe("Lifecycle Hooks", testLifecycleHooks);
    try t.describe("Nested Suites", testNestedSuites);
    try t.describe("Test Configuration", testConfiguration);

    const results = try framework.run();

    std.debug.print("\n=== Framework Test Results ===\n", .{});
    std.debug.print("Total: {d}\n", .{results.total});
    std.debug.print("Passed: {d}\n", .{results.passed});
    std.debug.print("Failed: {d}\n", .{results.failed});

    if (results.failed > 0) {
        std.debug.print("\n❌ Some framework tests failed!\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n✅ All framework tests passed!\n", .{});
    }
}

// ============================================================================
// Framework Runner Tests
// ============================================================================

fn testRunner() !void {
    try t.describe("Basic execution", struct {
        fn run() !void {
            try t.it("executes simple test", testSimpleExecution);
            try t.it("handles multiple tests", testMultipleTests);
        }
    }.run);
}

fn testSimpleExecution(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 1 + 1, expect.failures);
    try expect.toBe(2);
}

fn testMultipleTests(expect: *testing.ModernTest.Expect) !void {
    // Test 1
    expect.* = t.expect(expect.allocator, 10, expect.failures);
    try expect.toBeGreaterThan(5);

    // Test 2
    expect.* = t.expect(expect.allocator, "hello", expect.failures);
    try expect.toHaveLength(5);

    // Test 3
    expect.* = t.expect(expect.allocator, true, expect.failures);
    try expect.toBeTruthy();
}

// ============================================================================
// Lifecycle Hooks Tests
// ============================================================================

fn testLifecycleHooks() !void {
    try t.describe("beforeAll and afterAll", struct {
        var setup_called = false;
        var teardown_called = false;

        fn setup() !void {
            setup_called = true;
        }

        fn teardown() !void {
            teardown_called = true;
        }

        fn run() !void {
            t.beforeAll(setup);
            t.afterAll(teardown);

            try t.it("verifies beforeAll ran", testBeforeAll);
        }

        fn testBeforeAll(expect: *testing.ModernTest.Expect) !void {
            // setup_called should be true from beforeAll
            expect.* = t.expect(expect.allocator, setup_called, expect.failures);
            try expect.toBe(true);
        }
    }.run);

    try t.describe("beforeEach and afterEach", struct {
        var counter: i32 = 0;

        fn incrementBefore() !void {
            counter += 1;
        }

        fn resetAfter() !void {
            counter = 0;
        }

        fn run() !void {
            t.beforeEach(incrementBefore);
            t.afterEach(resetAfter);

            try t.it("test 1 sees counter", testCounterFirst);
            try t.it("test 2 sees reset counter", testCounterSecond);
        }

        fn testCounterFirst(expect: *testing.ModernTest.Expect) !void {
            // After beforeEach, counter should be 1
            expect.* = t.expect(expect.allocator, counter, expect.failures);
            try expect.toBeGreaterThan(0);
        }

        fn testCounterSecond(expect: *testing.ModernTest.Expect) !void {
            // After reset and increment again
            expect.* = t.expect(expect.allocator, counter, expect.failures);
            try expect.toBeGreaterThan(0);
        }
    }.run);
}

// ============================================================================
// Nested Suites Tests
// ============================================================================

fn testNestedSuites() !void {
    try t.describe("Outer suite", struct {
        fn run() !void {
            try t.it("outer test", testOuter);

            try t.describe("Inner suite 1", struct {
                fn run() !void {
                    try t.it("inner test 1", testInner1);
                }
            }.run);

            try t.describe("Inner suite 2", struct {
                fn run() !void {
                    try t.it("inner test 2", testInner2);

                    try t.describe("Deeply nested", struct {
                        fn run() !void {
                            try t.it("deeply nested test", testDeepNested);
                        }
                    }.run);
                }
            }.run);
        }
    }.run);
}

fn testOuter(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "outer", expect.failures);
    try expect.toHaveLength(5);
}

fn testInner1(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 1, expect.failures);
    try expect.toBe(1);
}

fn testInner2(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 2, expect.failures);
    try expect.toBe(2);
}

fn testDeepNested(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "deep", expect.failures);
    try expect.toStartWith("d");
}

// ============================================================================
// Configuration Tests
// ============================================================================

fn testConfiguration() !void {
    try t.describe("Reporter configuration", struct {
        fn run() !void {
            try t.it("accepts different reporters", testReporterConfig);
        }
    }.run);

    try t.describe("Timeout configuration", struct {
        fn run() !void {
            try t.it("has default timeout", testTimeout);
        }
    }.run);
}

fn testReporterConfig(expect: *testing.ModernTest.Expect) !void {
    // Just verify we can create configs
    const config = testing.ModernTest.Config{
        .reporter = .pretty,
        .timeout_ms = 5000,
    };

    expect.* = t.expect(expect.allocator, config.timeout_ms, expect.failures);
    try expect.toBe(5000);
}

fn testTimeout(expect: *testing.ModernTest.Expect) !void {
    const default_config = testing.ModernTest.Config{};
    expect.* = t.expect(expect.allocator, default_config.timeout_ms, expect.failures);
    try expect.toBe(5000);
}
