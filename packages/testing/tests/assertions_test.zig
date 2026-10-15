const std = @import("std");
const assertions = @import("assertions");

const Assert = assertions.Assert;
const Fixture = assertions.Fixture;
const Mock = assertions.Mock;

const ExpectedError = error{ Expected, Actual };

fn expectedFailure() ExpectedError!void {
    return error.Expected;
}

fn actualFailure() ExpectedError!void {
    return error.Actual;
}

fn recordCallWithAllocator(allocator: std.mem.Allocator) !void {
    var mock = Mock.initWithIo(allocator, std.testing.io);
    defer mock.deinit();

    try mock.recordCall("compile", "fixture.home");
    try std.testing.expectEqual(@as(usize, 1), mock.callCount("compile"));
}

fn replaceFixtureDataWithAllocator(allocator: std.mem.Allocator) !void {
    var fixture = Fixture.init(allocator);
    defer fixture.deinit();

    try fixture.setData(@as(u32, 41));
    try std.testing.expectEqual(@as(u32, 41), fixture.getData(u32).?.*);
    try fixture.setData(@as(u64, 42));
    try std.testing.expectEqual(@as(u64, 42), fixture.getData(u64).?.*);
}

test "assertions compare concrete error values" {
    try Assert.expectError(error.Expected, expectedFailure());
    try Assert.expectError(error.Actual, actualFailure());
}

test "mock records owned calls with an explicit IO clock" {
    var mock = Mock.initWithIo(std.testing.allocator, std.testing.io);
    defer mock.deinit();

    try mock.recordCall("compile", "fixture.home");
    try mock.recordCall("compile", "other.home");
    try std.testing.expect(mock.wasCalled("compile"));
    try std.testing.expectEqual(@as(usize, 2), mock.callCount("compile"));
    try std.testing.expect(mock.calls.items[0].timestamp > 0);

    mock.reset();
    try std.testing.expectEqual(@as(usize, 0), mock.calls.items.len);
}

test "mock call recording releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordCallWithAllocator,
        .{},
    );
}

test "fixtures own and replace type-erased data" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        replaceFixtureDataWithAllocator,
        .{},
    );
}
