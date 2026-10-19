const std = @import("std");
const watch = @import("ts_watch");
const testing = std.testing;

test "watcher emits one removal and detects same-metadata recreation" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    try fs.add("/entry.ts", 42, 128);

    var watcher = watch.Watcher.init(testing.allocator, fs.fs());
    defer watcher.deinit();
    try watcher.track("/entry.ts");

    fs.remove("/entry.ts");
    {
        var changes = try watcher.tick();
        defer changes.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), changes.changes.items.len);
        try testing.expectEqual(watch.ChangeKind.removed, changes.changes.items[0].kind);
    }
    {
        var changes = try watcher.tick();
        defer changes.deinit(testing.allocator);
        try testing.expect(changes.isEmpty());
    }

    try fs.add("/entry.ts", 42, 128);
    {
        var changes = try watcher.tick();
        defer changes.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), changes.changes.items.len);
        try testing.expectEqual(watch.ChangeKind.added, changes.changes.items[0].kind);
    }
    {
        var changes = try watcher.tick();
        defer changes.deinit(testing.allocator);
        try testing.expect(changes.isEmpty());
    }
}

test "watcher recognizes a present zero-stat file after tracking it missing" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    var watcher = watch.Watcher.init(testing.allocator, fs.fs());
    defer watcher.deinit();
    try watcher.track("/zero.ts");

    try fs.add("/zero.ts", 0, 0);
    var changes = try watcher.tick();
    defer changes.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), changes.changes.items.len);
    try testing.expectEqual(watch.ChangeKind.added, changes.changes.items[0].kind);
}

test "stat errors do not become removals or change the stored state" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    try fs.add("/entry.ts", 42, 128);

    var watcher = watch.Watcher.init(testing.allocator, fs.fs());
    defer watcher.deinit();
    try watcher.track("/entry.ts");

    fs.stat_error = error.AccessDenied;
    try testing.expectError(error.AccessDenied, watcher.tick());
    fs.stat_error = null;
    {
        var changes = try watcher.tick();
        defer changes.deinit(testing.allocator);
        try testing.expect(changes.isEmpty());
    }

    fs.remove("/entry.ts");
    var removal = try watcher.tick();
    defer removal.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), removal.changes.items.len);
    try testing.expectEqual(watch.ChangeKind.removed, removal.changes.items[0].kind);

    var other = watch.Watcher.init(testing.allocator, fs.fs());
    defer other.deinit();
    fs.stat_error = error.PermissionDenied;
    try testing.expectError(error.PermissionDenied, other.track("/entry.ts"));
    try testing.expectEqual(@as(usize, 0), other.count());
}

test "batch tracking publishes no partial set after a later stat error" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    try fs.add("/first.ts", 1, 1);
    try fs.add("/second.ts", 1, 1);
    var watcher = watch.Watcher.init(testing.allocator, fs.fs());
    defer watcher.deinit();

    fs.error_path = "/second.ts";
    fs.stat_error = error.AccessDenied;
    try testing.expectError(error.AccessDenied, watcher.trackMany(&.{ "/first.ts", "/second.ts" }));
    try testing.expectEqual(@as(usize, 0), watcher.count());

    fs.error_path = null;
    fs.stat_error = null;
    try fs.add("/first.ts", 2, 2);
    try watcher.trackMany(&.{ "/first.ts", "/second.ts", "/first.ts" });
    try testing.expectEqual(@as(usize, 2), watcher.count());
    var unchanged = try watcher.tick();
    defer unchanged.deinit(testing.allocator);
    try testing.expect(unchanged.isEmpty());

    try fs.add("/first.ts", 3, 2);
    var change = try watcher.tick();
    defer change.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), change.changes.items.len);
    try testing.expectEqualStrings("/first.ts", change.changes.items[0].path);
}

test "batch tracking is atomic across allocation failures" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    try fs.add("/first.ts", 1, 1);
    try fs.add("/second.ts", 1, 1);

    var saw_failure = false;
    var saw_success = false;
    for (0..12) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var watcher = watch.Watcher.init(failing.allocator(), fs.fs());
        defer watcher.deinit();
        if (watcher.trackMany(&.{ "/first.ts", "/second.ts" })) |_| {
            saw_success = true;
            try testing.expectEqual(@as(usize, 2), watcher.count());
        } else |err| {
            saw_failure = true;
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), watcher.count());
        }
    }
    try testing.expect(saw_failure);
    try testing.expect(saw_success);
}

test "batch tracking does not reset a pending change on an existing root" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    try fs.add("/root.ts", 1, 1);
    try fs.add("/new-import.ts", 1, 1);
    var watcher = watch.Watcher.init(testing.allocator, fs.fs());
    defer watcher.deinit();
    try watcher.track("/root.ts");

    try fs.add("/root.ts", 2, 2);
    try watcher.trackMany(&.{ "/root.ts", "/new-import.ts" });
    try testing.expectEqual(@as(usize, 2), watcher.count());
    var changes = try watcher.tick();
    defer changes.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), changes.changes.items.len);
    try testing.expectEqualStrings("/root.ts", changes.changes.items[0].path);
    try testing.expectEqual(watch.ChangeKind.modified, changes.changes.items[0].kind);
}

