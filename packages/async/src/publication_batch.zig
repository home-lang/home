//! Fixed-capacity, allocation-free validation for a shared publication decision.
//! Caller owns participants, locks in plan order, rechecks readiness under those
//! locks, then commits every member before releasing any lock or running hooks.
const std = @import("std");
pub const State = struct { ready: bool, published: bool = false, cancelled: bool = false };
pub fn Plan(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        count: usize,
        order: [capacity]usize = undefined,
        pub fn init(identities: []const usize) !Self {
            if (identities.len == 0 or identities.len > capacity) return error.InvalidCount;
            var result = Self{ .count = identities.len };
            for (identities, 0..) |id, i| {
                if (id == 0) return error.InvalidIdentity;
                var position = i;
                while (position > 0 and identities[result.order[position - 1]] > id) : (position -= 1) result.order[position] = result.order[position - 1];
                if (position > 0 and identities[result.order[position - 1]] == id) return error.DuplicateIdentity;
                result.order[position] = i;
            }
            return result;
        }
        /// Preflight all states before any publication mutation. The caller may
        /// not yield/release locks between this check and the shared decision.
        pub fn validate(s: *const Self, states: []const State) !void {
            if (states.len != s.count) return error.InvalidCount;
            for (states) |state| if (!state.ready or state.published or state.cancelled) return error.NotReady;
        }
    };
}
test "stable lock order uses every unique identity and preserves input order mapping" {
    const keys = [_]usize{ 9, 2, 7, 1, 5, 4, 8, 3 };
    const plan = try Plan(8).init(&keys);
    try std.testing.expectEqual(@as(usize, 8), plan.count);
    try std.testing.expectEqualSlices(usize, &.{ 3, 1, 7, 5, 4, 2, 6, 0 }, plan.order[0..plan.count]);
    try std.testing.expectEqualSlices(usize, &.{ 9, 2, 7, 1, 5, 4, 8, 3 }, &keys);
    var states: [8]State = @splat(.{ .ready = true });
    try plan.validate(&states);
    for (0..8) |i| {
        states[i].cancelled = true;
        try std.testing.expectError(error.NotReady, plan.validate(&states));
        states[i].cancelled = false;
        states[i].ready = false;
        try std.testing.expectError(error.NotReady, plan.validate(&states));
        states[i].ready = true;
        states[i].published = true;
        try std.testing.expectError(error.NotReady, plan.validate(&states));
        states[i].published = false;
    }
    try plan.validate(&states);
}
test "invalid counts and aliases reject before locking; readiness includes every participant" {
    try std.testing.expectError(error.InvalidCount, Plan(2).init(&.{}));
    try std.testing.expectError(error.InvalidCount, Plan(2).init(&.{ 1, 2, 3 }));
    try std.testing.expectError(error.InvalidIdentity, Plan(2).init(&.{ 1, 0 }));
    for ([_][3]usize{ .{ 1, 1, 2 }, .{ 2, 1, 1 }, .{ 3, 1, 3 } }) |keys| try std.testing.expectError(error.DuplicateIdentity, Plan(3).init(&keys));
    const single = try Plan(2).init(&.{std.math.maxInt(usize)});
    try std.testing.expectEqual(@as(usize, 0), single.order[0]);
    try std.testing.expectError(error.InvalidCount, single.validate(&.{}));
    try single.validate(&.{.{ .ready = true }});
}
