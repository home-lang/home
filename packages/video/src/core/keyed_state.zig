//! Bounded desired settings; stage by value, publish only after external accept.
const std = @import("std");
pub fn State(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        entries: [capacity]T = undefined,
        count: usize = 0,
        pub fn values(s: *const Self) []const T {
            return s.entries[0..s.count];
        }
        /// IDs are nonzero u32 keys. Removals happen before updates, permitting
        /// dependency invalidation and explicit overrides in the same batch.
        /// Sorted output is deterministic. Failure never mutates the source.
        pub fn updated(s: Self, updates: []const T, removed: []const u32) !Self {
            if (updates.len > capacity or removed.len > capacity) return error.InvalidBatch;
            for (updates, 0..) |value, i| {
                if (value.id == 0) return error.InvalidBatch;
                for (updates[0..i]) |previous| if (previous.id == value.id) return error.InvalidBatch;
            }
            var next: Self = .{};
            for (s.values()) |value| {
                var skip = false;
                for (removed) |id| if (id == value.id) {
                    skip = true;
                };
                if (!skip) {
                    next.entries[next.count] = value;
                    next.count += 1;
                }
            }
            for (updates) |value| {
                var index: usize = 0;
                while (index < next.count and next.entries[index].id < value.id) : (index += 1) {}
                if (index < next.count and next.entries[index].id == value.id) {
                    next.entries[index] = value;
                } else {
                    if (next.count == capacity) return error.StateFull;
                    var end = next.count;
                    while (end > index) : (end -= 1) next.entries[end] = next.entries[end - 1];
                    next.entries[index] = value;
                    next.count += 1;
                }
            }
            return next;
        }
    };
}
test "keyed settings stage ordered copies, removals and explicit dependency overrides" {
    const Value = struct { id: u32, value: i32 };
    const S = State(Value, 3);
    const empty: S = .{};
    const first = try empty.updated(&.{ .{ .id = 3, .value = 30 }, .{ .id = 1, .value = 10 } }, &.{});
    const next = try first.updated(&.{ .{ .id = 3, .value = 31 }, .{ .id = 2, .value = 20 } }, &.{3});
    try std.testing.expectEqual(@as(usize, 0), empty.count);
    try std.testing.expectEqual(@as(i32, 30), first.values()[1].value);
    try std.testing.expectEqual(@as(usize, 3), next.count);
    for (next.values(), 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i + 1)), value.id);
    try std.testing.expectEqual(@as(i32, 31), next.values()[2].value);
    const cleared = try next.updated(&.{}, &.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 0), cleared.count);
    try std.testing.expectError(error.StateFull, next.updated(&.{.{ .id = 4, .value = 0 }}, &.{}));
    try std.testing.expectError(error.InvalidBatch, next.updated(&.{ .{ .id = 2, .value = 1 }, .{ .id = 2, .value = 2 } }, &.{}));
    try std.testing.expectError(error.InvalidBatch, next.updated(&.{.{ .id = 0, .value = 0 }}, &.{}));
    try std.testing.expectError(error.InvalidBatch, next.updated(&.{}, &.{ 1, 2, 3, 4 }));
    try std.testing.expectEqual(@as(i32, 20), next.values()[1].value);
}
