const std = @import("std");
const testing = @import("../src/modern_test.zig");
const t = testing.t;

/// Tests for Mock and Spy functionality
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

    // Test mock functionality
    try t.describe("Mock Creation", testMockCreation);
    try t.describe("Mock Return Values", testMockReturnValues);
    try t.describe("Mock Implementation", testMockImplementation);
    try t.describe("Call Tracking", testCallTracking);
    try t.describe("Mock Assertions", testMockAssertions);

    const results = try framework.run();

    std.debug.print("\n=== Mock Test Results ===\n", .{});
    std.debug.print("Total: {d}\n", .{results.total});
    std.debug.print("Passed: {d}\n", .{results.passed});
    std.debug.print("Failed: {d}\n", .{results.failed});

    if (results.failed > 0) {
        std.debug.print("\n❌ Some mock tests failed!\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n✅ All mock tests passed!\n", .{});
    }
}

// ============================================================================
// Mock Creation Tests
// ============================================================================

fn testMockCreation() !void {
    try t.describe("initialization", struct {
        fn run() !void {
            try t.it("creates mock successfully", testCreateMock);
            try t.it("initializes with empty calls", testEmptyMock);
        }
    }.run);
}

fn testCreateMock(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    // Mock should be created successfully
    expect.* = t.expect(expect.allocator, mock.calls.items.len, expect.failures);
    try expect.toBe(0);
}

fn testEmptyMock(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    // Initially not called
    const called = mock.toHaveBeenCalled();
    expect.* = t.expect(expect.allocator, called, expect.failures);
    try expect.toBe(false);
}

// ============================================================================
// Mock Return Values Tests
// ============================================================================

fn testMockReturnValues() !void {
    try t.describe("mockReturnValue", struct {
        fn run() !void {
            try t.it("returns mocked value", testReturnValue);
            try t.it("cycles through values", testCycleValues);
        }
    }.run);
}

fn testReturnValue(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    const value: i32 = 42;
    try mock.mockReturnValue(@ptrCast(&value));

    const result = try mock.call(&.{});
    const result_value: *const i32 = @ptrCast(@alignCast(result.?));

    expect.* = t.expect(expect.allocator, result_value.*, expect.failures);
    try expect.toBe(42);
}

fn testCycleValues(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    const value1: i32 = 10;
    const value2: i32 = 20;

    try mock.mockReturnValue(@ptrCast(&value1));
    try mock.mockReturnValue(@ptrCast(&value2));

    // First call returns value1
    const result1 = try mock.call(&.{});
    const result1_value: *const i32 = @ptrCast(@alignCast(result1.?));
    expect.* = t.expect(expect.allocator, result1_value.*, expect.failures);
    try expect.toBe(10);

    // Second call returns value2
    const result2 = try mock.call(&.{});
    const result2_value: *const i32 = @ptrCast(@alignCast(result2.?));
    expect.* = t.expect(expect.allocator, result2_value.*, expect.failures);
    try expect.toBe(20);

    // Third call cycles back to value1
    const result3 = try mock.call(&.{});
    const result3_value: *const i32 = @ptrCast(@alignCast(result3.?));
    expect.* = t.expect(expect.allocator, result3_value.*, expect.failures);
    try expect.toBe(10);
}

// ============================================================================
// Mock Implementation Tests
// ============================================================================

fn testMockImplementation() !void {
    try t.describe("mockImplementation", struct {
        fn run() !void {
            try t.it("uses custom implementation", testCustomImpl);
            try t.it("receives arguments", testImplWithArgs);
        }
    }.run);
}

fn customAddImpl(args: []const ?*anyopaque) !?*anyopaque {
    _ = args;
    const result: i32 = 100;
    const ptr = @as(*const anyopaque, @ptrCast(&result));
    return @constCast(ptr);
}

fn testCustomImpl(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    mock.mockImplementation(customAddImpl);

    const result = try mock.call(&.{});

    // Verify result is not null
    expect.* = t.expect(expect.allocator, result != null, expect.failures);
    try expect.toBe(true);
}

