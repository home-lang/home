const std = @import("std");
const testing = @import("modern_test");
const ModernTest = testing.ModernTest;

fn passing(expect: *ModernTest.Expect) !void {
    expect.* = testing.t.expect(expect.allocator, @as(i32, 7), expect.failures);
    try expect.toBe(7);
}

fn assertionFailure(expect: *ModernTest.Expect) !void {
    expect.* = testing.t.expect(expect.allocator, false, expect.failures);
    try expect.toBeTruthy();
}

fn runtimeFailure(_: *ModernTest.Expect) !void {
    return error.RuntimeFailure;
}

fn allocationFailure(_: *ModernTest.Expect) !void {
    return error.OutOfMemory;
}

fn registerMixedSuite() !void {
    try testing.t.it("pass", passing);
    try testing.t.it("assertion failure", assertionFailure);
    try testing.t.it("runtime failure", runtimeFailure);
}

fn registerThenFail() !void {
    try testing.t.it("must roll back", passing);
    return error.SuiteRegistrationFailed;
}

fn runWithAllocator(allocator: std.mem.Allocator) !void {
    var framework = ModernTest.init(allocator, .{ .reporter = .minimal });
    defer framework.deinit();
    testing.global_test_framework = &framework;
    try testing.t.describe("suite", registerMixedSuite);
    const results = try framework.run();
    try std.testing.expectEqual(@as(usize, 3), results.total);
    try std.testing.expectEqual(@as(usize, 1), results.passed);
    try std.testing.expectEqual(@as(usize, 2), results.failed);
}

test "module API rejects missing framework" {
    testing.global_test_framework = null;
    try std.testing.expectError(error.NoTestFramework, testing.t.it("lost", passing));
    try std.testing.expectError(error.NoTestFramework, testing.t.describe("lost", registerMixedSuite));
}

test "runner counts assertions and runtime errors as failures" {
    try runWithAllocator(std.testing.allocator);
    try std.testing.expect(testing.global_test_framework == null);
}

test "failed suite registration rolls back partial tests" {
    var framework = ModernTest.init(std.testing.allocator, .{ .reporter = .minimal });
    defer framework.deinit();
    testing.global_test_framework = &framework;

    try std.testing.expectError(
        error.SuiteRegistrationFailed,
        testing.t.describe("broken", registerThenFail),
    );
    const results = try framework.run();
    try std.testing.expectEqual(@as(usize, 0), results.total);
}

test "allocator exhaustion propagates from tests" {
    var framework = ModernTest.init(std.testing.allocator, .{ .reporter = .minimal });
    defer framework.deinit();
    try framework.addTest("oom", allocationFailure);
    try std.testing.expectError(error.OutOfMemory, framework.run());
}

test "registration releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runWithAllocator, .{});
}
