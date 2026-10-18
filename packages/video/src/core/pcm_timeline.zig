//! Bounded PCM ownership and sample-accurate clipping on a common nanosecond clock.
//! Single serialized owner; returned data expires on the next push/mutation.
const std = @import("std");
pub fn at(origin: u64, frames: u64, rate: u32) !u64 {
    if (rate < 8000 or rate > 192000) return error.InvalidRate;
    const value = @as(u128, origin) + @as(u128, frames) * 1_000_000_000 / rate;
    if (value > std.math.maxInt(u64)) return error.TimestampOverflow;
    return @intCast(value);
}
pub fn before(origin: u64, cut: u64, rate: u32, limit: usize) usize {
    if (cut <= origin) return 0;
    return @intCast(@min(limit, (@as(u128, cut - origin) * rate + 999_999_999) / 1_000_000_000));
}
const Entry = struct { offset: usize, frames: usize, consumed: usize = 0, timestamp: u64 };
pub const Chunk = struct { data: []const u8, timestamp: u64, frames: usize };
pub const Queue = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    entries: []Entry,
    rate: u32,
    channels: u32,
    capacity: usize,
    head: usize = 0,
    count: usize = 0,
    used: usize = 0,
    write_pos: usize = 0,
    last_end: ?u64 = null,
    trimmed: u64 = 0,
    pub fn init(a: std.mem.Allocator, rate: u32, channels: u32, frames: usize, blocks: usize) !Queue {
        if (rate < 8000 or rate > 192000 or channels < 1 or channels > 2 or frames == 0 or frames > rate * 10 or blocks == 0 or blocks > 4096) return error.InvalidConfiguration;
        const data = try a.alloc(u8, frames * channels * 2);
        errdefer a.free(data);
        const entries = try a.alloc(Entry, blocks);
        return .{ .allocator = a, .data = data, .entries = entries, .rate = rate, .channels = channels, .capacity = frames };
    }
    pub fn deinit(s: *Queue) void {
        s.allocator.free(s.data);
        s.allocator.free(s.entries);
    }
    pub fn push(s: *Queue, data: []const u8, timestamp: u64) !void {
        const stride = s.channels * 2;
        if (data.len == 0 or data.len % stride != 0) return error.InvalidPcm;
        const frames = data.len / stride;
        if (frames > s.capacity - s.used or s.count == s.entries.len) return error.BufferFull;
        var ts = timestamp;
        if (s.last_end) |end| {
            if (ts < end) {
                if (end - ts > (1_000_000_000 + s.rate - 1) / s.rate) return error.InvalidTimestamp;
                ts = end;
            }
        }
        const end = try at(ts, frames, s.rate);
        const first = @min(frames, s.capacity - s.write_pos);
        @memcpy(s.data[s.write_pos * stride ..][0 .. first * stride], data[0 .. first * stride]);
        @memcpy(s.data[0 .. (frames - first) * stride], data[first * stride ..]);
        s.entries[(s.head + s.count) % s.entries.len] = .{ .offset = s.write_pos, .frames = frames, .timestamp = ts };
        s.write_pos = (s.write_pos + frames) % s.capacity;
        s.count += 1;
        s.used += frames;
        s.last_end = end;
    }
    fn consume(s: *Queue, e: *Entry, n: usize) void {
        e.consumed += n;
        s.used -= n;
        if (e.consumed == e.frames) {
            s.head = (s.head + 1) % s.entries.len;
            s.count -= 1;
        }
    }
    /// Emit samples with time >= minimum and < cut. Wrap is returned as separate
    /// contiguous chunks; never duplicate a sample at a segment boundary.
    pub fn take(s: *Queue, minimum: u64, cut: u64) !?Chunk {
        while (s.count != 0) {
            const e = &s.entries[s.head];
            const end = before(e.timestamp, cut, s.rate, e.frames);
            const begin = @max(e.consumed, @min(end, before(e.timestamp, minimum, s.rate, e.frames)));
            if (begin > e.consumed) {
                const n = begin - e.consumed;
                s.trimmed += n;
                s.consume(e, n);
                if (s.count == 0 or begin == e.frames) continue;
            }
            if (end <= e.consumed) return null;
            const offset = (e.offset + e.consumed) % s.capacity;
            const n = @min(end - e.consumed, s.capacity - offset);
            const result = Chunk{ .data = s.data[offset * s.channels * 2 ..][0 .. n * s.channels * 2], .timestamp = try at(e.timestamp, e.consumed, s.rate), .frames = n };
            s.consume(e, n);
            return result;
        }
        return null;
    }
};
test "PCM splits across samples and arena wrap without loss or duplicate frames" {
    var q = try Queue.init(std.testing.allocator, 48000, 1, 8, 4);
    defer q.deinit();
    try q.push(&.{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0 }, 1000000);
    const first = (try q.take(1000000, 1062500)).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0 }, first.data);
    try std.testing.expect((try q.take(1000000, 1062500)) == null);
    const next = (try q.take(1062500, 1125000)).?;
    try std.testing.expectEqualSlices(u8, &.{ 4, 0, 5, 0, 6, 0 }, next.data);
    try q.push(&.{ 7, 0, 8, 0, 9, 0, 10, 0 }, 1125000);
    const wrap = (try q.take(1125000, 2000000)).?;
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 8, 0 }, wrap.data);
    try std.testing.expectEqualSlices(u8, &.{ 9, 0, 10, 0 }, (try q.take(1125000, 2000000)).?.data);
    try std.testing.expectEqual(@as(usize, 0), q.used);
}
test "PCM rejects full queues, invalid inputs and overflow before modifying history" {
    var q = try Queue.init(std.testing.allocator, 48000, 1, 4, 2);
    defer q.deinit();
    try q.push(&.{ 1, 0, 2, 0, 3, 0, 4, 0 }, 1000000);
    try std.testing.expectError(error.BufferFull, q.push(&.{ 5, 0 }, 2000000));
    _ = try q.take(1041667, 2000000);
    try std.testing.expectEqual(@as(u64, 3), q.trimmed);
    try std.testing.expectError(error.InvalidPcm, q.push(&.{1}, 2000000));
    try std.testing.expectError(error.InvalidTimestamp, q.push(&.{ 1, 0 }, 1));
    try std.testing.expectError(error.TimestampOverflow, at(std.math.maxInt(u64), 1, 48000));
    try std.testing.expectEqual(@as(u64, 1_000_000_000), try at(0, 44100, 44100));
}
test "PCM partial allocation failure cleanup" {
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            var q = try Queue.init(a, 48000, 2, 1024, 32);
            defer q.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
