const std = @import("std");
const ts_cache = @import("ts_cache");
const testing = std.testing;

test "failed replacement preserves the old result" {
    const key = ts_cache.Cache.computeKey("source", "config");
    for (0..3) |fail_index| {
        var cache = try ts_cache.Cache.init(testing.allocator, null);
        defer cache.deinit();
        try cache.put(key, .{ .js = "old output", .diagnostic_count = 1, .has_errors = true });

        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        cache.gpa = failing.allocator();
        const replacement = cache.put(key, .{ .js = "new output", .diagnostic_count = 0, .has_errors = false });
        cache.gpa = testing.allocator;

        const result = (try cache.get(key)) orelse return error.LostPreviousResult;
        defer testing.allocator.free(result.js);
        if (replacement) |_| {
            try testing.expectEqualStrings("new output", result.js);
            try testing.expectEqual(@as(u32, 0), result.diagnostic_count);
            try testing.expect(!result.has_errors);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqualStrings("old output", result.js);
            try testing.expectEqual(@as(u32, 1), result.diagnostic_count);
            try testing.expect(result.has_errors);
        }
        try testing.expectEqual(@as(u32, 1), cache.count());
    }
}

test "failed insertion leaves no partial result" {
    const key = ts_cache.Cache.computeKey("new source", "config");
    for (0..4) |fail_index| {
        var cache = try ts_cache.Cache.init(testing.allocator, null);
        defer cache.deinit();

        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        cache.gpa = failing.allocator();
        const insertion = cache.put(key, .{ .js = "output", .diagnostic_count = 0, .has_errors = false });
        cache.gpa = testing.allocator;

        if (insertion) |_| {
            try testing.expectEqual(@as(u32, 1), cache.count());
            const result = (try cache.get(key)) orelse return error.MissingInsertedResult;
            defer testing.allocator.free(result.js);
            try testing.expectEqualStrings("output", result.js);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(u32, 0), cache.count());
            try testing.expect((try cache.get(key)) == null);
        }
    }
}
