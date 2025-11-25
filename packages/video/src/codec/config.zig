// Home Video Library - Codec Configuration
// Bitrate control, quality presets, profile/level selection

const std = @import("std");
const core = @import("../core.zig");

/// Bitrate control mode
pub const BitrateMode = enum {
    cbr, // Constant bitrate
    vbr, // Variable bitrate
    crf, // Constant rate factor (quality-based)
    cqp, // Constant quantization parameter
};

/// Quality preset
pub const QualityPreset = enum {
    very_low,
    low,
    medium,
    high,
    very_high,
    lossless,

    pub fn toCRF(self: QualityPreset, codec: core.VideoCodec) u8 {
        return switch (codec) {
            .h264, .hevc => switch (self) {
                .very_low => 35,
                .low => 28,
                .medium => 23,
                .high => 18,
                .very_high => 15,
                .lossless => 0,
            },
            .vp9, .av1 => switch (self) {
                .very_low => 45,
                .low => 35,
                .medium => 30,
                .high => 25,
                .very_high => 20,
                .lossless => 0,
            },
            else => 23,
        };
    }

    pub fn toBitrate(self: QualityPreset, width: u32, height: u32, fps: f64) u32 {
        const pixels = width * height;
        const base_rate: f32 = switch (self) {
            .very_low => 0.05,
            .low => 0.1,
            .medium => 0.15,
            .high => 0.25,
            .very_high => 0.4,
            .lossless => 1.0,
        };

        const bits_per_pixel = base_rate * @as(f32, @floatCast(fps));
        return @intFromFloat(@as(f32, @floatFromInt(pixels)) * bits_per_pixel);
    }
};

/// Latency mode
pub const LatencyMode = enum {
    quality, // Optimize for quality (slower)
    balanced, // Balance quality and speed
    realtime, // Optimize for low latency (faster)
    ultra_low_latency, // Minimal latency, lowest quality
};

/// GOP structure configuration
pub const GOPConfig = struct {
    keyframe_interval: u32 = 250, // Frames between keyframes
    min_keyframe_interval: u32 = 25,
    max_keyframe_interval: u32 = 250,
    scene_cut_threshold: ?f32 = 0.4, // null = disable scene cut detection
    closed_gop: bool = false,

    pub fn auto(fps: core.Rational) GOPConfig {
        const fps_f = @as(f32, @floatFromInt(fps.num)) / @as(f32, @floatFromInt(fps.den));
        const keyframe_secs: f32 = 10.0; // 10 second GOP
        const keyframe_interval: u32 = @intFromFloat(fps_f * keyframe_secs);

        return .{
            .keyframe_interval = keyframe_interval,
            .min_keyframe_interval = @intFromFloat(fps_f * 1.0),
            .max_keyframe_interval = keyframe_interval,
        };
    }
};

/// Reference frame configuration
pub const ReferenceConfig = struct {
    num_ref_frames: u32 = 3, // Number of reference frames
    b_frames: u32 = 3, // Number of B-frames
    b_pyramid: bool = true, // Use hierarchical B-frames
    ref_frame_scheme: RefScheme = .default,

    pub const RefScheme = enum {
        default,
        low_delay, // P frames only
        hierarchical_p, // Hierarchical P prediction
        hierarchical_b, // Hierarchical B prediction
    };
};

/// Motion estimation configuration
pub const MotionConfig = struct {
    search_range: u32 = 16, // Search range in pixels
    subpel_refinement: u32 = 8, // Subpixel refinement level (0-11)
    me_method: MEMethod = .hexagon,
    enable_fast_pskip: bool = true,
    enable_dct_decimate: bool = true,

    pub const MEMethod = enum {
        diamond,
        hexagon,
        multi_hexagon,
        exhaustive,
        transformed_exhaustive,
    };
};

