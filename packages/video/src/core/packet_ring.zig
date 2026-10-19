//! Owned encoded-packet history. One caller serializes all access. Fixed byte
//! arena and entry array; push never allocates, blocks, or keeps borrowed input.
//! Eviction drops dependent packets until the oldest retained packet is a key.
const std = @import("std");
pub const Entry = struct { offset: usize, length: usize, timestamp: u64, key: bool };
pub const Ring = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    entries: []Entry,
    duration: u64,
    head: usize = 0,
    count: usize = 0,
    used: usize = 0,
    write_pos: usize = 0,
    last: ?u64 = null,
    evicted: u64 = 0,
    skipped: u64 = 0,
    pub fn init(allocator: std.mem.Allocator, byte_capacity: usize, frame_capacity: usize, duration: u64) !Ring {
        if (byte_capacity == 0 or frame_capacity == 0 or frame_capacity > std.math.maxInt(usize) / 2 or duration == 0) return error.InvalidConfiguration;
        const bytes = try allocator.alloc(u8, byte_capacity);
        errdefer allocator.free(bytes);
        const entries = try allocator.alloc(Entry, frame_capacity);
        return .{ .allocator = allocator, .bytes = bytes, .entries = entries, .duration = duration };
    }
    pub fn deinit(s: *Ring) void {
        s.allocator.free(s.bytes);
        s.allocator.free(s.entries);
    }
    fn drop(s: *Ring) void {
        s.used -= s.entries[s.head].length;
        s.head = (s.head + 1) % s.entries.len;
        s.count -= 1;
        s.evicted += 1;
    }
    pub fn entry(s: *const Ring, index: usize) ?Entry {
        if (index >= s.count) return null;
        return s.entries[(s.head + index) % s.entries.len];
    }
    /// False means waiting for a key after eviction. Limits are upper bounds;
    /// history can be empty when a GOP is larger than the retention limits.
    /// Oversized/invalid input is rejected before modifying retained history.
    pub fn push(s: *Ring, packet: []const u8, timestamp: u64, key: bool) !bool {
        if (packet.len == 0 or packet.len > s.bytes.len) return error.PacketTooLarge;
        if (s.last) |last| if (timestamp <= last) return error.InvalidTimestamp;
        while (s.count > 0 and (s.count == s.entries.len or packet.len > s.bytes.len - s.used or timestamp - s.entry(0).?.timestamp > s.duration)) s.drop();
        while (s.count > 0 and !s.entry(0).?.key) s.drop();
        s.last = timestamp;
        if (s.count == 0 and !key) {
            s.skipped += 1;
            return false;
        }
        s.store(packet, timestamp, key);
        return true;
    }
    fn store(s: *Ring, packet: []const u8, timestamp: u64, key: bool) void {
        s.last = timestamp;
        const first = @min(packet.len, s.bytes.len - s.write_pos);
        @memcpy(s.bytes[s.write_pos..][0..first], packet[0..first]);
        @memcpy(s.bytes[0 .. packet.len - first], packet[first..]);
        s.entries[(s.head + s.count) % s.entries.len] = .{ .offset = s.write_pos, .length = packet.len, .timestamp = timestamp, .key = key };
        s.write_pos = if (packet.len - first != 0) packet.len - first else if (s.write_pos + first == s.bytes.len) 0 else s.write_pos + first;
        s.count += 1;
        s.used += packet.len;
    }
    /// FIFO mode: no implicit eviction or GOP filtering. A consumer must pop
    /// mature entries before enqueueing; overflow leaves all state unchanged.
    pub fn pushQueued(s: *Ring, packet: []const u8, timestamp: u64, key: bool) !void {
        if (packet.len == 0 or packet.len > s.bytes.len) return error.PacketTooLarge;
        if (s.last) |last| if (timestamp <= last) return error.InvalidTimestamp;
        if (s.count == s.entries.len or packet.len > s.bytes.len - s.used) return error.BufferFull;
        s.store(packet, timestamp, key);
    }
    pub fn pop(s: *Ring) void {
        if (s.count != 0) s.drop();
    }
    /// Null clock flushes EOF; subtraction avoids overflowing timestamp+delay.
    pub fn ready(s: *const Ring, now: ?u64, delay: u64) bool {
        const e = s.entry(0) orelse return false;
        const clock = now orelse return true;
        return clock >= e.timestamp and clock - e.timestamp >= delay;
    }
    /// Own only the selected suffix. Borrowed source data never escapes.
    pub fn cloneFrom(s: *const Ring, a: std.mem.Allocator, start: usize) !Ring {
        if (start >= s.count) return error.InvalidIndex;
        var bytes: usize = 0;
        for (start..s.count) |i| bytes = try std.math.add(usize, bytes, s.entry(i).?.length);
        var result = try Ring.init(a, bytes, s.count - start, s.duration);
        errdefer result.deinit();
        // Destination is contiguous in this clone; copy straight into its arena.
        for (start..s.count) |i| {
            const e = s.entry(i).?;
            _ = try s.copy(i, result.bytes[result.used..]);
            result.entries[result.count] = .{ .offset = result.used, .length = e.length, .timestamp = e.timestamp, .key = e.key };
            result.count += 1;
            result.used += e.length;
            result.last = e.timestamp;
        }
        result.write_pos = 0;
        return result;
    }
    /// Explicit owned snapshot copy; data and metadata views otherwise expire
    /// on the next mutation. Returns the active destination slice.
    pub fn copy(s: *const Ring, index: usize, out: []u8) ![]const u8 {
        const e = s.entry(index) orelse return error.InvalidIndex;
        if (out.len < e.length) return error.BufferTooSmall;
        const first = @min(e.length, s.bytes.len - e.offset);
        @memcpy(out[0..first], s.bytes[e.offset..][0..first]);
        @memcpy(out[first..e.length], s.bytes[0 .. e.length - first]);
        return out[0..e.length];
    }
};
test "byte wrap and GOP eviction keep only independently decodable history" {
    var ring = try Ring.init(std.testing.allocator, 10, 4, 100);
    defer ring.deinit();
    try std.testing.expect(try ring.push("aaaa", 0, true));
    try std.testing.expect(try ring.push("bb", 1, false));
    try std.testing.expect(try ring.push("ccc", 2, true));
    try std.testing.expect(try ring.push("dddd", 3, false));
    try std.testing.expectEqual(@as(usize, 2), ring.count);
    try std.testing.expectEqual(@as(usize, 7), ring.used);
    var out: [10]u8 = undefined;
    try std.testing.expectEqualStrings("ccc", try ring.copy(0, &out));
    try std.testing.expectEqualStrings("dddd", try ring.copy(1, &out));
    try std.testing.expect(!try ring.push("12345678", 4, false));
    try std.testing.expectEqual(@as(usize, 0), ring.count);
    try std.testing.expect(try ring.push("key", 5, true));
    try std.testing.expectEqualStrings("key", try ring.copy(0, &out));
}
test "frame and time limits; rejected inputs preserve existing payload" {
    var ring = try Ring.init(std.testing.allocator, 10, 2, 3);
    defer ring.deinit();
    try std.testing.expect(!try ring.push("p", 0, false));
    try std.testing.expect(try ring.push("a", 1, true));
    try std.testing.expect(try ring.push("b", 2, false));
    try std.testing.expect(!try ring.push("c", 3, false));
    try std.testing.expect(try ring.push("d", 4, true));
    try std.testing.expectError(error.PacketTooLarge, ring.push("01234567890", 5, true));
    try std.testing.expectError(error.InvalidTimestamp, ring.push("x", 4, true));
    var out: [1]u8 = undefined;
    try std.testing.expectEqualStrings("d", try ring.copy(0, &out));
    try std.testing.expect(!try ring.push("e", 8, false));
    try std.testing.expectEqual(@as(usize, 0), ring.count);
    try std.testing.expectError(error.InvalidIndex, ring.copy(0, &out));
}
test "initialization rejects zero limits and frees partial allocations" {
    try std.testing.expectError(error.InvalidConfiguration, Ring.init(std.testing.allocator, 0, 1, 1));
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            var r = try Ring.init(a, 10, 2, 3);
            defer r.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "FIFO delay preserves dependencies and rejects overflow atomically" {
    var r = try Ring.init(std.testing.allocator, 8, 3, 1);
    defer r.deinit();
    try r.pushQueued("key", 10, true);
    try r.pushQueued("p", 20, false);
    try std.testing.expect(!r.ready(19, 10));
    try std.testing.expect(r.ready(20, 10));
    r.pop();
    try std.testing.expect(!r.entry(0).?.key);
    try r.pushQueued("next", 30, false);
    try std.testing.expectError(error.BufferFull, r.pushQueued("full", 40, true));
    try std.testing.expectEqual(@as(u64, 30), r.last.?);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expect(r.ready(null, std.math.maxInt(u64)));
    try std.testing.expect(!r.ready(0, 0));
    var clone = try r.cloneFrom(std.testing.allocator, 0);
    defer clone.deinit();
    r.pop();
    r.pop();
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("next", try clone.copy(1, &out));
}
test "suffix cloning frees partial allocations and preserves source" {
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            var r = try Ring.init(a, 9, 3, 10);
            defer r.deinit();
            _ = try r.push("first", 0, true);
            _ = try r.push("next", 1, true);
            var frozen = try r.cloneFrom(a, 1);
            defer frozen.deinit();
            try std.testing.expectEqual(@as(usize, 2), r.count);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
