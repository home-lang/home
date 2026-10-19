const std = @import("std");
const fs = @import("basics_fs_util");
const testing = std.testing;

fn tempPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, parts: []const []const u8) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buffer);
    const all_parts = try allocator.alloc([]const u8, parts.len + 1);
    defer allocator.free(all_parts);
    all_parts[0] = root_buffer[0..root_len];
    @memcpy(all_parts[1..], parts);
    return std.fs.path.join(allocator, all_parts);
}

test "public fs_util file modes preserve cursor, limits, and append data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try tempPath(allocator, &tmp, &.{"data.txt"});
    defer allocator.free(path);

    try fs.writeFile(allocator, path, "hello");
    const file = try fs.File.open(allocator, path, .ReadWrite);
    try testing.expectEqual(@as(u64, 5), try file.size());
    var prefix: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try file.read(&prefix));
    try testing.expectEqualStrings("he", &prefix);
    try testing.expectEqual(@as(u64, 2), try file.tell());
    const rest = try file.readToString(3);
    defer allocator.free(rest);
    try testing.expectEqualStrings("llo", rest);
    try file.seek(1);
    try file.writeString("A");
    try testing.expectEqual(@as(u64, 2), try file.tell());
    file.close();

    try fs.appendFile(allocator, path, "!");
    const append = try fs.File.open(allocator, path, .Append);
    try append.seek(0);
    try append.writeString("?");
    append.close();

    const contents = try fs.readFile(allocator, path);
    defer allocator.free(contents);
    try testing.expectEqualStrings("hAllo!?", contents);

    const limited = try fs.File.open(allocator, path, .Read);
    defer limited.close();
    try testing.expectError(error.StreamTooLong, limited.readToString(2));
    try limited.seek(5);
    const suffix = try limited.readToString(2);
    defer allocator.free(suffix);
    try testing.expectEqualStrings("!?", suffix);
}

test "public fs_util directory operations and paths are exercised" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const root = try tempPath(allocator, &tmp, &.{});
    defer allocator.free(root);
    const nested = try tempPath(allocator, &tmp, &.{ "a", "b" });
    defer allocator.free(nested);
    const source = try tempPath(allocator, &tmp, &.{ "a", "b", "source.txt" });
    defer allocator.free(source);
    const copy = try tempPath(allocator, &tmp, &.{ "a", "b", "copy.txt" });
    defer allocator.free(copy);
    const moved = try tempPath(allocator, &tmp, &.{ "a", "b", "moved.txt" });
    defer allocator.free(moved);

    try fs.Dir.createAll(allocator, nested);
    try testing.expect(fs.Dir.exists(allocator, nested));
    try fs.writeFile(allocator, source, "payload");
    try fs.Dir.copyFile(allocator, source, copy);
    try fs.Dir.rename(allocator, copy, moved);
    try testing.expect(!fs.Dir.exists(allocator, copy));
    try testing.expect(fs.Dir.exists(allocator, moved));

    {
        const dir = try fs.Dir.open(allocator, nested);
        defer dir.close();
        const entries = try dir.list();
        defer {
            for (entries) |entry| allocator.free(entry.name);
            allocator.free(entries);
        }
        var found_source = false;
        var found_moved = false;
        for (entries) |entry| {
            try testing.expectEqual(fs.EntryKind.File, entry.kind);
            if (std.mem.eql(u8, entry.name, "source.txt")) found_source = true;
            if (std.mem.eql(u8, entry.name, "moved.txt")) found_moved = true;
        }
        try testing.expect(found_source and found_moved);
    }

    const absolute = try fs.Path.absolute(allocator, moved);
    defer allocator.free(absolute);
    try testing.expect(fs.Path.isAbsolute(absolute));
    try testing.expectEqualStrings("moved.txt", fs.Path.basename(absolute));
    try testing.expectEqualStrings(".txt", fs.Path.extension(absolute));
    try testing.expectEqualStrings(nested, fs.Path.dirname(absolute));

    try fs.Dir.deleteFile(allocator, source);
    try fs.Dir.deleteFile(allocator, moved);
    try fs.Dir.deleteDir(allocator, nested);
    const parent = try fs.Path.join(allocator, &.{ root, "a" });
    defer allocator.free(parent);
    try fs.Dir.deleteDirAll(allocator, parent);
    try testing.expect(!fs.Dir.exists(allocator, parent));
}

test "public fs_util creates and opens without leaking on errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const nested = try tempPath(allocator, &tmp, &.{"single"});
    defer allocator.free(nested);
    const path = try tempPath(allocator, &tmp, &.{ "single", "file.txt" });
    defer allocator.free(path);
    const missing = try tempPath(allocator, &tmp, &.{"missing.txt"});
    defer allocator.free(missing);

    try testing.expectError(error.FileNotFound, fs.File.open(allocator, missing, .Read));
    try fs.Dir.create(allocator, nested);
    const created = try fs.File.create(allocator, path);
    try created.writeString("1234");
    created.close();

    const writable = try fs.File.open(allocator, path, .Write);
    try testing.expectEqual(@as(usize, 1), try writable.write("X"));
    writable.close();
    const original = try fs.readFile(allocator, path);
    defer allocator.free(original);
    try testing.expectEqualStrings("X234", original);

    const truncated = try fs.File.create(allocator, path);
    try testing.expectEqual(@as(u64, 0), try truncated.size());
    truncated.close();
    const empty = try fs.readFile(allocator, path);
    defer allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}
