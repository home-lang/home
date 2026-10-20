//! Fixed-capacity cooperative waits. Caller supplies capacity observations and a
//! monotonic clock, serializes access, and releases every admitted ticket.
const std = @import("std");
pub const Outcome = enum { ready, timeout, cancelled, closed };
pub const Counters = struct {
    requested: u64 = 0,
    blocked: u64 = 0,
    satisfied: u64 = 0,
    timed_out: u64 = 0,
    cancelled: u64 = 0,
    closed: u64 = 0,
    pending: u64 = 0,
    total_ns: u64 = 0,
    high_ns: u64 = 0,
};
pub fn Registry(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Wait = struct { ticket: u64, bytes: u64, operations: u32, started: u64, deadline: u64, outcome: ?Outcome = null };
        slots: [capacity]?Wait = @splat(null),
        issued: u64 = 0,
        counters: Counters = .{},
        pub fn get(s: *Self, ticket: u64) ?*Wait {
            for (&s.slots) |*slot| if (slot.*) |*wait| if (wait.ticket == ticket) return wait;
            return null;
        }
        fn finish(s: *Self, wait: *Wait, now: u64, outcome: Outcome) void {
            if (wait.outcome != null) return;
            wait.outcome = outcome;
            s.counters.pending -= 1;
            const elapsed = now -| wait.started;
            s.counters.total_ns +|= elapsed;
            s.counters.high_ns = @max(s.counters.high_ns, elapsed);
            const count = switch (outcome) {
                .ready => &s.counters.satisfied,
                .timeout => &s.counters.timed_out,
                .cancelled => &s.counters.cancelled,
                .closed => &s.counters.closed,
            };
            count.* +|= 1;
        }
        pub fn begin(s: *Self, bytes: u64, operations: u32, timeout: u64, now: u64, available: bool) !u64 {
            if (operations == 0) return error.InvalidConfiguration;
            if (s.issued == std.math.maxInt(u64)) return error.SequenceOverflow;
            for (&s.slots) |*slot| if (slot.* == null) {
                s.issued += 1;
                slot.* = .{ .ticket = s.issued, .bytes = bytes, .operations = operations, .started = now, .deadline = now +| timeout };
                s.counters.requested +|= 1;
                s.counters.pending += 1;
                if (available) s.finish(&slot.*.?, now, .ready) else {
                    s.counters.blocked +|= 1;
                    if (timeout == 0) s.finish(&slot.*.?, now, .timeout);
                }
                return s.issued;
            };
            return error.BufferFull;
        }
        pub fn poll(s: *Self, ticket: u64, now: u64, available: bool, closed: bool) !?Outcome {
            const wait = s.get(ticket) orelse return error.StaleTicket;
            if (wait.outcome == null) {
                if (closed) s.finish(wait, now, .closed) else if (now >= wait.deadline) s.finish(wait, now, .timeout) else if (available) s.finish(wait, now, .ready);
            }
            return wait.outcome;
        }
        pub fn release(s: *Self, ticket: u64, now: u64) !void {
            for (&s.slots) |*slot| if (slot.*) |*wait| if (wait.ticket == ticket) {
                s.finish(wait, now, .cancelled);
                slot.* = null;
                return;
            };
            return error.StaleTicket;
        }
        pub fn close(s: *Self, now: u64) void {
            for (&s.slots) |*slot| if (slot.*) |*wait| s.finish(wait, now, .closed);
        }
    };
}
test "capacity waits retain outcomes, enforce deadlines and bound tickets" {
    var waits: Registry(2) = .{};
    const first = try waits.begin(4, 1, 10, 100, false);
    const second = try waits.begin(0, 1, 0, 100, true);
    try std.testing.expectError(error.BufferFull, waits.begin(0, 1, 10, 100, false));
    try std.testing.expectEqual(@as(?Outcome, null), try waits.poll(first, 109, false, false));
    try std.testing.expectEqual(@as(?Outcome, .timeout), try waits.poll(first, 110, true, false));
    waits.close(120);
    try std.testing.expectEqual(@as(?Outcome, .ready), try waits.poll(second, 120, false, true));
    try waits.release(first, 120);
    try std.testing.expectError(error.StaleTicket, waits.release(first, 120));
    const third = try waits.begin(1, 1, 20, 130, false);
    try std.testing.expect(third > second);
    try waits.release(third, 135);
    try std.testing.expectEqual(@as(u64, 1), waits.counters.cancelled);
    try std.testing.expectEqual(@as(u64, 1), waits.counters.timed_out);
    try std.testing.expectEqual(@as(u64, 1), waits.counters.satisfied);
    try std.testing.expectEqual(@as(u64, 0), waits.counters.pending);
    try std.testing.expectEqual(@as(u64, 15), waits.counters.total_ns);
}
test "zero deadlines, closure, saturation and exhaustion never wrap" {
    var waits: Registry(1) = .{};
    try std.testing.expectError(error.InvalidConfiguration, waits.begin(0, 0, 1, 0, true));
    const first = try waits.begin(0, 1, 0, 0, false);
    try std.testing.expectEqual(@as(?Outcome, .timeout), try waits.poll(first, 0, true, false));
    try waits.release(first, 0);
    waits.issued = std.math.maxInt(u64) - 1;
    const last = try waits.begin(1, 1, 100, std.math.maxInt(u64) - 10, false);
    waits.close(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(?Outcome, .closed), try waits.poll(last, std.math.maxInt(u64), true, false));
    try waits.release(last, std.math.maxInt(u64));
    try std.testing.expectError(error.SequenceOverflow, waits.begin(0, 1, 1, 0, true));
}
