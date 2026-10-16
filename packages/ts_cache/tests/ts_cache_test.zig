const std = @import("std");
const ts_cache = @import("ts_cache");

test "source/config boundaries do not alias a cache entry" {
    const first = ts_cache.Cache.computeKey("a|b", "c");
    const second = ts_cache.Cache.computeKey("a", "b|c");
    const empty_config = ts_cache.Cache.computeKey("a|b", "");
    const nonempty_config = ts_cache.Cache.computeKey("a", "b");

    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    try std.testing.expect(!std.mem.eql(u8, &empty_config, &nonempty_config));

    var cache = try ts_cache.Cache.init(std.testing.allocator, null);
    defer cache.deinit();
    try cache.put(first, .{ .js = "first output", .diagnostic_count = 0, .has_errors = false });
    try std.testing.expect((try cache.get(second)) == null);
}

test "binary source and config bytes remain distinct" {
    const first = ts_cache.Cache.computeKey("a\x00b", "c");
    const second = ts_cache.Cache.computeKey("a", "\x00bc");
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}
