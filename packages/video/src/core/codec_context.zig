// Home Video Library - Codec Context
// Encoder/decoder state and configuration

const std = @import("std");
const types = @import("types.zig");
const frame = @import("frame.zig");
const packet = @import("packet.zig");

pub const VideoCodec = types.VideoCodec;
pub const AudioCodec = types.AudioCodec;
pub const PixelFormat = types.PixelFormat;
pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const ColorSpace = types.ColorSpace;
pub const ColorRange = types.ColorRange;
pub const Rational = types.Rational;
pub const QualityPreset = types.QualityPreset;
pub const VideoFrame = frame.VideoFrame;
pub const AudioFrame = frame.AudioFrame;
pub const Packet = packet.Packet;

/// Rate control mode
pub const RateControlMode = enum {
    cbr, // Constant bitrate
    vbr, // Variable bitrate
    crf, // Constant rate factor (quality-based)
    cqp, // Constant quantization parameter
};

/// Latency mode
pub const LatencyMode = enum {
    quality, // Optimized for quality (multi-pass analysis)
    balanced, // Balanced quality/speed
    realtime, // Optimized for realtime/low latency
};

/// GOP structure
pub const GOPStructure = struct {
    /// Keyframe interval (0 = only first frame, -1 = infinite)
    keyframe_interval: i32 = 250,

    /// Minimum GOP size
    min_gop_size: u32 = 12,

    /// Maximum B-frame count
    max_b_frames: u8 = 3,

    /// Reference frame count
    ref_frames: u8 = 3,

    /// Closed GOP (no frame references across keyframes)
    closed_gop: bool = true,
};

/// Video encoder configuration
pub const VideoEncoderConfig = struct {
    /// Codec to use
    codec: VideoCodec,

    /// Output dimensions
    width: u32,
    height: u32,

    /// Pixel format
    pixel_format: PixelFormat = .yuv420p,

    /// Frame rate
    frame_rate: Rational,

    /// Time base for timestamps
    time_base: Rational = Rational.TIME_BASE_US,

    /// Rate control
    rate_control: RateControlMode = .crf,
    bitrate: u32 = 0, // bits/second (for CBR/VBR)
    max_bitrate: u32 = 0, // for VBR
    crf: u8 = 23, // for CRF mode (0-51, lower = better)

    /// Quality preset
    quality: QualityPreset = .medium,

    /// GOP structure
    gop: GOPStructure = .{},

    /// Profile (codec-specific string)
    profile: ?[]const u8 = null,

    /// Level (codec-specific string)
    level: ?[]const u8 = null,

    /// Latency mode
    latency: LatencyMode = .balanced,

    /// Color properties
    color_space: ColorSpace = .bt709,
    color_range: ColorRange = .limited,

    /// Hardware acceleration hint
    use_hardware: bool = false,

    /// Number of encoding threads (0 = auto)
    threads: u8 = 0,
};

/// Audio encoder configuration
pub const AudioEncoderConfig = struct {
    /// Codec to use
    codec: AudioCodec,

    /// Sample rate
    sample_rate: u32,

    /// Number of channels
    channels: u8,

    /// Channel layout
    channel_layout: ChannelLayout,

    /// Sample format
    sample_format: SampleFormat = .f32le,

    /// Time base for timestamps
    time_base: Rational = Rational.TIME_BASE_US,

    /// Bitrate in bits/second
    bitrate: u32,

    /// Quality (codec-specific, typically 0.0-1.0)
    quality: f32 = 0.5,

    /// Profile (codec-specific string)
    profile: ?[]const u8 = null,
};

/// Video decoder configuration
pub const VideoDecoderConfig = struct {
    /// Codec to decode
    codec: VideoCodec,

    /// Expected dimensions (for validation)
    width: u32,
    height: u32,

    /// Extradata (SPS/PPS for H.264, etc.)
    extradata: ?[]const u8 = null,

    /// Hardware acceleration hint
    use_hardware: bool = false,

    /// Number of decoding threads (0 = auto)
    threads: u8 = 0,

    /// Output pixel format (null = use codec default)
    output_format: ?PixelFormat = null,
};

/// Audio decoder configuration
pub const AudioDecoderConfig = struct {
    /// Codec to decode
    codec: AudioCodec,

    /// Sample rate
    sample_rate: u32,

    /// Number of channels
    channels: u8,

    /// Extradata (AudioSpecificConfig for AAC, etc.)
    extradata: ?[]const u8 = null,

    /// Output sample format (null = use codec default)
    output_format: ?SampleFormat = null,
};

