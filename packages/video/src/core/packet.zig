// Home Video Library - Packet and Stream Types
// Encoded data packets and stream abstractions

const std = @import("std");
const types = @import("types.zig");

pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const Rational = types.Rational;
pub const VideoCodec = types.VideoCodec;
pub const AudioCodec = types.AudioCodec;
pub const PixelFormat = types.PixelFormat;
pub const SampleFormat = types.SampleFormat;
pub const ColorSpace = types.ColorSpace;
pub const ColorRange = types.ColorRange;
pub const ChannelLayout = types.ChannelLayout;

// ============================================================================
// Packet - Encoded compressed data
// ============================================================================

pub const PacketType = enum {
    video,
    audio,
    subtitle,
    data, // Metadata, chapter markers, etc.
};

pub const PacketFlags = packed struct {
    is_key_frame: bool = false,
    is_corrupt: bool = false,
    is_discard: bool = false, // Can be dropped (B-frame)
    is_disposable: bool = false,
    _padding: u4 = 0,
};

pub const Packet = struct {
    /// Packet type
    packet_type: PacketType,

    /// Stream index this packet belongs to
    stream_index: u32,

    /// Encoded data
    data: []u8,

    /// Presentation timestamp (when to display)
    pts: Timestamp,

    /// Decode timestamp (when to decode, may differ due to B-frames)
    dts: Timestamp,

    /// Duration of this packet
    duration: Duration,

    /// Packet flags
    flags: PacketFlags,

    /// Position in the source file (for seeking)
    file_position: ?u64,

    /// Sequence number for ordering
    sequence: u64,

    /// Memory allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new packet with allocated data
    pub fn init(
        allocator: std.mem.Allocator,
        packet_type: PacketType,
        data_size: usize,
    ) !Self {
        const data = try allocator.alloc(u8, data_size);

        return Self{
            .packet_type = packet_type,
            .stream_index = 0,
            .data = data,
            .pts = Timestamp.INVALID,
            .dts = Timestamp.INVALID,
            .duration = Duration.ZERO,
            .flags = .{},
            .file_position = null,
            .sequence = 0,
            .allocator = allocator,
        };
    }

    /// Create from existing data (copies data)
    pub fn fromData(
        allocator: std.mem.Allocator,
        packet_type: PacketType,
        data: []const u8,
    ) !Self {
        const owned_data = try allocator.alloc(u8, data.len);
        @memcpy(owned_data, data);

        return Self{
            .packet_type = packet_type,
            .stream_index = 0,
            .data = owned_data,
            .pts = Timestamp.INVALID,
            .dts = Timestamp.INVALID,
            .duration = Duration.ZERO,
            .flags = .{},
            .file_position = null,
            .sequence = 0,
            .allocator = allocator,
        };
    }

    /// Create from existing data (takes ownership)
    pub fn fromOwnedData(
        allocator: std.mem.Allocator,
        packet_type: PacketType,
        data: []u8,
    ) Self {
        return Self{
            .packet_type = packet_type,
            .stream_index = 0,
            .data = data,
            .pts = Timestamp.INVALID,
            .dts = Timestamp.INVALID,
            .duration = Duration.ZERO,
            .flags = .{},
            .file_position = null,
            .sequence = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Clone this packet
    pub fn clone(self: *const Self) !Self {
        const new_data = try self.allocator.alloc(u8, self.data.len);
        @memcpy(new_data, self.data);

        var pkt = self.*;
        pkt.data = new_data;
        return pkt;
    }

    /// Get the effective timestamp (PTS if valid, else DTS)
    pub fn getTimestamp(self: *const Self) Timestamp {
        if (self.pts.isValid()) return self.pts;
        return self.dts;
    }

    /// Is this a keyframe?
    pub fn isKeyFrame(self: *const Self) bool {
        return self.flags.is_key_frame;
    }

    /// Size in bytes
    pub fn size(self: *const Self) usize {
        return self.data.len;
    }
};

// ============================================================================
// Stream - Track within a container
// ============================================================================

pub const StreamType = enum {
    video,
    audio,
    subtitle,
    data,
    attachment,
};

pub const StreamDisposition = packed struct {
    is_default: bool = false,
    is_forced: bool = false,
    is_hearing_impaired: bool = false,
    is_visual_impaired: bool = false,
    is_clean_effects: bool = false,
    is_attached_pic: bool = false,
    is_captions: bool = false,
    is_descriptions: bool = false,
    is_metadata: bool = false,
    is_original: bool = false,
    is_dub: bool = false,
    is_comment: bool = false,
    is_lyrics: bool = false,
    is_karaoke: bool = false,
    _padding: u2 = 0,
};

pub const VideoStreamInfo = struct {
    /// Codec
    codec: VideoCodec,

    /// Coded dimensions (may differ from display)
    coded_width: u32,
    coded_height: u32,

    /// Display dimensions (after SAR/crop)
    display_width: u32,
    display_height: u32,

    /// Pixel format
    pixel_format: PixelFormat,

    /// Frame rate
    frame_rate: Rational,

    /// Average frame rate (for VFR content)
    avg_frame_rate: Rational,

    /// Time base for timestamps
    time_base: Rational,

    /// Color properties
    color_space: ColorSpace,
    color_range: ColorRange,

    /// Rotation in degrees
    rotation: u16,

    /// Sample aspect ratio (pixel shape)
    sample_aspect_ratio: Rational,

    /// Codec-specific data (SPS/PPS for H.264, etc.)
    extradata: ?[]const u8,

    /// Bit depth
    bit_depth: u8,

    /// Number of B-frames in GOP
    b_frame_count: u8,

    /// Has B-frames (affects decode ordering)
    has_b_frames: bool,

    /// Profile (codec-specific)
    profile: ?[]const u8,

    /// Level (codec-specific)
    level: ?[]const u8,

    pub fn getCodecString(self: *const VideoStreamInfo) []const u8 {
        // Generate codec string like "avc1.64001f"
        return switch (self.codec) {
            .h264 => "avc1",
            .hevc => "hvc1",
            .vp9 => "vp09",
            .av1 => "av01",
            else => "unknown",
        };
    }
};

pub const AudioStreamInfo = struct {
    /// Codec
    codec: AudioCodec,

    /// Sample rate in Hz
    sample_rate: u32,

    /// Number of channels
    channels: u8,

    /// Channel layout
    channel_layout: ChannelLayout,

    /// Sample format
    sample_format: SampleFormat,

    /// Time base for timestamps
    time_base: Rational,

    /// Bit depth
    bit_depth: u8,

    /// Bitrate in bits/second (0 if variable/unknown)
    bitrate: u32,

    /// Codec-specific data (AudioSpecificConfig for AAC, etc.)
    extradata: ?[]const u8,

    /// Profile (codec-specific)
    profile: ?[]const u8,
};

pub const SubtitleStreamInfo = struct {
    /// Codec name (webvtt, srt, ass, etc.)
    codec: []const u8,

    /// Time base for timestamps
    time_base: Rational,
};

pub const StreamInfo = union(StreamType) {
    video: VideoStreamInfo,
    audio: AudioStreamInfo,
    subtitle: SubtitleStreamInfo,
    data: void,
    attachment: void,
};

pub const Stream = struct {
    /// Stream index in the container
    index: u32,

    /// Stream type
    stream_type: StreamType,

    /// Stream-specific info
    info: StreamInfo,

    /// Language code (ISO 639-2/T, e.g., "eng", "spa")
    language: ?[3]u8,

    /// Track title/name
    title: ?[]const u8,

    /// Disposition flags
    disposition: StreamDisposition,

    /// Duration of the stream
    duration: Duration,

    /// Number of frames (video) or samples (audio)
    frame_count: ?u64,

    /// Bitrate in bits/second
    bitrate: ?u32,

    /// Start time (may be non-zero)
    start_time: Timestamp,

    /// Codec delay (number of samples to skip at start)
    codec_delay: u32,

    const Self = @This();

    /// Get video info (if this is a video stream)
    pub fn videoInfo(self: *const Self) ?*const VideoStreamInfo {
        return switch (self.info) {
            .video => |*v| v,
            else => null,
        };
    }

    /// Get audio info (if this is an audio stream)
    pub fn audioInfo(self: *const Self) ?*const AudioStreamInfo {
        return switch (self.info) {
            .audio => |*a| a,
            else => null,
        };
    }

    /// Is this a video stream?
    pub fn isVideo(self: *const Self) bool {
        return self.stream_type == .video;
    }

    /// Is this an audio stream?
    pub fn isAudio(self: *const Self) bool {
        return self.stream_type == .audio;
    }

    /// Is this a subtitle stream?
    pub fn isSubtitle(self: *const Self) bool {
        return self.stream_type == .subtitle;
    }

    /// Get the time base
    pub fn getTimeBase(self: *const Self) Rational {
        return switch (self.info) {
            .video => |v| v.time_base,
            .audio => |a| a.time_base,
            .subtitle => |s| s.time_base,
            else => Rational.TIME_BASE_US,
        };
    }

    /// Get MIME type with codec string
    pub fn getMimeType(self: *const Self) []const u8 {
        return switch (self.info) {
            .video => |v| switch (v.codec) {
                .h264 => "video/mp4; codecs=\"avc1.64001f\"",
                .hevc => "video/mp4; codecs=\"hvc1.1.6.L93.B0\"",
                .vp9 => "video/webm; codecs=\"vp09.00.10.08\"",
                .av1 => "video/mp4; codecs=\"av01.0.04M.08\"",
                else => "video/mp4",
            },
            .audio => |a| switch (a.codec) {
                .aac => "audio/mp4; codecs=\"mp4a.40.2\"",
                .mp3 => "audio/mpeg",
                .opus => "audio/webm; codecs=\"opus\"",
                .vorbis => "audio/ogg; codecs=\"vorbis\"",
                .flac => "audio/flac",
                else => "audio/mp4",
            },
            else => "application/octet-stream",
        };
    }
};

// ============================================================================
// MediaFile - Container holding streams
// ============================================================================

pub const MediaFile = struct {
    /// All streams in this file
    streams: []Stream,

    /// Total duration
    duration: Duration,

    /// Overall bitrate
    bitrate: ?u32,

    /// Container format name
    format_name: []const u8,

    /// MIME type
    mime_type: []const u8,

    /// Is seekable?
    is_seekable: bool,

    /// Is live/streaming?
    is_live: bool,

    /// Start time (may be non-zero)
    start_time: Timestamp,

    /// File size in bytes (null for streams)
    file_size: ?u64,

    /// Allocator for cleanup
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        for (self.streams) |*stream| {
            if (stream.title) |title| {
                self.allocator.free(title);
            }
        }
        self.allocator.free(self.streams);
    }

    /// Get the primary video stream (first video or default)
    pub fn getPrimaryVideoStream(self: *const Self) ?*const Stream {
        var first_video: ?*const Stream = null;

        for (self.streams) |*stream| {
            if (stream.stream_type == .video) {
                if (stream.disposition.is_default) return stream;
                if (first_video == null) first_video = stream;
            }
        }

        return first_video;
    }

    /// Get the primary audio stream (first audio or default)
    pub fn getPrimaryAudioStream(self: *const Self) ?*const Stream {
        var first_audio: ?*const Stream = null;

        for (self.streams) |*stream| {
            if (stream.stream_type == .audio) {
                if (stream.disposition.is_default) return stream;
                if (first_audio == null) first_audio = stream;
            }
        }

        return first_audio;
    }

    /// Get all video streams
    pub fn getVideoStreams(self: *const Self, allocator: std.mem.Allocator) ![]const *const Stream {
        var count: usize = 0;
        for (self.streams) |*stream| {
            if (stream.stream_type == .video) count += 1;
        }

        const result = try allocator.alloc(*const Stream, count);
        var idx: usize = 0;
        for (self.streams) |*stream| {
            if (stream.stream_type == .video) {
                result[idx] = stream;
                idx += 1;
            }
        }

        return result;
    }

    /// Get all audio streams
    pub fn getAudioStreams(self: *const Self, allocator: std.mem.Allocator) ![]const *const Stream {
        var count: usize = 0;
        for (self.streams) |*stream| {
            if (stream.stream_type == .audio) count += 1;
        }

        const result = try allocator.alloc(*const Stream, count);
        var idx: usize = 0;
        for (self.streams) |*stream| {
            if (stream.stream_type == .audio) {
                result[idx] = stream;
                idx += 1;
            }
        }

        return result;
    }

    /// Get stream by index
    pub fn getStream(self: *const Self, index: u32) ?*const Stream {
        for (self.streams) |*stream| {
            if (stream.index == index) return stream;
        }
        return null;
    }

    /// Check if file has video
    pub fn hasVideo(self: *const Self) bool {
        for (self.streams) |stream| {
            if (stream.stream_type == .video) return true;
        }
        return false;
    }

    /// Check if file has audio
    pub fn hasAudio(self: *const Self) bool {
        for (self.streams) |stream| {
            if (stream.stream_type == .audio) return true;
        }
        return false;
    }

    /// Get total number of video streams
    pub fn videoStreamCount(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.streams) |stream| {
            if (stream.stream_type == .video) count += 1;
        }
        return count;
    }

    /// Get total number of audio streams
    pub fn audioStreamCount(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.streams) |stream| {
            if (stream.stream_type == .audio) count += 1;
        }
        return count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Packet creation" {
    var pkt = try Packet.init(std.testing.allocator, .video, 1024);
    defer pkt.deinit();

    try std.testing.expectEqual(@as(usize, 1024), pkt.size());
    try std.testing.expectEqual(PacketType.video, pkt.packet_type);
}

test "Packet flags" {
    var pkt = try Packet.init(std.testing.allocator, .video, 100);
    defer pkt.deinit();

    pkt.flags.is_key_frame = true;
    try std.testing.expect(pkt.isKeyFrame());
}

test "Packet timestamp" {
    var pkt = try Packet.init(std.testing.allocator, .audio, 100);
    defer pkt.deinit();

    pkt.pts = Timestamp.fromSeconds(1.5);
    pkt.dts = Timestamp.fromSeconds(1.4);

    try std.testing.expectApproxEqAbs(@as(f64, 1.5), pkt.getTimestamp().toSeconds(), 0.001);
}
