const std = @import("std");
const testing = std.testing;
const basics = @import("basics");

test "Basics fs exposes current Io file and directory types" {
    try testing.expect(basics.fs.File == std.Io.File);
    try testing.expect(basics.fs.Dir == std.Io.Dir);
    try testing.expect(@TypeOf(basics.fs.cwd()) == std.Io.Dir);
}

test "Basics fs absolute operations create, read, and remove real files and directories" {
    const io = testing.io;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const child = try std.fs.path.join(allocator, &.{ root, "child" });
    defer allocator.free(child);
    const file_path = try std.fs.path.join(allocator, &.{ child, "payload.txt" });
    defer allocator.free(file_path);

    try basics.fs.makeDirAbsolute(io, child);
    try testing.expectError(error.PathAlreadyExists, basics.fs.makeDirAbsolute(io, child));

    {
        const output = try basics.fs.createFileAbsolute(io, file_path, .{});
        defer output.close(io);
        try output.writeStreamingAll(io, "Home Io");
    }

    {
        const input = try basics.fs.openFileAbsolute(io, file_path, .{});
        defer input.close(io);
        const stat = try input.stat(io);
        try testing.expectEqual(@as(u64, 7), stat.size);
    }
    const data = try basics.fs.cwd().readFileAlloc(io, file_path, allocator, .limited(32));
    defer allocator.free(data);
    try testing.expectEqualStrings("Home Io", data);

    try basics.fs.deleteFileAbsolute(io, file_path);
    try testing.expectError(error.FileNotFound, basics.fs.openFileAbsolute(io, file_path, .{}));
    try basics.fs.deleteDirAbsolute(io, child);
}
