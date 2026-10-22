//! Allocation-free elementary-packet and PTS output helpers. Callers own sinks.
const std = @import("std");
/// Validate every four-byte big-endian NAL length before any destination write.
/// Annex B uses four-byte start codes, so conversion preserves byte length.
pub fn annexB(input: []const u8, output: []u8) ![]const u8 {
    if (input.len == 0) return error.InvalidPacket;
    var at: usize = 0;
    while (at < input.len) {
        if (input.len - at < 4) return error.InvalidPacket;
        const n = std.mem.readInt(u32, input[at..][0..4], .big);
        at += 4;
        if (n == 0 or n > input.len - at) return error.InvalidPacket;
        at += n;
    }
    if (output.len < input.len) return error.BufferTooSmall;
    at = 0;
    while (at < input.len) {
        const n = std.mem.readInt(u32, input[at..][0..4], .big);
        @memcpy(output[at..][0..4], &[_]u8{ 0, 0, 0, 1 });
        @memcpy(output[at + 4 ..][0..n], input[at + 4 ..][0..n]);
        at += 4 + n;
    }
    return output[0..input.len];
}
/// Codec header filtering only: framing/header bits are checked, not full SPS syntax.
pub const Codec = enum { avc, hevc };
fn frameLength(input: []const u8, at: usize) !usize {
    if (input.len - at < 4) return error.InvalidPacket;
    const n = std.mem.readInt(u32, input[at..][0..4], .big);
    if (n == 0 or n > input.len - at - 4) return error.InvalidPacket;
    return n;
}
fn validateFraming(input: []const u8) !void {
    if (input.len == 0) return error.InvalidPacket;
    var at: usize = 0;
    while (at < input.len) at += 4 + try frameLength(input, at);
}
fn overlaps(input: []const u8, output: []const u8) bool {
    if (input.len == 0 or output.len == 0) return false;
    const a = @intFromPtr(input.ptr);
    const b = @intFromPtr(output.ptr);
    return if (a <= b) b - a < input.len else a - b < output.len;
}
fn parameterKind(codec: Codec, nal: []const u8) !u3 {
    if (nal[0] & 128 != 0) return error.InvalidPacket;
    return switch (codec) {
        .avc => switch (nal[0] & 31) {
            7 => 1,
            8 => 2,
            13 => 4,
            else => 0,
        },
        .hevc => blk: {
            if (nal.len < 2 or nal[1] & 7 == 0) return error.InvalidPacket;
            break :blk switch ((nal[0] >> 1) & 63) {
                32 => 1,
                33 => 2,
                34 => 4,
                else => 0,
            };
        },
    };
}
/// Size of length-prefixed SPS/PPS (+ AVC SPS extension) or HEVC VPS/SPS/PPS.
/// Excludes SEI/AUD and other NALs; every framing length is validated first.
pub fn parameterSetSize(headers: []const u8, codec: Codec) !usize {
    try validateFraming(headers);
    var at: usize = 0;
    var size: usize = 0;
    var seen: u3 = 0;
    while (at < headers.len) {
        const n = try frameLength(headers, at);
        const kind = try parameterKind(codec, headers[at + 4 ..][0..n]);
        if (kind != 0) {
            size += 4 + n;
            seen |= kind;
        }
        at += 4 + n;
    }
    const required: u3 = if (codec == .avc) 3 else 7;
    if (seen & required != required) return error.InvalidPacket;
    return size;
}
/// Copy just parameter sets, preserving their original order/length framing.
/// Preflight failures leave output unchanged. Input/output must not overlap.
pub fn parameterSets(headers: []const u8, codec: Codec, output: []u8) ![]const u8 {
    const size = try parameterSetSize(headers, codec);
    if (size > output.len) return error.BufferTooSmall;
    if (overlaps(headers, output[0..size])) return error.InvalidPacket;
    var at: usize = 0;
    var written: usize = 0;
    while (at < headers.len) {
        const n = try frameLength(headers, at);
        if (try parameterKind(codec, headers[at + 4 ..][0..n]) != 0) {
            @memcpy(output[written..][0 .. 4 + n], headers[at..][0 .. 4 + n]);
            written += 4 + n;
        }
        at += 4 + n;
    }
    return output[0..size];
}
/// Preflight one access unit and an optional cached header prefix. No allocation.
pub fn annexBAccessUnitSize(headers: []const u8, packet: []const u8) !usize {
    if (headers.len != 0) try validateFraming(headers);
    try validateFraming(packet);
    return std.math.add(usize, headers.len, packet.len) catch error.InvalidPacket;
}
/// Assemble prefix + access unit with four-byte Annex B start codes. Both inputs,
/// capacity and overlap are checked before any write; output borrows caller storage.
pub fn annexBAccessUnit(headers: []const u8, packet: []const u8, output: []u8) ![]const u8 {
    const size = try annexBAccessUnitSize(headers, packet);
    if (size > output.len) return error.BufferTooSmall;
    if (overlaps(headers, output[0..size]) or overlaps(packet, output[0..size])) return error.InvalidPacket;
    if (headers.len != 0) _ = try annexB(headers, output[0..headers.len]);
    _ = try annexB(packet, output[headers.len..size]);
    return output[0..size];
}
/// Microsecond PTS as milliseconds with exactly three decimals and LF. Integer
/// arithmetic preserves zero and all u64 values without floating-point loss.
pub fn formatPts(timestamp_us: u64, output: []u8) ![]const u8 {
    var scratch: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&scratch, "{d}.{d:0>3}\n", .{ timestamp_us / 1000, timestamp_us % 1000 });
    if (output.len < line.len) return error.BufferTooSmall;
    @memcpy(output[0..line.len], line);
    return output[0..line.len];
}
pub const Sink = struct { context: *anyopaque, write: *const fn (*anyopaque, []const u8) anyerror!void };
pub const PtsWriter = struct {
    sink: Sink,
    last: ?u64 = null,
    failed: bool = false,
    pub fn frame(self: *PtsWriter, timestamp_us: u64) !void {
        if (self.failed) return error.SinkFailed;
        if (self.last) |last| if (timestamp_us <= last) return error.InvalidTimestamp;
        var buffer: [32]u8 = undefined;
        const line = try formatPts(timestamp_us, &buffer);
        self.sink.write(self.sink.context, line) catch |err| {
            self.failed = true;
            return err;
        };
        self.last = timestamp_us;
    }
};
test "Annex B converts multiple NAL units and rejects malformed input atomically" {
    var out: [16]u8 = undefined;
    @memset(&out, 0x55);
    for ([_][]const u8{ &.{}, &.{0}, &.{ 0, 0, 0, 0 }, &.{ 0, 0, 0, 2, 1 }, &.{ 0, 0, 0, 1, 5, 0 } }) |bad| {
        try std.testing.expectError(error.InvalidPacket, annexB(bad, &out));
        for (out) |byte| try std.testing.expectEqual(@as(u8, 0x55), byte);
    }
    const packet = [_]u8{ 0, 0, 0, 2, 0x67, 0x11, 0, 0, 0, 1, 0x68 };
    try std.testing.expectError(error.BufferTooSmall, annexB(&packet, out[0..10]));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67, 0x11, 0, 0, 0, 1, 0x68 }, try annexB(&packet, &out));
}
test "PTS formatting is exact and too-small destinations are unchanged" {
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.000\n", try formatPts(0, &out));
    try std.testing.expectEqualStrings("41.666\n", try formatPts(41666, &out));
    try std.testing.expectEqualStrings("18446744073709551.615\n", try formatPts(std.math.maxInt(u64), &out));
    @memset(&out, 0x55);
    try std.testing.expectError(error.BufferTooSmall, formatPts(1234, out[0..2]));
    for (out) |byte| try std.testing.expectEqual(@as(u8, 0x55), byte);
}
test "PTS sink failure poisons the writer; rejected timestamps do not call the sink" {
    const Test = struct {
        calls: usize = 0,
        fn write(ctx: *anyopaque, data: []const u8) !void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.calls += 1;
            if (s.calls > 1) return error.Injected;
            try std.testing.expectEqualStrings("0.000\n", data);
        }
    };
    var state: Test = .{};
    var writer = PtsWriter{ .sink = .{ .context = &state, .write = Test.write } };
    try writer.frame(0);
    try std.testing.expectError(error.InvalidTimestamp, writer.frame(0));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectError(error.Injected, writer.frame(1));
    try std.testing.expectError(error.SinkFailed, writer.frame(2));
    try std.testing.expectEqual(@as(usize, 2), state.calls);
}

