const std = @import("std");
const testing = @import("../src/modern_test.zig");
const t = testing.t;

/// Comprehensive tests for all matchers in the modern testing framework
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

    // Test all matchers
    try t.describe("Equality Matchers", testEqualityMatchers);
    try t.describe("Truthiness Matchers", testTruthinessMatchers);
    try t.describe("Numeric Comparison Matchers", testNumericComparisonMatchers);
    try t.describe("Numeric Property Matchers", testNumericPropertyMatchers);
    try t.describe("String Matchers", testStringMatchers);
    try t.describe("Negation", testNegation);

    const results = try framework.run();

    std.debug.print("\n=== Test Results ===\n", .{});
    std.debug.print("Total: {d}\n", .{results.total});
    std.debug.print("Passed: {d}\n", .{results.passed});
    std.debug.print("Failed: {d}\n", .{results.failed});
    std.debug.print("Skipped: {d}\n", .{results.skipped});
    std.debug.print("Todo: {d}\n", .{results.todo});

    if (results.failed > 0) {
        std.debug.print("\n❌ Some tests failed!\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n✅ All tests passed!\n", .{});
    }
}

// ============================================================================
// Equality Matchers Tests
// ============================================================================

fn testEqualityMatchers() !void {
    try t.describe("toBe", struct {
        fn run() !void {
            try t.it("matches equal integers", testToBe_Integer);
            try t.it("matches equal booleans", testToBe_Boolean);
            try t.it("matches equal strings", testToBe_String);
        }
    }.run);

    try t.describe("toEqual", struct {
        fn run() !void {
            try t.it("matches equal values", testToEqual);
        }
    }.run);
}

fn testToBe_Integer(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 42, expect.failures);
    try expect.toBe(42);
}

fn testToBe_Boolean(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, true, expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, false, expect.failures);
    try expect.toBe(false);
}

fn testToBe_String(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "hello", expect.failures);
    try expect.toBe("hello");
}

fn testToEqual(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 100, expect.failures);
    try expect.toEqual(100);
}

// ============================================================================
// Truthiness Matchers Tests
// ============================================================================

fn testTruthinessMatchers() !void {
    try t.describe("toBeTruthy", struct {
        fn run() !void {
            try t.it("true is truthy", testTruthy_True);
            try t.it("non-zero numbers are truthy", testTruthy_Number);
            try t.it("non-empty strings are truthy", testTruthy_String);
        }
    }.run);

    try t.describe("toBeFalsy", struct {
        fn run() !void {
            try t.it("false is falsy", testFalsy_False);
            try t.it("zero is falsy", testFalsy_Zero);
            try t.it("empty string is falsy", testFalsy_EmptyString);
        }
    }.run);

    try t.describe("toBeNull", struct {
        fn run() !void {
            try t.it("null is null", testNull);
        }
    }.run);

    try t.describe("toBeDefined", struct {
        fn run() !void {
            try t.it("non-null values are defined", testDefined);
        }
    }.run);

    try t.describe("toBeUndefined", struct {
        fn run() !void {
            try t.it("null is undefined", testUndefined);
        }
    }.run);
}

fn testTruthy_True(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, true, expect.failures);
    try expect.toBeTruthy();
}

fn testTruthy_Number(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 42, expect.failures);
    try expect.toBeTruthy();

    expect.* = t.expect(expect.allocator, -5, expect.failures);
    try expect.toBeTruthy();
}

fn testTruthy_String(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "text", expect.failures);
    try expect.toBeTruthy();
}

fn testFalsy_False(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, false, expect.failures);
    try expect.toBeFalsy();
}

fn testFalsy_Zero(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 0, expect.failures);
    try expect.toBeFalsy();
}

fn testFalsy_EmptyString(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "", expect.failures);
    try expect.toBeFalsy();
}

fn testNull(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, null, expect.failures);
    try expect.toBeNull();
}

fn testDefined(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 42, expect.failures);
    try expect.toBeDefined();
}

fn testUndefined(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, null, expect.failures);
    try expect.toBeUndefined();
}

// ============================================================================
// Numeric Comparison Matchers Tests
// ============================================================================

