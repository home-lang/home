//! Owned producer/host-consumer FIFO. Caller serializes access. Acknowledgement
//! retains in-flight capacity; sequence-checked copies never expose arena bytes.
const std = @import("std");
const Owned = @import("owned_fifo.zig");
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Item = struct { value: T, sequence: u64 };
        fifo: Owned.Queue(Item),
        issued: u64 = 0,
        completed: u64 = 0,
        failure: ?i32 = null,
        accepted_bytes: u64 = 0,
        completed_bytes: u64 = 0,
        rejected: u64 = 0,
        high_bytes: usize = 0,
        high_items: usize = 0,
        pub const Stats = struct { queued_bytes: usize, queued_items: usize, accepted: u64, completed: u64, rejected: u64, high_bytes: usize, high_items: usize, max_bytes: usize, max_items: usize, accepted_bytes: u64, completed_bytes: u64, failure: ?i32 };
        pub fn stats(s: *const Self) Stats {
            return .{ .queued_bytes = s.fifo.used, .queued_items = s.fifo.count, .accepted = s.issued, .completed = s.completed, .rejected = s.rejected, .high_bytes = s.high_bytes, .high_items = s.high_items, .max_bytes = s.fifo.bytes.len, .max_items = s.fifo.entries.len, .accepted_bytes = s.accepted_bytes, .completed_bytes = s.completed_bytes, .failure = s.failure };
        }
        /// A point-in-time observation, not a reservation. In-flight entries
        /// remain charged until ack; callers serialize subsequent admissions.
        pub fn capacity(s: *const Self, bytes: usize, items: usize) !bool {
            if (items == 0 or bytes > s.fifo.bytes.len or items > s.fifo.entries.len) return error.InvalidCapacity;
            if (s.failure != null) return error.Closed;
            return bytes <= s.fifo.bytes.len - s.fifo.used and items <= s.fifo.entries.len - s.fifo.count;
        }
        pub fn init(a: std.mem.Allocator, bytes: usize, items: usize) !Self {
            return .{ .fifo = try Owned.Queue(Item).init(a, bytes, items) };
        }
        pub fn deinit(s: *Self) void {
            s.fifo.deinit();
        }
        pub fn push(s: *Self, value: T, bytes: []const u8) !u64 {
            errdefer s.rejected +|= 1;
            if (s.failure != null) return error.Closed;
            if (s.issued == std.math.maxInt(u64)) return error.SequenceOverflow;
            const sequence = s.issued + 1;
            try s.fifo.push(.{ .value = value, .sequence = sequence }, bytes);
            s.issued = sequence;
            s.accepted_bytes +|= bytes.len;
            s.high_bytes = @max(s.high_bytes, s.fifo.used);
            s.high_items = @max(s.high_items, s.fifo.count);
            return sequence;
        }
        pub fn copy(s: *const Self, sequence: u64, out: []u8) ![]const u8 {
            const entry = s.fifo.front() orelse return error.EmptyBuffer;
            if (entry.value.sequence != sequence) return error.StaleSequence;
            return s.fifo.copyFront(out);
        }
        pub fn ack(s: *Self, sequence: u64) !void {
            if (s.failure != null) return error.Closed;
            const entry = s.fifo.front() orelse return error.EmptyBuffer;
            if (entry.value.sequence != sequence) return error.StaleSequence;
            s.completed_bytes +|= entry.length;
            s.fifo.pop();
            s.completed = sequence;
        }
        pub fn fail(s: *Self, code: i32) void {
            if (s.failure == null) s.failure = code;
        }
        /// A later failure cannot poison an already completed prefix.
        pub fn poll(s: *const Self, target: u64) !?i32 {
            if (target > s.issued) return error.InvalidTarget;
            if (target <= s.completed) return 0;
            if (s.failure) |code| return code;
            return null;
        }
    };
}
test "telemetry includes in-flight ownership, rejection and batch headroom without reservation" {
    var q = try Queue(u8).init(std.testing.allocator, 4, 2);
    defer q.deinit();
    const first = try q.push(1, "abc");
    var copy: [4]u8 = undefined;
    _ = try q.copy(first, &copy);
    try std.testing.expect(!try q.capacity(2, 1));
    try std.testing.expect(try q.capacity(1, 1));
    try std.testing.expect(!try q.capacity(0, 2));
    try std.testing.expectError(error.InvalidCapacity, q.capacity(5, 1));
    try std.testing.expectError(error.BufferFull, q.push(2, "xx"));
    var stats = q.stats();
    try std.testing.expectEqual(@as(usize, 3), stats.queued_bytes);
    try std.testing.expectEqual(@as(u64, 1), stats.rejected);
    try q.ack(first);
    try std.testing.expect(try q.capacity(4, 2));
    _ = try q.push(3, "");
    stats = q.stats();
    try std.testing.expectEqual(@as(usize, 3), stats.high_bytes);
    try std.testing.expectEqual(@as(u64, 3), stats.accepted_bytes);
    try std.testing.expectEqual(@as(u64, 3), stats.completed_bytes);
    try std.testing.expectEqual(@as(u64, 2), stats.accepted);
    q.fail(-6);
    try std.testing.expectError(error.Closed, q.capacity(0, 1));
}
test "host delivery retains in-flight capacity, rejects stale acknowledgements and owns bytes" {
    var q = try Queue(u32).init(std.testing.allocator, 4, 2);
    defer q.deinit();
    var source = [_]u8{ 1, 2, 3 };
    const first = try q.push(9, &source);
    source[0] = 99;
    var copy: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, try q.copy(first, &copy));
    try std.testing.expectError(error.BufferFull, q.push(10, "xx"));
    try std.testing.expectError(error.StaleSequence, q.ack(first + 1));
    try q.ack(first);
    const second = try q.push(10, "xyz");
    try std.testing.expectError(error.StaleSequence, q.copy(first, &copy));
    q.fail(-6);
    q.fail(-4);
    try std.testing.expectEqual(@as(?i32, 0), try q.poll(first));
    try std.testing.expectEqual(@as(?i32, -6), try q.poll(second));
    try std.testing.expectError(error.Closed, q.push(11, ""));
    try std.testing.expectError(error.Closed, q.ack(second));
}
test "metadata, wrap, invalid prefix and sequence exhaustion are bounded" {
    var q = try Queue(u8).init(std.testing.allocator, 3, 2);
    defer q.deinit();
    const first = try q.push(1, "ab");
    _ = try q.push(2, "");
    try std.testing.expectError(error.BufferFull, q.push(3, ""));
    try q.ack(first);
    const third = try q.push(3, "xyz");
    try q.ack(2);
    var out: [3]u8 = undefined;
    try std.testing.expectEqualStrings("xyz", try q.copy(third, &out));
    try std.testing.expectEqual(@as(?i32, null), try q.poll(third));
    try q.ack(third);
    try std.testing.expectEqual(@as(?i32, 0), try q.poll(third));
    try std.testing.expectError(error.InvalidTarget, q.poll(third + 1));
    q.issued = std.math.maxInt(u64);
    try std.testing.expectError(error.SequenceOverflow, q.push(4, ""));
}
