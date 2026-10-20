//! Bounded asynchronous output-factory admission on a caller's media clock.
const std = @import("std");
const Policy = @import("recording_policy.zig").Policy;
const Retry = @import("output_recovery.zig").Retry;
pub const Mode = enum { rotation, recovery };
pub const Config = struct {
    mode: Mode,
    next_index: u64 = 1,
    duration_ns: u64 = 0,
    max_bytes: u64 = 0,
    max_attempts: u32 = 3,
    initial_ns: u64 = 100_000_000,
    maximum_ns: u64 = 5_000_000_000,
};
pub const Input = struct {
    now: u64,
    frames: u64,
    elapsed_ns: u64,
    bytes: u64,
    failed: bool,
    available: bool,
};
pub const Claim = struct { ticket: u64, index: u64 };
pub const State = struct {
    config: Config,
    retry: Retry,
    issued: u64 = 0,
    pending: ?Claim = null,
    next_index: u64,
    index_exhausted: bool = false,
    error_code: i32 = 0,
    pub fn init(config: Config) !State {
        if (config.mode == .rotation and config.duration_ns == 0 and config.max_bytes == 0) return error.InvalidConfiguration;
        return .{ .config = config, .retry = try Retry.init(config.max_attempts, config.initial_ns, config.maximum_ns), .next_index = config.next_index };
    }
    /// Reconfiguration cannot revoke a live claim or repeat a completion ticket.
    pub fn configure(s: *State, config: Config) !void {
        if (s.pending != null) return error.Busy;
        var replacement = try State.init(config);
        replacement.issued = s.issued;
        s.* = replacement;
    }
    pub fn poll(s: *State, input: Input) ?Claim {
        if (s.pending != null) return null;
        if (s.config.mode == .recovery and !input.failed) _ = s.retry.poll(input.now, false);
        if (!input.available or s.index_exhausted or s.issued == std.math.maxInt(u64)) return null;
        const due = if (s.config.mode == .rotation)
            !input.failed and s.error_code == 0 and (Policy{ .duration_ns = s.config.duration_ns, .max_bytes = s.config.max_bytes }).due(input.frames, input.elapsed_ns, input.bytes, false)
        else
            s.retry.poll(input.now, input.failed);
        if (!due) return null;
        s.issued += 1;
        const claim = Claim{ .ticket = s.issued, .index = s.next_index };
        if (s.next_index == std.math.maxInt(u64)) s.index_exhausted = true else s.next_index += 1;
        s.pending = claim;
        return claim;
    }
    pub fn finishAt(s: *State, ticket: u64, code: i32, now: u64) !void {
        try s.finish(ticket, code);
        if (s.config.mode == .recovery) s.retry.observe(now, code != 0);
    }
    pub fn finish(s: *State, ticket: u64, code: i32) !void {
        const claim = s.pending orelse return error.StaleClaim;
        if (claim.ticket != ticket) return error.StaleClaim;
        if (code > 0) return error.InvalidResult;
        s.pending = null;
        s.error_code = code;
    }
};
test "rotation reserves fresh indices, rejects stale completion and latches construction failures" {
    var s = try State.init(.{ .mode = .rotation, .max_bytes = 10 });
    var input = Input{ .now = 0, .frames = 1, .elapsed_ns = 0, .bytes = 10, .failed = false, .available = false };
    try std.testing.expect(s.poll(input) == null);
    try std.testing.expectEqual(@as(u64, 1), s.next_index);
    input.available = true;
    const first = s.poll(input).?;
    try std.testing.expect(s.poll(input) == null);
    try std.testing.expectError(error.Busy, s.configure(.{ .mode = .rotation, .duration_ns = 10 }));
    try std.testing.expectError(error.StaleClaim, s.finish(first.ticket + 1, 0));
    try std.testing.expectError(error.InvalidResult, s.finish(first.ticket, 1));
    try std.testing.expect(s.pending != null);
    try s.finish(first.ticket, -6);
    try std.testing.expect(s.poll(input) == null);
    try s.configure(.{ .mode = .rotation, .max_bytes = 10, .next_index = 2 });
    const second = s.poll(input).?;
    try std.testing.expect(second.ticket > first.ticket);
    try std.testing.expectError(error.StaleClaim, s.finish(first.ticket, 0));
    try s.finish(second.ticket, 0);
}
test "recovery counts only admitted claims, preserves lifetime budgets and exhausts index without wrapping" {
    var s = try State.init(.{ .mode = .recovery, .max_attempts = 2, .initial_ns = 10, .maximum_ns = 20, .next_index = std.math.maxInt(u64) - 1 });
    var input = Input{ .now = 100, .frames = 0, .elapsed_ns = 0, .bytes = 0, .failed = true, .available = false };
    try std.testing.expect(s.poll(input) == null);
    try std.testing.expect(s.retry.deadline == null);
    input.available = true;
    try std.testing.expect(s.poll(input) == null);
    input.now = 110;
    const first = s.poll(input).?;
    try s.finishAt(first.ticket, -6, 110);
    try std.testing.expectEqual(@as(?u64, 130), s.retry.deadline);
    input.failed = false;
    _ = s.poll(input);
    try std.testing.expectEqual(@as(u32, 1), s.retry.attempts);
    input.failed = true;
    try std.testing.expect(s.poll(input) == null);
    input.now = 130;
    const second = s.poll(input).?;
    try std.testing.expectEqual(std.math.maxInt(u64), second.index);
    try s.finish(second.ticket, 0);
    try std.testing.expect(s.index_exhausted and s.retry.exhausted());
    input.now = std.math.maxInt(u64);
    try std.testing.expect(s.poll(input) == null);
}
