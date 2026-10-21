//! Caller-serialized scoped access to a leased frame. The caller owns generation
//! tokens and storage; publish a prepared gate only after retaining the map owner.
const std = @import("std");
pub const Gate = struct {
    readers: u32 = 0,
    writer: bool = false,
    pub fn beginning(self: Gate, write: bool, owners: u32) !Gate {
        if (owners == 0) return error.StaleOwner;
        if (self.writer or (write and (owners != 1 or self.readers != 0))) return error.AccessBusy;
        var next = self;
        if (write) next.writer = true else {
            if (self.readers == std.math.maxInt(u32)) return error.AccessFull;
            next.readers += 1;
        }
        return next;
    }
    pub fn ending(self: Gate, write: bool) !Gate {
        var next = self;
        if (write) {
            if (!self.writer or self.readers != 0) return error.StaleAccess;
            next.writer = false;
        } else {
            if (self.writer or self.readers == 0) return error.StaleAccess;
            next.readers -= 1;
        }
        return next;
    }
};
test "frame readers share access while writers require a sole external owner" {
    var gate: Gate = .{};
    const before = gate;
    try std.testing.expectError(error.StaleOwner, gate.beginning(false, 0));
    try std.testing.expectError(error.AccessBusy, gate.beginning(true, 2));
    try std.testing.expectEqualDeep(before, gate);
    gate = try gate.beginning(false, 1);
    gate = try gate.beginning(false, 5);
    try std.testing.expectError(error.AccessBusy, gate.beginning(true, 1));
    gate = try gate.ending(false);
    gate = try gate.ending(false);
    gate = try gate.beginning(true, 1);
    try std.testing.expectError(error.AccessBusy, gate.beginning(true, 1));
    try std.testing.expectError(error.AccessBusy, gate.beginning(false, 1));
    try std.testing.expectError(error.StaleAccess, gate.ending(false));
    gate = try gate.ending(true);
    try std.testing.expectEqualDeep(before, gate);
    try std.testing.expectError(error.StaleAccess, gate.ending(true));
    try std.testing.expectError(error.StaleAccess, gate.ending(false));
}
test "frame access capacity rejects atomically without counter wrap" {
    const gate: Gate = .{ .readers = std.math.maxInt(u32) };
    try std.testing.expectError(error.AccessFull, gate.beginning(false, 1));
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, (try gate.ending(false)).readers);
}
