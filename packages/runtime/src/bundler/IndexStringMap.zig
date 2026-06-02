// Copied from bun/src/bundler/IndexStringMap.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"); bun.ast → home_rt.ast.

const IndexStringMap = @This();

pub const Index = home_rt.ast.Index;

map: std.AutoArrayHashMapUnmanaged(Index.Int, []const u8) = .{},

pub fn deinit(self: *IndexStringMap, allocator: std.mem.Allocator) void {
    for (self.map.values()) |value| {
        allocator.free(value);
    }
    self.map.deinit(allocator);
}

pub fn get(self: *const IndexStringMap, index: Index.Int) ?[]const u8 {
    return self.map.get(index);
}

pub fn put(self: *IndexStringMap, allocator: std.mem.Allocator, index: Index.Int, value: []const u8) !void {
    const duped = try allocator.dupe(u8, value);
    errdefer allocator.free(duped);
    try self.map.put(allocator, index, duped);
}

const home_rt = @import("home");
const std = @import("std");

test "IndexStringMap: put then get round-trips" {
    var map = IndexStringMap{};
    defer map.deinit(std.testing.allocator);
    try map.put(std.testing.allocator, 0, "hello");
    try map.put(std.testing.allocator, 1, "world");
    try std.testing.expectEqualStrings("hello", map.get(0).?);
    try std.testing.expectEqualStrings("world", map.get(1).?);
    try std.testing.expect(map.get(999) == null);
}
