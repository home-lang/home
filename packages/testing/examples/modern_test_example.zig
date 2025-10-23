const std = @import("std");
const testing = @import("../src/modern_test.zig");
const test = testing.test;

/// Example: Modern testing framework demonstration
/// Run with: zig test modern_test_example.zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize modern test framework
    var framework = testing.ModernTest.init(allocator, .{
        .reporter = .pretty,
        .verbose = true,
    });
    defer framework.deinit();

    // Set global framework for describe/it syntax
    testing.global_test_framework = &framework;

    // Example 1: Basic describe/it syntax
    try test.describe("Calculator", struct {
        fn run() !void {
            try test.it("adds two numbers", testAdd);
            try test.it("subtracts two numbers", testSubtract);
            try test.it("multiplies two numbers", testMultiply);
        }
    }.run);

    // Example 2: Nested describes
    try test.describe("String utilities", struct {
        fn run() !void {
            try test.describe("length", struct {
                fn run() !void {
                    try test.it("returns correct length", testStringLength);
                    try test.it("handles empty strings", testEmptyString);
                }
            }.run);

            try test.describe("contains", struct {
                fn run() !void {
                    try test.it("finds substrings", testContains);
                    try test.it("returns false when not found", testNotContains);
                }
            }.run);
        }
    }.run);

    // Example 3: Lifecycle hooks
    try test.describe("Database operations", struct {
        var db_connection: i32 = 0;

        fn setup() !void {
            db_connection = 42;
            std.debug.print("  [Setup] Connected to database\n", .{});
        }

        fn teardown() !void {
            db_connection = 0;
            std.debug.print("  [Teardown] Closed database connection\n", .{});
        }

        fn run() !void {
            test.beforeAll(setup);
            test.afterAll(teardown);

            try test.it("inserts records", testInsert);
            try test.it("queries records", testQuery);
        }
    }.run);

    // Run all tests
    const results = try framework.run();

    // Exit with error code if any tests failed
    if (results.failed > 0) {
        std.process.exit(1);
    }
}

// Test functions
fn testAdd(expect: *testing.ModernTest.Expect) !void {
    const result = 2 + 3;
    expect.* = test.expect(expect.allocator, result, expect.failures);
    try expect.toBe(5);
}

fn testSubtract(expect: *testing.ModernTest.Expect) !void {
    const result = 10 - 4;
    expect.* = test.expect(expect.allocator, result, expect.failures);
    try expect.toBe(6);
}

fn testMultiply(expect: *testing.ModernTest.Expect) !void {
    const result = 3 * 7;
    expect.* = test.expect(expect.allocator, result, expect.failures);
    try expect.toBe(21);
}

fn testStringLength(expect: *testing.ModernTest.Expect) !void {
    const str = "hello";
    expect.* = test.expect(expect.allocator, str, expect.failures);
    try expect.toHaveLength(5);
}

fn testEmptyString(expect: *testing.ModernTest.Expect) !void {
    const str = "";
    expect.* = test.expect(expect.allocator, str, expect.failures);
    try expect.toHaveLength(0);
}

fn testContains(expect: *testing.ModernTest.Expect) !void {
    const str = "hello world";
    expect.* = test.expect(expect.allocator, str, expect.failures);
    try expect.toContain("world");
}

fn testNotContains(expect: *testing.ModernTest.Expect) !void {
    const str = "hello world";
    expect.* = test.expect(expect.allocator, str, expect.failures);

    // Use .not modifier
    expect.not = true;
    try expect.toContain("xyz");
}

fn testInsert(_: *testing.ModernTest.Expect) !void {
    // Simulated database insert
    std.debug.print("  [Test] Inserting record...\n", .{});
}

fn testQuery(_: *testing.ModernTest.Expect) !void {
    // Simulated database query
    std.debug.print("  [Test] Querying records...\n", .{});
}
