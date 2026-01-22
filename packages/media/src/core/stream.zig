// Home Media Library - Stream Abstraction
// Unified stream handling for media input/output

const std = @import("std");
const types = @import("types.zig");
const err = @import("error.zig");

const MediaType = types.MediaType;
const VideoCodec = types.VideoCodec;
const AudioCodec = types.AudioCodec;
const Timestamp = types.Timestamp;
const Duration = types.Duration;
const Rational = types.Rational;
const MediaError = err.MediaError;

// ============================================================================
// Stream Types
// ============================================================================

pub const StreamType = enum {
    video,
    audio,
    subtitle,
    attachment,
    data,
    unknown,
};

// ============================================================================
// Stream Information
// ============================================================================

pub const StreamInfo = struct {
    index: u32 = 0,
    stream_type: StreamType = .unknown,
    codec_name: ?[]const u8 = null,
    duration: Duration = Duration.ZERO,
    start_time: Timestamp = Timestamp.ZERO,
    bitrate: u32 = 0,
    language: ?[]const u8 = null,
    title: ?[]const u8 = null,
    is_default: bool = false,
    is_forced: bool = false,

    // Video-specific
    video: ?VideoStreamInfo = null,

    // Audio-specific
    audio: ?AudioStreamInfo = null,

    // Subtitle-specific
    subtitle: ?SubtitleStreamInfo = null,
};

pub const VideoStreamInfo = struct {
    codec: VideoCodec = .unknown,
    width: u32 = 0,
    height: u32 = 0,
    frame_rate: Rational = Rational.ZERO,
    pixel_format: ?[]const u8 = null,
    color_space: ?[]const u8 = null,
    color_range: ?[]const u8 = null,
    color_primaries: ?[]const u8 = null,
    color_transfer: ?[]const u8 = null,
    display_aspect_ratio: Rational = Rational.ZERO,
    sample_aspect_ratio: Rational = Rational.ONE,
    bit_depth: u8 = 8,
    is_interlaced: bool = false,
    has_b_frames: bool = false,
    profile: ?[]const u8 = null,
    level: ?[]const u8 = null,
    hdr_format: ?[]const u8 = null,
};

pub const AudioStreamInfo = struct {
    codec: AudioCodec = .unknown,
    sample_rate: u32 = 0,
    channels: u8 = 0,
    channel_layout: ?[]const u8 = null,
    sample_format: ?[]const u8 = null,
    bit_depth: u8 = 16,
    frame_size: u32 = 0,
};

pub const SubtitleStreamInfo = struct {
    format: []const u8 = "",
    is_text_based: bool = true,
    is_bitmap_based: bool = false,
};

// ============================================================================
// Media Stream
// ============================================================================

pub const MediaStream = struct {
    allocator: std.mem.Allocator,
    info: StreamInfo,
    packets: std.ArrayList(Packet),
    frames: std.ArrayList(Frame),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, stream_type: StreamType) Self {
        return .{
            .allocator = allocator,
            .info = .{ .stream_type = stream_type },
            .packets = std.ArrayList(Packet).init(allocator),
            .frames = std.ArrayList(Frame).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.packets.items) |*packet| {
            packet.deinit(self.allocator);
        }
        self.packets.deinit();

        for (self.frames.items) |*frame| {
            frame.deinit(self.allocator);
        }
        self.frames.deinit();
    }

    pub fn addPacket(self: *Self, packet: Packet) !void {
        try self.packets.append(packet);
    }

    pub fn addFrame(self: *Self, frame: Frame) !void {
        try self.frames.append(frame);
    }
};

// ============================================================================
// Packet
// ============================================================================

pub const Packet = struct {
    data: []u8,
    pts: Timestamp = Timestamp.ZERO,
    dts: Timestamp = Timestamp.ZERO,
    duration: Duration = Duration.ZERO,
    stream_index: u32 = 0,
    flags: PacketFlags = .{},
    pos: i64 = -1, // Position in file

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
        return .{
            .data = try allocator.alloc(u8, size),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
        var new = Self{
            .data = try allocator.alloc(u8, self.data.len),
            .pts = self.pts,
            .dts = self.dts,
            .duration = self.duration,
            .stream_index = self.stream_index,
            .flags = self.flags,
            .pos = self.pos,
        };
        @memcpy(new.data, self.data);
        return new;
    }
};

