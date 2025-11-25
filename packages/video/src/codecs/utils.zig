// Home Video Library - Codec Utilities
// Capability queries, codec selection, and parameter string generation

const std = @import("std");
const core = @import("../core.zig");

// ============================================================================
// Codec Capabilities
// ============================================================================

pub const CodecType = enum {
    video,
    audio,
    subtitle,
};

pub const CodecCapabilities = struct {
    /// Can this codec encode
    can_encode: bool,

    /// Can this codec decode
    can_decode: bool,

    /// Is this codec lossy
    is_lossy: bool,

    /// Codec type
    codec_type: CodecType,

    /// Supported pixel formats (video only)
    pixel_formats: []const core.PixelFormat = &.{},

    /// Supported sample formats (audio only)
    sample_formats: []const core.SampleFormat = &.{},

    /// Supported sample rates (audio only)
    sample_rates: []const u32 = &.{},

    /// Maximum supported width (video only)
    max_width: u32 = 8192,

    /// Maximum supported height (video only)
    max_height: u32 = 8192,

    /// Supports variable frame rate
    supports_vfr: bool = true,

    /// Supports B-frames (video only)
    supports_bframes: bool = true,

    /// Supports alpha channel (video only)
    supports_alpha: bool = false,

    /// Hardware acceleration available
    hardware_available: bool = false,
};

/// Video codec identifier
pub const VideoCodec = enum {
    h264,
    hevc,
    vp8,
    vp9,
    av1,
    mpeg2,
    mpeg4,
    mjpeg,
    prores,
    theora,
    raw,

    pub fn getName(self: VideoCodec) []const u8 {
        return switch (self) {
            .h264 => "H.264/AVC",
            .hevc => "H.265/HEVC",
            .vp8 => "VP8",
            .vp9 => "VP9",
            .av1 => "AV1",
            .mpeg2 => "MPEG-2",
            .mpeg4 => "MPEG-4 Part 2",
            .mjpeg => "Motion JPEG",
            .prores => "Apple ProRes",
            .theora => "Theora",
            .raw => "Raw Video",
        };
    }

    pub fn getFourCC(self: VideoCodec) []const u8 {
        return switch (self) {
            .h264 => "avc1",
            .hevc => "hvc1",
            .vp8 => "VP80",
            .vp9 => "VP90",
            .av1 => "av01",
            .mpeg2 => "mp4v",
            .mpeg4 => "mp4v",
            .mjpeg => "mjpg",
            .prores => "apch",
            .theora => "theo",
            .raw => "raw ",
        };
    }

    pub fn getCapabilities(self: VideoCodec) CodecCapabilities {
        return switch (self) {
            .h264 => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .video,
                .pixel_formats = &.{ .yuv420p, .yuv422p, .yuv444p, .nv12 },
                .supports_bframes = true,
                .hardware_available = true,
            },
            .hevc => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .video,
                .pixel_formats = &.{ .yuv420p, .yuv422p, .yuv444p, .yuv420p10le },
                .supports_bframes = true,
                .hardware_available = true,
            },
            .vp8 => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .video,
                .pixel_formats = &.{.yuv420p},
                .supports_bframes = false,
            },
            .vp9 => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .video,
                .pixel_formats = &.{ .yuv420p, .yuv422p, .yuv444p, .yuv420p10le },
                .supports_alpha = true,
                .supports_bframes = false,
            },
            .av1 => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .video,
                .pixel_formats = &.{ .yuv420p, .yuv422p, .yuv444p, .yuv420p10le, .yuv420p12le },
                .supports_bframes = false,
                .hardware_available = true,
            },
            .prores => .{
                .can_encode = false, // Decode only in this implementation
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .video,
                .pixel_formats = &.{ .yuv422p10le, .yuv444p10le },
                .supports_alpha = true,
                .supports_bframes = false,
            },
            .raw => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = false,
                .codec_type = .video,
                .pixel_formats = &.{ .yuv420p, .yuv422p, .yuv444p, .rgb24, .rgba },
                .supports_bframes = false,
            },
            else => .{
                .can_encode = false,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .video,
                .pixel_formats = &.{.yuv420p},
            },
        };
    }

    /// Check if codec can encode
    pub fn canEncode(self: VideoCodec) bool {
        return self.getCapabilities().can_encode;
    }

    /// Check if codec can decode
    pub fn canDecode(self: VideoCodec) bool {
        return self.getCapabilities().can_decode;
    }

    /// Check if hardware acceleration is available
    pub fn hasHardwareAcceleration(self: VideoCodec) bool {
        return self.getCapabilities().hardware_available;
    }
};

