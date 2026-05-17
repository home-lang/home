// Copied verbatim from bun/src/http/HeaderValueIterator.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

const HeaderValueIterator = @This();

iterator: std.mem.TokenIterator(u8, .scalar),

pub fn init(input: []const u8) HeaderValueIterator {
    return HeaderValueIterator{
        .iterator = std.mem.tokenizeScalar(u8, std.mem.trim(u8, input, " \t"), ','),
    };
}

pub fn next(self: *HeaderValueIterator) ?[]const u8 {
    const slice = std.mem.trim(u8, self.iterator.next() orelse return null, " \t");
    if (slice.len == 0) return self.next();

    return slice;
}

const std = @import("std");

test "HeaderValueIterator splits on commas and trims whitespace" {
    var it = HeaderValueIterator.init("gzip, deflate ,  br");
    try std.testing.expectEqualStrings("gzip", it.next().?);
    try std.testing.expectEqualStrings("deflate", it.next().?);
    try std.testing.expectEqualStrings("br", it.next().?);
    try std.testing.expect(it.next() == null);
}

test "HeaderValueIterator skips empty segments" {
    var it = HeaderValueIterator.init("a,,b");
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("b", it.next().?);
    try std.testing.expect(it.next() == null);
}
