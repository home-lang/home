//! Bounded capture-consumer admission. No frames/pointers/threads are retained.
//! Caller serializes operations; encoded producer queues own actual copied bytes.
const std = @import("std");
const Slots = @import("packet_output.zig").Slots;
pub const Policy = enum { wait, drop };
pub const Outcome = enum { completed, failed, cancelled };
pub const State = struct {
    id: u64,
    submitted: u64 = 0,
    completed: u64 = 0,
    skipped: u64 = 0,
    failures: u64 = 0,
    cancelled: u64 = 0,
    last_frame: ?u64 = null,
    ticket: ?u64 = null,
    active: bool = true,
    failed: bool = false,
    retiring: bool = false,
    policy: Policy,
};
pub fn Registry(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        slots: Slots(State, capacity) = .{},
        next_ticket: u64 = 1,
        next_frame: u64 = 0,
        pub fn add(self: *Self, policy: Policy) !u64 {
            const id = try self.slots.add(.{ .id = 0, .policy = policy });
            (try self.entry(id)).id = id;
            return id;
        }
        pub fn state(self: *Self, id: u64) !State {
            return (try self.entry(id)).*;
        }
        fn entry(self: *Self, id: u64) !*State {
            for (&self.slots.entries) |*slot| if (slot.id == id and slot.value != null) return &slot.value.?;
            return error.Stale;
        }
        pub fn ready(self: *Self) bool {
            for (self.slots.entries) |slot| if (slot.value) |consumer| {
                if (consumer.active and consumer.policy == .wait and consumer.ticket != null) return false;
            };
            return true;
        }
        pub fn offer(self: *Self) !u64 {
            if (self.next_frame == std.math.maxInt(u64)) return error.IdentityExhausted;
            const frame = self.next_frame;
            self.next_frame += 1;
            return frame;
        }
        /// Null means a busy dropping consumer skipped this offered source frame.
        /// A wait consumer returns Busy; the caller should check ready() first.
        pub fn claim(self: *Self, id: u64, frame: u64) !?u64 {
            const consumer = try self.entry(id);
            if (!consumer.active) return error.Closed;
            if (self.next_frame == 0 or frame != self.next_frame - 1 or (consumer.last_frame != null and frame <= consumer.last_frame.?)) return error.Stale;
            if (consumer.ticket != null) {
                if (consumer.policy == .wait) return error.Busy;
                consumer.last_frame = frame;
                consumer.skipped +|= 1;
                return null;
            }
            if (self.next_ticket == std.math.maxInt(u64)) return error.IdentityExhausted;
            const ticket = self.next_ticket;
            self.next_ticket += 1;
            consumer.ticket = ticket;
            consumer.last_frame = frame;
            consumer.submitted +|= 1;
            return ticket;
        }
        /// Returns the final immutable snapshot when a retired entry is removed.
        pub fn finish(self: *Self, id: u64, ticket: u64, outcome: Outcome) !State {
            const consumer = try self.entry(id);
            if (consumer.ticket == null or consumer.ticket.? != ticket) return error.Stale;
            consumer.ticket = null;
            switch (outcome) {
                .completed => consumer.completed +|= 1,
                .cancelled => consumer.cancelled +|= 1,
                .failed => {
                    consumer.failures +|= 1;
                    consumer.failed = true;
                    consumer.active = false;
                },
            }
            const result = consumer.*;
            if (consumer.retiring) _ = self.slots.remove(id);
            return result;
        }
        /// Quarantine source/dispatch failures even when no claim was admitted.
        /// Existing tickets remain valid and must still be joined by the owner.
        pub fn fail(self: *Self, id: u64) !State {
            const consumer = try self.entry(id);
            if (!consumer.failed) consumer.failures +|= 1;
            consumer.active = false;
            consumer.failed = true;
            return consumer.*;
        }
        /// Busy retirement reserves its slot until the exact in-flight claim ends.
        pub fn retire(self: *Self, id: u64) !State {
            const consumer = try self.entry(id);
            consumer.active = false;
            consumer.retiring = true;
            const result = consumer.*;
            if (consumer.ticket == null) _ = self.slots.remove(id);
            return result;
        }
    };
}
test "slow dropping consumer never stalls a healthy peer or retains another source" {
    var r: Registry(2) = .{};
    const slow = try r.add(.drop);
    const healthy = try r.add(.wait);
    const first = try r.offer();
    const a = (try r.claim(slow, first)).?;
    const b = (try r.claim(healthy, first)).?;
    try std.testing.expect(!r.ready());
    _ = try r.finish(healthy, b, .completed);
    try std.testing.expect(r.ready());
    const next = try r.offer();
    try std.testing.expectEqual(null, try r.claim(slow, next));
    const c = (try r.claim(healthy, next)).?;
    _ = try r.finish(healthy, c, .completed);
    try std.testing.expectEqual(@as(u64, 1), (try r.entry(slow)).skipped);
    _ = try r.finish(slow, a, .completed);
    try std.testing.expectError(error.Stale, r.finish(slow, a, .failed));
    try std.testing.expect((try r.entry(slow)).active);
}
test "retiring claims keep capacity and late completions cannot affect replacements" {
    var r: Registry(1) = .{};
    const id = try r.add(.wait);
    const ticket = (try r.claim(id, try r.offer())).?;
    _ = try r.retire(id);
    try std.testing.expect(r.ready());
    try std.testing.expectError(error.Capacity, r.add(.drop));
    const final = try r.finish(id, ticket, .failed);
    try std.testing.expect(final.retiring and final.failed and final.ticket == null);
    const replacement = try r.add(.wait);
    try std.testing.expect(replacement != id);
    try std.testing.expectError(error.Stale, r.finish(id, ticket, .completed));
    try std.testing.expectError(error.Stale, r.retire(id));
    try std.testing.expect((try r.entry(replacement)).active);
}
test "wait and failure gates are explicit and duplicate offers never count twice" {
    var r: Registry(2) = .{};
    const a = try r.add(.wait);
    const b = try r.add(.drop);
    try std.testing.expectError(error.Stale, r.claim(a, 0));
    const first = try r.offer();
    const ticket = (try r.claim(a, first)).?;
    try std.testing.expectError(error.Stale, r.claim(a, first));
    const second = try r.offer();
    try std.testing.expectError(error.Busy, r.claim(a, second));
    try std.testing.expectEqual(@as(u64, 0), (try r.entry(a)).skipped);
    _ = try r.finish(a, ticket, .failed);
    try std.testing.expect(r.ready());
    try std.testing.expectError(error.Closed, r.claim(a, second));
    const good = (try r.claim(b, second)).?;
    _ = try r.finish(b, good, .completed);
    _ = try r.retire(a);
    _ = try r.retire(b);
    try std.testing.expectEqual(@as(usize, 0), r.slots.count);
}
test "identity and clock exhaustion reject without wrapping or changing ownership" {
    var r: Registry(1) = .{};
    const a = try r.add(.wait);
    r.next_ticket = std.math.maxInt(u64);
    const frame = try r.offer();
    try std.testing.expectError(error.IdentityExhausted, r.claim(a, frame));
    try std.testing.expectEqual(null, (try r.entry(a)).ticket);
    try std.testing.expectEqual(@as(u64, 0), (try r.entry(a)).submitted);
    r.next_frame = std.math.maxInt(u64);
    try std.testing.expectError(error.IdentityExhausted, r.offer());
    _ = try r.retire(a);
    r.slots.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.IdentityExhausted, r.add(.drop));
}

test "cancellation does not poison a consumer and external failure keeps the entered claim" {
    var r: Registry(1) = .{};
    const id = try r.add(.wait);
    const first = (try r.claim(id, try r.offer())).?;
    const cancelled = try r.finish(id, first, .cancelled);
    try std.testing.expect(cancelled.active and !cancelled.failed);
    try std.testing.expectEqual(@as(u64, 1), cancelled.cancelled);
    const next = (try r.claim(id, try r.offer())).?;
    const failed = try r.fail(id);
    try std.testing.expect(failed.failed and !failed.active and failed.ticket.? == next);
    _ = try r.fail(id);
    try std.testing.expectEqual(@as(u64, 1), (try r.state(id)).failures);
    _ = try r.retire(id);
    try std.testing.expectError(error.Capacity, r.add(.wait));
    _ = try r.finish(id, next, .completed);
    try std.testing.expectEqual(@as(usize, 0), r.slots.count);
}