/// Audio codec identifier
pub const AudioCodec = enum {
    aac,
    mp3,
    opus,
    vorbis,
    flac,
    ac3,
    eac3,
    dts,
    pcm_s16le,
    pcm_s24le,
    pcm_s32le,
    pcm_f32le,

    pub fn getName(self: AudioCodec) []const u8 {
        return switch (self) {
            .aac => "AAC",
            .mp3 => "MP3",
            .opus => "Opus",
            .vorbis => "Vorbis",
            .flac => "FLAC",
            .ac3 => "AC-3",
            .eac3 => "E-AC-3",
            .dts => "DTS",
            .pcm_s16le => "PCM signed 16-bit LE",
            .pcm_s24le => "PCM signed 24-bit LE",
            .pcm_s32le => "PCM signed 32-bit LE",
            .pcm_f32le => "PCM float 32-bit LE",
        };
    }

    pub fn getCapabilities(self: AudioCodec) CodecCapabilities {
        return switch (self) {
            .aac => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .audio,
                .sample_formats = &.{ .s16, .fltp },
                .sample_rates = &.{ 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000 },
            },
            .mp3 => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .audio,
                .sample_formats = &.{ .s16, .s32, .fltp },
                .sample_rates = &.{ 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000 },
            },
            .opus => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .audio,
                .sample_formats = &.{.fltp},
                .sample_rates = &.{ 8000, 12000, 16000, 24000, 48000 },
            },
            .vorbis => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .audio,
                .sample_formats = &.{.fltp},
                .sample_rates = &.{ 8000, 11025, 16000, 22050, 32000, 44100, 48000 },
            },
            .flac => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = false,
                .codec_type = .audio,
                .sample_formats = &.{ .s16, .s32 },
                .sample_rates = &.{ 8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000 },
            },
            .pcm_s16le, .pcm_s24le, .pcm_s32le, .pcm_f32le => .{
                .can_encode = true,
                .can_decode = true,
                .is_lossy = false,
                .codec_type = .audio,
                .sample_formats = &.{ .s16, .s24, .s32, .fltp },
                .sample_rates = &.{ 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000 },
            },
            else => .{
                .can_encode = false,
                .can_decode = true,
                .is_lossy = true,
                .codec_type = .audio,
                .sample_formats = &.{.fltp},
            },
        };
    }

    pub fn canEncode(self: AudioCodec) bool {
        return self.getCapabilities().can_encode;
    }

    pub fn canDecode(self: AudioCodec) bool {
        return self.getCapabilities().can_decode;
    }
};

// ============================================================================
// Codec Selection
// ============================================================================

/// Select best video codec for a given container format
pub fn selectBestVideoCodec(format: core.VideoFormat) VideoCodec {
    return switch (format) {
        .mp4, .mov => .h264,
        .webm => .vp9,
        .mkv => .hevc, // Prefer HEVC for MKV (better compression)
        .avi => .mpeg4,
        .gif => .raw, // GIF handles its own encoding
        .unknown => .h264, // Default
    };
}

/// Select best audio codec for a given container format
pub fn selectBestAudioCodec(format: core.AudioFormat) AudioCodec {
    return switch (format) {
        .mp3 => .mp3,
        .aac => .aac,
        .wav => .pcm_s16le,
        .flac => .flac,
        .ogg => .vorbis,
        .opus => .opus,
        .unknown => .aac, // Default
    };
}

/// Check if codec is compatible with container
pub fn isCodecCompatible(codec: VideoCodec, format: core.VideoFormat) bool {
    return switch (format) {
        .mp4, .mov => switch (codec) {
            .h264, .hevc, .av1, .mpeg4, .mjpeg => true,
            else => false,
        },
        .webm => switch (codec) {
            .vp8, .vp9, .av1 => true,
            else => false,
        },
        .mkv => true, // MKV supports almost everything
        .avi => switch (codec) {
            .h264, .mpeg4, .mjpeg => true,
            else => false,
        },
        .gif => codec == .raw,
        .unknown => false,
    };
}

// ============================================================================
// Codec Parameter String Generation
// ============================================================================

/// Generate codec parameter string for MIME type (e.g., "avc1.64001f")
pub fn generateCodecString(
    allocator: std.mem.Allocator,
    codec: VideoCodec,
    profile: ?u8,
    level: ?u8,
) ![]const u8 {
    return switch (codec) {
        .h264 => blk: {
            const p = profile orelse 100; // High profile default
            const l = level orelse 31; // Level 3.1 default
            break :blk try std.fmt.allocPrint(
                allocator,
                "avc1.{x:0>2}{x:0>2}{x:0>2}",
                .{ p, 0, l },
            );
        },
        .hevc => blk: {
            const p = profile orelse 1; // Main profile default
            const l = level orelse 93; // Level 3.1 default
            break :blk try std.fmt.allocPrint(
                allocator,
                "hvc1.{d}.4.L{d}.B0",
                .{ p, l },
            );
        },
        .vp9 => blk: {
            const p = profile orelse 0;
            break :blk try std.fmt.allocPrint(
                allocator,
                "vp09.00.{d:0>2}.08",
                .{p},
            );
        },
        .av1 => blk: {
            const p = profile orelse 0;
            const l = level orelse 8; // Level 4.0
            break :blk try std.fmt.allocPrint(
                allocator,
                "av01.{d}.{d:0>2}M.08",
                .{ p, l },
            );
        },
        else => try allocator.dupe(u8, codec.getFourCC()),
    };
}

/// Get recommended bitrate for resolution and frame rate
pub fn getRecommendedBitrate(
    width: u32,
    height: u32,
    fps: f64,
    codec: VideoCodec,
) u32 {
    const pixels = width * height;
    const pixels_per_sec = @as(f64, @floatFromInt(pixels)) * fps;

    // Base bitrate calculation (bits per pixel per second)
    const bpp: f64 = switch (codec) {
        .h264 => 0.1,
        .hevc => 0.05, // HEVC is ~50% more efficient
        .vp9 => 0.06,
        .av1 => 0.04, // AV1 is ~30% more efficient than HEVC
        else => 0.1,
    };

    const bitrate = pixels_per_sec * bpp;
    return @intFromFloat(bitrate);
}

/// Get codec complexity score (higher = more complex to encode)
pub fn getCodecComplexity(codec: VideoCodec) u8 {
    return switch (codec) {
        .raw => 0,
        .mjpeg => 1,
        .h264 => 3,
        .vp8 => 4,
        .vp9 => 6,
        .hevc => 7,
        .av1 => 9,
        else => 5,
    };
}
