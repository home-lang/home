//! Bounded ownership admission for separately allocated asynchronous payloads.
//! Caller serializes access and releases each ticket only after payload cleanup.
const std = @import("std");
pub fn Registry(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Ticket = struct { slot: usize, id: u64 };
        const Entry = struct { id: u64, bytes: usize };
        slots: [capacity]?Entry = @splat(null),
        max_bytes: usize,
        max_items: usize,
        used: usize = 0,
        count: usize = 0,
        high_bytes: usize = 0,
        high_items: usize = 0,
        issued: u64 = 0,
        released: u64 = 0,
        rejected: u64 = 0,
        pub fn init(bytes: usize, items: usize) !Self {
            if (bytes == 0 or items == 0 or items > capacity) return error.InvalidConfiguration;
            return .{ .max_bytes = bytes, .max_items = items };
        }
        pub fn reserve(s: *Self, bytes: usize) !Ticket {
            errdefer s.rejected +|= 1;
            if (bytes > s.max_bytes) return error.PayloadTooLarge;
            if (s.issued == std.math.maxInt(u64)) return error.SequenceOverflow;
            if (s.count >= s.max_items or bytes > s.max_bytes - s.used) return error.BufferFull;
            for (&s.slots, 0..) |*slot, i| if (slot.* == null) {
                s.issued += 1;
                slot.* = .{ .id = s.issued, .bytes = bytes };
                s.count += 1;
                s.used += bytes;
                s.high_bytes = @max(s.high_bytes, s.used);
                s.high_items = @max(s.high_items, s.count);
                return .{ .slot = i, .id = s.issued };
            };
            unreachable;
        }
        pub fn release(s: *Self, ticket: Ticket) !void {
            if (ticket.slot >= capacity) return error.StaleTicket;
            const entry = s.slots[ticket.slot] orelse return error.StaleTicket;
            if (entry.id != ticket.id) return error.StaleTicket;
            s.used -= entry.bytes;
            s.count -= 1;
            s.slots[ticket.slot] = null;
            s.released += 1;
        }
        /// Adjust a live payload reservation without issuing another identity.
        /// Reserve a bounded preparation allowance first, then reconcile the
        /// exact cost before allocating the payload. Failure preserves ownership.
        pub fn resize(s: *Self, ticket: Ticket, bytes: usize) !void {
            errdefer s.rejected +|= 1;
            if (ticket.slot >= capacity) return error.StaleTicket;
            const old = s.slots[ticket.slot] orelse return error.StaleTicket;
            if (old.id != ticket.id) return error.StaleTicket;
            if (bytes > s.max_bytes) return error.PayloadTooLarge;
            const other = s.used - old.bytes;
            if (bytes > s.max_bytes - other) return error.BufferFull;
            s.slots[ticket.slot] = .{ .id = old.id, .bytes = bytes };
            s.used = other + bytes;
            s.high_bytes = @max(s.high_bytes, s.used);
        }
        /// True while any payload admitted at/before target still owns storage.
        /// Out-of-order releases and later admissions cannot extend this prefix.
        /// This is a cleanup fence, not an operation-success watermark.
        pub fn pendingThrough(s: *const Self, target: u64) !bool {
            if (target > s.issued) return error.InvalidTarget;
            for (s.slots) |slot| if (slot) |entry| {
                if (entry.id <= target) return true;
            };
            return false;
        }
    };
}
test "ownership prefixes survive holes, slot reuse and later admissions" {
    var r = try Registry(3).init(10, 3);
    try std.testing.expect(!try r.pendingThrough(0));
    try std.testing.expectError(error.InvalidTarget, r.pendingThrough(1));
    const a = try r.reserve(1);
    const b = try r.reserve(1);
    const target = r.issued;
    try r.release(b);
    const later = try r.reserve(1);
    try std.testing.expect(try r.pendingThrough(target));
    try r.release(a);
    try std.testing.expect(!try r.pendingThrough(target));
    try std.testing.expect(try r.pendingThrough(later.id));
    try r.release(later);
    try std.testing.expect(!try r.pendingThrough(target));
}
test "admission charges in-flight ownership, rejects atomically and never accepts stale releases" {
    var r = try Registry(2).init(10, 2);
    const a = try r.reserve(6);
    try std.testing.expectError(error.BufferFull, r.reserve(5));
    const b = try r.reserve(4);
    try std.testing.expectError(error.BufferFull, r.reserve(0));
    try std.testing.expectEqual(@as(usize, 10), r.used);
    try r.release(a);
    const c = try r.reserve(6);
    try std.testing.expectError(error.StaleTicket, r.release(a));
    try std.testing.expectEqual(@as(usize, 10), r.used);
    try r.release(b);
    try r.release(c);
    try std.testing.expectEqual(@as(usize, 0), r.used);
    try std.testing.expectEqual(@as(usize, 10), r.high_bytes);
    try std.testing.expectEqual(@as(u64, 3), r.released);
}
test "limits, oversized payloads and ticket exhaustion preserve ownership" {
    try std.testing.expectError(error.InvalidConfiguration, Registry(2).init(0, 1));
    try std.testing.expectError(error.InvalidConfiguration, Registry(2).init(10, 3));
    var r = try Registry(2).init(10, 1);
    try std.testing.expectError(error.PayloadTooLarge, r.reserve(11));
    r.issued = std.math.maxInt(u64) - 1;
    const last = try r.reserve(10);
    try r.release(last);
    try std.testing.expectError(error.SequenceOverflow, r.reserve(1));
    try std.testing.expectEqual(@as(usize, 0), r.used);
}
test "reservation resizing preserves identity cleanup fences and accounting on rejected growth" {
    const t = std.testing;
    var r = try Registry(2).init(10, 2);
    const a = try r.reserve(2);
    const b = try r.reserve(3);
    try r.resize(a, 7);
    try t.expectEqual(@as(usize, 10), r.used);
    try t.expectError(error.BufferFull, r.resize(b, 4));
    try t.expectError(error.PayloadTooLarge, r.resize(a, 11));
    try t.expectEqual(@as(usize, 10), r.used);
    try t.expectEqual(@as(usize, 2), r.count);
    try t.expectEqual(@as(u64, 2), r.issued);
    try r.resize(a, 0);
    try t.expect(try r.pendingThrough(a.id));
    try r.release(a);
    const next = try r.reserve(4);
    try t.expectError(error.StaleTicket, r.resize(a, 0));
    try t.expectEqual(@as(usize, 7), r.used);
    try r.release(next);
    try r.release(b);
    try t.expectEqual(@as(usize, 0), r.used);
    try t.expectEqual(@as(usize, 10), r.high_bytes);
}
