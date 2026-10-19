const std = @import("std");
const builtin = @import("builtin");
const process = @import("basics_process");
const testing = std.testing;

test "exec captures stdout, stderr, and the actual exit status" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var result = try process.exec(testing.allocator, testing.io, &.{ "/bin/sh", "-c", "printf out; printf err >&2; exit 7" });
    defer result.deinit();
    try testing.expectEqualStrings("out", result.stdout);
    try testing.expectEqualStrings("err", result.stderr);
    try testing.expectEqual(@as(u32, 7), result.exit_code);
}

test "exec drains both child pipes without a pipe-capacity deadlock" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const command = "i=0; while [ \"$i\" -lt 8192 ]; do printf 'abcdefghijklmnop'; printf 'ABCDEFGHIJKLMNOP' >&2; i=$((i+1)); done";
    var result = try process.exec(testing.allocator, testing.io, &.{ "/bin/sh", "-c", command });
    defer result.deinit();
    try testing.expectEqual(@as(u32, 0), result.exit_code);
    try testing.expectEqual(@as(usize, 131_072), result.stdout.len);
    try testing.expectEqual(@as(usize, 131_072), result.stderr.len);
    try testing.expectEqualStrings("abcdefghijklmnop", result.stdout[0..16]);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", result.stderr[result.stderr.len - 16 ..]);
}

test "shell resolves the platform command interpreter" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var result = try process.shell(testing.allocator, testing.io, "printf shell");
    defer result.deinit();
    try testing.expectEqual(@as(u32, 0), result.exit_code);
    try testing.expectEqualStrings("shell", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "exec rejects empty commands and bounds captured output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expectError(error.NoCommand, process.exec(testing.allocator, testing.io, &.{}));
    try testing.expectError(
        error.StreamTooLong,
        process.exec(testing.allocator, testing.io, &.{ "/bin/sh", "-c", "dd if=/dev/zero bs=1048576 count=11 2>/dev/null" }),
    );
}
