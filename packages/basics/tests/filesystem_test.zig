const std = @import("std");
const fs = @import("basics_filesystem");

const testing = std.testing;

fn tempPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, parts: []const []const u8) ![]u8 {
    var root_buffer: [fs.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);

    var all_parts = try allocator.alloc([]const u8, parts.len + 1);
    defer allocator.free(all_parts);
    all_parts[0] = root_buffer[0..root_len];
    @memcpy(all_parts[1..], parts);
    return std.fs.path.join(allocator, all_parts);
}

test "default filesystem helpers round trip files and directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const nested_dir = try tempPath(allocator, &tmp, &.{ "nested", "child" });
    defer allocator.free(nested_dir);
    const source = try tempPath(allocator, &tmp, &.{ "nested", "child", "source.txt" });
    defer allocator.free(source);
    const copied = try tempPath(allocator, &tmp, &.{ "nested", "child", "copied.txt" });
    defer allocator.free(copied);
    const moved = try tempPath(allocator, &tmp, &.{ "nested", "child", "moved.txt" });
    defer allocator.free(moved);
    const top_level_dir = try tempPath(allocator, &tmp, &.{"nested"});
    defer allocator.free(top_level_dir);

    try fs.createDirectory(nested_dir);
    try testing.expect(fs.exists(nested_dir));
    try testing.expect(fs.isDirectory(nested_dir));
    try testing.expect(!fs.isFile(nested_dir));

    try fs.writeFile(source, "hello");
    try fs.appendFile(source, " home");
    try testing.expect(fs.isFile(source));
    try testing.expectEqual(@as(u64, 10), try fs.fileSize(source));

    const contents = try fs.readFile(allocator, source);
    defer allocator.free(contents);
    try testing.expectEqualStrings("hello home", contents);

    try fs.copyFile(source, copied);
    try fs.moveFile(copied, moved);
    try testing.expect(!fs.exists(copied));
    try testing.expect(fs.exists(moved));

    const absolute = try fs.absolutePath(allocator, moved);
    defer allocator.free(absolute);
    try testing.expect(std.fs.path.isAbsolute(absolute));
    try testing.expectEqualStrings("moved.txt", fs.basename(absolute));

    try fs.deleteFile(source);
    try testing.expect(!fs.exists(source));
    try fs.deleteDirectory(top_level_dir);
    try testing.expect(!fs.exists(nested_dir));
}

test "explicit I/O helpers expose and close directory iteration" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = testing.allocator;
    const root = try tempPath(allocator, &tmp, &.{});
    defer allocator.free(root);
    const first = try tempPath(allocator, &tmp, &.{"first.txt"});
    defer allocator.free(first);
    const second = try tempPath(allocator, &tmp, &.{"second.txt"});
    defer allocator.free(second);

    try fs.writeFileWithIo(testing.io, first, "1");
    try fs.writeFileWithIo(testing.io, second, "22");
    try testing.expect(fs.existsWithIo(testing.io, first));
    try testing.expectEqual(@as(u64, 2), try fs.fileSizeWithIo(testing.io, second));

    var iterator = try fs.listDirectoryWithIo(testing.io, root);
    defer iterator.deinit();

    var found_first = false;
    var found_second = false;
    while (try iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "first.txt")) found_first = true;
        if (std.mem.eql(u8, entry.name, "second.txt")) found_second = true;
    }
    try testing.expect(found_first);
    try testing.expect(found_second);

    const cwd = try fs.getCurrentDirectoryWithIo(testing.io, allocator);
    defer allocator.free(cwd);
    try testing.expect(std.fs.path.isAbsolute(cwd));
}

test "all filesystem declarations compile" {
    std.testing.refAllDecls(fs);
}