/// Rate control configuration
pub const RateControlConfig = struct {
    mode: BitrateMode = .vbr,
    bitrate: u32, // Target bitrate (bits/sec)
    max_bitrate: ?u32 = null, // Maximum bitrate for VBR
    buffer_size: ?u32 = null, // VBV buffer size
    crf: ?u8 = null, // For CRF mode (0-51 for H.264/HEVC)
    qp: ?u8 = null, // For CQP mode
    lookahead: u32 = 40, // Frames to look ahead for rate control
    aq_mode: AQMode = .variance,
    aq_strength: f32 = 1.0,

    pub const AQMode = enum {
        none,
        variance, // Variance-based AQ
        auto_variance, // Auto-variance AQ
    };

    pub fn vbr(bitrate: u32, max_bitrate: u32) RateControlConfig {
        return .{
            .mode = .vbr,
            .bitrate = bitrate,
            .max_bitrate = max_bitrate,
        };
    }

    pub fn cbr(bitrate: u32) RateControlConfig {
        return .{
            .mode = .cbr,
            .bitrate = bitrate,
            .max_bitrate = bitrate,
            .buffer_size = bitrate / 2,
        };
    }

    pub fn crf(quality: u8) RateControlConfig {
        return .{
            .mode = .crf,
            .bitrate = 0,
            .crf = quality,
        };
    }
};

/// Complete encoder configuration
pub const EncoderConfig = struct {
    codec: core.VideoCodec,
    width: u32,
    height: u32,
    fps: core.Rational,
    pixel_format: core.PixelFormat = .yuv420p,

    // Quality/Rate control
    quality_preset: QualityPreset = .medium,
    rate_control: RateControlConfig,

    // GOP structure
    gop: GOPConfig,

    // Reference frames
    references: ReferenceConfig = .{},

    // Motion estimation
    motion: MotionConfig = .{},

    // Latency
    latency_mode: LatencyMode = .balanced,

    // Profile/Level
    profile: ?[]const u8 = null,
    level: ?[]const u8 = null,

    // Codec-specific
    threads: u32 = 0, // 0 = auto
    tune: ?Tune = null,

    pub const Tune = enum {
        film, // For film content
        animation, // For animated content
        grain, // For grainy content
        still_image, // For still images
        fast_decode, // Optimize for fast decoding
        zero_latency, // Zero latency streaming
    };

    pub fn h264Default(width: u32, height: u32, bitrate: u32, fps: core.Rational) EncoderConfig {
        return .{
            .codec = .h264,
            .width = width,
            .height = height,
            .fps = fps,
            .rate_control = RateControlConfig.vbr(bitrate, bitrate * 2),
            .gop = GOPConfig.auto(fps),
            .profile = "high",
            .level = "4.1",
        };
    }

    pub fn hevcDefault(width: u32, height: u32, bitrate: u32, fps: core.Rational) EncoderConfig {
        return .{
            .codec = .hevc,
            .width = width,
            .height = height,
            .fps = fps,
            .rate_control = RateControlConfig.vbr(bitrate, bitrate * 2),
            .gop = GOPConfig.auto(fps),
            .profile = "main",
            .level = "5.1",
        };
    }

    pub fn av1Default(width: u32, height: u32, fps: core.Rational) EncoderConfig {
        const quality_crf = QualityPreset.medium.toCRF(.av1);

        return .{
            .codec = .av1,
            .width = width,
            .height = height,
            .fps = fps,
            .rate_control = RateControlConfig.crf(quality_crf),
            .gop = GOPConfig.auto(fps),
        };
    }

    pub fn forStreaming(width: u32, height: u32, bitrate: u32, fps: core.Rational) EncoderConfig {
        return .{
            .codec = .h264,
            .width = width,
            .height = height,
            .fps = fps,
            .rate_control = RateControlConfig.cbr(bitrate),
            .gop = .{
                .keyframe_interval = 60, // 2 seconds @ 30fps
                .closed_gop = true,
            },
            .references = .{
                .b_frames = 0, // No B-frames for low latency
            },
            .latency_mode = .ultra_low_latency,
            .tune = .zero_latency,
            .profile = "baseline",
        };
    }
};

