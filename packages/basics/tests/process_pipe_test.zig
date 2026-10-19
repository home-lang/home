const std = @import("std");
const builtin = @import("builtin");
const process = @import("basics_process");
const testing = std.testing;

test "Pipe rejects an empty chain or command" {
    var pipe = process.Pipe.init(testing.allocator, testing.io);
    defer pipe.deinit();
    try testing.expectError(error.NoPipeline, pipe.run());
    try testing.expectError(error.NoCommand, pipe.add(&.{}));
}

test "Pipe returns the final command output and exit status" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var pipe = process.Pipe.init(testing.allocator, testing.io);
    defer pipe.deinit();
    try pipe.add(&.{ "/bin/sh", "-c", "printf hello" });
    try pipe.add(&.{ "/bin/sh", "-c", "tr a-z A-Z; exit 7" });
    var result = try pipe.run();
    defer result.deinit();
    try testing.expectEqualStrings("HELLO", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectEqual(@as(u32, 7), result.exit_code);
}

test "Pipe streams through three live processes beyond pipe capacity" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var pipe = process.Pipe.init(testing.allocator, testing.io);
    defer pipe.deinit();
    try pipe.add(&.{ "/bin/sh", "-c", "yes x | head -c 262144" });
    try pipe.add(&.{ "/bin/sh", "-c", "cat" });
    try pipe.add(&.{ "/bin/sh", "-c", "cat" });

    var result = try pipe.run();
    defer result.deinit();
    try testing.expectEqual(@as(u32, 0), result.exit_code);
    try testing.expectEqual(@as(usize, 262144), result.stdout.len);
    try testing.expectEqualStrings("x\n", result.stdout[0..2]);
    try testing.expectEqualStrings("", result.stderr);

    var second = try pipe.run();
    defer second.deinit();
    try testing.expectEqual(@as(u32, 0), second.exit_code);
    try testing.expectEqual(@as(usize, 262144), second.stdout.len);
}

test "Pipe retains last-command status when an earlier command fails" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var pipe = process.Pipe.init(testing.allocator, testing.io);
    defer pipe.deinit();
    try pipe.add(&.{ "/bin/sh", "-c", "exit 9" });
    try pipe.add(&.{ "/bin/sh", "-c", "cat; printf done" });
    var result = try pipe.run();
    defer result.deinit();
    try testing.expectEqual(@as(u32, 0), result.exit_code);
    try testing.expectEqualStrings("done", result.stdout);
}

test "Pipe enforces the output limit and reaps every stage on failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var pipe = process.Pipe.init(testing.allocator, testing.io);
    defer pipe.deinit();
    try pipe.add(&.{ "/bin/sh", "-c", "head -c 11000000 /dev/zero" });
    try pipe.add(&.{ "/bin/sh", "-c", "cat" });
    try testing.expectError(error.StreamTooLong, pipe.run());
}
