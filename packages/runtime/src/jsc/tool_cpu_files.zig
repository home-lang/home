//! Bounded reads of kernel pseudo files; their stat size can be zero.
const std = @import("std");
const io = std.Io.Threaded.global_single_threaded.io();

pub fn read(allocator: std.mem.Allocator, directory: std.Io.Dir, path: []const u8, limit: std.Io.Limit) ![]u8 {
    var file = try directory.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    // The positional reader's allocating-writer optimization trusts stat.size.
    // procfs/cgroup files can advertise zero while returning live data.
    var reader = std.Io.File.Reader.initStreaming(file, io, &buffer);
    return reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
}

test "CPU pseudo-file reads ignore zero advertised length and retain byte limits" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const content = "cpu0 1 2 3 4 5 6\n";
    try temporary.dir.writeFile(io, .{ .sub_path = "stat", .data = content });
    var file = try temporary.dir.openFile(io, "stat", .{});
    defer file.close(io);
    var cached = std.Io.File.Reader.initSize(file, io, &.{}, 0);
    const empty = try cached.interface.allocRemaining(std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const streamed = try read(std.testing.allocator, temporary.dir, "stat", .limited(1024));
    defer std.testing.allocator.free(streamed);
    try std.testing.expectEqualStrings(content, streamed);
    try std.testing.expectError(error.StreamTooLong, read(std.testing.allocator, temporary.dir, "stat", .limited(8)));
}
