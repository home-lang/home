//! Home streaming fragmented MP4 with optional AAC-LC audio, adapted from mp4_muxer.zig.
//! Complete sample description + mvex; exact sizes/offsets; no file-sized buffer.
//! AVC/HEVC are length-prefixed, with out-of-band parameter sets (avc1/hvc1).
const std = @import("std");
pub const Codec = enum { h264, hevc };
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
    patch: ?*const fn (*anyopaque, u64, []const u8) anyerror!void = null,
};
pub const AudioConfig = struct { sample_rate: u32, channels: u32, bitrate: u32, delay: u32, config: [2]u8 };
const AudioOffsets = struct { track: usize = 0, media: usize = 0, empty: usize = 0, edit: usize = 0 };

const Buffer = struct {
    data: [16384]u8 = undefined,
    len: usize = 0,
    fn bytes(s: *Buffer, b: []const u8) !void {
        if (b.len > s.data.len - s.len) return error.HeaderTooLarge;
        @memcpy(s.data[s.len..][0..b.len], b);
        s.len += b.len;
    }
    fn zero(s: *Buffer, n: usize) !void {
        if (n > s.data.len - s.len) return error.HeaderTooLarge;
        @memset(s.data[s.len..][0..n], 0);
        s.len += n;
    }
    fn int16(s: *Buffer, n: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, n, .big);
        try s.bytes(&b);
    }
    fn int32(s: *Buffer, n: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, n, .big);
        try s.bytes(&b);
    }
    fn int64(s: *Buffer, n: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, n, .big);
        try s.bytes(&b);
    }
    fn box(s: *Buffer, name: *const [4]u8) !usize {
        const at = s.len;
        try s.int32(0);
        try s.bytes(name);
        return at;
    }
    fn end(s: *Buffer, at: usize) void {
        std.mem.writeInt(u32, s.data[at..][0..4], @intCast(s.len - at), .big);
    }
    fn full(s: *Buffer, name: *const [4]u8, flags: u32) !usize {
        const at = try s.box(name);
        try s.int32(flags);
        return at;
    }
    fn slice(s: *const Buffer) []const u8 {
        return s.data[0..s.len];
    }
    fn matrix(s: *Buffer) !void {
        for ([_]u32{ 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000 }) |v| try s.int32(v);
    }
};
pub const Nals = struct {
    data: []const u8,
    at: usize = 0,
    pub fn next(s: *Nals) !?[]const u8 {
        if (s.at == s.data.len) return null;
        if (s.data.len - s.at < 4) return error.InvalidNal;
        const n = std.mem.readInt(u32, s.data[s.at..][0..4], .big);
        s.at += 4;
        if (n == 0 or n > s.data.len - s.at) return error.InvalidNal;
        const nal = s.data[s.at..][0..n];
        s.at += n;
        return nal;
    }
};
fn config(b: *Buffer, codec: Codec, headers: []const u8) !void {
    var nals: Nals = .{ .data = headers };
    var sps: []const u8 = &.{};
    var pps: []const u8 = &.{};
    var vps: []const u8 = &.{};
    while (try nals.next()) |nal| {
        if (nal.len > 2048) return error.HeaderTooLarge;
        const kind = if (codec == .h264) nal[0] & 31 else (nal[0] >> 1) & 63;
        if (kind == (if (codec == .h264) @as(u8, 7) else 33)) sps = nal;
        if (kind == (if (codec == .h264) @as(u8, 8) else 34)) pps = nal;
        if (codec == .hevc and kind == 32) vps = nal;
    }
    if (sps.len < 4 or pps.len < 2) return error.MissingParameterSets;
    const at = try b.box(if (codec == .h264) "avcC" else "hvcC");
    if (codec == .h264) {
        // The adapter fixes AVC to 8-bit 4:2:0 High profile.
        if (sps[1] != 100) return error.UnsupportedProfile;
        try b.bytes(&.{ 1, sps[1], sps[2], sps[3], 255, 225 });
        try b.int16(@intCast(sps.len));
        try b.bytes(sps);
        try b.bytes(&.{1});
        try b.int16(@intCast(pps.len));
        try b.bytes(pps);
        try b.bytes(&.{ 253, 248, 248, 0 }); // high profile: 4:2:0, 8-bit, no SPS extensions
    } else {
        if (vps.len < 2 or sps.len < 16) return error.MissingParameterSets;
        // Remove emulation prevention before reading SPS profile_tier_level.
        var rbsp: [2048]u8 = undefined;
        var len: usize = 0;
        var zeros: usize = 0;
        for (sps[2..]) |byte| {
            if (zeros >= 2 and byte == 3) {
                zeros = 0;
                continue;
            }
            rbsp[len] = byte;
            len += 1;
            zeros = if (byte == 0) zeros + 1 else 0;
        }
        if (len < 13 or (rbsp[0] & 14) != 0 or (rbsp[1] & 31) != 1) return error.UnsupportedProfile;
        try b.bytes(&.{1});
        try b.bytes(rbsp[1..13]);
        try b.bytes(&.{ 240, 0, 252, 253, 248, 248, 0, 0, 15, 3 });
        for ([_]u8{ 32, 33, 34 }, [_][]const u8{ vps, sps, pps }) |kind, nal| {
            try b.bytes(&.{128 | kind});
            try b.int16(1);
            try b.int16(@intCast(nal.len));
            try b.bytes(nal);
        }
    }
    b.end(at);
}
fn audioTrack(b: *Buffer, cfg: AudioConfig) !AudioOffsets {
    const rates = [_]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000 };
    var index: ?u16 = null;
    for (rates, 0..) |rate, i| if (rate == cfg.sample_rate) {
        index = @intCast(i);
    };
    if (index == null or cfg.sample_rate > 48000 or cfg.channels < 1 or cfg.channels > 2 or cfg.bitrate < 16000 or cfg.bitrate > 320000 or cfg.delay > 16384) return error.InvalidConfiguration;
    const expected = (@as(u16, 2) << 11) | (index.? << 7) | (@as(u16, @intCast(cfg.channels)) << 3);
    if (std.mem.readInt(u16, &cfg.config, .big) != expected) return error.InvalidConfiguration;
    var offsets: AudioOffsets = .{};
    const trak = try b.box("trak");
    const tkhd = try b.full("tkhd", 0x1000007);
    try b.zero(16);
    try b.int32(2);
    try b.zero(4);
    offsets.track = b.len;
    try b.int64(0);
    try b.zero(8);
    try b.zero(4);
    try b.int16(0x100);
    try b.int16(0);
    try b.matrix();
    try b.zero(8);
    b.end(tkhd);
    const edts = try b.box("edts");
    const elst = try b.full("elst", 0x1000000);
    try b.int32(2);
    offsets.empty = b.len;
    try b.int64(0);
    try b.int64(std.math.maxInt(u64));
    try b.int16(1);
    try b.int16(0);
    offsets.edit = b.len;
    try b.int64(0);
    try b.int64(cfg.delay);
    try b.int16(1);
    try b.int16(0);
    b.end(elst);
    b.end(edts);
    const mdia = try b.box("mdia");
    const mdhd = try b.full("mdhd", 0x1000000);
    try b.zero(16);
    try b.int32(cfg.sample_rate);
    offsets.media = b.len;
    try b.int64(0);
    try b.int16(0x55c4);
    try b.int16(0);
    b.end(mdhd);
    const hdlr = try b.full("hdlr", 0);
    try b.int32(0);
    try b.bytes("soun");
    try b.zero(12);
    try b.bytes("Home AAC\x00");
    b.end(hdlr);
    const minf = try b.box("minf");
    const smhd = try b.full("smhd", 0);
    try b.zero(4);
    b.end(smhd);
    const dinf = try b.box("dinf");
    const dref = try b.full("dref", 0);
    try b.int32(1);
    const url = try b.full("url ", 1);
    b.end(url);
    b.end(dref);
    b.end(dinf);
    const stbl = try b.box("stbl");
    const stsd = try b.full("stsd", 0);
    try b.int32(1);
    const entry = try b.box("mp4a");
    try b.zero(6);
    try b.int16(1);
    try b.zero(8);
    try b.int16(@intCast(cfg.channels));
    try b.int16(16);
    try b.zero(4);
    try b.int32(cfg.sample_rate << 16);
    const esds = try b.full("esds", 0);
    try b.bytes(&.{ 3, 25 });
    try b.int16(2);
    try b.bytes(&.{ 0, 4, 17, 0x40, 0x15, 0, 0x20, 0 });
    try b.int32(cfg.bitrate);
    try b.int32(cfg.bitrate);
    try b.bytes(&.{ 5, 2 });
    try b.bytes(&cfg.config);
    try b.bytes(&.{ 6, 1, 2 });
    b.end(esds);
    b.end(entry);
    b.end(stsd);
    for ([_]*const [4]u8{ "stts", "stsc", "stco" }) |name| {
        const at = try b.full(name, 0);
        try b.int32(0);
        b.end(at);
    }
    const stsz = try b.full("stsz", 0);
    try b.zero(8);
    b.end(stsz);
    // Explicit decoder pre-roll makes the edit list authoritative. Without
    // roll sample groups Apple assumes an additional legacy 2112-sample delay.
    const sgpd = try b.full("sgpd", 0x1000000);
    try b.bytes("roll");
    try b.int32(2);
    try b.int32(1);
    try b.int16(65535);
    b.end(sgpd);
    const sbgp = try b.full("sbgp", 0);
    try b.bytes("roll");
    try b.int32(0);
    b.end(sbgp);
    b.end(stbl);
    b.end(minf);
    b.end(mdia);
    b.end(trak);
    return offsets;
}
pub const Writer = struct {
    sink: Sink,
    sequence: u32 = 1,
    last_dts: u64 = 0,
    frames: u64 = 0,
    failed: bool = false,
    finished: bool = false,
    audio_config: ?AudioConfig = null,
    audio_packets: u64 = 0,
    audio_pending: [8192]u8 = undefined,
    audio_pending_len: usize = 0,
    video_end_us: u64 = 0,
    movie_duration: usize = 0,
    video_duration: usize = 0,
    video_media_duration: usize = 0,
    audio_offsets: AudioOffsets = .{},
    pub fn initAv(sink: Sink, width: u32, height: u32, codec: Codec, headers: []const u8, audio_cfg: AudioConfig) !Writer {
        if (sink.patch == null) return error.InvalidConfiguration;
        return initInternal(sink, width, height, codec, headers, audio_cfg);
    }
    pub fn init(sink: Sink, width: u32, height: u32, codec: Codec, headers: []const u8) !Writer {
        return initInternal(sink, width, height, codec, headers, null);
    }
    fn initInternal(sink: Sink, width: u32, height: u32, codec: Codec, headers: []const u8, audio_cfg: ?AudioConfig) !Writer {
        if (width == 0 or height == 0 or width > 8192 or height > 8192) return error.InvalidConfiguration;
        var b: Buffer = .{};
        const ftyp = try b.box("ftyp");
        try b.bytes("iso6");
        try b.int32(512);
        try b.bytes("iso6isommp41");
        b.end(ftyp);
        const moov = try b.box("moov");
        const mvhd = try b.full("mvhd", 0x1000000);
        try b.zero(16);
        try b.int32(1000000);
        const movie_duration = b.len;
        try b.int64(0);
        try b.int32(0x10000);
        try b.int16(0x100);
        try b.zero(10);
        try b.matrix();
        try b.zero(24);
        try b.int32(if (audio_cfg != null) 3 else 2);
        b.end(mvhd);
        const trak = try b.box("trak");
        const tkhd = try b.full("tkhd", 0x1000007);
        try b.zero(16);
        try b.int32(1);
        try b.zero(4);
        const video_duration = b.len;
        try b.int64(0);
        try b.zero(8);
        try b.zero(8);
        try b.matrix();
        try b.int32(width << 16);
        try b.int32(height << 16);
        b.end(tkhd);
        const mdia = try b.box("mdia");
        const mdhd = try b.full("mdhd", 0x1000000);
        try b.zero(16);
        try b.int32(1000000);
        const video_media_duration = b.len;
        try b.int64(0);
        try b.int16(0x55c4);
        try b.int16(0);
        b.end(mdhd);
        const hdlr = try b.full("hdlr", 0);
        try b.int32(0);
        try b.bytes("vide");
        try b.zero(12);
        try b.bytes("Home Video\x00");
        b.end(hdlr);
        const minf = try b.box("minf");
        const vmhd = try b.full("vmhd", 1);
        try b.zero(8);
        b.end(vmhd);
        const dinf = try b.box("dinf");
        const dref = try b.full("dref", 0);
        try b.int32(1);
        const url = try b.full("url ", 1);
        b.end(url);
        b.end(dref);
        b.end(dinf);
        const stbl = try b.box("stbl");
        const stsd = try b.full("stsd", 0);
        try b.int32(1);
        const entry = try b.box(if (codec == .h264) "avc1" else "hvc1");
        try b.zero(6);
        try b.int16(1);
        try b.zero(16);
        try b.int16(@intCast(width));
        try b.int16(@intCast(height));
        try b.int32(0x480000);
        try b.int32(0x480000);
        try b.int32(0);
        try b.int16(1);
        try b.zero(32);
        try b.int16(24);
        try b.int16(65535);
        try config(&b, codec, headers);
        const colr = try b.box("colr");
        try b.bytes("nclx");
        try b.int16(1);
        try b.int16(13);
        try b.int16(6);
        try b.bytes(&.{0});
        b.end(colr);
        b.end(entry);
        b.end(stsd);
        for ([_]*const [4]u8{ "stts", "stsc", "stco" }) |name| {
            const at = try b.full(name, 0);
            try b.int32(0);
            b.end(at);
        }
        const stsz = try b.full("stsz", 0);
        try b.zero(8);
        b.end(stsz);
        b.end(stbl);
        b.end(minf);
        b.end(mdia);
        b.end(trak);
        const offsets = if (audio_cfg) |cfg| try audioTrack(&b, cfg) else AudioOffsets{};
        const mvex = try b.box("mvex");
        const trex = try b.full("trex", 0);
        try b.int32(1);
        try b.int32(1);
        try b.zero(12);
        b.end(trex);
        if (audio_cfg != null) {
            const audio_trex = try b.full("trex", 0);
            try b.int32(2);
            try b.int32(1);
            try b.int32(1024);
            try b.int32(0);
            try b.int32(0x02000000);
            b.end(audio_trex);
        }
        b.end(mvex);
        b.end(moov);
        try sink.write(sink.context, b.slice());
        return .{ .sink = sink, .audio_config = audio_cfg, .audio_offsets = offsets, .movie_duration = movie_duration, .video_duration = video_duration, .video_media_duration = video_media_duration };
    }
    /// One complete sample. Caller supplies its actual duration, using the next
    /// capture time; the last sample uses nominal frame duration. PTS == DTS.
    pub fn frame(s: *Writer, sample: []const u8, dts_us: u64, duration_us: u32, key: bool) !void {
        if (s.failed or s.finished) return error.WriterFailed;
        if (sample.len == 0 or sample.len > std.math.maxInt(u32) - 8 or duration_us == 0 or (s.frames != 0 and dts_us <= s.last_dts) or s.sequence == std.math.maxInt(u32)) return error.InvalidSample;
        var nals: Nals = .{ .data = sample };
        while (try nals.next()) |_| {}
        const end = try std.math.add(u64, dts_us, duration_us);
        try s.fragment(1, sample, dts_us, duration_us, key);
        s.frames += 1;
        s.last_dts = dts_us;
        s.video_end_us = end;
    }
    pub fn audio(s: *Writer, sample: []const u8) !void {
        if (s.audio_config == null or s.failed or s.finished) return error.WriterFailed;
        if (sample.len == 0 or sample.len > 8192 or s.sequence == std.math.maxInt(u32)) return error.InvalidSample;
        if (s.audio_pending_len != 0) try s.flushAudio(1024);
        @memcpy(s.audio_pending[0..sample.len], sample);
        s.audio_pending_len = sample.len;
    }
    fn flushAudio(s: *Writer, duration: u32) !void {
        if (s.audio_pending_len == 0) return;
        const time = try std.math.mul(u64, s.audio_packets, 1024);
        try s.fragment(2, s.audio_pending[0..s.audio_pending_len], time, duration, true);
        s.audio_pending_len = 0;
        s.audio_packets += 1;
    }
    /// Patch fixed metadata only after draining AAC. Decoder delay and tail
    /// padding stay in media samples; edit lists expose exactly the input PCM.
    pub fn finish(s: *Writer, audio_start_us: u64, presented_frames: u64) !void {
        if (s.failed or s.finished) return error.WriterFailed;
        const cfg = s.audio_config orelse return error.InvalidConfiguration;
        const encoded = try std.math.mul(u64, s.audio_packets + @intFromBool(s.audio_pending_len != 0), 1024);
        const valid_media = try std.math.add(u64, presented_frames, cfg.delay);
        if (encoded < valid_media or encoded - valid_media >= 1024) return error.InvalidSample;
        const padding = encoded - valid_media;
        const scaled = @as(u128, presented_frames) * 1000000 / cfg.sample_rate;
        if (scaled > std.math.maxInt(u64)) return error.InvalidSample;
        const duration: u64 = @intCast(scaled);
        const audio_end = try std.math.add(u64, audio_start_us, duration);
        errdefer s.failed = true;
        // A short final duration also signals tail trim to fragmented readers
        // that do not apply the finite edit duration to the last fragment.
        try s.flushAudio(@intCast(1024 - padding));
        try s.patch64(s.movie_duration, @max(s.video_end_us, audio_end));
        try s.patch64(s.video_duration, s.video_end_us);
        try s.patch64(s.video_media_duration, s.video_end_us);
        try s.patch64(s.audio_offsets.track, audio_end);
        try s.patch64(s.audio_offsets.media, valid_media);
        try s.patch64(s.audio_offsets.empty, audio_start_us);
        try s.patch64(s.audio_offsets.edit, duration);
        s.finished = true;
    }
    fn patch64(s: *Writer, offset: usize, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .big);
        try s.sink.patch.?(s.sink.context, offset, &bytes);
    }
    fn fragment(s: *Writer, track: u32, sample: []const u8, time: u64, duration: u32, key: bool) !void {
        if (s.failed or s.finished) return error.WriterFailed;
        if (s.sequence == std.math.maxInt(u32)) return error.InvalidSample;
        var b: Buffer = .{};
        const moof = try b.box("moof");
        const mfhd = try b.full("mfhd", 0);
        try b.int32(s.sequence);
        b.end(mfhd);
        const traf = try b.box("traf");
        const tfhd = try b.full("tfhd", 0x20000);
        try b.int32(track);
        b.end(tfhd);
        const tfdt = try b.full("tfdt", 0x1000000);
        try b.int64(time);
        b.end(tfdt);
        const trun = try b.full("trun", 0x701);
        try b.int32(1);
        const offset = b.len;
        try b.int32(0);
        try b.int32(duration);
        try b.int32(@intCast(sample.len));
        try b.int32(if (key) 0x02000000 else 0x01010000);
        b.end(trun);
        if (track == 2) {
            const sbgp = try b.full("sbgp", 0);
            try b.bytes("roll");
            try b.int32(1);
            try b.int32(1);
            try b.int32(1);
            b.end(sbgp);
        }
        b.end(traf);
        b.end(moof);
        std.mem.writeInt(u32, b.data[offset..][0..4], @intCast(b.len + 8), .big);
        try b.int32(@intCast(sample.len + 8));
        try b.bytes("mdat");
        errdefer s.failed = true;
        try s.sink.write(s.sink.context, b.slice());
        try s.sink.write(s.sink.context, sample);
        s.sequence += 1;
    }
};
test "NAL lengths reject truncation and empty units" {
    var n: Nals = .{ .data = &.{ 0, 0, 0, 2, 0x65 } };
    try std.testing.expectError(error.InvalidNal, n.next());
    n = .{ .data = &.{ 0, 0, 0, 0 } };
    try std.testing.expectError(error.InvalidNal, n.next());
}
test "fragment sizes, offsets and 64-bit time are exact; sink failure poisons writer" {
    const Out = struct {
        data: std.ArrayList(u8) = .empty,
        fail: bool = false,
        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.fail) return error.DiskFull;
            try s.data.appendSlice(std.testing.allocator, bytes);
        }
    };
    var out: Out = .{};
    defer out.data.deinit(std.testing.allocator);
    var writer: Writer = .{ .sink = .{ .context = &out, .write = Out.write } };
    try writer.frame(&.{ 0, 0, 0, 2, 0x65, 0x80 }, 0x100000000, 41667, true);
    const bytes = out.data.items;
    const size = std.mem.readInt(u32, bytes[0..4], .big);
    try std.testing.expectEqualStrings("moof", bytes[4..8]);
    try std.testing.expectEqual(@as(u32, 114), std.mem.readInt(u32, bytes[size..][0..4], .big) + size);
    try std.testing.expectEqual(@as(u64, 0x100000000), std.mem.readInt(u64, bytes[60..68], .big));
    try std.testing.expectEqual(size + 8, std.mem.readInt(u32, bytes[84..88], .big));
    try std.testing.expectError(error.InvalidSample, writer.frame(&.{ 0, 0, 0, 1, 1 }, 0x100000000, 1, false));
    out.fail = true;
    try std.testing.expectError(error.DiskFull, writer.frame(&.{ 0, 0, 0, 1, 1 }, 0x100000001, 1, false));
    try std.testing.expectError(error.WriterFailed, writer.frame(&.{ 0, 0, 0, 1, 1 }, 0x100000002, 1, false));
}

