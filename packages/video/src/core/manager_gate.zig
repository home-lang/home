//! Shared manager leases and an idle-only exclusive mutation. Caller serializes
//! access and balances each successful entry with its matching leave operation.
//! Generations advance only when a new shared/exclusive lifetime starts.
const std = @import("std");
pub const Gate = struct {
    users: u32 = 0,
    generation: u64 = 0,
    exclusive: bool = false,
    fn validate(self: Gate) !void {
        if ((self.exclusive and self.users != 1) or (self.users != 0 and self.generation == 0)) return error.InvalidState;
    }
    fn next(self: Gate) !u64 {
        if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        return self.generation + 1;
    }
    pub fn enterShared(self: *Gate) !u64 {
        try self.validate();
        if (self.exclusive or self.users == std.math.maxInt(u32)) return error.Busy;
        const generation = if (self.users == 0) try self.next() else self.generation;
        self.users += 1;
        self.generation = generation;
        return generation;
    }
    pub fn enterExclusive(self: *Gate) !u64 {
        try self.validate();
        if (self.users != 0) return error.Busy;
        const generation = try self.next();
        self.* = .{ .users = 1, .generation = generation, .exclusive = true };
        return generation;
    }
    /// True when the last lease retired; caller may then destroy the manager.
    pub fn leaveShared(self: *Gate) !bool {
        try self.validate();
        if (self.users == 0 or self.exclusive) return error.InvalidLease;
        self.users -= 1;
        return self.users == 0;
    }
    pub fn leaveExclusive(self: *Gate) !void {
        try self.validate();
        if (!self.exclusive or self.users != 1) return error.InvalidLease;
        self.users = 0;
        self.exclusive = false;
    }
};
test "manager shared lifetimes pin generation and exclude mutation until every lease retires" {
    const t = std.testing;
    var gate = Gate{};
    try t.expectEqual(@as(u64, 1), try gate.enterShared());
    try t.expectEqual(@as(u64, 1), try gate.enterShared());
    const before = gate;
    try t.expectError(error.Busy, gate.enterExclusive());
    try t.expectEqualDeep(before, gate);
    try t.expect(!try gate.leaveShared());
    try t.expectError(error.Busy, gate.enterExclusive());
    try t.expect(try gate.leaveShared());
    try t.expectEqual(@as(u64, 2), try gate.enterExclusive());
    const exclusive = gate;
    try t.expectError(error.Busy, gate.enterShared());
    try t.expectError(error.Busy, gate.enterExclusive());
    try t.expectError(error.InvalidLease, gate.leaveShared());
    try t.expectEqualDeep(exclusive, gate);
    try gate.leaveExclusive();
    try t.expectEqual(@as(u64, 3), try gate.enterShared());
    try t.expect(try gate.leaveShared());
}
test "manager overflow and invalid release never mutate ownership or generation" {
    const t = std.testing;
    var gate = Gate{};
    try t.expectError(error.InvalidLease, gate.leaveShared());
    try t.expectError(error.InvalidLease, gate.leaveExclusive());
    gate = .{ .users = std.math.maxInt(u32), .generation = 4 };
    const full = gate;
    try t.expectError(error.Busy, gate.enterShared());
    try t.expectError(error.Busy, gate.enterExclusive());
    try t.expectEqualDeep(full, gate);
    gate = .{ .generation = std.math.maxInt(u64) };
    const exhausted = gate;
    try t.expectError(error.GenerationExhausted, gate.enterShared());
    try t.expectError(error.GenerationExhausted, gate.enterExclusive());
    try t.expectEqualDeep(exhausted, gate);
    gate = .{ .users = 2, .generation = 1, .exclusive = true };
    const invalid = gate;
    try t.expectError(error.InvalidState, gate.enterShared());
    try t.expectError(error.InvalidState, gate.leaveExclusive());
    try t.expectEqualDeep(invalid, gate);
}
