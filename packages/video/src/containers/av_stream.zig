//! Home streaming Matroska video + lossless S16LE PCM. One cluster per packet;
//! microsecond timecodes, independent per-track ordering, no file-sized buffer.
const std = @import("std");
pub const Sink = struct { context: *anyopaque, write: *const fn (*anyopaque, []const u8) anyerror!void };
pub const Config = struct { width: u32, height: u32, fps_num: u32, fps_den: u32, codec: u32, sample_rate: u32, channels: u32, codec_private: []const u8 = &.{} };
const Buffer = struct {
    data: [16384]u8 = undefined,
    len: usize = 0,
    fn bytes(s: *Buffer, data: []const u8) !void {
        if (data.len > s.data.len - s.len) return error.HeaderTooLarge;
        @memcpy(s.data[s.len..][0..data.len], data);
        s.len += data.len;
    }
    fn slice(s: *const Buffer) []const u8 {
        return s.data[0..s.len];
    }
    fn number(s: *Buffer, value: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, value, .big);
        var n: usize = 0;
        while (n < 7 and b[n] == 0) : (n += 1) {}
        try s.bytes(b[n..]);
    }
    fn vint(s: *Buffer, value: u64) !void {
        var n: usize = 1;
        while (n < 8 and value >= (@as(u64, 1) << @intCast(n * 7)) - 1) : (n += 1) {}
        if (value >= (@as(u64, 1) << 56) - 1) return error.PacketTooLarge;
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, value | (@as(u64, 1) << @intCast(n * 7)), .big);
        try s.bytes(b[8 - n ..]);
    }
    fn element(s: *Buffer, id: u32, value: []const u8) !void {
        try s.number(id);
        try s.vint(value.len);
        try s.bytes(value);
    }
    fn uint(s: *Buffer, id: u32, value: u64) !void {
        var b: Buffer = .{};
        try b.number(value);
        try s.element(id, b.slice());
    }
};
pub const Writer = struct {
    sink: Sink,
    config: Config,
    last_video: ?u64 = null,
    last_audio: ?u64 = null,
    failed: bool = false,
    pub fn init(sink: Sink, cfg: Config) !Writer {
        if (cfg.width == 0 or cfg.height == 0 or cfg.width > 16384 or cfg.height > 16384 or cfg.fps_num == 0 or cfg.fps_den == 0 or cfg.fps_num > 1000000 or cfg.fps_den > 1000000 or cfg.codec < 1 or cfg.codec > 3 or cfg.sample_rate < 8000 or cfg.sample_rate > 192000 or cfg.channels < 1 or cfg.channels > 2 or cfg.codec_private.len > 8192) return error.InvalidConfiguration;
        if (cfg.codec != 3 and (cfg.codec_private.len < (if (cfg.codec == 1) @as(usize, 7) else 23) or cfg.codec_private[0] != 1)) return error.InvalidConfiguration;
        var ebml: Buffer = .{};
        try ebml.uint(0x4286, 1);
        try ebml.uint(0x42f7, 1);
        try ebml.uint(0x42f2, 4);
        try ebml.uint(0x42f3, 8);
        try ebml.element(0x4282, "matroska");
        try ebml.uint(0x4287, 4);
        try ebml.uint(0x4285, 2);
        var header: Buffer = .{};
        try header.element(0x1a45dfa3, ebml.slice());
        try header.bytes(&.{ 0x18, 0x53, 0x80, 0x67, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
        var info: Buffer = .{};
        try info.uint(0x2ad7b1, 1000);
        try info.element(0x4d80, "Home");
        try info.element(0x5741, "Home synchronized A/V");
        try header.element(0x1549a966, info.slice());
        var tracks: Buffer = .{};
        var video_info: Buffer = .{};
        try video_info.uint(0xb0, cfg.width);
        try video_info.uint(0xba, cfg.height);
        var track: Buffer = .{};
        try track.uint(0xd7, 1);
        try track.uint(0x73c5, 1);
        try track.uint(0x83, 1);
        try track.uint(0x9c, 0);
        try track.element(0x86, if (cfg.codec == 3) "V_MJPEG" else if (cfg.codec == 1) "V_MPEG4/ISO/AVC" else "V_MPEGH/ISO/HEVC");
        try track.uint(0x23e383, @as(u64, 1_000_000_000) * cfg.fps_den / cfg.fps_num);
        if (cfg.codec != 3) try track.element(0x63a2, cfg.codec_private);
        try track.element(0xe0, video_info.slice());
        try tracks.element(0xae, track.slice());
        var audio_info: Buffer = .{};
        var rate: [8]u8 = undefined;
        std.mem.writeInt(u64, &rate, @bitCast(@as(f64, @floatFromInt(cfg.sample_rate))), .big);
        try audio_info.element(0xb5, &rate);
        try audio_info.uint(0x9f, cfg.channels);
        try audio_info.uint(0x6264, 16);
        track = .{};
        try track.uint(0xd7, 2);
        try track.uint(0x73c5, 2);
        try track.uint(0x83, 2);
        try track.uint(0x9c, 0);
        try track.element(0x86, "A_PCM/INT/LIT");
        try track.element(0xe1, audio_info.slice());
        try tracks.element(0xae, track.slice());
        try header.element(0x1654ae6b, tracks.slice());
        try sink.write(sink.context, header.slice());
        // Codec-private bytes were consumed synchronously, not retained.
        var owned = cfg;
        owned.codec_private = &.{};
        return .{ .sink = sink, .config = owned };
    }
    fn block(s: *Writer, track: u8, data: []const u8, timestamp_ns: u64, key: bool) !void {
        if (s.failed) return error.WriterFailed;
        if (data.len == 0 or data.len > std.math.maxInt(u32)) return error.InvalidPacket;
        const last = if (track == 1) s.last_video else s.last_audio;
        if (last) |t| if (timestamp_ns <= t) return error.InvalidTimestamp;
        var time: Buffer = .{};
        try time.uint(0xe7, timestamp_ns / 1000);
        var size: Buffer = .{};
        try size.vint(data.len + 4);
        var header: Buffer = .{};
        try header.number(0x1f43b675);
        try header.vint(time.len + 1 + size.len + 4 + data.len);
        try header.bytes(time.slice());
        try header.bytes(&.{0xa3});
        try header.bytes(size.slice());
        try header.bytes(&.{ 0x80 | track, 0, 0, if (key) @as(u8, 0x80) else 0 });
        errdefer s.failed = true;
        try s.sink.write(s.sink.context, header.slice());
        try s.sink.write(s.sink.context, data);
        if (track == 1) s.last_video = timestamp_ns else s.last_audio = timestamp_ns;
    }
    pub fn video(s: *Writer, data: []const u8, timestamp_ns: u64, key: bool) !void {
        if (s.config.codec == 3 and (data.len < 4 or !std.mem.startsWith(u8, data, &.{ 255, 216 }) or !std.mem.endsWith(u8, data, &.{ 255, 217 }))) return error.InvalidPacket;
        try s.block(1, data, timestamp_ns, key);
    }
    pub fn audio(s: *Writer, data: []const u8, timestamp_ns: u64) !void {
        if (data.len == 0 or data.len % (s.config.channels * 2) != 0) return error.InvalidPcm;
        try s.block(2, data, timestamp_ns, true);
    }
};
test "Matroska has real PCM track, allows interleaved track times, and poisons on I/O failure" {
    const Out = struct {
        data: std.ArrayList(u8) = .empty,
        fail: bool = false,
        fn write(ctx: *anyopaque, data: []const u8) anyerror!void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.fail) return error.Full;
            try s.data.appendSlice(std.testing.allocator, data);
        }
    };
    var out: Out = .{};
    defer out.data.deinit(std.testing.allocator);
    var writer = try Writer.init(.{ .context = &out, .write = Out.write }, .{ .width = 32, .height = 32, .fps_num = 30, .fps_den = 1, .codec = 3, .sample_rate = 48000, .channels = 2 });
    try std.testing.expect(std.mem.indexOf(u8, out.data.items, "A_PCM/INT/LIT") != null);
    try writer.video(&.{ 255, 216, 255, 217 }, 1000000, true);
    try writer.audio(&.{ 1, 0, 2, 0 }, 0);
    try std.testing.expectError(error.InvalidPcm, writer.audio(&.{1}, 100));
    try std.testing.expectError(error.InvalidTimestamp, writer.audio(&.{ 1, 0, 2, 0 }, 0));
    out.fail = true;
    try std.testing.expectError(error.Full, writer.audio(&.{ 1, 0, 2, 0 }, 2000000));
    try std.testing.expectError(error.WriterFailed, writer.video(&.{ 255, 216, 255, 217 }, 3000000, true));
}
