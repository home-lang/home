const std = @import("std");
const TestFramework = @import("testing_framework").TestFramework;

fn passingTest(ctx: *TestFramework.TestContext) !void {
    try ctx.assert(true, "true is true");
    try ctx.assertEqual(@as(u8, 4), @as(u8, 4));
    try ctx.assertNotEqual(@as(u8, 4), @as(u8, 5));
}

fn failingTest(ctx: *TestFramework.TestContext) !void {
    try ctx.fail("intentional failure");
}

fn benchmarkOperation() void {}

fn teardownFailure(_: *TestFramework.TestContext) !void {
    return error.TeardownFailed;
}

test "context owns failure messages" {
    var context = TestFramework.TestContext.initWithIo(std.testing.allocator, std.testing.io, "assertions");
    defer context.deinit();

    try context.assert(false, "borrowed message");
    try context.assertEqual(@as(u8, 1), @as(u8, 2));
    try context.assertError(error.Expected, error.Actual);

    try std.testing.expect(context.failed);
    try std.testing.expectEqual(@as(usize, 3), context.assertions);
    try std.testing.expectEqual(@as(usize, 3), context.failures.items.len);
}

test "coverage counts each recorded line once" {
    var coverage = TestFramework.Coverage.init(std.testing.allocator);
    defer coverage.deinit();

    try coverage.recordLine("fixture.home", 7);
    try coverage.recordLine("fixture.home", 7);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try coverage.generateReport(&output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "executed 2 times") != null);
}

test "benchmark reports a completed operation" {
    const benchmark = try TestFramework.Benchmark.runWithIo(
        std.testing.allocator,
        std.testing.io,
        "noop",
        1,
        benchmarkOperation,
    );
    try std.testing.expectEqual(@as(usize, 1), benchmark.iterations);
    try std.testing.expectError(
        error.InvalidIterations,
        TestFramework.Benchmark.runWithIo(
            std.testing.allocator,
            std.testing.io,
            "invalid",
            0,
            benchmarkOperation,
        ),
    );
}

test "framework records pass failure and skip results" {
    var framework = TestFramework.initWithIo(std.testing.allocator, std.testing.io, .{ .parallel = false });
    defer framework.deinit();

    try framework.registerTest(.{ .name = "pass", .suite = null, .func = passingTest });
    try framework.registerTest(.{ .name = "fail", .suite = null, .func = failingTest });
    try framework.registerTest(.{ .name = "skip", .suite = null, .func = passingTest, .skip = true });

    const results = try framework.run();
    try std.testing.expectEqual(@as(usize, 2), results.total);
    try std.testing.expectEqual(@as(usize, 1), results.passed);
    try std.testing.expectEqual(@as(usize, 1), results.failed);
    try std.testing.expectEqual(@as(usize, 1), results.skipped);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try results.print(&output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "1 test(s) failed") != null);
}

test "suite teardown errors fail the test" {
    var framework = TestFramework.initWithIo(std.testing.allocator, std.testing.io, .{ .parallel = false });
    defer framework.deinit();

    var suite_tests: std.ArrayList(TestFramework.TestCase) = .empty;
    errdefer suite_tests.deinit(std.testing.allocator);
    try suite_tests.append(std.testing.allocator, .{
        .name = "teardown failure",
        .suite = "suite",
        .func = passingTest,
    });
    try framework.registerSuite(.{
        .name = "suite",
        .teardown = teardownFailure,
        .tests = suite_tests,
    });
    suite_tests = .empty;

    const results = try framework.run();
    try std.testing.expectEqual(@as(usize, 1), results.total);
    try std.testing.expectEqual(@as(usize, 0), results.passed);
    try std.testing.expectEqual(@as(usize, 1), results.failed);
}

fn runWithAllocator(allocator: std.mem.Allocator) !void {
    var framework = TestFramework.initWithIo(allocator, std.testing.io, .{ .parallel = false });
    defer framework.deinit();
    try framework.registerTest(.{ .name = "pass", .suite = null, .func = passingTest });
    try framework.registerTest(.{ .name = "fail", .suite = null, .func = failingTest });
    const results = try framework.run();
    try std.testing.expectEqual(@as(usize, 1), results.passed);
    try std.testing.expectEqual(@as(usize, 1), results.failed);
}

test "framework releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runWithAllocator, .{});
}

test "compatibility constructors preserve behavior" {
    var context = TestFramework.TestContext.init(std.testing.allocator, "compatibility");
    defer context.deinit();
    try context.assert(true, "pass");

    var framework = TestFramework.init(std.testing.allocator, .{ .parallel = false });
    defer framework.deinit();
    try framework.registerTest(.{ .name = "pass", .suite = null, .func = passingTest });
    const results = try framework.run();
    try std.testing.expectEqual(@as(usize, 1), results.passed);

    const benchmark = try TestFramework.Benchmark.run(
        std.testing.allocator,
        "compatibility",
        1,
        benchmarkOperation,
    );
    try std.testing.expectEqual(@as(usize, 1), benchmark.iterations);
}
