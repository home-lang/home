//! Bounded retry claims on a caller-supplied monotonic clock. No sleeping,
//! allocation or I/O; the caller creates a fresh sink for every claimed attempt.
const std = @import("std");
pub const Retry = struct {
    limit: u32 = 0,
    attempts: u32 = 0,
    initial_ns: u64 = 0,
    maximum_ns: u64 = 0,
    deadline: ?u64 = null,

    pub fn init(limit: u32, initial_ns: u64, maximum_ns: u64) !Retry {
        if (maximum_ns < initial_ns) return error.InvalidConfiguration;
        return .{ .limit = limit, .initial_ns = initial_ns, .maximum_ns = maximum_ns };
    }
    pub fn exhausted(s: Retry) bool {
        return s.limit != 0 and s.attempts >= s.limit;
    }
    /// A successful sink clears the pending deadline, not the lifetime budget.
    /// Failed attempts, including failed sink creation, consume that budget.
    /// Arm backoff without consuming an attempt. Async owners call this when
    /// construction finishes so the next frame does not shift the deadline.
    pub fn observe(s: *Retry, now: u64, failed: bool) void {
        if (!failed or s.limit == 0 or s.exhausted()) {
            s.deadline = null;
            return;
        }
        if (s.deadline == null) {
            var delay = s.initial_ns;
            var remaining = s.attempts;
            while (remaining > 0 and delay < s.maximum_ns and delay != 0) : (remaining -= 1) delay = @min(s.maximum_ns, std.math.mul(u64, delay, 2) catch std.math.maxInt(u64));
            s.deadline = std.math.add(u64, now, delay) catch std.math.maxInt(u64);
        }
    }
    pub fn poll(s: *Retry, now: u64, failed: bool) bool {
        s.observe(now, failed);
        if (s.deadline == null) return false;
        if (now < s.deadline.?) return false;
        s.attempts += 1;
        s.deadline = null;
        return true;
    }
};
test "backoff equality, failed creation, flapping and lifetime exhaustion" {
    var r = try Retry.init(3, 10, 15);
    try std.testing.expect(!r.poll(100, true));
    try std.testing.expect(!r.poll(109, true));
    try std.testing.expect(r.poll(110, true));
    try std.testing.expect(!r.poll(110, true));
    try std.testing.expect(r.poll(125, true));
    try std.testing.expect(!r.poll(126, false));
    try std.testing.expect(!r.poll(200, true));
    try std.testing.expect(r.poll(215, true));
    try std.testing.expect(!r.poll(1000, true));
    try std.testing.expect(r.exhausted());
}
test "disabled, immediate, saturating clocks and invalid caps" {
    var disabled: Retry = .{};
    try std.testing.expect(!disabled.poll(0, true));
    var immediate = try Retry.init(1, 0, 0);
    try std.testing.expect(immediate.poll(0, true));
    try std.testing.expect(!immediate.poll(0, true));
    var saturated = try Retry.init(2, 10, std.math.maxInt(u64));
    try std.testing.expect(!saturated.poll(std.math.maxInt(u64) - 1, true));
    try std.testing.expect(saturated.poll(std.math.maxInt(u64), true));
    try std.testing.expect(saturated.poll(std.math.maxInt(u64), true));
    try std.testing.expectError(error.InvalidConfiguration, Retry.init(1, 20, 10));
}

test "async completion observes a deadline without spending or shifting another claim" {
    var r = try Retry.init(3, 10, 20);
    r.observe(100, true);
    try std.testing.expectEqual(@as(u32, 0), r.attempts);
    try std.testing.expect(r.poll(110, true));
    r.observe(120, true);
    try std.testing.expectEqual(@as(?u64, 140), r.deadline);
    try std.testing.expectEqual(@as(u32, 1), r.attempts);
    try std.testing.expect(!r.poll(139, true));
    try std.testing.expect(r.poll(140, true));
    r.observe(150, false);
    try std.testing.expect(r.deadline == null);
    try std.testing.expectEqual(@as(u32, 2), r.attempts);
}
