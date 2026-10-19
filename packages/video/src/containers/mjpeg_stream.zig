//! Home video: bounded-memory Matroska/MJPEG stream writer.
//! EBML IDs and track layout adapted from Home webm/mkv muxers (MIT).
const std = @import("std");
pub const Sink = struct { context: *anyopaque, write: *const fn (*anyopaque, []const u8) anyerror!void };
fn number(value: u64, buf: *[8]u8) []const u8 {
    std.mem.writeInt(u64, buf, value, .big);
    var i: usize = 0;
    while (i < 7 and buf[i] == 0) : (i += 1) {}
    return buf[i..];
}
fn vint(value: u64, buf: *[8]u8) ![]const u8 {
    var n: usize = 1;
    while (n < 8 and value >= (@as(u64, 1) << @intCast(n * 7)) - 1) : (n += 1) {}
    if (value >= (@as(u64, 1) << 56) - 1) return error.FrameTooLarge;
    const marked = value | (@as(u64, 1) << @intCast(n * 7));
    std.mem.writeInt(u64, buf, marked, .big);
    return buf[8 - n ..];
}
const Buffer = struct {
    data: [1024]u8 = undefined,
    len: usize = 0,
    fn bytes(self: *Buffer, b: []const u8) void {
        std.debug.assert(self.len + b.len <= self.data.len);
        @memcpy(self.data[self.len..][0..b.len], b);
        self.len += b.len;
    }
    fn element(self: *Buffer, id: u32, value: []const u8) void {
        var b: [8]u8 = undefined;
        self.bytes(number(id, &b));
        self.bytes(vint(value.len, &b) catch unreachable);
        self.bytes(value);
    }
    fn uint(self: *Buffer, id: u32, value: u64) void {
        var b: [8]u8 = undefined;
        self.element(id, number(value, &b));
    }
    fn slice(self: *const Buffer) []const u8 {
        return self.data[0..self.len];
    }
};
pub const Writer = struct {
    sink: Sink,
    first_ns: u64 = 0,
    last_ns: u64 = 0,
    frames: u64 = 0,
    failed: bool = false,
    pub fn init(sink: Sink, width: u32, height: u32, fps_num: u32, fps_den: u32) !Writer {
        if (width == 0 or height == 0 or fps_num == 0 or fps_den == 0 or fps_num > 1000000 or fps_den > 1000000) return error.InvalidConfiguration;
        var ebml: Buffer = .{};
        ebml.uint(0x4286, 1);
        ebml.uint(0x42f7, 1);
        ebml.uint(0x42f2, 4);
        ebml.uint(0x42f3, 8);
        ebml.element(0x4282, "matroska");
        ebml.uint(0x4287, 4);
        ebml.uint(0x4285, 2);
        var header: Buffer = .{};
        header.element(0x1a45dfa3, ebml.slice());
        header.bytes(&.{ 0x18, 0x53, 0x80, 0x67, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
        var info: Buffer = .{};
        info.uint(0x2ad7b1, 1000000);
        info.element(0x4d80, "Home");
        info.element(0x5741, "Home native MJPEG");
        header.element(0x1549a966, info.slice());
        var video: Buffer = .{};
        video.uint(0xb0, width);
        video.uint(0xba, height);
        var track: Buffer = .{};
        track.uint(0xd7, 1);
        track.uint(0x73c5, 1);
        track.uint(0x83, 1);
        track.uint(0x9c, 0);
        track.element(0x86, "V_MJPEG");
        track.uint(0x23e383, @as(u64, 1000000000) * fps_den / fps_num);
        track.element(0xe0, video.slice());
        var entry: Buffer = .{};
        entry.element(0xae, track.slice());
        header.element(0x1654ae6b, entry.slice());
        try sink.write(sink.context, header.slice());
        return .{ .sink = sink };
    }
    pub fn frame(self: *Writer, jpeg: []const u8, timestamp_ns: u64) !void {
        if (self.failed) return error.WriterFailed;
        if (jpeg.len < 4 or !std.mem.startsWith(u8, jpeg, &.{ 255, 216 }) or !std.mem.endsWith(u8, jpeg, &.{ 255, 217 })) return error.InvalidFrame;
        if (self.frames != 0 and timestamp_ns <= self.last_ns) return error.InvalidTimestamp;
        const first = if (self.frames == 0) timestamp_ns else self.first_ns;
        var time: Buffer = .{};
        time.uint(0xe7, (timestamp_ns - first) / 1000000);
        var size: [8]u8 = undefined;
        const block_size = try vint(jpeg.len + 4, &size);
        var header: Buffer = .{};
        header.bytes(&.{ 0x1f, 0x43, 0xb6, 0x75 });
        var cluster_size: [8]u8 = undefined;
        header.bytes(try vint(time.len + 1 + block_size.len + 4 + jpeg.len, &cluster_size));
        header.bytes(time.slice());
        header.bytes(&.{0xa3});
        header.bytes(block_size);
        header.bytes(&.{ 0x81, 0, 0, 0x80 });
        errdefer self.failed = true;
        try self.sink.write(self.sink.context, header.slice());
        try self.sink.write(self.sink.context, jpeg);
        self.first_ns = first;
        self.last_ns = timestamp_ns;
        self.frames += 1;
    }
};
test "stream rejects timestamps and propagates sink failure without accumulating frames" {
    const Output = struct {
        data: std.ArrayList(u8) = .empty,
        fail: bool = false,
        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fail) return error.TestSinkFailure;
            try self.data.appendSlice(std.testing.allocator, bytes);
        }
    };
    var out: Output = .{};
    defer out.data.deinit(std.testing.allocator);
    var writer = try Writer.init(.{ .context = &out, .write = Output.write }, 32, 24, 30, 1);
    try writer.frame(&.{ 255, 216, 1, 2, 255, 217 }, 1000);
    try std.testing.expectError(error.InvalidTimestamp, writer.frame(&.{ 255, 216, 255, 217 }, 1000));
    out.fail = true;
    try std.testing.expectError(error.TestSinkFailure, writer.frame(&.{ 255, 216, 255, 217 }, 2000));
    try std.testing.expectError(error.WriterFailed, writer.frame(&.{ 255, 216, 255, 217 }, 3000));
}