fn testNumericComparisonMatchers() !void {
    try t.describe("toBeGreaterThan", struct {
        fn run() !void {
            try t.it("10 > 5", testGreaterThan);
        }
    }.run);

    try t.describe("toBeLessThan", struct {
        fn run() !void {
            try t.it("3 < 10", testLessThan);
        }
    }.run);

    try t.describe("toBeGreaterThanOrEqual", struct {
        fn run() !void {
            try t.it("10 >= 10", testGreaterThanOrEqual_Equal);
            try t.it("15 >= 10", testGreaterThanOrEqual_Greater);
        }
    }.run);

    try t.describe("toBeLessThanOrEqual", struct {
        fn run() !void {
            try t.it("10 <= 10", testLessThanOrEqual_Equal);
            try t.it("5 <= 10", testLessThanOrEqual_Less);
        }
    }.run);

    try t.describe("toBeCloseTo", struct {
        fn run() !void {
            try t.it("handles float precision", testCloseTo_Precision);
            try t.it("works with pi", testCloseTo_Pi);
        }
    }.run);

    try t.describe("toBeBetween", struct {
        fn run() !void {
            try t.it("5 is between 1 and 10", testBetween_Inside);
            try t.it("includes boundaries", testBetween_Boundary);
        }
    }.run);
}

fn testGreaterThan(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 10, expect.failures);
    try expect.toBeGreaterThan(5);
}

fn testLessThan(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 3, expect.failures);
    try expect.toBeLessThan(10);
}

fn testGreaterThanOrEqual_Equal(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 10, expect.failures);
    try expect.toBeGreaterThanOrEqual(10);
}

fn testGreaterThanOrEqual_Greater(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 15, expect.failures);
    try expect.toBeGreaterThanOrEqual(10);
}

fn testLessThanOrEqual_Equal(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 10, expect.failures);
    try expect.toBeLessThanOrEqual(10);
}

fn testLessThanOrEqual_Less(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 5, expect.failures);
    try expect.toBeLessThanOrEqual(10);
}

fn testCloseTo_Precision(expect: *testing.ModernTest.Expect) !void {
    const value: f64 = 0.1 + 0.2; // = 0.30000000000000004
    expect.* = t.expect(expect.allocator, value, expect.failures);
    try expect.toBeCloseTo(0.3, 1);
}

fn testCloseTo_Pi(expect: *testing.ModernTest.Expect) !void {
    const pi: f64 = 3.14159;
    expect.* = t.expect(expect.allocator, pi, expect.failures);
    try expect.toBeCloseTo(3.14, 2);
}

fn testBetween_Inside(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 5, expect.failures);
    try expect.toBeBetween(1, 10);
}

fn testBetween_Boundary(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 1, expect.failures);
    try expect.toBeBetween(1, 10);

    expect.* = t.expect(expect.allocator, 10, expect.failures);
    try expect.toBeBetween(1, 10);
}

// ============================================================================
// Numeric Property Matchers Tests
// ============================================================================

fn testNumericPropertyMatchers() !void {
    try t.describe("toBePositive", struct {
        fn run() !void {
            try t.it("positive numbers", testPositive);
        }
    }.run);

    try t.describe("toBeNegative", struct {
        fn run() !void {
            try t.it("negative numbers", testNegative);
        }
    }.run);

    try t.describe("toBeZero", struct {
        fn run() !void {
            try t.it("zero", testZero);
        }
    }.run);

    try t.describe("toBeEven", struct {
        fn run() !void {
            try t.it("even numbers", testEven);
        }
    }.run);

    try t.describe("toBeOdd", struct {
        fn run() !void {
            try t.it("odd numbers", testOdd);
        }
    }.run);

    try t.describe("toBeNaN", struct {
        fn run() !void {
            try t.it("NaN values", testNaN);
        }
    }.run);

    try t.describe("toBeInfinite", struct {
        fn run() !void {
            try t.it("infinite values", testInfinite);
        }
    }.run);
}

fn testPositive(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 42, expect.failures);
    try expect.toBePositive();

    expect.* = t.expect(expect.allocator, 1, expect.failures);
    try expect.toBePositive();
}

fn testNegative(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, -5, expect.failures);
    try expect.toBeNegative();

    expect.* = t.expect(expect.allocator, -100, expect.failures);
    try expect.toBeNegative();
}

fn testZero(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 0, expect.failures);
    try expect.toBeZero();
}