fn testImplWithArgs(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    const arg1: i32 = 5;
    const arg2: i32 = 10;

    _ = try mock.call(&.{ @ptrCast(&arg1), @ptrCast(&arg2) });

    // Verify mock was called
    const called = mock.toHaveBeenCalled();
    expect.* = t.expect(expect.allocator, called, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Call Tracking Tests
// ============================================================================

fn testCallTracking() !void {
    try t.describe("call history", struct {
        fn run() !void {
            try t.it("tracks call count", testCallCount);
            try t.it("tracks arguments", testTrackArguments);
            try t.it("tracks timestamps", testTrackTimestamps);
        }
    }.run);
}

fn testCallCount(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    // No calls yet
    expect.* = t.expect(expect.allocator, mock.calls.items.len, expect.failures);
    try expect.toBe(0);

    // Make 3 calls
    _ = try mock.call(&.{});
    _ = try mock.call(&.{});
    _ = try mock.call(&.{});

    expect.* = t.expect(expect.allocator, mock.calls.items.len, expect.failures);
    try expect.toBe(3);
}

fn testTrackArguments(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    const arg1: i32 = 42;
    _ = try mock.call(&.{@ptrCast(&arg1)});

    // Verify call was tracked
    expect.* = t.expect(expect.allocator, mock.calls.items.len, expect.failures);
    try expect.toBe(1);

    // Verify argument was tracked
    const first_call = mock.calls.items[0];
    expect.* = t.expect(expect.allocator, first_call.args.len, expect.failures);
    try expect.toBe(1);
}

fn testTrackTimestamps(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    _ = try mock.call(&.{});

    const first_call = mock.calls.items[0];

    // Timestamp should be non-zero
    expect.* = t.expect(expect.allocator, first_call.timestamp > 0, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Mock Assertions Tests
// ============================================================================

fn testMockAssertions() !void {
    try t.describe("toHaveBeenCalled", struct {
        fn run() !void {
            try t.it("returns true when called", testHasBeenCalled);
            try t.it("returns false when not called", testNotCalled);
        }
    }.run);

    try t.describe("toHaveBeenCalledTimes", struct {
        fn run() !void {
            try t.it("checks exact call count", testCalledTimes);
        }
    }.run);

    try t.describe("toHaveBeenCalledWith", struct {
        fn run() !void {
            try t.it("verifies arguments", testCalledWith);
        }
    }.run);
}

fn testHasBeenCalled(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    _ = try mock.call(&.{});

    const called = mock.toHaveBeenCalled();
    expect.* = t.expect(expect.allocator, called, expect.failures);
    try expect.toBe(true);
}

fn testNotCalled(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    const called = mock.toHaveBeenCalled();
    expect.* = t.expect(expect.allocator, called, expect.failures);
    try expect.toBe(false);
}

fn testCalledTimes(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    // Call 3 times
    _ = try mock.call(&.{});
    _ = try mock.call(&.{});
    _ = try mock.call(&.{});

    const called_3_times = mock.toHaveBeenCalledTimes(3);
    expect.* = t.expect(expect.allocator, called_3_times, expect.failures);
    try expect.toBe(true);

    const called_2_times = mock.toHaveBeenCalledTimes(2);
    expect.* = t.expect(expect.allocator, called_2_times, expect.failures);
    try expect.toBe(false);
}

fn testCalledWith(expect: *testing.ModernTest.Expect) !void {
    var mock = testing.ModernTest.Mock.init(expect.allocator);
    defer mock.deinit();

    const arg1: i32 = 42;
    const arg2: i32 = 100;

    const args = [_]?*anyopaque{ @ptrCast(&arg1), @ptrCast(&arg2) };
    _ = try mock.call(&args);

    const called_with = mock.toHaveBeenCalledWith(&args);
    expect.* = t.expect(expect.allocator, called_with, expect.failures);
    try expect.toBe(true);
}
