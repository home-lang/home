const std = @import("std");
const testing = @import("vitest");
const t = testing.t;

/// Example: Modern testing framework demonstration
/// Run with: zig build test -Dfilter=testing_vitest_examples
pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // Initialize modern test framework
    var framework = testing.ModernTest.init(allocator, .{
        .reporter = .pretty,
        .verbose = true,
    });
    defer framework.deinit();

    // Set global framework for describe/it syntax
    testing.global_test_framework = &framework;

    // Example 1: Basic describe/it syntax
    try t.describe("Calculator", struct {
        fn run() !void {
            try t.it("adds two numbers", testAdd);
            try t.it("subtracts two numbers", testSubtract);
            try t.it("multiplies two numbers", testMultiply);
        }
    }.run);

    // Example 2: Nested describes
    try t.describe("String utilities", struct {
        fn run() !void {
            try t.describe("length", struct {
                fn run() !void {
                    try t.it("returns correct length", testStringLength);
                    try t.it("handles empty strings", testEmptyString);
                }
            }.run);

            try t.describe("contains", struct {
                fn run() !void {
                    try t.it("finds substrings", testContains);
                    try t.it("returns false when not found", testNotContains);
                }
            }.run);
        }
    }.run);

    // Example 3: Lifecycle hooks
    try t.describe("Database operations", struct {
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
            try t.beforeAll(setup);
            try t.afterAll(teardown);

            try t.it("inserts records", testInsert);
            try t.it("queries records", testQuery);
        }
    }.run);

    // Run all tests
    const results = try framework.run();

    if (results.failed > 0) return error.TestsFailed;
}

// Test functions
fn testAdd(expect: *testing.ModernTest.Expect) !void {
    const result = 2 + 3;
    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(5);
}

fn testSubtract(expect: *testing.ModernTest.Expect) !void {
    const result = 10 - 4;
    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(6);
}

fn testMultiply(expect: *testing.ModernTest.Expect) !void {
    const result = 3 * 7;
    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(21);
}

fn testStringLength(expect: *testing.ModernTest.Expect) !void {
    const str = "hello";
    expect.* = t.expect(expect.allocator, str, expect.failures);
    try expect.toHaveLength(5);
}

fn testEmptyString(expect: *testing.ModernTest.Expect) !void {
    const str = "";
    expect.* = t.expect(expect.allocator, str, expect.failures);
    try expect.toHaveLength(0);
}

fn testContains(expect: *testing.ModernTest.Expect) !void {
    const str = "hello world";
    expect.* = t.expect(expect.allocator, str, expect.failures);
    try expect.toContain("world");
}

fn testNotContains(expect: *testing.ModernTest.Expect) !void {
    const str = "hello world";
    expect.* = t.expect(expect.allocator, str, expect.failures);

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
