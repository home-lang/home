const std = @import("std");
const testing = @import("../src/modern_test.zig");
const test = testing.test;

/// Comprehensive showcase of all available matchers
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = testing.ModernTest.init(allocator, .{
        .reporter = .pretty,
    });
    defer framework.deinit();

    testing.global_test_framework = &framework;

    // Equality Matchers
    try test.describe("Equality Matchers", struct {
        fn run() !void {
            try test.it("toBe - strict equality", testToBe);
            try test.it("toEqual - deep equality", testToEqual);
        }
    }.run);

    // Truthiness Matchers
    try test.describe("Truthiness Matchers", struct {
        fn run() !void {
            try test.it("toBeTruthy", testTruthy);
            try test.it("toBeFalsy", testFalsy);
            try test.it("toBeNull", testNull);
            try test.it("toBeDefined", testDefined);
            try test.it("toBeUndefined", testUndefined);
        }
    }.run);

    // Numeric Comparison Matchers
    try test.describe("Numeric Matchers", struct {
        fn run() !void {
            try test.it("toBeGreaterThan", testGreaterThan);
            try test.it("toBeLessThan", testLessThan);
            try test.it("toBeGreaterThanOrEqual", testGreaterThanOrEqual);
            try test.it("toBeLessThanOrEqual", testLessThanOrEqual);
            try test.it("toBeCloseTo - float precision", testCloseTo);
            try test.it("toBeBetween - range check", testBetween);
        }
    }.run);

    // Numeric Property Matchers
    try test.describe("Numeric Properties", struct {
        fn run() !void {
            try test.it("toBePositive", testPositive);
            try test.it("toBeNegative", testNegative);
            try test.it("toBeZero", testZero);
            try test.it("toBeEven", testEven);
            try test.it("toBeOdd", testOdd);
            try test.it("toBeNaN", testNaN);
            try test.it("toBeInfinite", testInfinite);
        }
    }.run);

    // String Matchers
    try test.describe("String Matchers", struct {
        fn run() !void {
            try test.it("toContain - substring", testContain);
            try test.it("toStartWith - prefix", testStartWith);
            try test.it("toEndWith - suffix", testEndWith);
            try test.it("toHaveLength", testLength);
            try test.it("toBeEmpty", testEmpty);
            try test.it("toMatch - glob pattern", testMatch);
        }
    }.run);

    // Negation Examples
    try test.describe("Negation with .not", struct {
        fn run() !void {
            try test.it("not.toBe", testNotToBe);
            try test.it("not.toContain", testNotContain);
            try test.it("not.toBePositive", testNotPositive);
        }
    }.run);

    const results = try framework.run();
    if (results.failed > 0) std.process.exit(1);
}

// ============================================================================
// Equality Matchers
// ============================================================================

fn testToBe(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 42, expect.failures);
    try expect.toBe(42);

    expect.* = test.expect(expect.allocator, "hello", expect.failures);
    try expect.toBe("hello");
}

fn testToEqual(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 100, expect.failures);
    try expect.toEqual(100);
}

// ============================================================================
// Truthiness Matchers
// ============================================================================

fn testTruthy(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, true, expect.failures);
    try expect.toBeTruthy();

    expect.* = test.expect(expect.allocator, 42, expect.failures);
    try expect.toBeTruthy();

    expect.* = test.expect(expect.allocator, "text", expect.failures);
    try expect.toBeTruthy();
}

fn testFalsy(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, false, expect.failures);
    try expect.toBeFalsy();

    expect.* = test.expect(expect.allocator, 0, expect.failures);
    try expect.toBeFalsy();

    expect.* = test.expect(expect.allocator, "", expect.failures);
    try expect.toBeFalsy();
}

fn testNull(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, null, expect.failures);
    try expect.toBeNull();
}

fn testDefined(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 42, expect.failures);
    try expect.toBeDefined();
}

fn testUndefined(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, null, expect.failures);
    try expect.toBeUndefined();
}

// ============================================================================
// Numeric Comparison Matchers
// ============================================================================