/// CodecPrivate for Matroska, without the enclosing avcC/hvcC box header.
pub fn codecPrivate(codec: Codec, headers: []const u8, destination: []u8) ![]const u8 {
    var b: Buffer = .{};
    try config(&b, codec, headers);
    const data = b.slice()[8..];
    if (destination.len < data.len) return error.HeaderTooLarge;
    @memcpy(destination[0..data.len], data);
    return destination[0..data.len];
}
test "Matroska CodecPrivate reuses checked config and respects destination bounds" {
    const headers = [_]u8{ 0, 0, 0, 4, 0x67, 100, 0, 40, 0, 0, 0, 2, 0x68, 0x80 };
    var destination: [128]u8 = undefined;
    const data = try codecPrivate(.h264, &headers, &destination);
    try std.testing.expectEqualSlices(u8, &.{ 1, 100, 0, 40, 255, 225 }, data[0..6]);
    try std.testing.expectError(error.HeaderTooLarge, codecPrivate(.h264, &headers, destination[0..1]));
    try std.testing.expectError(error.MissingParameterSets, codecPrivate(.h264, &.{}, &destination));
}
test "AAC track sample clock, edit delay/tail, fixed patches and sink failure" {
    const Out = struct {
        bytes: std.ArrayList(u8) = .empty,
        fail: bool = false,
        fn write(ctx: *anyopaque, data: []const u8) anyerror!void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            try s.bytes.appendSlice(std.testing.allocator, data);
        }
        fn patch(ctx: *anyopaque, offset: u64, data: []const u8) anyerror!void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.fail) return error.DiskFull;
            if (offset + data.len > s.bytes.items.len) return error.InvalidOffset;
            @memcpy(s.bytes.items[@intCast(offset)..][0..data.len], data);
        }
    };
    var out: Out = .{};
    defer out.bytes.deinit(std.testing.allocator);
    const headers = [_]u8{ 0, 0, 0, 4, 0x67, 100, 0, 40, 0, 0, 0, 2, 0x68, 0x80 };
    const cfg: AudioConfig = .{ .sample_rate = 48000, .channels = 2, .bitrate = 128000, .delay = 2048, .config = .{ 0x11, 0x90 } };
    const sink: Sink = .{ .context = &out, .write = Out.write, .patch = Out.patch };
    var writer = try Writer.initAv(sink, 128, 96, .h264, &headers, cfg);
    try std.testing.expect(std.mem.indexOf(u8, out.bytes.items, "mp4a") != null);
    try writer.frame(&.{ 0, 0, 0, 2, 0x65, 0x80 }, 0, 41667, true);
    try std.testing.expectError(error.InvalidSample, writer.finish(12345, 1000));
    for (0..3) |_| try writer.audio(&.{ 0x21, 0x10 });
    try writer.finish(12345, 1000);
    try std.testing.expectEqual(@as(u64, 12345), std.mem.readInt(u64, out.bytes.items[writer.audio_offsets.empty..][0..8], .big));
    try std.testing.expectEqual(@as(u64, 20833), std.mem.readInt(u64, out.bytes.items[writer.audio_offsets.edit..][0..8], .big));
    try std.testing.expectEqual(@as(u64, 2048), std.mem.readInt(u64, out.bytes.items[writer.audio_offsets.edit + 8 ..][0..8], .big));
    try std.testing.expectEqual(@as(u64, 3048), std.mem.readInt(u64, out.bytes.items[writer.audio_offsets.media..][0..8], .big));
    try std.testing.expectError(error.WriterFailed, writer.audio(&.{1}));
    var failure = try Writer.initAv(sink, 128, 96, .h264, &headers, cfg);
    try failure.audio(&.{ 0x21, 0x10 });
    try failure.audio(&.{ 0x21, 0x10 });
    out.fail = true;
    try std.testing.expectError(error.DiskFull, failure.finish(0, 0));
    try std.testing.expectError(error.WriterFailed, failure.audio(&.{1}));
}