/// Video encoder context
pub const VideoEncoderContext = struct {
    config: VideoEncoderConfig,
    allocator: std.mem.Allocator,

    /// Frame counter
    frame_count: u64 = 0,

    /// Current sequence number
    sequence: u64 = 0,

    /// Internal encoder state (codec-specific)
    state: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: VideoEncoderConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Codec-specific cleanup
    }

    /// Encode a video frame to a packet
    pub fn encode(self: *Self, video_frame: *const VideoFrame) !Packet {
        _ = self;
        _ = video_frame;
        // Implementation delegated to codec-specific encoder
        return error.NotImplemented;
    }

    /// Flush buffered frames
    pub fn flush(self: *Self) !?Packet {
        _ = self;
        return null;
    }
};

/// Audio encoder context
pub const AudioEncoderContext = struct {
    config: AudioEncoderConfig,
    allocator: std.mem.Allocator,

    /// Sample counter
    sample_count: u64 = 0,

    /// Current sequence number
    sequence: u64 = 0,

    /// Internal encoder state (codec-specific)
    state: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: AudioEncoderConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Codec-specific cleanup
    }

    /// Encode an audio frame to a packet
    pub fn encode(self: *Self, audio_frame: *const AudioFrame) !Packet {
        _ = self;
        _ = audio_frame;
        // Implementation delegated to codec-specific encoder
        return error.NotImplemented;
    }

    /// Flush buffered samples
    pub fn flush(self: *Self) !?Packet {
        _ = self;
        return null;
    }
};

/// Video decoder context
pub const VideoDecoderContext = struct {
    config: VideoDecoderConfig,
    allocator: std.mem.Allocator,

    /// Frame counter
    frame_count: u64 = 0,

    /// Internal decoder state (codec-specific)
    state: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: VideoDecoderConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Codec-specific cleanup
    }

    /// Decode a packet to a video frame
    pub fn decode(self: *Self, pkt: *const Packet) !?VideoFrame {
        _ = self;
        _ = pkt;
        // Implementation delegated to codec-specific decoder
        return error.NotImplemented;
    }

    /// Flush decoder (return remaining frames)
    pub fn flush(self: *Self) !?VideoFrame {
        _ = self;
        return null;
    }
};

/// Audio decoder context
pub const AudioDecoderContext = struct {
    config: AudioDecoderConfig,
    allocator: std.mem.Allocator,

    /// Sample counter
    sample_count: u64 = 0,

    /// Internal decoder state (codec-specific)
    state: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: AudioDecoderConfig) Self {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Codec-specific cleanup
    }

    /// Decode a packet to an audio frame
    pub fn decode(self: *Self, pkt: *const Packet) !?AudioFrame {
        _ = self;
        _ = pkt;
        // Implementation delegated to codec-specific decoder
        return error.NotImplemented;
    }

    /// Flush decoder (return remaining samples)
    pub fn flush(self: *Self) !?AudioFrame {
        _ = self;
        return null;
    }
};

/// Codec capabilities
pub const CodecCapabilities = struct {
    /// Can encode
    can_encode: bool,

    /// Can decode
    can_decode: bool,

    /// Hardware acceleration available
    has_hardware_support: bool,

    /// Supported pixel formats (video)
    supported_pixel_formats: ?[]const PixelFormat = null,

    /// Supported sample formats (audio)
    supported_sample_formats: ?[]const SampleFormat = null,

    /// Maximum dimensions (video)
    max_width: ?u32 = null,
    max_height: ?u32 = null,

    /// Supported sample rates (audio)
    supported_sample_rates: ?[]const u32 = null,
};

/// Query codec capabilities
pub fn queryCodecCapabilities(video_codec: VideoCodec) CodecCapabilities {
    return switch (video_codec) {
        .h264 => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = true,
            .max_width = 8192,
            .max_height = 8192,
        },
        .hevc => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = true,
            .max_width = 8192,
            .max_height = 8192,
        },
        .vp8 => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = false,
            .max_width = 16383,
            .max_height = 16383,
        },
        .vp9 => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = true,
            .max_width = 65535,
            .max_height = 65535,
        },
        .av1 => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = true,
            .max_width = 65536,
            .max_height = 65536,
        },
        .mjpeg => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = false,
            .max_width = null,
            .max_height = null,
        },
        .prores => .{
            .can_encode = false,
            .can_decode = true,
            .has_hardware_support = true,
            .max_width = null,
            .max_height = null,
        },
        else => .{
            .can_encode = false,
            .can_decode = false,
            .has_hardware_support = false,
        },
    };
}

/// Query audio codec capabilities
pub fn queryAudioCodecCapabilities(audio_codec: AudioCodec) CodecCapabilities {
    return switch (audio_codec) {
        .aac => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = false,
        },
        .mp3 => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = false,
        },
        .opus => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = false,
        },
        .vorbis => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = false,
        },
        .flac => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = false,
        },
        .ac3 => .{
            .can_encode = true,
            .can_decode = true,
            .has_hardware_support = false,
        },
        .dts => .{
            .can_encode = false,
            .can_decode = true,
            .has_hardware_support = false,
        },
        else => .{
            .can_encode = false,
            .can_decode = false,
            .has_hardware_support = false,
        },
    };
}
