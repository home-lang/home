//! Bounded PCM ownership and sample-accurate clipping on a common nanosecond clock.
//! Single serialized owner; returned data expires on the next push/mutation.
const std = @import("std");
pub fn at(origin: u64, frames: u64, rate: u32) !u64 {
    return atPhase(origin, frames, rate, 0);
}
fn atPhase(origin: u64, frames: u64, rate: u32, phase: u32) !u64 {
    if (rate < 8000 or rate > 192000) return error.InvalidRate;
    const value = @as(u128, origin) + (@as(u128, frames) * 1_000_000_000 + phase) / rate;
    if (value > std.math.maxInt(u64)) return error.TimestampOverflow;
    return @intCast(value);
}
pub fn before(origin: u64, cut: u64, rate: u32, limit: usize) usize {
    return beforePhase(origin, cut, rate, limit, 0);
}
fn beforePhase(origin: u64, cut: u64, rate: u32, limit: usize, phase: u32) usize {
    if (cut <= origin) return 0;
    return @intCast(@min(limit, (@as(u128, cut - origin) * rate - phase + 999_999_999) / 1_000_000_000));
}
const Entry = struct { offset: usize, frames: usize, consumed: usize = 0, timestamp: u64, phase: u32 };
pub const Chunk = struct { data: []const u8, timestamp: u64, frames: usize, end_ns: u64, phase: u32 = 0 };
pub const Cursor = struct { block: usize = 0, frame: usize = 0 };
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
    last_phase: u32 = 0,
    trimmed: u64 = 0,
    retention_floor: ?u64 = null,
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
        // A block timestamp is the floor of the cumulative sample clock. Carry
        // its fractional numerator across contiguous blocks instead of flooring
        // every block again (which shifts exact cuts by one sample at 44.1 kHz).
        const phase = if (s.last_end != null and timestamp == s.last_end.?) s.last_phase else 0;
        return s.pushPhased(data, timestamp, phase);
    }
    fn pushPhased(s: *Queue, data: []const u8, timestamp: u64, phase: u32) !void {
        const stride = s.channels * 2;
        if (data.len == 0 or data.len % stride != 0) return error.InvalidPcm;
        const frames = data.len / stride;
        if (frames > s.capacity - s.used or s.count == s.entries.len) return error.BufferFull;
        const ts = timestamp;
        if (s.last_end) |end| if (ts < end) return error.InvalidTimestamp;
        const end = try atPhase(ts, frames, s.rate, phase);
        const first = @min(frames, s.capacity - s.write_pos);
        @memcpy(s.data[s.write_pos * stride ..][0 .. first * stride], data[0 .. first * stride]);
        @memcpy(s.data[0 .. (frames - first) * stride], data[first * stride ..]);
        s.entries[(s.head + s.count) % s.entries.len] = .{ .offset = s.write_pos, .frames = frames, .timestamp = ts, .phase = phase };
        s.write_pos = (s.write_pos + frames) % s.capacity;
        s.count += 1;
        s.used += frames;
        s.last_end = end;
        s.last_phase = @intCast((@as(u128, frames) * 1_000_000_000 + phase) % s.rate);
    }
    fn consume(s: *Queue, e: *Entry, n: usize) void {
        e.consumed += n;
        s.used -= n;
        if (e.consumed == e.frames) {
            s.head = (s.head + 1) % s.entries.len;
            s.count -= 1;
        }
    }
    /// Circular ownership: reject invalid input before eviction, then discard
    /// whole oldest blocks until the new block fits. No allocation after init.
    pub fn pushRolling(s: *Queue, data: []const u8, timestamp: u64) !void {
        const stride = s.channels * 2;
        if (data.len == 0 or data.len % stride != 0) return error.InvalidPcm;
        const frames = data.len / stride;
        if (frames > s.capacity) return error.BufferFull;
        if (s.last_end) |end| if (timestamp < end) return error.InvalidTimestamp;
        const phase = if (s.last_end != null and timestamp == s.last_end.?) s.last_phase else 0;
        _ = try atPhase(timestamp, frames, s.rate, phase);
        while (frames > s.capacity - s.used or s.count == s.entries.len) {
            const e = &s.entries[s.head];
            const n = e.frames - e.consumed;
            s.retention_floor = try atPhase(e.timestamp, e.frames, s.rate, e.phase);
            s.trimmed += n;
            s.consume(e, n);
        }
        try s.push(data, timestamp);
    }
    /// Non-consuming sample window. Cursor and returned slices expire on any
    /// mutation. Separate cursors can replay the same history independently.
    pub fn window(s: *const Queue, minimum: u64, cut: u64, cursor: *Cursor) !?Chunk {
        while (cursor.block < s.count) {
            const e = s.entries[(s.head + cursor.block) % s.entries.len];
            const begin = @max(@max(e.consumed, cursor.frame), beforePhase(e.timestamp, minimum, s.rate, e.frames, e.phase));
            const end = beforePhase(e.timestamp, cut, s.rate, e.frames, e.phase);
            if (begin >= end) {
                if (end < e.frames) return null;
                cursor.block += 1;
                cursor.frame = 0;
                continue;
            }
            const offset = (e.offset + begin) % s.capacity;
            const n = @min(end - begin, s.capacity - offset);
            cursor.frame = begin + n;
            return .{ .data = s.data[offset * s.channels * 2 ..][0 .. n * s.channels * 2], .timestamp = try atPhase(e.timestamp, begin, s.rate, e.phase), .frames = n, .phase = @intCast((@as(u128, begin) * 1_000_000_000 + e.phase) % s.rate), .end_ns = try atPhase(e.timestamp, begin + n, s.rate, e.phase) };
        }
        return null;
    }
    /// Freeze a selected sample window into independent, minimally sized storage.
    /// Caller serializes source mutation; destination may then move to a worker.
    pub fn cloneWindow(s: *const Queue, a: std.mem.Allocator, minimum: u64, cut: u64) !Queue {
        var cursor: Cursor = .{};
        var frames: usize = 0;
        var blocks: usize = 0;
        while (try s.window(minimum, cut, &cursor)) |chunk| {
            frames += chunk.frames;
            blocks += 1;
        }
        // One wrapped source block can become two contiguous descriptors.
        // A full source therefore needs at most entries.len + 1 descriptors.
        const data = try a.alloc(u8, @max(frames, 1) * s.channels * 2);
        errdefer a.free(data);
        const entries = try a.alloc(Entry, @max(blocks, 1));
        errdefer a.free(entries);
        var result = Queue{ .allocator = a, .data = data, .entries = entries, .rate = s.rate, .channels = s.channels, .capacity = @max(frames, 1) };
        cursor = .{};
        while (try s.window(minimum, cut, &cursor)) |chunk| try result.pushPhased(chunk.data, chunk.timestamp, chunk.phase);
        return result;
    }
    /// Emit samples with time >= minimum and < cut. Wrap is returned as separate
    /// contiguous chunks; never duplicate a sample at a segment boundary.
    pub fn take(s: *Queue, minimum: u64, cut: u64) !?Chunk {
        while (s.count != 0) {
            const e = &s.entries[s.head];
            const end = beforePhase(e.timestamp, cut, s.rate, e.frames, e.phase);
            const begin = @max(e.consumed, @min(end, beforePhase(e.timestamp, minimum, s.rate, e.frames, e.phase)));
            if (begin > e.consumed) {
                const n = begin - e.consumed;
                s.trimmed += n;
                s.consume(e, n);
                if (s.count == 0 or begin == e.frames) continue;
            }
            if (end <= e.consumed) return null;
            const offset = (e.offset + e.consumed) % s.capacity;
            const n = @min(end - e.consumed, s.capacity - offset);
            const result = Chunk{ .data = s.data[offset * s.channels * 2 ..][0 .. n * s.channels * 2], .timestamp = try atPhase(e.timestamp, e.consumed, s.rate, e.phase), .frames = n, .phase = @intCast((@as(u128, e.consumed) * 1_000_000_000 + e.phase) % s.rate), .end_ns = try atPhase(e.timestamp, e.consumed + n, s.rate, e.phase) };
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
    const previous = q.last_end.?;
    try std.testing.expectError(error.InvalidTimestamp, q.push(&.{ 1, 0 }, previous - 1));
    try std.testing.expectEqual(previous, q.last_end.?);
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

test "rolling PCM snapshots are repeatable across wrap and exact sample boundaries" {
    var q = try Queue.init(std.testing.allocator, 44100, 1, 8, 3);
    defer q.deinit();
    try q.pushRolling(&.{ 1, 0, 2, 0, 3, 0, 4, 0, 5, 0 }, 1000000);
    try q.pushRolling(&.{ 6, 0, 7, 0, 8, 0, 9, 0 }, try at(1000000, 5, 44100));
    try std.testing.expectEqual(@as(u64, 5), q.trimmed);
    try std.testing.expectEqual(@as(usize, 4), q.used);
    const start = try at(try at(1000000, 5, 44100), 1, 44100);
    for (0..2) |_| {
        var cursor: Cursor = .{};
        const a = (try q.window(start, std.math.maxInt(u64), &cursor)).?;
        try std.testing.expectEqualSlices(u8, &.{ 7, 0, 8, 0 }, a.data);
        const b = (try q.window(start, std.math.maxInt(u64), &cursor)).?;
        try std.testing.expectEqualSlices(u8, &.{ 9, 0 }, b.data);
        try std.testing.expect((try q.window(start, std.math.maxInt(u64), &cursor)) == null);
        try std.testing.expectEqual(@as(usize, 4), q.used);
    }
    const floor = q.retention_floor;
    try std.testing.expectError(error.InvalidTimestamp, q.pushRolling(&.{ 1, 0 }, 0));
    var oversized: [18]u8 = undefined;
    @memset(&oversized, 0);
    try std.testing.expectError(error.BufferFull, q.pushRolling(&oversized, q.last_end.?));
    try std.testing.expectEqual(floor, q.retention_floor);
    try std.testing.expectEqual(@as(usize, 4), q.used);
}
test "rolling PCM metadata limit and window clipping preserve gaps" {
    var q = try Queue.init(std.testing.allocator, 8000, 2, 16, 2);
    defer q.deinit();
    const block = [_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 };
    try q.pushRolling(&block, 0);
    try q.pushRolling(&block, 1000000);
    try q.pushRolling(&block, 2000000);
    try std.testing.expectEqual(@as(u64, 2), q.trimmed);
    var cursor: Cursor = .{};
    const chunk = (try q.window(1125000, 2000000, &cursor)).?;
    try std.testing.expectEqual(@as(usize, 1), chunk.frames);
    try std.testing.expectEqual(@as(u64, 1250000), chunk.end_ns);
    try std.testing.expect((try q.window(1125000, 2000000, &cursor)) == null);
}

test "frozen PCM windows own wrapped clipped samples and clean up allocation failures" {
    const Check = struct {
        fn run(a: std.mem.Allocator) !void {
            var q = try Queue.init(a, 44100, 1, 6, 3);
            defer q.deinit();
            try q.pushRolling(&.{ 1, 0, 2, 0, 3, 0, 4, 0 }, 1000);
            try q.pushRolling(&.{ 5, 0, 6, 0, 7, 0, 8, 0 }, try at(1000, 4, 44100));
            const begin = try at(try at(1000, 4, 44100), 1, 44100);
            var frozen = try q.cloneWindow(a, begin, std.math.maxInt(u64));
            defer frozen.deinit();
            try q.pushRolling(&.{ 9, 0, 10, 0, 11, 0, 12, 0 }, q.last_end.?);
            var cursor: Cursor = .{};
            var frames: usize = 0;
            var values: [6]u8 = undefined;
            while (try frozen.window(0, std.math.maxInt(u64), &cursor)) |chunk| {
                @memcpy(values[frames * 2 ..][0..chunk.data.len], chunk.data);
                frames += chunk.frames;
            }
            try std.testing.expectEqualSlices(u8, &.{ 6, 0, 7, 0, 8, 0 }, &values);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "freeze supports a full descriptor queue with a wrapped final block" {
    var q = try Queue.init(std.testing.allocator, 48000, 1, 8193, 4096);
    defer q.deinit();
    for (0..4097) |i| try q.pushRolling(&.{ 1, 0, 2, 0 }, try at(0, i * 2, 48000));
    var frozen = try q.cloneWindow(std.testing.allocator, 0, std.math.maxInt(u64));
    defer frozen.deinit();
    try std.testing.expectEqual(@as(usize, 4096), q.count);
    try std.testing.expectEqual(@as(usize, 4097), frozen.count);
    try std.testing.expectEqual(q.used, frozen.used);
}

test "contiguous 44.1 kHz blocks and frozen partial windows preserve sample phase" {
    const a = std.testing.allocator;
    var q = try Queue.init(a, 44100, 1, 22050, 32);
    defer q.deinit();
    var block: [2048]u8 = undefined;
    for (0..20) |i| {
        for (0..1024) |j| std.mem.writeInt(u16, block[j * 2 ..][0..2], @intCast(i * 1024 + j), .little);
        try q.push(&block, try at(0, i * 1024, 44100));
    }
    var cursor: Cursor = .{};
    var count: usize = 0;
    while (try q.window(0, 320_000_000, &cursor)) |chunk| count += chunk.frames;
    try std.testing.expectEqual(@as(usize, 14112), count);
    // Freezing from a partial block must carry the first sample's fraction too.
    var frozen = try q.cloneWindow(a, try at(0, 3001, 44100), 400_000_000);
    defer frozen.deinit();
    count = 0;
    while (try frozen.take(0, 320_000_000)) |chunk| count += chunk.frames;
    try std.testing.expectEqual(@as(usize, 14112 - 3001), count);
    count = 0;
    while (try q.take(0, 320_000_000)) |chunk| count += chunk.frames;
    try std.testing.expectEqual(@as(usize, 14112), count);
    const next = (try q.take(320_000_000, 400_000_000)).?;
    try std.testing.expectEqual(@as(u16, 14112), std.mem.readInt(u16, next.data[0..2], .little));
    try std.testing.expectEqual(@as(u64, 320_000_000), next.timestamp);
}

test "rolling phase survives fractional block boundaries and gaps reset the clock" {
    for ([_]u32{ 8000, 11025, 22050, 44100, 48000, 96000, 192000 }) |rate| {
        var q = try Queue.init(std.testing.allocator, rate, 1, 170, 10);
        defer q.deinit();
        var block: [34]u8 = undefined;
        @memset(&block, 0);
        for (0..10) |i| try q.pushRolling(&block, try at(7_000_000_000, i * 17, rate));
        for (1..170) |n| {
            var cursor: Cursor = .{};
            var count: usize = 0;
            while (try q.window(7_000_000_000, try at(7_000_000_000, n, rate), &cursor)) |chunk| count += chunk.frames;
            try std.testing.expectEqual(n, count);
        }
        const gap = q.last_end.? + 1000000;
        try q.pushRolling(&block, gap);
        try std.testing.expectEqual(@as(u32, @intCast((@as(u64, 17) * 1000000000) % rate)), q.last_phase);
        var frozen = try q.cloneWindow(std.testing.allocator, gap, try at(gap, 7, rate));
        defer frozen.deinit();
        try std.testing.expectEqual(@as(usize, 7), frozen.used);
    }
}