test "track owns its path only after insertion succeeds" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    try fs.add("/entry.ts", 42, 128);

    for (0..3) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var watcher = watch.Watcher.init(failing.allocator(), fs.fs());
        defer watcher.deinit();

        if (watcher.track("/entry.ts")) |_| {
            try testing.expectEqual(@as(usize, 1), watcher.count());
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), watcher.count());
        }
    }
}

test "failed event allocation leaves the change pending" {
    for (0..3) |fail_index| {
        var fs = watch.VirtualWatchFs.init(testing.allocator);
        defer fs.deinit();
        try fs.add("/entry.ts", 42, 128);
        var watcher = watch.Watcher.init(testing.allocator, fs.fs());
        defer watcher.deinit();
        try watcher.track("/entry.ts");
        try fs.add("/entry.ts", 43, 128);

        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        watcher.gpa = failing.allocator();
        const attempt = watcher.tick();
        watcher.gpa = testing.allocator;

        if (attempt) |changes| {
            var owned = changes;
            defer owned.deinit(failing.allocator());
            try testing.expectEqual(@as(usize, 1), owned.changes.items.len);
            var next = try watcher.tick();
            defer next.deinit(testing.allocator);
            try testing.expect(next.isEmpty());
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            var next = try watcher.tick();
            defer next.deinit(testing.allocator);
            try testing.expectEqual(@as(usize, 1), next.changes.items.len);
            try testing.expectEqual(watch.ChangeKind.modified, next.changes.items[0].kind);
        }
    }
}

test "a later stat failure does not consume an earlier change" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    try fs.add("/a.ts", 42, 128);
    try fs.add("/b.ts", 42, 128);
    var watcher = watch.Watcher.init(testing.allocator, fs.fs());
    defer watcher.deinit();
    try watcher.track("/a.ts");
    try watcher.track("/b.ts");

    var paths = watcher.tracked.iterator();
    const first = paths.next().?.key_ptr.*;
    const second = paths.next().?.key_ptr.*;
    try fs.add(first, 43, 128);
    fs.error_path = second;
    fs.stat_error = error.AccessDenied;
    try testing.expectError(error.AccessDenied, watcher.tick());
    fs.stat_error = null;
    fs.error_path = null;

    var changes = try watcher.tick();
    defer changes.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), changes.changes.items.len);
    try testing.expectEqualStrings(first, changes.changes.items[0].path);
    try testing.expectEqual(watch.ChangeKind.modified, changes.changes.items[0].kind);
}

test "allocation failure after any of two changes keeps both pending" {
    for (0..8) |fail_index| {
        var fs = watch.VirtualWatchFs.init(testing.allocator);
        defer fs.deinit();
        try fs.add("/a.ts", 42, 128);
        try fs.add("/b.ts", 42, 128);
        var watcher = watch.Watcher.init(testing.allocator, fs.fs());
        defer watcher.deinit();
        try watcher.track("/a.ts");
        try watcher.track("/b.ts");
        try fs.add("/a.ts", 43, 128);
        try fs.add("/b.ts", 43, 128);

        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        watcher.gpa = failing.allocator();
        const attempt = watcher.tick();
        watcher.gpa = testing.allocator;

        if (attempt) |changes| {
            var owned = changes;
            defer owned.deinit(failing.allocator());
            try testing.expectEqual(@as(usize, 2), owned.changes.items.len);
            var next = try watcher.tick();
            defer next.deinit(testing.allocator);
            try testing.expect(next.isEmpty());
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            var next = try watcher.tick();
            defer next.deinit(testing.allocator);
            try testing.expectEqual(@as(usize, 2), next.changes.items.len);
        }
    }
}

test "virtual filesystem replacement updates in place without allocation" {
    var fs = watch.VirtualWatchFs.init(testing.allocator);
    defer fs.deinit();
    try fs.add("/entry.ts", 42, 128);

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    fs.gpa = failing.allocator();
    try fs.add("/entry.ts", 43, 256);
    fs.gpa = testing.allocator;

    try testing.expectEqual(@as(usize, 1), fs.files.count());
    try testing.expectEqual(@as(i128, 43), fs.files.get("/entry.ts").?.mtime);
    try testing.expectEqual(@as(u64, 256), fs.files.get("/entry.ts").?.size);
}

test "failed virtual filesystem insertion owns no incomplete entry" {
    for (0..4) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var fs = watch.VirtualWatchFs.init(failing.allocator());
        defer fs.deinit();

        if (fs.add("/new.ts", 42, 128)) |_| {
            try testing.expectEqual(@as(usize, 1), fs.files.count());
            try testing.expectEqual(@as(i128, 42), fs.files.get("/new.ts").?.mtime);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), fs.files.count());
        }
    }
}
