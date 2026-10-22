//! Counted keyframe intent. Caller serializes admission with request commit and
//! consumes only after an input is accepted by the encoder, not when a delayed
//! output packet appears. This ledger neither calls a codec nor owns a lock.
const std = @import("std");
pub const Requests = Ledger(std.math.maxInt(u32));
pub fn Ledger(comptime maximum_pending: u32) type {
    if (maximum_pending == 0) @compileError("keyframe ledger needs pending capacity");
    return struct {
        requested: u64 = 0,
        applied: u64 = 0,
        const Self = @This();
        pub fn pending(self: Self) u32 {
            return @intCast(self.requested - self.applied);
        }
        /// Transactional admission: rejection never changes either counter.
        pub fn request(self: *Self) !void {
            if (self.requested == std.math.maxInt(u64)) return error.CounterExhausted;
            if (self.pending() == maximum_pending) return error.BufferFull;
            self.requested += 1;
        }
        /// One requested keyframe per accepted input, even if that input already
        /// starts a GOP. False means no public intent was waiting for this input.
        pub fn consume(self: *Self) bool {
            if (self.applied == self.requested) return false;
            self.applied += 1;
            return true;
        }
    };
}
test "requests remain distinct and capacity is released by accepted input only" {
    const t = std.testing;
    var requests: Ledger(2) = .{};
    try requests.request();
    try requests.request();
    try t.expectError(error.BufferFull, requests.request());
    try t.expectEqual(@as(u64, 2), requests.requested);
    try t.expectEqual(@as(u64, 0), requests.applied);
    try t.expectEqual(@as(u32, 2), requests.pending());
    try t.expect(requests.consume());
    try requests.request();
    try t.expectEqual(@as(u32, 2), requests.pending());
    try t.expect(requests.consume());
    try t.expect(requests.consume());
    try t.expect(!requests.consume());
    try t.expectEqual(@as(u64, 3), requests.requested);
    try t.expectEqual(requests.requested, requests.applied);
}
test "request and pending counters do not wrap or mutate on exhaustion" {
    const t = std.testing;
    var requests: Requests = .{ .requested = std.math.maxInt(u64) - 1, .applied = std.math.maxInt(u64) - 2 };
    try requests.request();
    try t.expectError(error.CounterExhausted, requests.request());
    try t.expectEqual(@as(u32, 2), requests.pending());
    try t.expect(requests.consume());
    try t.expect(requests.consume());
    try t.expect(!requests.consume());
    try t.expectError(error.CounterExhausted, requests.request());
    requests = .{ .requested = std.math.maxInt(u32) };
    try t.expectError(error.BufferFull, requests.request());
    try t.expectEqual(std.math.maxInt(u32), requests.pending());
}
test "separate recording sessions and ledgers never share intent" {
    const t = std.testing;
    var first: Requests = .{};
    var second: Requests = .{};
    try first.request();
    try first.request();
    try t.expect(!second.consume());
    try t.expect(first.consume());
    first = .{};
    try t.expectEqual(@as(u64, 0), first.requested);
    try t.expectEqual(@as(u64, 0), first.applied);
    try t.expect(!first.consume());
}