fn testGreaterThan(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 10, expect.failures);
    try expect.toBeGreaterThan(5);
}

fn testLessThan(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 3, expect.failures);
    try expect.toBeLessThan(10);
}

fn testGreaterThanOrEqual(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 10, expect.failures);
    try expect.toBeGreaterThanOrEqual(10);

    expect.* = test.expect(expect.allocator, 15, expect.failures);
    try expect.toBeGreaterThanOrEqual(10);
}

fn testLessThanOrEqual(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 10, expect.failures);
    try expect.toBeLessThanOrEqual(10);

    expect.* = test.expect(expect.allocator, 5, expect.failures);
    try expect.toBeLessThanOrEqual(10);
}

fn testCloseTo(expect: *testing.ModernTest.Expect) !void {
    // Test floating point with precision
    const pi: f64 = 3.14159;
    expect.* = test.expect(expect.allocator, pi, expect.failures);
    try expect.toBeCloseTo(3.14, 2); // 2 decimal places

    const value: f64 = 0.1 + 0.2;
    expect.* = test.expect(expect.allocator, value, expect.failures);
    try expect.toBeCloseTo(0.3, 1); // 1 decimal place
}

fn testBetween(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 5, expect.failures);
    try expect.toBeBetween(1, 10);

    expect.* = test.expect(expect.allocator, 10, expect.failures);
    try expect.toBeBetween(10, 20); // inclusive
}

// ============================================================================
// Numeric Property Matchers
// ============================================================================

fn testPositive(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 42, expect.failures);
    try expect.toBePositive();
}

fn testNegative(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, -5, expect.failures);
    try expect.toBeNegative();
}

fn testZero(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 0, expect.failures);
    try expect.toBeZero();
}

fn testEven(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 4, expect.failures);
    try expect.toBeEven();

    expect.* = test.expect(expect.allocator, 100, expect.failures);
    try expect.toBeEven();
}

fn testOdd(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 3, expect.failures);
    try expect.toBeOdd();

    expect.* = test.expect(expect.allocator, 99, expect.failures);
    try expect.toBeOdd();
}

fn testNaN(expect: *testing.ModernTest.Expect) !void {
    const nan_value = std.math.nan(f64);
    expect.* = test.expect(expect.allocator, nan_value, expect.failures);
    try expect.toBeNaN();
}

fn testInfinite(expect: *testing.ModernTest.Expect) !void {
    const inf_value = std.math.inf(f64);
    expect.* = test.expect(expect.allocator, inf_value, expect.failures);
    try expect.toBeInfinite();
}

// ============================================================================
// String Matchers
// ============================================================================

fn testContain(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, "hello world", expect.failures);
    try expect.toContain("world");

    expect.* = test.expect(expect.allocator, "The quick brown fox", expect.failures);
    try expect.toContain("quick");
}

fn testStartWith(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, "hello world", expect.failures);
    try expect.toStartWith("hello");
}

fn testEndWith(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, "hello world", expect.failures);
    try expect.toEndWith("world");
}

fn testLength(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, "hello", expect.failures);
    try expect.toHaveLength(5);
}

fn testEmpty(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, "", expect.failures);
    try expect.toBeEmpty();
}

fn testMatch(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, "hello world", expect.failures);
    try expect.toMatch("hello*");

    expect.* = test.expect(expect.allocator, "test123", expect.failures);
    try expect.toMatch("test*");
}

// ============================================================================
// Negation Examples
// ============================================================================

fn testNotToBe(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, 42, expect.failures);
    expect.not = true;
    try expect.toBe(99); // Passes because 42 != 99
}

fn testNotContain(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, "hello world", expect.failures);
    expect.not = true;
    try expect.toContain("xyz"); // Passes because "xyz" not in string
}

fn testNotPositive(expect: *testing.ModernTest.Expect) !void {
    expect.* = test.expect(expect.allocator, -5, expect.failures);
    expect.not = true;
    try expect.toBePositive(); // Passes because -5 is not positive
}