pub const PacketFlags = packed struct {
    keyframe: bool = false,
    corrupt: bool = false,
    discard: bool = false,
    trusted: bool = false,
    disposable: bool = false,
    _padding: u3 = 0,
};

// ============================================================================
// Frame
// ============================================================================

pub const Frame = struct {
    data: [][]u8, // Plane data
    linesize: []u32, // Bytes per line for each plane
    width: u32 = 0,
    height: u32 = 0,
    format: FrameFormat = .unknown,
    pts: Timestamp = Timestamp.ZERO,
    duration: Duration = Duration.ZERO,
    flags: FrameFlags = .{},

    // Audio-specific
    num_samples: u32 = 0,
    sample_rate: u32 = 0,
    channels: u8 = 0,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn initVideo(allocator: std.mem.Allocator, width: u32, height: u32, format: FrameFormat) !Self {
        const plane_count = format.planeCount();
        const data = try allocator.alloc([]u8, plane_count);
        const linesize = try allocator.alloc(u32, plane_count);

        // Calculate plane sizes and allocate
        for (0..plane_count) |i| {
            const plane_width = if (i > 0 and format.isYuv()) width / 2 else width;
            const plane_height = if (i > 0 and format.isYuv()) height / 2 else height;
            const bytes_per_pixel = format.bytesPerPixel(i);
            linesize[i] = plane_width * bytes_per_pixel;
            data[i] = try allocator.alloc(u8, linesize[i] * plane_height);
        }

        return .{
            .data = data,
            .linesize = linesize,
            .width = width,
            .height = height,
            .format = format,
            .allocator = allocator,
        };
    }

    pub fn initAudio(allocator: std.mem.Allocator, num_samples: u32, channels: u8, format: FrameFormat) !Self {
        const plane_count = if (format.isPlanar()) channels else 1;
        const data = try allocator.alloc([]u8, plane_count);
        const linesize = try allocator.alloc(u32, plane_count);

        const bytes_per_sample = format.bytesPerSample();
        const samples_per_plane = if (format.isPlanar()) num_samples else num_samples * channels;

        for (0..plane_count) |i| {
            linesize[i] = samples_per_plane * bytes_per_sample;
            data[i] = try allocator.alloc(u8, linesize[i]);
        }

        return .{
            .data = data,
            .linesize = linesize,
            .format = format,
            .num_samples = num_samples,
            .channels = channels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.data) |plane| {
            allocator.free(plane);
        }
        allocator.free(self.data);
        allocator.free(self.linesize);
    }
};

pub const FrameFlags = packed struct {
    keyframe: bool = false,
    corrupt: bool = false,
    interlaced: bool = false,
    top_field_first: bool = false,
    _padding: u4 = 0,
};

pub const FrameFormat = enum {
    // Video formats
    unknown,
    yuv420p,
    yuv422p,
    yuv444p,
    yuv420p10le,
    yuv422p10le,
    yuv444p10le,
    nv12,
    nv21,
    rgb24,
    bgr24,
    rgba,
    bgra,
    gray8,
    gray16le,

    // Audio formats
    s16,
    s16p,
    s32,
    s32p,
    flt,
    fltp,
    dbl,
    dblp,
    u8_,
    u8p,

    pub fn planeCount(self: FrameFormat) usize {
        return switch (self) {
            .yuv420p, .yuv422p, .yuv444p, .yuv420p10le, .yuv422p10le, .yuv444p10le => 3,
            .nv12, .nv21 => 2,
            .rgb24, .bgr24, .rgba, .bgra, .gray8, .gray16le => 1,
            .s16p, .s32p, .fltp, .dblp, .u8p => 8, // Max channels
            else => 1,
        };
    }

    pub fn bytesPerPixel(self: FrameFormat, plane: usize) u32 {
        return switch (self) {
            .yuv420p, .yuv422p, .yuv444p, .gray8, .nv12, .nv21 => 1,
            .yuv420p10le, .yuv422p10le, .yuv444p10le, .gray16le => 2,
            .rgb24, .bgr24 => 3,
            .rgba, .bgra => 4,
            else => if (plane == 0) 1 else 0,
        };
    }

    pub fn bytesPerSample(self: FrameFormat) u32 {
        return switch (self) {
            .u8_, .u8p => 1,
            .s16, .s16p => 2,
            .s32, .s32p, .flt, .fltp => 4,
            .dbl, .dblp => 8,
            else => 0,
        };
    }

    pub fn isYuv(self: FrameFormat) bool {
        return switch (self) {
            .yuv420p, .yuv422p, .yuv444p, .yuv420p10le, .yuv422p10le, .yuv444p10le, .nv12, .nv21 => true,
            else => false,
        };
    }

    pub fn isPlanar(self: FrameFormat) bool {
        return switch (self) {
            .yuv420p, .yuv422p, .yuv444p, .yuv420p10le, .yuv422p10le, .yuv444p10le,
            .s16p, .s32p, .fltp, .dblp, .u8p,
            => true,
            else => false,
        };
    }
};

