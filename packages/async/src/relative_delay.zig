//! Checked relative idle intervals in a caller-supplied monotonic clock domain.
//! The owner supplies clocks, timers and cancellation; no sleeping or allocation.
const std = @import("std");
pub const Delay = struct {
    started_ns: u64 = 0,
    last_ns: u64 = 0,
    deadline_ns: u64 = 0,
    armed: bool = false,
    /// Explicitly replace the interval. Overflow preserves the previous plan.
    pub fn arm(self: *Delay, now_ns: u64, duration_ns: u64) !void {
        const deadline = std.math.add(u64, now_ns, duration_ns) catch return error.DeadlineOverflow;
        self.* = .{ .started_ns = now_ns, .last_ns = now_ns, .deadline_ns = deadline, .armed = true };
    }
    /// Polling never extends the interval or advances a repeating cadence.
    /// Clock regression preserves observation state; overshoot saturates to zero.
    pub fn remaining(self: *Delay, now_ns: u64) !u64 {
        if (!self.armed) return error.NotArmed;
        if (now_ns < self.last_ns) return error.ClockRegression;
        self.last_ns = now_ns;
        return self.deadline_ns -| now_ns;
    }
    pub fn reset(self: *Delay) void {
        self.* = .{};
    }
};
test "relative delays start after prior work instead of catching up an absolute cadence" {
    const t = std.testing;
    var delay: Delay = .{};
    try delay.arm(100, 20);
    try t.expectEqual(@as(u64, 20), try delay.remaining(100));
    try t.expectEqual(@as(u64, 1), try delay.remaining(119));
    try t.expectEqual(@as(u64, 0), try delay.remaining(120));
    try t.expectEqual(@as(u64, 0), try delay.remaining(160));
    // A new interval begins after work completes, even after an overrun.
    try delay.arm(200, 20);
    try t.expectEqual(@as(u64, 20), try delay.remaining(200));
    try t.expectEqual(@as(u64, 0), try delay.remaining(220));
}
test "unarmed regression reset and overflow never publish a partial observation" {
    const t = std.testing;
    var delay: Delay = .{};
    try t.expectError(error.NotArmed, delay.remaining(0));
    try delay.arm(10, 20);
    _ = try delay.remaining(15);
    const before = delay;
    try t.expectError(error.ClockRegression, delay.remaining(14));
    try t.expectEqualDeep(before, delay);
    try t.expectError(error.DeadlineOverflow, delay.arm(std.math.maxInt(u64), 1));
    try t.expectEqualDeep(before, delay);
    delay.reset();
    try t.expectError(error.NotArmed, delay.remaining(20));
}
test "zero maximum and overshot durations stay exact without integer wrap" {
    const t = std.testing;
    var delay: Delay = .{};
    try delay.arm(std.math.maxInt(u64), 0);
    try t.expectEqual(@as(u64, 0), try delay.remaining(std.math.maxInt(u64)));
    try delay.arm(0, std.math.maxInt(u64));
    try t.expectEqual(std.math.maxInt(u64), try delay.remaining(0));
    try t.expectEqual(@as(u64, 1), try delay.remaining(std.math.maxInt(u64) - 1));
    try t.expectEqual(@as(u64, 0), try delay.remaining(std.math.maxInt(u64)));
}
