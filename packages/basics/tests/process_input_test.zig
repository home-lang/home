const std = @import("std");
const builtin = @import("builtin");
const process = @import("basics_process");
const testing = std.testing;

test "execWithInput closes stdin and returns child output and status" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var result = try process.execWithInput(
        testing.allocator,
        testing.io,
        &.{ "/bin/sh", "-c", "cat; printf 'diagnostic' >&2; exit 7" },
        "hello from stdin",
    );
    defer result.deinit();
    try testing.expectEqualStrings("hello from stdin", result.stdout);
    try testing.expectEqualStrings("diagnostic", result.stderr);
    try testing.expectEqual(@as(u32, 7), result.exit_code);
}

test "execWithInput concurrently feeds stdin and drains both output pipes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const input = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(input);
    @memset(input, 'x');

    const command = "cat; i=0; while [ \"$i\" -lt 8192 ]; do printf 'ABCDEFGHIJKLMNOP' >&2; i=$((i+1)); done";
    var result = try process.execWithInput(testing.allocator, testing.io, &.{ "/bin/sh", "-c", command }, input);
    defer result.deinit();
    try testing.expectEqual(@as(u32, 0), result.exit_code);
    try testing.expectEqualSlices(u8, input, result.stdout);
    try testing.expectEqual(@as(usize, 131_072), result.stderr.len);
    try testing.expectEqualStrings("ABCDEFGHIJKLMNOP", result.stderr[result.stderr.len - 16 ..]);
}

test "execWithInput handles empty stdin and rejects an empty command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var result = try process.execWithInput(testing.allocator, testing.io, &.{ "/bin/sh", "-c", "cat" }, "");
    defer result.deinit();
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectError(error.NoCommand, process.execWithInput(testing.allocator, testing.io, &.{}, "x"));
}

test "execWithInput enforces the capture limit after stdin closes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expectError(
        error.StreamTooLong,
        process.execWithInput(
            testing.allocator,
            testing.io,
            &.{ "/bin/sh", "-c", "cat >/dev/null; dd if=/dev/zero bs=1048576 count=11 2>/dev/null" },
            "input",
        ),
    );
}

test "execWithInput reports unavailable concurrency without waiting on child stdin" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    try testing.expectError(
        error.ConcurrencyUnavailable,
        process.execWithInput(testing.allocator, threaded.io(), &.{ "/bin/sh", "-c", "cat" }, "input"),
    );

    var empty_result = try process.execWithInput(testing.allocator, threaded.io(), &.{ "/bin/sh", "-c", "cat" }, "");
    defer empty_result.deinit();
    try testing.expectEqual(@as(u32, 0), empty_result.exit_code);
    try testing.expectEqualStrings("", empty_result.stdout);
}
