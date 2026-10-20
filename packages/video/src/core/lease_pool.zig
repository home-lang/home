//! Fixed-capacity shared resource leases. Every retained reference gets a distinct
//! generation-checked token; releasing one token cannot consume another owner.
//! Caller supplies synchronization and destroys/recycles a resource only after
//! release returns true. No allocations, resource access or destruction here.
const std = @import("std");
pub fn Pool(comptime resources: usize, comptime references: usize) type {
    if (resources == 0 or resources > std.math.maxInt(u32) or references == 0 or references > std.math.maxInt(u32)) @compileError("invalid lease pool bounds");
    return struct {
        const Self = @This();
        const Entry = struct { id: u64 = 0, resource: u32 = 0 };
        const bits = std.math.log2_int_ceil(u64, references);
        const mask: u64 = (@as(u64, 1) << bits) - 1;
        pub const max_sequence = std.math.maxInt(u64) >> bits;
        entries: [references]Entry = @splat(.{}),
        counts: [resources]u32 = @splat(0),
        issued: u64 = 0,
        used: usize = 0,
        cursor: usize = 0,
        pub fn resource(self: *const Self, id: u64) ?u32 {
            const slot = id & mask;
            if (id == 0 or slot >= references or self.entries[slot].id != id) return null;
            return self.entries[slot].resource;
        }
        fn issue(self: *Self, index: u32) !u64 {
            if (self.issued == max_sequence) return error.SequenceExhausted;
            if (self.used == references) return error.ReferenceLimit;
            for (0..references) |offset| {
                const slot = (self.cursor + offset) % references;
                if (self.entries[slot].id != 0) continue;
                self.issued += 1;
                const id = (self.issued << bits) | @as(u64, @intCast(slot));
                self.entries[slot] = .{ .id = id, .resource = index };
                self.counts[index] += 1;
                self.used += 1;
                self.cursor = (slot + 1) % references;
                return id;
            }
            unreachable;
        }
        pub fn acquire(self: *Self, index: u32) !u64 {
            if (index >= resources) return error.InvalidResource;
            if (self.counts[index] != 0) return error.ResourceBusy;
            return self.issue(index);
        }
        pub fn retain(self: *Self, id: u64) !u64 {
            return self.issue(self.resource(id) orelse return error.StaleLease);
        }
        pub fn count(self: *const Self, id: u64) !u32 {
            return self.counts[self.resource(id) orelse return error.StaleLease];
        }
        /// True only for the final reference to this resource. Failure is atomic.
        pub fn release(self: *Self, id: u64) !bool {
            const index = self.resource(id) orelse return error.StaleLease;
            self.entries[id & mask] = .{};
            self.counts[index] -= 1;
            self.used -= 1;
            return self.counts[index] == 0;
        }
    };
}
test "distinct references survive parent release and resource slot reuse rejects stale owners" {
    var p: Pool(2, 3) = .{};
    const first = try p.acquire(0);
    const retained = try p.retain(first);
    try std.testing.expect(first != retained);
    try std.testing.expectEqual(@as(u32, 2), try p.count(retained));
    try std.testing.expect(!try p.release(first));
    try std.testing.expectError(error.StaleLease, p.release(first));
    try std.testing.expectEqual(@as(u32, 0), p.resource(retained).?);
    try std.testing.expectError(error.ResourceBusy, p.acquire(0));
    try std.testing.expect(try p.release(retained));
    const later = try p.acquire(0);
    try std.testing.expect(later != retained);
    try std.testing.expect(p.resource(retained) == null);
    try std.testing.expectError(error.StaleLease, p.retain(retained));
    try std.testing.expect(try p.release(later));
    try std.testing.expectEqual(@as(usize, 0), p.used);
}
test "reference limits and sequence exhaustion never mutate live ownership" {
    var p: Pool(2, 2) = .{};
    const a = try p.acquire(0);
    const b = try p.retain(a);
    try std.testing.expectError(error.ReferenceLimit, p.retain(a));
    try std.testing.expectError(error.ReferenceLimit, p.acquire(1));
    try std.testing.expectEqual(@as(u32, 2), try p.count(a));
    try std.testing.expectError(error.InvalidResource, p.acquire(2));
    try std.testing.expectError(error.StaleLease, p.release(0));
    try std.testing.expect(!try p.release(a));
    try std.testing.expect(try p.release(b));
    p.issued = @TypeOf(p).max_sequence;
    try std.testing.expectError(error.SequenceExhausted, p.acquire(0));
    try std.testing.expectEqual(@as(usize, 0), p.used);
}
test "one-slot and non-power-of-two pools validate encoded slot bounds" {
    var one: Pool(1, 1) = .{};
    const id = try one.acquire(0);
    try std.testing.expectEqual(@as(u64, 1), id);
    try std.testing.expect(try one.release(id));
    var p: Pool(1, 3) = .{};
    try std.testing.expect(p.resource(7) == null);
    const a = try p.acquire(0);
    const b = try p.retain(a);
    const c = try p.retain(b);
    try std.testing.expect(!try p.release(b));
    try std.testing.expect(!try p.release(a));
    try std.testing.expect(try p.release(c));
}