/// Codec capability query
pub const CodecCapabilities = struct {
    codec: core.VideoCodec,
    can_encode: bool,
    can_decode: bool,
    supported_profiles: []const []const u8,
    supported_pixel_formats: []const core.PixelFormat,
    max_width: u32,
    max_height: u32,
    max_framerate: core.Rational,

    pub fn query(codec: core.VideoCodec) CodecCapabilities {
        return switch (codec) {
            .h264 => .{
                .codec = .h264,
                .can_encode = true,
                .can_decode = true,
                .supported_profiles = &[_][]const u8{ "baseline", "main", "high" },
                .supported_pixel_formats = &[_]core.PixelFormat{ .yuv420p, .yuv422p, .yuv444p },
                .max_width = 4096,
                .max_height = 2304,
                .max_framerate = .{ .num = 120, .den = 1 },
            },
            .hevc => .{
                .codec = .hevc,
                .can_encode = true,
                .can_decode = true,
                .supported_profiles = &[_][]const u8{ "main", "main10" },
                .supported_pixel_formats = &[_]core.PixelFormat{ .yuv420p, .yuv422p, .yuv444p },
                .max_width = 8192,
                .max_height = 4320,
                .max_framerate = .{ .num = 120, .den = 1 },
            },
            .vp9 => .{
                .codec = .vp9,
                .can_encode = true,
                .can_decode = true,
                .supported_profiles = &[_][]const u8{ "profile0", "profile1", "profile2" },
                .supported_pixel_formats = &[_]core.PixelFormat{ .yuv420p, .yuv422p, .yuv444p },
                .max_width = 8192,
                .max_height = 4320,
                .max_framerate = .{ .num = 120, .den = 1 },
            },
            .av1 => .{
                .codec = .av1,
                .can_encode = true,
                .can_decode = true,
                .supported_profiles = &[_][]const u8{ "main", "high", "professional" },
                .supported_pixel_formats = &[_]core.PixelFormat{ .yuv420p, .yuv422p, .yuv444p },
                .max_width = 8192,
                .max_height = 4320,
                .max_framerate = .{ .num = 120, .den = 1 },
            },
            else => .{
                .codec = codec,
                .can_encode = false,
                .can_decode = true,
                .supported_profiles = &[_][]const u8{},
                .supported_pixel_formats = &[_]core.PixelFormat{},
                .max_width = 1920,
                .max_height = 1080,
                .max_framerate = .{ .num = 60, .den = 1 },
            },
        };
    }

    pub fn bestCodecForContainer(container: core.VideoFormat) core.VideoCodec {
        return switch (container) {
            .mp4, .mov => .h264,
            .webm => .vp9,
            .mkv => .hevc,
            else => .h264,
        };
    }
};

/// Generate codec parameter string for containers
pub const CodecString = struct {
    pub fn h264(profile: []const u8, level: []const u8) ![]const u8 {
        _ = level;

        // Simplified codec string generation
        if (std.mem.eql(u8, profile, "baseline")) {
            return "avc1.42E01E";
        } else if (std.mem.eql(u8, profile, "main")) {
            return "avc1.4D401E";
        } else if (std.mem.eql(u8, profile, "high")) {
            return "avc1.64001F";
        }

        return "avc1.64001F";
    }

    pub fn hevc(profile: []const u8, level: []const u8) ![]const u8 {
        _ = profile;
        _ = level;
        // Simplified
        return "hev1.1.6.L93.B0";
    }

    pub fn vp9(profile: u8) []const u8 {
        return switch (profile) {
            0 => "vp09.00.10.08",
            1 => "vp09.01.10.08",
            2 => "vp09.02.10.10",
            else => "vp09.00.10.08",
        };
    }

    pub fn av1(profile: u8, level: u8) ![]const u8 {
        _ = profile;
        _ = level;
        return "av01.0.04M.08";
    }
};