/// Fixed-capacity, allocation-free attachment identities. Serialized owner only;
/// payload ownership stays with the caller. IDs are never reused, so a stale
/// detach cannot remove a later attachment occupying the same slot.
pub fn Slots(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { id: u64 = 0, value: ?T = null };
        entries: [capacity]Entry = std.mem.zeroes([capacity]Entry),
        count: usize = 0,
        next_id: u64 = 1,
        pub fn add(s: *Self, value: T) !u64 {
            if (s.count == capacity) return error.Capacity;
            if (s.next_id == std.math.maxInt(u64)) return error.IdentityExhausted;
            for (&s.entries) |*entry| if (entry.value == null) {
                const id = s.next_id;
                entry.* = .{ .id = id, .value = value };
                s.next_id += 1;
                s.count += 1;
                return id;
            };
            unreachable;
        }
        pub fn get(s: *const Self, id: u64) ?T {
            if (id == 0) return null;
            for (s.entries) |entry| if (entry.id == id) return entry.value;
            return null;
        }
        /// Replace a live payload without changing its stable identity/count.
        /// The caller receives ownership of the old payload only on success.
        pub fn replace(s: *Self, id: u64, value: T) !T {
            if (id == 0) return error.StaleIdentity;
            for (&s.entries) |*entry| if (entry.id == id and entry.value != null) {
                const old = entry.value.?;
                entry.value = value;
                return old;
            };
            return error.StaleIdentity;
        }
        pub fn remove(s: *Self, id: u64) ?T {
            if (id == 0) return null;
            for (&s.entries) |*entry| if (entry.id == id and entry.value != null) {
                const value = entry.value;
                entry.* = .{};
                s.count -= 1;
                return value;
            };
            return null;
        }
    };
}
test "attachment slots bound capacity and reject stale or exhausted identities atomically" {
    var slots: Slots(u32, 2) = .{};
    const first = try slots.add(10);
    const second = try slots.add(20);
    try std.testing.expectError(error.Capacity, slots.add(30));
    try std.testing.expectEqual(@as(u64, 3), slots.next_id);
    try std.testing.expectEqual(@as(u32, 10), slots.remove(first).?);
    const third = try slots.add(30);
    try std.testing.expect(third != first);
    try std.testing.expect(slots.remove(first) == null);
    try std.testing.expect(slots.get(0) == null);
    try std.testing.expectEqual(@as(u32, 20), slots.get(second).?);
    try std.testing.expectEqual(@as(u32, 30), slots.get(third).?);
    _ = slots.remove(second);
    slots.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.IdentityExhausted, slots.add(40));
    try std.testing.expectEqual(@as(usize, 1), slots.count);
    try std.testing.expectEqual(@as(u32, 30), slots.get(third).?);
    var empty: Slots(u32, 0) = .{};
    try std.testing.expectError(error.Capacity, empty.add(1));
}

