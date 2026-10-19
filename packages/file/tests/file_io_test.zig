const std = @import("std");
const file = @import("file");

fn pathIn(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, name });
}

test "file cursor preserves seek, overwrite, read, and append semantics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try pathIn(allocator, root, "cursor.txt");
    defer allocator.free(path);

    {
        var output = try file.File.create(allocator, path, io);
        defer output.close();
        try output.write("abcd");
        try std.testing.expectEqual(@as(u64, 4), try output.getPos());
        try output.seekTo(2);
        try output.write("XY");
        try output.sync();
        try std.testing.expectEqual(@as(u64, 4), try output.size());
    }

    {
        var input = try file.File.open(allocator, path, io);
        defer input.close();
        try input.seekTo(1);
        const rest = try input.readAll();
        defer allocator.free(rest);
        try std.testing.expectEqualStrings("bXY", rest);
        try std.testing.expectEqual(@as(u64, 4), try input.getPos());
    }

    {
        var output = try file.File.openForAppend(allocator, path, io);
        defer output.close();
        try std.testing.expectEqual(@as(u64, 4), try output.getPos());
        try output.write("!");
    }
    const content = try file.readToString(allocator, path, io);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("abXY!", content);
}

test "file directory helpers distinguish one-level creation and recursive removal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const parent = try pathIn(allocator, root, "parent");
    defer allocator.free(parent);
    const nested = try pathIn(allocator, parent, "nested");
    defer allocator.free(nested);
    const payload = try pathIn(allocator, nested, "payload.txt");
    defer allocator.free(payload);

    try std.testing.expectError(error.FileNotFound, file.createDir(nested, io));
    try file.createDirAll(nested, io);
    try std.testing.expect(file.isDir(nested, io));
    try file.writeString(allocator, payload, "payload", io);
    try std.testing.expect(file.isFile(payload, io));
    try file.removeDirAll(parent, io);
    try std.testing.expect(!file.exists(parent, io));
}
