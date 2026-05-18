// Home Runtime — ported from Bun.
// Upstream:  packages/runtime/upstream/src/bundler/IndexStringMap.zig
// Pinned SHA: fd0b6f1a271fca0b8124b69f230b100f4d636af6
//
// Renames applied (per packages/runtime/README.md naming convention):
//   - `@import("bun")`              -> `@import("home_rt")`
//   - `bun.ast.Index`               -> `home_rt.ast.Index`
//
// Pure-data leaf: a `std.AutoArrayHashMapUnmanaged(Index.Int, []const u8)`
// where the map owns the value strings (they're duped on insert and freed on
// deinit). Used by the bundler to attach short per-source-index labels to
// AST source slots. Nothing JSC- or sys-tied, so this ports verbatim once
// `home_rt.ast.Index` is in place.

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

const home_rt = @import("home_rt");
const std = @import("std");

test "IndexStringMap: put + get round-trip + deinit frees values" {
    const allocator = std.testing.allocator;
    var m: IndexStringMap = .{};
    defer m.deinit(allocator);

    try m.put(allocator, 1, "home");
    try m.put(allocator, 42, "runtime");

    try std.testing.expectEqualStrings("home", m.get(1).?);
    try std.testing.expectEqualStrings("runtime", m.get(42).?);
    try std.testing.expect(m.get(7) == null);
}

test "IndexStringMap: empty map returns null" {
    var m: IndexStringMap = .{};
    // No allocator interaction needed when never inserting.
    try std.testing.expect(m.get(0) == null);
    try std.testing.expect(m.get(std.math.maxInt(Index.Int)) == null);
}

test "IndexStringMap: many inserts cleaned up by deinit" {
    const allocator = std.testing.allocator;
    var m: IndexStringMap = .{};
    defer m.deinit(allocator);

    var i: Index.Int = 0;
    while (i < 32) : (i += 1) {
        try m.put(allocator, i, "value");
    }
    try std.testing.expectEqual(@as(usize, 32), m.map.count());
}
