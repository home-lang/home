const std = @import("std");
const builtin = @import("builtin");
const process = @import("basics_process");
const testing = std.testing;

test "SpawnedProcess captures both pipes and reaps the child" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var spawned = try process.SpawnedProcess.init(
        testing.allocator,
        testing.io,
        &.{ "/bin/sh", "-c", "printf out; printf err >&2; exit 9" },
    );
    defer spawned.deinit();
    try testing.expect(spawned.pid() != null);
    var result = try spawned.wait();
    defer result.deinit();
    try testing.expectEqual(@as(u32, 9), result.exit_code);
    try testing.expectEqualStrings("out", result.stdout);
    try testing.expectEqualStrings("err", result.stderr);
    try testing.expect(spawned.pid() == null);
    try testing.expectError(error.ProcessAlreadyWaited, spawned.wait());
}

test "ProcessBuilder passes arguments, replacement environment, and working directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = path_buf[0..path_len];

    var builder = process.ProcessBuilder.init(testing.allocator, testing.io);
    defer builder.deinit();
    _ = try builder.command("/bin/sh");
    _ = try builder.args(&.{ "-c", "printf '%s\\n' \"$HOME_PROCESS_TEST\"; pwd" });
    _ = try builder.env("HOME_PROCESS_TEST", "configured");
    _ = try builder.currentDir(path);
    var result = try builder.run();
    defer result.deinit();
    try testing.expectEqual(@as(u32, 0), result.exit_code);
    const expected = try std.fmt.allocPrint(testing.allocator, "configured\n{s}\n", .{path});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "ProcessBuilder honors each output stream mode" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var builder = process.ProcessBuilder.init(testing.allocator, testing.io);
    defer builder.deinit();
    _ = try builder.command("/bin/sh");
    _ = try builder.args(&.{ "-c", "printf out; printf err >&2" });
    _ = builder.stderr(.ignore);
    var one_stream = try builder.run();
    defer one_stream.deinit();
    try testing.expectEqualStrings("out", one_stream.stdout);
    try testing.expectEqualStrings("", one_stream.stderr);

    _ = builder.stdout(.ignore);
    _ = builder.stderr(.pipe);
    var other_stream = try builder.run();
    defer other_stream.deinit();
    try testing.expectEqualStrings("", other_stream.stdout);
    try testing.expectEqualStrings("err", other_stream.stderr);

    _ = builder.stderr(.ignore);
    var no_streams = try builder.run();
    defer no_streams.deinit();
    try testing.expectEqualStrings("", no_streams.stdout);
    try testing.expectEqualStrings("", no_streams.stderr);
}

test "SpawnedProcess kill is idempotent and ProcessBuilder rejects empty argv" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var builder = process.ProcessBuilder.init(testing.allocator, testing.io);
    defer builder.deinit();
    try testing.expectError(error.NoCommand, builder.spawn());

    var spawned = try process.SpawnedProcess.init(testing.allocator, testing.io, &.{ "/bin/sleep", "30" });
    defer spawned.deinit();
    try testing.expect(spawned.pid() != null);
    try spawned.kill();
    try spawned.kill();
    try testing.expect(spawned.pid() == null);
    try testing.expectError(error.ProcessAlreadyWaited, spawned.wait());
}

test "ProcessBuilder closes unused piped stdin before waiting" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var builder = process.ProcessBuilder.init(testing.allocator, testing.io);
    defer builder.deinit();
    _ = try builder.command("/bin/sh");
    _ = try builder.args(&.{ "-c", "cat >/dev/null; printf done" });
    _ = builder.stdin(.pipe);
    var result = try builder.run();
    defer result.deinit();
    try testing.expectEqual(@as(u32, 0), result.exit_code);
    try testing.expectEqualStrings("done", result.stdout);
}
