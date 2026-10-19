const std = @import("std");
const builtin = @import("builtin");
const process = @import("basics_process");
const testing = std.testing;

test "environment helpers own values and validate child environment entries" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();

    try process.setEnv(&map, "HOME_PROCESS_CONTEXT", "first");
    try testing.expectEqualStrings("first", map.get("HOME_PROCESS_CONTEXT").?);
    try process.setEnv(&map, "HOME_PROCESS_CONTEXT", "second");
    try testing.expectEqualStrings("second", map.get("HOME_PROCESS_CONTEXT").?);
    try testing.expectError(error.InvalidEnvironmentVariableName, process.setEnv(&map, "BAD=NAME", "value"));
    try testing.expectError(error.InvalidEnvironmentVariableValue, process.setEnv(&map, "GOOD", "bad\x00value"));
    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expect(process.unsetEnv(&map, "HOME_PROCESS_CONTEXT"));
    try testing.expect(!process.unsetEnv(&map, "HOME_PROCESS_CONTEXT"));
    try testing.expectEqual(@as(usize, 0), map.count());
}

test "environment snapshots return owned values and independent maps" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try process.setEnv(&map, "HOME_PROCESS_CONTEXT", "snapshot");
    const block = try map.createPosixBlock(testing.allocator, .{});
    defer block.deinit(testing.allocator);
    const environ: std.process.Environ = .{ .block = block };

    const value = (try process.getEnv(testing.allocator, environ, "HOME_PROCESS_CONTEXT")).?;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("snapshot", value);
    try testing.expect((try process.getEnv(testing.allocator, environ, "MISSING")) == null);

    var copy = try process.getEnvMap(testing.allocator, environ);
    defer copy.deinit();
    try testing.expectEqualStrings("snapshot", copy.get("HOME_PROCESS_CONTEXT").?);
    try process.setEnv(&map, "HOME_PROCESS_CONTEXT", "changed");
    try testing.expectEqualStrings("snapshot", copy.get("HOME_PROCESS_CONTEXT").?);
}

test "argument snapshot returns independently owned argument strings" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const args: std.process.Args = .{ .vector = &.{ "home", "one", "two" } };
    const copied = try process.getArgs(testing.allocator, args);
    defer {
        for (copied) |arg| testing.allocator.free(arg);
        testing.allocator.free(copied);
    }
    try testing.expectEqual(@as(usize, 3), copied.len);
    try testing.expectEqualStrings("home", copied[0]);
    try testing.expectEqualStrings("one", copied[1]);
    try testing.expectEqualStrings("two", copied[2]);
}

fn copyArgsUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    const args: std.process.Args = .{ .vector = &.{ "home", "one", "two" } };
    const copied = try process.getArgs(allocator, args);
    defer {
        for (copied) |arg| allocator.free(arg);
        allocator.free(copied);
    }
    try testing.expectEqual(@as(usize, 3), copied.len);
}

test "argument snapshot releases partial copies on every allocation failure" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testing.allocator, copyArgsUnderAllocationFailure, .{});
}

test "cwd helpers use the supplied Io implementation" {
    const cwd = try process.getCwd(testing.allocator, testing.io);
    defer testing.allocator.free(cwd);
    try testing.expect(cwd.len > 0);
    try process.setCwd(testing.io, cwd);
    const after = try process.getCwd(testing.allocator, testing.io);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(cwd, after);
}