fn testEven(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 2, expect.failures);
    try expect.toBeEven();

    expect.* = t.expect(expect.allocator, 100, expect.failures);
    try expect.toBeEven();

    expect.* = t.expect(expect.allocator, 0, expect.failures);
    try expect.toBeEven();
}

fn testOdd(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 1, expect.failures);
    try expect.toBeOdd();

    expect.* = t.expect(expect.allocator, 99, expect.failures);
    try expect.toBeOdd();

    expect.* = t.expect(expect.allocator, -3, expect.failures);
    try expect.toBeOdd();
}

fn testNaN(expect: *testing.ModernTest.Expect) !void {
    const nan_value = std.math.nan(f64);
    expect.* = t.expect(expect.allocator, nan_value, expect.failures);
    try expect.toBeNaN();
}

fn testInfinite(expect: *testing.ModernTest.Expect) !void {
    const inf_value = std.math.inf(f64);
    expect.* = t.expect(expect.allocator, inf_value, expect.failures);
    try expect.toBeInfinite();

    const neg_inf = -std.math.inf(f64);
    expect.* = t.expect(expect.allocator, neg_inf, expect.failures);
    try expect.toBeInfinite();
}

// ============================================================================
// String Matchers Tests
// ============================================================================

fn testStringMatchers() !void {
    try t.describe("toContain", struct {
        fn run() !void {
            try t.it("finds substrings", testContain);
        }
    }.run);

    try t.describe("toStartWith", struct {
        fn run() !void {
            try t.it("matches prefix", testStartWith);
        }
    }.run);

    try t.describe("toEndWith", struct {
        fn run() !void {
            try t.it("matches suffix", testEndWith);
        }
    }.run);

    try t.describe("toHaveLength", struct {
        fn run() !void {
            try t.it("checks string length", testLength);
        }
    }.run);

    try t.describe("toBeEmpty", struct {
        fn run() !void {
            try t.it("checks empty strings", testEmpty);
        }
    }.run);

    try t.describe("toMatch", struct {
        fn run() !void {
            try t.it("matches glob patterns", testMatch);
        }
    }.run);
}

fn testContain(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "hello world", expect.failures);
    try expect.toContain("world");

    expect.* = t.expect(expect.allocator, "The quick brown fox", expect.failures);
    try expect.toContain("quick");
}

fn testStartWith(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "hello world", expect.failures);
    try expect.toStartWith("hello");

    expect.* = t.expect(expect.allocator, "Error: something", expect.failures);
    try expect.toStartWith("Error:");
}

fn testEndWith(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "hello world", expect.failures);
    try expect.toEndWith("world");

    expect.* = t.expect(expect.allocator, "file.txt", expect.failures);
    try expect.toEndWith(".txt");
}

fn testLength(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "hello", expect.failures);
    try expect.toHaveLength(5);

    expect.* = t.expect(expect.allocator, "", expect.failures);
    try expect.toHaveLength(0);
}

fn testEmpty(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "", expect.failures);
    try expect.toBeEmpty();
}

fn testMatch(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "hello world", expect.failures);
    try expect.toMatch("hello*");

    expect.* = t.expect(expect.allocator, "test123.txt", expect.failures);
    try expect.toMatch("test*");

    expect.* = t.expect(expect.allocator, "file.json", expect.failures);
    try expect.toMatch("*.json");
}

// ============================================================================
// Negation Tests
// ============================================================================

fn testNegation() !void {
    try t.describe("not.toBe", struct {
        fn run() !void {
            try t.it("inverts toBe", testNotToBe);
        }
    }.run);

    try t.describe("not.toContain", struct {
        fn run() !void {
            try t.it("inverts toContain", testNotContain);
        }
    }.run);

    try t.describe("not.toBePositive", struct {
        fn run() !void {
            try t.it("inverts toBePositive", testNotPositive);
        }
    }.run);
}

fn testNotToBe(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, 42, expect.failures);
    expect.not = true;
    try expect.toBe(99);
}

fn testNotContain(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, "hello world", expect.failures);
    expect.not = true;
    try expect.toContain("xyz");
}

fn testNotPositive(expect: *testing.ModernTest.Expect) !void {
    expect.* = t.expect(expect.allocator, -5, expect.failures);
    expect.not = true;
    try expect.toBePositive();
}
