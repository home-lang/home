//! Serialized, bounded PCM history with independent sample watermarks.
//! Prepared views borrow the shared arena until exact finish/retirement. A
//! producer must copy them before accepting its ticket; push rejects live views.
const std = @import("std");
const pcm = @import("pcm_timeline.zig");
const Slots = @import("packet_output.zig").Slots;
pub const Chunk = pcm.Chunk;
const Pending = struct { ticket: u64, next_ns: u64, frames: u64, cut: u64 };
pub const State = struct {
    id: u64 = 0,
    next_ns: ?u64 = null,
    cut: ?u64 = null,
    pending: ?Pending = null,
    frames: u64 = 0,
    overruns: u64 = 0,
    cancelled: u64 = 0,
    active: bool = true,
};
pub const Batch = struct { ticket: u64, frames: u64, next_ns: u64, blocks: usize };
pub fn Fanout(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        queue: pcm.Queue,
        slots: Slots(State, capacity) = .{},
        next_ticket: u64 = 1,
        pushed_frames: u64 = 0,
        high_frames: usize = 0,
        high_blocks: usize = 0,
        pub fn init(a: std.mem.Allocator, rate: u32, channels: u32, frames: usize, blocks: usize) !Self {
            return .{ .queue = try pcm.Queue.init(a, rate, channels, frames, blocks) };
        }
        pub fn deinit(s: *Self) void {
            s.queue.deinit();
        }
        fn entry(s: *Self, id: u64) !*State {
            for (&s.slots.entries) |*slot| if (slot.id == id and slot.value != null) return &slot.value.?;
            return error.Stale;
        }
        pub fn add(s: *Self) !u64 {
            const id = try s.slots.add(.{});
            (try s.entry(id)).id = id;
            return id;
        }
        pub fn check(s: *Self, id: u64) !State {
            const consumer = try s.entry(id);
            if (!consumer.active) return error.Closed;
            if (consumer.next_ns) |start| if (s.queue.retention_floor) |floor| if (start < floor) {
                consumer.overruns +|= 1;
                consumer.active = false;
                return error.Overrun;
            };
            return consumer.*;
        }
        pub fn state(s: *Self, id: u64) !State {
            return (try s.entry(id)).*;
        }
        pub fn prepared(s: *const Self) bool {
            for (s.slots.entries) |slot| if (slot.value) |value| {
                if (value.pending != null) return true;
            };
            return false;
        }
        pub fn push(s: *Self, data: []const u8, timestamp: u64) !void {
            if (s.prepared()) return error.Busy;
            try s.queue.pushRolling(data, timestamp);
            s.pushed_frames +|= @intCast(data.len / (s.queue.channels * 2));
            s.high_frames = @max(s.high_frames, s.queue.used);
            s.high_blocks = @max(s.high_blocks, s.queue.count);
        }
        /// Reject stale/oversized batches before writing output descriptors.
        /// A history overrun deliberately quarantines only this consumer.
        pub fn prepare(s: *Self, id: u64, minimum: u64, cut: u64, out: []Chunk) !Batch {
            const consumer = try s.entry(id);
            if (!consumer.active) return error.Closed;
            if (consumer.pending != null) return error.Busy;
            const start = consumer.next_ns orelse minimum;
            if (cut < minimum or (consumer.cut != null and cut < consumer.cut.?)) return error.InvalidTimestamp;
            if (s.queue.retention_floor) |floor| if (start < floor) {
                consumer.overruns +|= 1;
                consumer.active = false;
                return error.Overrun;
            };
            if (s.next_ticket == std.math.maxInt(u64)) return error.IdentityExhausted;
            var cursor: pcm.Cursor = .{};
            var blocks: usize = 0;
            var frames: u64 = 0;
            var next = start;
            while (try s.queue.window(start, cut, &cursor)) |chunk| {
                blocks += 1;
                frames += @intCast(chunk.frames);
                next = chunk.end_ns;
            }
            if (blocks > out.len) return error.BufferTooSmall;
            cursor = .{};
            for (out[0..blocks]) |*chunk| chunk.* = (try s.queue.window(start, cut, &cursor)).?;
            const ticket = s.next_ticket;
            s.next_ticket += 1;
            consumer.pending = .{ .ticket = ticket, .next_ns = next, .frames = frames, .cut = cut };
            return .{ .ticket = ticket, .frames = frames, .next_ns = next, .blocks = blocks };
        }
        /// Acceptance means the bounded producer owns its copy, not delivery.
        /// Cancellation preserves the sample watermark for a retry.
        pub fn finish(s: *Self, id: u64, ticket: u64, accepted: bool) !State {
            const consumer = try s.entry(id);
            const pending = consumer.pending orelse return error.Stale;
            if (pending.ticket != ticket) return error.Stale;
            if (accepted) {
                consumer.next_ns = pending.next_ns;
                consumer.cut = pending.cut;
                consumer.frames +|= pending.frames;
            } else consumer.cancelled +|= 1;
            consumer.pending = null;
            return consumer.*;
        }
        pub fn retire(s: *Self, id: u64) !State {
            var consumer = s.slots.remove(id) orelse return error.Stale;
            if (consumer.pending != null) consumer.cancelled +|= 1;
            consumer.pending = null;
            consumer.active = false;
            return consumer;
        }
    };
}
test "independent consumers retain every sample across skips and retry rejected copies" {
    var f = try Fanout(2).init(std.testing.allocator, 48000, 1, 8, 4);
    defer f.deinit();
    const a = try f.add();
    const b = try f.add();
    try f.push(&.{ 1, 0, 2, 0, 3, 0, 4, 0 }, 0);
    var out: [8]Chunk = undefined;
    const first = try f.prepare(a, 0, 41667, &out);
    try std.testing.expectEqual(@as(u64, 3), first.frames);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0 }, out[0].data);
    try std.testing.expectError(error.Busy, f.push(&.{ 5, 0 }, 83333));
    _ = try f.finish(a, first.ticket, false);
    const retry = try f.prepare(a, 0, 41667, &out);
    try std.testing.expectEqual(first.frames, retry.frames);
    _ = try f.finish(a, retry.ticket, true);
    try f.push(&.{ 5, 0, 6, 0 }, 83333);
    const late = try f.prepare(b, 0, 125000, &out);
    try std.testing.expectEqual(@as(u64, 6), late.frames);
    _ = try f.finish(b, late.ticket, true);
    const tail = try f.prepare(a, 0, 125000, &out);
    try std.testing.expectEqual(@as(u64, 3), tail.frames);
    try std.testing.expectEqualSlices(u8, &.{ 4, 0 }, out[0].data);
    _ = try f.finish(a, tail.ticket, true);
}
test "only the overrun consumer fails while healthy watermarks survive rolling eviction" {
    var f = try Fanout(2).init(std.testing.allocator, 48000, 1, 4, 2);
    defer f.deinit();
    const a = try f.add();
    const b = try f.add();
    var out: [4]Chunk = undefined;
    const empty = try f.prepare(b, 0, 0, &out);
    _ = try f.finish(b, empty.ticket, true);
    for (0..5) |i| {
        const time: u64 = @intCast(i * 41667);
        try f.push(&.{ 1, 0, 2, 0 }, time);
        const batch = try f.prepare(a, 0, time + 41667, &out);
        _ = try f.finish(a, batch.ticket, true);
    }
    try std.testing.expectError(error.Overrun, f.prepare(b, 0, 300000, &out));
    try std.testing.expect(!(try f.state(b)).active);
    try std.testing.expect((try f.state(a)).active);
    try std.testing.expectEqual(@as(u64, 1), (try f.state(b)).overruns);
    try std.testing.expect(f.queue.used <= 4 and f.queue.count <= 2);
}
test "44.1 kHz fractional boundaries and late reads never duplicate or discard lagging PCM" {
    var f = try Fanout(1).init(std.testing.allocator, 44100, 1, 128, 128);
    defer f.deinit();
    const id = try f.add();
    var out: [128]Chunk = undefined;
    var total: u64 = 0;
    for (0..70) |i| {
        const time = try pcm.at(0, @intCast(i), 44100);
        // First ask ahead of input. Accepting an empty batch must not jump cut.
        const early = try f.prepare(id, 0, time + 100000, &out);
        _ = try f.finish(id, early.ticket, true);
        try f.push(&.{ 1, 0 }, time);
        const batch = try f.prepare(id, 0, time + 100000, &out);
        total += batch.frames;
        _ = try f.finish(id, batch.ticket, true);
    }
    try std.testing.expectEqual(@as(u64, 70), total);
    try std.testing.expectEqual(try pcm.at(0, 70, 44100), (try f.state(id)).next_ns.?);
}
test "borrowed batches fence mutation and stale finishes cannot change replacement watermarks" {
    var f = try Fanout(1).init(std.testing.allocator, 48000, 2, 8, 2);
    defer f.deinit();
    const a = try f.add();
    try f.push(&.{ 1, 0, 2, 0, 3, 0, 4, 0 }, 0);
    var out: [2]Chunk = undefined;
    try std.testing.expectError(error.BufferTooSmall, f.prepare(a, 0, 100000, out[0..0]));
    try std.testing.expectEqual(null, (try f.state(a)).pending);
    const batch = try f.prepare(a, 0, 100000, &out);
    try std.testing.expectError(error.Stale, f.finish(a, batch.ticket + 1, true));
    try std.testing.expectError(error.Busy, f.prepare(a, 0, 100000, &out));
    _ = try f.retire(a);
    const b = try f.add();
    try std.testing.expect(b != a);
    try std.testing.expectError(error.Stale, f.finish(a, batch.ticket, true));
    try std.testing.expectEqual(null, (try f.state(b)).next_ns);
    f.next_ticket = std.math.maxInt(u64);
    try std.testing.expectError(error.IdentityExhausted, f.prepare(b, 0, 100000, &out));
}
test "partial allocation failure releases the bounded history" {
    const Test = struct {
        fn run(a: std.mem.Allocator) !void {
            var f = try Fanout(8).init(a, 48000, 2, 96000, 256);
            defer f.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Test.run, .{});
}

test "video cuts inside one audio sample interval emit empty batches without moving backwards" {
    var f = try Fanout(1).init(std.testing.allocator, 8000, 1, 8, 2);
    defer f.deinit();
    const id = try f.add();
    try f.push(&.{ 1, 0, 2, 0, 3, 0 }, 0);
    var out: [2]Chunk = undefined;
    for (1..10) |i| {
        const batch = try f.prepare(id, @intCast((i - 1) * 1000), @intCast(i * 1000), &out);
        try std.testing.expectEqual(@as(u64, if (i == 1) 1 else 0), batch.frames);
        _ = try f.finish(id, batch.ticket, true);
    }
    try std.testing.expectError(error.InvalidTimestamp, f.prepare(id, 0, 999, &out));
    const next = try f.prepare(id, 0, 125001, &out);
    try std.testing.expectEqual(@as(u64, 1), next.frames);
    _ = try f.finish(id, next.ticket, true);
}
