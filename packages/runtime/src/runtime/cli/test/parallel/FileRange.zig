// Copied verbatim from bun/src/runtime/cli/test/parallel/FileRange.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../../cli/LICENSE.bun.md. Pure data structure; no rewrites needed
// (no `bun.*` references, no `Bun`-prefixed identifiers).

//! Contiguous slice of `Coordinator.files` owned by a worker. Dispatching
//! pulls from the front (cache-hot region); stealing takes from the back
//! (furthest from the owner's hot region).

pub const FileRange = @This();

lo: u32,
hi: u32,

pub fn len(self: @This()) u32 {
    return self.hi - self.lo;
}
pub fn isEmpty(self: @This()) bool {
    return self.lo >= self.hi;
}
pub fn popFront(self: *@This()) ?u32 {
    if (self.isEmpty()) return null;
    defer self.lo += 1;
    return self.lo;
}
/// Take the back half as a new contiguous range for the thief, leaving the
/// owner the front half. The thief then walks its stolen block forward via
/// popFront, so both workers keep directory locality. For len()==1 the
/// single file goes to the thief (owner is either already inflight or was
/// never spawned).
pub fn stealBackHalf(self: *@This()) ?FileRange {
    if (self.isEmpty()) return null;
    const mid = self.lo + self.len() / 2;
    const stolen = FileRange{ .lo = mid, .hi = self.hi };
    self.hi = mid;
    return stolen;
}

const std = @import("std");

test "FileRange.len / isEmpty / popFront" {
    var r = FileRange{ .lo = 3, .hi = 7 };
    try std.testing.expectEqual(@as(u32, 4), r.len());
    try std.testing.expect(!r.isEmpty());

    try std.testing.expectEqual(@as(?u32, 3), r.popFront());
    try std.testing.expectEqual(@as(?u32, 4), r.popFront());
    try std.testing.expectEqual(@as(?u32, 5), r.popFront());
    try std.testing.expectEqual(@as(?u32, 6), r.popFront());
    try std.testing.expect(r.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), r.popFront());
}

test "FileRange.stealBackHalf splits evenly with locality" {
    var owner = FileRange{ .lo = 0, .hi = 10 };
    const thief = owner.stealBackHalf().?;
    // Owner keeps the front half; thief gets the back half.
    try std.testing.expectEqual(@as(u32, 0), owner.lo);
    try std.testing.expectEqual(@as(u32, 5), owner.hi);
    try std.testing.expectEqual(@as(u32, 5), thief.lo);
    try std.testing.expectEqual(@as(u32, 10), thief.hi);
    try std.testing.expectEqual(@as(u32, 5), owner.len());
    try std.testing.expectEqual(@as(u32, 5), thief.len());
}

test "FileRange.stealBackHalf hands a singleton to the thief" {
    // len()==1 → mid == lo, so owner ends up empty and thief takes the file.
    var owner = FileRange{ .lo = 2, .hi = 3 };
    const thief = owner.stealBackHalf().?;
    try std.testing.expect(owner.isEmpty());
    try std.testing.expectEqual(@as(u32, 2), thief.lo);
    try std.testing.expectEqual(@as(u32, 3), thief.hi);
}

test "FileRange.stealBackHalf on empty returns null" {
    var r = FileRange{ .lo = 5, .hi = 5 };
    try std.testing.expectEqual(@as(?FileRange, null), r.stealBackHalf());
}
