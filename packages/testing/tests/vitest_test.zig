const std = @import("std");
const vitest = @import("vitest");

const ModernTest = vitest.ModernTest;

fn clearFailures(failures: *std.ArrayListUnmanaged(ModernTest.Expect.Failure)) void {
    for (failures.items) |*failure| failure.deinit(std.testing.allocator);
    failures.deinit(std.testing.allocator);
    failures.* = .empty;
}

test "matchers cover literals, negation, numeric validation, and wildcards" {
    var failures: std.ArrayListUnmanaged(ModernTest.Expect.Failure) = .empty;
    defer clearFailures(&failures);

    var string_expect = vitest.expect(std.testing.allocator, "home-language", &failures);
    try string_expect.toBe("home-language");
    try string_expect.toContain("language");
    try string_expect.toHaveLength(13);
    try string_expect.toMatch("home-*");
    try string_expect.toStartWith("home");
    try string_expect.toEndWith("language");

    var number_expect = vitest.expect(std.testing.allocator, @as(i32, 8), &failures);
    try number_expect.toBeGreaterThan(4);
    try number_expect.toBeLessThanOrEqual(8);
    try number_expect.toBeBetween(7, 9);
    try number_expect.toBeEven();
    _ = number_expect.negate();
    try number_expect.toBe(7);

    var invalid_numeric = vitest.expect(std.testing.allocator, true, &failures);
    try std.testing.expectError(error.InvalidType, invalid_numeric.toBeGreaterThan(0));
    try std.testing.expectEqual(@as(usize, 0), failures.items.len);

    var mismatch = vitest.expect(std.testing.allocator, "actual", &failures);
    try mismatch.toBe("expected");
    try std.testing.expectEqual(@as(usize, 1), failures.items.len);
}

test "snapshots own names and values and replace values atomically" {
    var snapshots = ModernTest.Snapshots.init(std.testing.allocator, "snapshots");
    defer snapshots.deinit();

    var name = [_]u8{ 'n', 'a', 'm', 'e' };
    var value = [_]u8{ 'o', 'l', 'd' };
    try std.testing.expect(try snapshots.matchSnapshot(&name, &value));
    name[0] = 'x';
    value[0] = 'x';
    try std.testing.expect(try snapshots.matchSnapshot("name", "old"));
    try snapshots.updateSnapshot("name", "new");
    try std.testing.expect(try snapshots.matchSnapshot("name", "new"));
    try std.testing.expect(!(try snapshots.matchSnapshot("name", "old")));
}

fn throwing() !void {
    return error.ExpectedFailure;
}

test "mocks copy call arguments and integrate with expect matchers" {
    var mock = ModernTest.Mock.initWithIo(std.testing.allocator, std.testing.io);
    defer mock.deinit();
    var first: u8 = 1;
    var second: u8 = 2;
    var args = [_]?*anyopaque{ &first, &second };
    try mock.mockReturnValue(&second);
    try std.testing.expectEqual(@as(?*anyopaque, &second), try mock.call(&args));
    args[0] = null;

    var expected_args = [_]?*anyopaque{ &first, &second };
    try std.testing.expect(mock.toHaveBeenCalledWith(&expected_args));

    var failures: std.ArrayListUnmanaged(ModernTest.Expect.Failure) = .empty;
    defer clearFailures(&failures);
    var mock_expect = vitest.expect(std.testing.allocator, &mock, &failures);
    try mock_expect.toHaveBeenCalled();
    try mock_expect.toHaveBeenCalledTimes(1);
    try mock_expect.toHaveBeenCalledWith(&expected_args);

    const throwing_fn: ModernTest.Expect.ThrowingFn = throwing;
    var throw_expect = vitest.expect(std.testing.allocator, throwing_fn, &failures);
    try throw_expect.toThrow();
    try throw_expect.toThrowError(error.ExpectedFailure);
    try std.testing.expectEqual(@as(usize, 0), failures.items.len);
}

var retry_count: usize = 0;
var hook_count: usize = 0;

fn beforeEachHook() !void {
    hook_count += 1;
}

fn passing(expectation: *ModernTest.Expect) !void {
    expectation.* = vitest.expect(expectation.allocator, true, expectation.failures);
    try expectation.toBeTruthy();
}

fn failing(expectation: *ModernTest.Expect) !void {
    expectation.* = vitest.expect(expectation.allocator, false, expectation.failures);
    try expectation.toBeTruthy();
}

fn retrying(_: *ModernTest.Expect) !void {
    retry_count += 1;
    if (retry_count == 1) return error.TryAgain;
}

fn nestedRegistration() !void {
    try vitest.it("nested pass", passing);
}

fn suiteRegistration() !void {
    try vitest.beforeEach(beforeEachHook);
    try vitest.it("pass", passing);
    try vitest.it("fail", failing);
    try vitest.it("retry", retrying);
    try vitest.describe("nested", nestedRegistration);
}

test "runner executes nested suites, hooks, retries, skip, and todo" {
    retry_count = 0;
    hook_count = 0;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var framework = ModernTest.initWithWriter(
        std.testing.allocator,
        std.testing.io,
        .{ .reporter = .json, .retry = 1 },
        &output.writer,
    );
    defer framework.deinit();
    vitest.global_test_framework = &framework;
    try vitest.describe("root", suiteRegistration);
    framework.suites.items[0].tests.items[0].skip = true;
    framework.suites.items[0].nested_suites.items[0].tests.items[0].todo = true;

    const results = try framework.run();
    try std.testing.expectEqual(@as(usize, 4), results.total);
    try std.testing.expectEqual(@as(usize, 1), results.passed);
    try std.testing.expectEqual(@as(usize, 1), results.failed);
    try std.testing.expectEqual(@as(usize, 1), results.skipped);
    try std.testing.expectEqual(@as(usize, 1), results.todo);
    try std.testing.expectEqual(@as(usize, 2), retry_count);
    try std.testing.expectEqual(@as(usize, 4), hook_count);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"failed\":1") != null);
}

fn partialRegistration() !void {
    try vitest.it("rolled back", passing);
    return error.RegistrationFailed;
}

test "registration rejects missing context and rolls back partial suites" {
    vitest.global_test_framework = null;
    vitest.current_suite = null;
    try std.testing.expectError(error.NoTestFramework, vitest.it("missing", passing));
    try std.testing.expectError(error.NoTestSuite, vitest.beforeAll(beforeEachHook));

    var framework = ModernTest.initWithIo(std.testing.allocator, std.testing.io, .{ .reporter = .minimal });
    defer framework.deinit();
    vitest.global_test_framework = &framework;
    try std.testing.expectError(error.RegistrationFailed, vitest.describe("partial", partialRegistration));
    try std.testing.expectEqual(@as(usize, 0), framework.suites.items.len);
    try std.testing.expect(vitest.current_suite == null);
}

fn exerciseSnapshotAllocations(allocator: std.mem.Allocator) !void {
    var snapshots = ModernTest.Snapshots.init(allocator, "snapshots");
    defer snapshots.deinit();
    _ = try snapshots.matchSnapshot("owned-name", "owned-value");
    try snapshots.updateSnapshot("owned-name", "updated-value");
}

test "snapshot ownership survives every allocation failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSnapshotAllocations, .{});
}

test "public Vitest-compatible surface is linked into the build" {
    std.testing.refAllDecls(vitest);
}