// ============================================================================
// Stream Source (Input)
// ============================================================================

pub const StreamSource = struct {
    allocator: std.mem.Allocator,
    streams: std.ArrayList(MediaStream),
    path: ?[]const u8 = null,
    is_open: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .streams = std.ArrayList(MediaStream).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.streams.items) |*stream| {
            stream.deinit();
        }
        self.streams.deinit();

        if (self.path) |p| {
            self.allocator.free(p);
        }
    }

    pub fn open(self: *Self, path: []const u8) !void {
        self.path = try self.allocator.dupe(u8, path);
        self.is_open = true;
    }

    pub fn close(self: *Self) void {
        self.is_open = false;
    }

    pub fn getStream(self: *Self, index: usize) ?*MediaStream {
        if (index >= self.streams.items.len) return null;
        return &self.streams.items[index];
    }

    pub fn findStream(self: *Self, stream_type: StreamType) ?*MediaStream {
        for (self.streams.items) |*stream| {
            if (stream.info.stream_type == stream_type) {
                return stream;
            }
        }
        return null;
    }
};

// ============================================================================
// Stream Sink (Output)
// ============================================================================

pub const StreamSink = struct {
    allocator: std.mem.Allocator,
    streams: std.ArrayList(MediaStream),
    path: ?[]const u8 = null,
    is_open: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .streams = std.ArrayList(MediaStream).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.streams.items) |*stream| {
            stream.deinit();
        }
        self.streams.deinit();

        if (self.path) |p| {
            self.allocator.free(p);
        }
    }

    pub fn open(self: *Self, path: []const u8) !void {
        self.path = try self.allocator.dupe(u8, path);
        self.is_open = true;
    }

    pub fn close(self: *Self) void {
        self.is_open = false;
    }

    pub fn addStream(self: *Self, stream_type: StreamType) !*MediaStream {
        var stream = MediaStream.init(self.allocator, stream_type);
        stream.info.index = @intCast(self.streams.items.len);
        try self.streams.append(stream);
        return &self.streams.items[self.streams.items.len - 1];
    }

    pub fn writePacket(self: *Self, packet: *const Packet) !void {
        if (!self.is_open) return MediaError.PipelineNotReady;
        if (packet.stream_index >= self.streams.items.len) return MediaError.InvalidArgument;

        var stream = &self.streams.items[packet.stream_index];
        const cloned = try packet.clone(self.allocator);
        try stream.addPacket(cloned);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StreamInfo initialization" {
    const info = StreamInfo{
        .index = 0,
        .stream_type = .video,
    };
    try std.testing.expectEqual(StreamType.video, info.stream_type);
}

test "FrameFormat properties" {
    try std.testing.expectEqual(@as(usize, 3), FrameFormat.yuv420p.planeCount());
    try std.testing.expect(FrameFormat.yuv420p.isYuv());
    try std.testing.expect(FrameFormat.yuv420p.isPlanar());
    try std.testing.expect(!FrameFormat.rgba.isYuv());
    try std.testing.expect(!FrameFormat.rgba.isPlanar());
}

test "MediaStream creation" {
    const allocator = std.testing.allocator;
    var stream = MediaStream.init(allocator, .video);
    defer stream.deinit();

    try std.testing.expectEqual(StreamType.video, stream.info.stream_type);
}