test "attachment replacement preserves identity and ownership; stale replacement is atomic" {
    var slots: Slots(u32, 2) = .{};
    const id = try slots.add(10);
    const next = slots.next_id;
    try std.testing.expectEqual(@as(u32, 10), try slots.replace(id, 20));
    try std.testing.expectEqual(@as(u32, 20), slots.get(id).?);
    try std.testing.expectEqual(@as(usize, 1), slots.count);
    try std.testing.expectEqual(next, slots.next_id);
    try std.testing.expectError(error.StaleIdentity, slots.replace(0, 30));
    _ = slots.remove(id);
    const newer = try slots.add(40);
    try std.testing.expectError(error.StaleIdentity, slots.replace(id, 50));
    try std.testing.expectEqual(@as(u32, 40), slots.get(newer).?);
}

test "parameter-set extraction keeps codec-required sets and excludes SEI/AUD" {
    const t = std.testing;
    const avc = [_]u8{ 0, 0, 0, 2, 6, 9, 0, 0, 0, 2, 0x67, 1, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 9 };
    const hevc = [_]u8{ 0, 0, 0, 2, 78, 1, 0, 0, 0, 2, 64, 1, 0, 0, 0, 2, 66, 1, 0, 0, 0, 2, 68, 1 };
    var out: [64]u8 = undefined;
    try t.expectEqualSlices(u8, avc[6..17], try parameterSets(&avc, .avc, &out));
    try t.expectEqualSlices(u8, hevc[6..], try parameterSets(&hevc, .hevc, &out));
    const extension = avc[6..17].* ++ [_]u8{ 0, 0, 0, 1, 13 };
    try t.expectEqualSlices(u8, &extension, try parameterSets(&extension, .avc, &out));
}
test "header extraction rejects missing sets, bad header bits, framing, capacity and overlap atomically" {
    const t = std.testing;
    var out: [64]u8 = @splat(0xa5);
    for ([_][]const u8{ &.{}, &.{ 0, 0, 0, 1, 0x67 }, &.{ 0, 0, 0, 1, 0x68 }, &.{ 0, 0, 0, 1, 0xe7 }, &.{ 0, 0, 0, 2, 0x67 } }) |bad| try t.expectError(error.InvalidPacket, parameterSets(bad, .avc, &out));
    for ([_][]const u8{ &.{ 0, 0, 0, 1, 64 }, &.{ 0, 0, 0, 2, 64, 0 }, &.{ 0, 0, 0, 2, 192, 1 } }) |bad| try t.expectError(error.InvalidPacket, parameterSets(bad, .hevc, &out));
    var headers = [_]u8{ 0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68 };
    try t.expectError(error.BufferTooSmall, parameterSets(&headers, .avc, out[0..9]));
    const original = headers;
    try t.expectError(error.InvalidPacket, parameterSets(&headers, .avc, &headers));
    try t.expectEqualSlices(u8, &original, &headers);
    for (out) |b| try t.expectEqual(@as(u8, 0xa5), b);
}
test "access-unit assembly validates both inputs before writing a prefix" {
    const t = std.testing;
    const headers = [_]u8{ 0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68 };
    const packet = [_]u8{ 0, 0, 0, 2, 0x65, 9 };
    var out: [32]u8 = @splat(0xa5);
    try t.expectEqual(@as(usize, 16), try annexBAccessUnitSize(&headers, &packet));
    try t.expectError(error.InvalidPacket, annexBAccessUnit(&headers, &.{ 0, 0, 0, 2, 1 }, &out));
    try t.expectError(error.InvalidPacket, annexBAccessUnit(&.{ 0, 0, 0, 0 }, &packet, &out));
    try t.expectError(error.BufferTooSmall, annexBAccessUnit(&headers, &packet, out[0..15]));
    for (out) |b| try t.expectEqual(@as(u8, 0xa5), b);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 9 }, try annexBAccessUnit(&headers, &packet, &out));
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x65, 9 }, try annexBAccessUnit(&.{}, &packet, &out));
}
test "access-unit overlap is rejected before mutating either source" {
    const t = std.testing;
    var bytes = [_]u8{ 0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 0, 0, 0, 0, 0 };
    const original = bytes;
    try t.expectError(error.InvalidPacket, annexBAccessUnit(bytes[0..10], bytes[10..15], bytes[0..15]));
    try t.expectError(error.InvalidPacket, annexBAccessUnit(bytes[0..10], bytes[10..15], bytes[3..18]));
    try t.expectEqualSlices(u8, &original, &bytes);
}
