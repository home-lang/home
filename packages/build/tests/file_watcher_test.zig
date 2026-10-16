const std = @import("std");
const file_watcher = @import("file_watcher");

test "a deleted file emits once and recreation emits created" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/watched.home", .{temp.sub_path});
    defer allocator.free(path);

    const original = try std.Io.Dir.cwd().createFile(io, path, .{});
    try original.writeStreamingAll(io, "original");
    original.close(io);

    var watcher = file_watcher.FileWatcher.init(allocator, 10, io);
    defer watcher.deinit();
    try watcher.watch(path);

    try watcher.pollOnce();
    try std.testing.expect(!watcher.hasPendingChanges());

    try std.Io.Dir.cwd().deleteFile(io, path);
    try watcher.pollOnce();
    const deleted = try watcher.pollEvents(allocator);
    defer file_watcher.deinitEvents(allocator, deleted);
    try std.testing.expectEqual(@as(usize, 1), deleted.len);
    try std.testing.expectEqual(file_watcher.FileEvent.EventType.Deleted, deleted[0].event_type);

    try watcher.pollOnce();
    try std.testing.expect(!watcher.hasPendingChanges());

    const recreated = try std.Io.Dir.cwd().createFile(io, path, .{});
    try recreated.writeStreamingAll(io, "recreated");
    recreated.close(io);
    try watcher.pollOnce();
    const created = try watcher.pollEvents(allocator);
    defer file_watcher.deinitEvents(allocator, created);
    try std.testing.expectEqual(@as(usize, 1), created.len);
    try std.testing.expectEqual(file_watcher.FileEvent.EventType.Created, created[0].event_type);

    try watcher.pollOnce();
    try std.testing.expect(!watcher.hasPendingChanges());

    const modified = try std.Io.Dir.cwd().createFile(io, path, .{});
    try modified.writeStreamingAll(io, "a different length");
    modified.close(io);
    try watcher.pollOnce();
    const updated = try watcher.pollEvents(allocator);
    defer file_watcher.deinitEvents(allocator, updated);
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqual(file_watcher.FileEvent.EventType.Modified, updated[0].event_type);
}

test "a failed deletion enqueue is retried on the next poll" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    for (0..2) |fail_index| {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/watched.home", .{temp.sub_path});
        defer allocator.free(path);

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        file.close(io);
        var watcher = file_watcher.FileWatcher.init(allocator, 10, io);
        defer watcher.deinit();
        try watcher.watch(path);
        try std.Io.Dir.cwd().deleteFile(io, path);

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        watcher.allocator = failing.allocator();
        const failed_poll = watcher.pollOnce();
        watcher.allocator = allocator;
        try std.testing.expectError(error.OutOfMemory, failed_poll);
        try std.testing.expect(!watcher.hasPendingChanges());

        try watcher.pollOnce();
        const events = try watcher.pollEvents(allocator);
        defer file_watcher.deinitEvents(allocator, events);
        try std.testing.expectEqual(@as(usize, 1), events.len);
        try std.testing.expectEqual(file_watcher.FileEvent.EventType.Deleted, events[0].event_type);
    }
}
