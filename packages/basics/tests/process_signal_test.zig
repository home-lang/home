const std = @import("std");
const builtin = @import("builtin");
const process = @import("basics_process");
const testing = std.testing;

test "signal values follow the host's POSIX signal numbers" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expectEqual(@backingInt(std.posix.SIG.TERM), @backingInt(process.Signal.SIGTERM));
    try testing.expectEqual(@backingInt(std.posix.SIG.USR1), @backingInt(process.Signal.SIGUSR1));
    try testing.expectEqual(@backingInt(std.posix.SIG.USR2), @backingInt(process.Signal.SIGUSR2));
}

test "signal termination and liveness use the same child identity" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var child = try process.SpawnedProcess.init(testing.allocator, testing.io, &.{ "/bin/sleep", "30" });
    defer child.deinit();
    const pid = child.pid().?;
    try testing.expect(process.isRunning(pid));
    try process.Signal.SIGTERM.send(pid);
    var result = try child.wait();
    defer result.deinit();
    try testing.expectEqual(@as(u32, 1), result.exit_code);
    try testing.expect(!process.isRunning(pid));
}

test "POSIX process helpers reject group identifiers and observe the current process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expect(process.isRunning(process.currentPid()));
    try testing.expect(process.parentPid() > 0);
    try testing.expect(!process.isRunning(0));
    try testing.expectError(error.InvalidProcessId, process.Signal.SIGTERM.send(0));
}

test "sleep uses caller-provided Io and accepts zero duration" {
    try process.sleep(testing.io, 0);
    try process.sleep(testing.io, 1);
}

test "Windows child-handle liveness and termination paths compile" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const handle: std.process.Child.Id = @ptrFromInt(1);
    try testing.expect(!process.isRunning(handle));
    try testing.expectError(error.UnsupportedSignal, process.Signal.SIGINT.send(handle));
}
