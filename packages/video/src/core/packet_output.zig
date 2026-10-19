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
