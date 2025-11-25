// Home Video Library - Codec Configuration
// Universal configuration types for video and audio encoding

const std = @import("std");

// ============================================================================
// Rate Control Modes
// ============================================================================

/// Video bitrate control mode
pub const RateControlMode = enum {
    /// Constant Bitrate - Maintains target bitrate throughout
    cbr,
    /// Variable Bitrate - Allows bitrate to vary for better quality
    vbr,
    /// Constant Rate Factor - Quality-based encoding (CRF value 0-51)
    crf,
    /// Constant Quantizer Parameter - Fixed QP value
    cqp,
    /// Average Bitrate - Target average bitrate with buffer constraints
    abr,
};

/// Audio bitrate mode
pub const AudioBitrateMode = enum {
    /// Constant Bitrate
    cbr,
    /// Variable Bitrate
    vbr,
    /// Average Bitrate
    abr,
};

// ============================================================================
// Quality Presets
// ============================================================================

/// Encoding speed vs quality tradeoff preset
pub const QualityPreset = enum {
    /// Fastest encoding, lowest quality
    very_fast,
    /// Fast encoding, lower quality
    fast,
    /// Balanced speed and quality
    medium,
    /// Slower encoding, higher quality
    slow,
    /// Slowest encoding, highest quality
    very_slow,

    pub fn toX264Preset(self: QualityPreset) []const u8 {
        return switch (self) {
            .very_fast => "veryfast",
            .fast => "fast",
            .medium => "medium",
            .slow => "slow",
            .very_slow => "veryslow",
        };
    }

    pub fn toX265Preset(self: QualityPreset) []const u8 {
        return switch (self) {
            .very_fast => "veryfast",
            .fast => "fast",
            .medium => "medium",
            .slow => "slow",
            .very_slow => "veryslow",
        };
    }
};

/// Tuning hints for encoder optimization
pub const TuningHint = enum {
    /// General-purpose encoding
    none,
    /// Optimized for film content
    film,
    /// Optimized for animation
    animation,
    /// Optimized for still images/slideshows
    still_image,
    /// Optimized for screen capture
    screen,
    /// Fast decode for real-time playback
    fast_decode,
    /// Low latency for streaming
    zero_latency,
};

// ============================================================================
// Profile and Level Selection
// ============================================================================

/// H.264/AVC profile
pub const H264Profile = enum {
    baseline,
    constrained_baseline,
    main,
    extended,
    high,
    high_10,
    high_422,
    high_444_predictive,

    pub fn toProfileIDC(self: H264Profile) u8 {
        return switch (self) {
            .baseline, .constrained_baseline => 66,
            .main => 77,
            .extended => 88,
            .high => 100,
            .high_10 => 110,
            .high_422 => 122,
            .high_444_predictive => 244,
        };
    }

    pub fn supportsConstraints(self: H264Profile) bool {
        return self == .constrained_baseline;
    }
};

/// H.264 level
pub const H264Level = enum {
    @"1",
    @"1.1",
    @"1.2",
    @"1.3",
    @"2",
    @"2.1",
    @"2.2",
    @"3",
    @"3.1",
    @"3.2",
    @"4",
    @"4.1",
    @"4.2",
    @"5",
    @"5.1",
    @"5.2",
    @"6",
    @"6.1",
    @"6.2",

    pub fn toLevelIDC(self: H264Level) u8 {
        return switch (self) {
            .@"1" => 10,
            .@"1.1" => 11,
            .@"1.2" => 12,
            .@"1.3" => 13,
            .@"2" => 20,
            .@"2.1" => 21,
            .@"2.2" => 22,
            .@"3" => 30,
            .@"3.1" => 31,
            .@"3.2" => 32,
            .@"4" => 40,
            .@"4.1" => 41,
            .@"4.2" => 42,
            .@"5" => 50,
            .@"5.1" => 51,
            .@"5.2" => 52,
            .@"6" => 60,
            .@"6.1" => 61,
            .@"6.2" => 62,
        };
    }

    /// Get maximum macroblock processing rate for this level
    pub fn getMaxMBPS(self: H264Level) u32 {
        return switch (self) {
            .@"1" => 1485,
            .@"1.1" => 3000,
            .@"1.2" => 6000,
            .@"1.3" => 11880,
            .@"2" => 11880,
            .@"2.1" => 19800,
            .@"2.2" => 20250,
            .@"3" => 40500,
            .@"3.1" => 108000,
            .@"3.2" => 216000,
            .@"4" => 245760,
            .@"4.1" => 245760,
            .@"4.2" => 522240,
            .@"5" => 589824,
            .@"5.1" => 983040,
            .@"5.2" => 2073600,
            .@"6" => 4177920,
            .@"6.1" => 8355840,
            .@"6.2" => 16711680,
        };
    }
};

/// H.265/HEVC profile
pub const HEVCProfile = enum {
    main,
    main_10,
    main_still_picture,
    main_444,
    main_444_10,
    main_intra,
    main_444_still_picture,

    pub fn toProfileIDC(self: HEVCProfile) u8 {
        return switch (self) {
            .main => 1,
            .main_10 => 2,
            .main_still_picture => 3,
            .main_444 => 4,
            .main_444_10 => 5,
            .main_intra => 6,
            .main_444_still_picture => 7,
        };
    }
};

/// VP9 profile
pub const VP9Profile = enum {
    profile_0, // 8-bit 4:2:0
    profile_1, // 8-bit 4:2:2/4:4:4
    profile_2, // 10/12-bit 4:2:0
    profile_3, // 10/12-bit 4:2:2/4:4:4

    pub fn toProfileValue(self: VP9Profile) u8 {
        return switch (self) {
            .profile_0 => 0,
            .profile_1 => 1,
            .profile_2 => 2,
            .profile_3 => 3,
        };
    }
};

/// AV1 profile
pub const AV1Profile = enum {
    main,
    high,
    professional,

    pub fn toProfileValue(self: AV1Profile) u8 {
        return switch (self) {
            .main => 0,
            .high => 1,
            .professional => 2,
        };
    }
};

// ============================================================================
// GOP Structure Configuration
// ============================================================================

/// Group of Pictures (GOP) structure configuration
pub const GOPConfig = struct {
    /// Keyframe interval in frames (I-frame distance)
    /// 0 = auto, typically 250-300 for 30fps
    keyframe_interval: u32 = 250,

    /// Minimum distance between keyframes (for scene detection)
    min_keyframe_interval: u32 = 0,

    /// Maximum distance between keyframes
    max_keyframe_interval: u32 = 250,

    /// Number of B-frames between I/P frames (0-16)
    /// 0 = no B-frames (I/P only)
    /// 2-3 = good balance
    /// Higher = better compression, more latency
    bframes: u32 = 3,

    /// Number of reference frames (1-16)
    /// More = better quality, more memory
    ref_frames: u32 = 3,

    /// Enable adaptive B-frame placement
    adaptive_bframes: bool = true,

    /// B-frame pyramid mode
    b_pyramid: BPyramidMode = .normal,

    /// Scene cut detection threshold (0-100)
    /// 0 = disabled, 40 = default, 100 = very sensitive
    scene_cut_threshold: u8 = 40,

    /// Force closed GOP (all frames after I-frame reference only frames in same GOP)
    closed_gop: bool = false,

    /// Intra refresh (for low-latency streaming)
    intra_refresh: bool = false,

    pub const BPyramidMode = enum {
        none, // No B-pyramid
        strict, // Strict hierarchical B-frames
        normal, // Normal B-pyramid (default)
    };

    /// Auto-configure GOP for specific use case
    pub fn forUseCase(use_case: UseCase) GOPConfig {
        return switch (use_case) {
            .streaming => .{
                .keyframe_interval = 60, // 2 seconds at 30fps
                .bframes = 0, // Low latency
                .ref_frames = 1,
                .adaptive_bframes = false,
                .closed_gop = true,
                .intra_refresh = true,
            },
            .archive => .{
                .keyframe_interval = 300, // 10 seconds at 30fps
                .bframes = 8, // Maximum compression
                .ref_frames = 6,
                .adaptive_bframes = true,
                .b_pyramid = .normal,
            },
            .editing => .{
                .keyframe_interval = 1, // All I-frames
                .bframes = 0,
                .ref_frames = 1,
                .adaptive_bframes = false,
            },
            .balanced => .{}, // Use defaults
        };
    }

    pub const UseCase = enum {
        streaming,
        archive,
        editing,
        balanced,
    };
};

// ============================================================================
// Motion Estimation Configuration
// ============================================================================

/// Motion estimation configuration
pub const MotionEstimationConfig = struct {
    /// Motion estimation algorithm
    method: Method = .hex,

    /// Search range in pixels (-1 = auto)
    range: i32 = -1,

    /// Subpixel motion estimation quality
    /// 0 = disabled, 11 = highest (h264)
    subpel_quality: u8 = 7,

    /// Motion estimation comparison function
    comparison: ComparisonFunc = .satd,

    /// Enable quarter-pixel motion estimation
    quarter_pixel: bool = true,

    /// Enable weighted prediction
    weighted_pred: bool = true,

    pub const Method = enum {
        dia, // Diamond search
        hex, // Hexagonal search (default)
        umh, // Uneven multi-hexagon search
        esa, // Exhaustive search (very slow)
        tesa, // Transformed exhaustive search
    };

    pub const ComparisonFunc = enum {
        sad, // Sum of Absolute Differences
        satd, // Sum of Absolute Transformed Differences (default)
        rd, // Rate-distortion optimized
    };
};

// ============================================================================
// Video Encoder Configuration
// ============================================================================

/// Complete video encoder configuration
pub const VideoEncoderConfig = struct {
    /// Rate control configuration
    rate_control: RateControlMode = .crf,

    /// Target bitrate (for CBR/VBR/ABR modes) in bits/second
    bitrate: ?u32 = null,

    /// Maximum bitrate (for VBR mode)
    max_bitrate: ?u32 = null,

    /// CRF value (for CRF mode, 0-51, lower = better quality)
    /// Typical values: 18 = visually lossless, 23 = default, 28 = acceptable
    crf: u8 = 23,

    /// Constant QP value (for CQP mode, 0-51)
    qp: ?u8 = null,

    /// Quality preset (speed vs compression tradeoff)
    preset: QualityPreset = .medium,

    /// Tuning hint
    tune: TuningHint = .none,

    /// GOP structure
    gop: GOPConfig = .{},

    /// Motion estimation
    motion_estimation: MotionEstimationConfig = .{},

    /// Rate control lookahead in frames (0 = disabled, 40-60 typical)
    lookahead: u32 = 40,

    /// VBV buffer size in kilobits (0 = auto)
    vbv_bufsize: u32 = 0,

    /// VBV max bitrate in kilobits (0 = auto)
    vbv_maxrate: u32 = 0,

    /// Multi-pass encoding
    pass: Pass = .single,

    /// Statistics file for multi-pass encoding
    stats_file: ?[]const u8 = null,

    /// Number of threads (0 = auto)
    threads: u32 = 0,

    /// Enable frame-level multithreading
    frame_threads: bool = true,

    /// Enable slice-level multithreading
    slice_threads: bool = true,

    pub const Pass = enum {
        single, // One-pass encoding
        first, // First pass (analysis)
        second, // Second pass (encoding)
        third, // Third pass (optional refinement)
    };

    /// Validate configuration
    pub fn validate(self: *const VideoEncoderConfig) !void {
        // Check CRF value
        if (self.rate_control == .crf and self.crf > 51) {
            return error.InvalidCRFValue;
        }

        // Check QP value
        if (self.rate_control == .cqp) {
            if (self.qp == null or self.qp.? > 51) {
                return error.InvalidQPValue;
            }
        }

        // Check bitrate modes
        if ((self.rate_control == .cbr or self.rate_control == .vbr or self.rate_control == .abr) and self.bitrate == null) {
            return error.BitrateRequired;
        }

        // Check GOP config
        if (self.gop.bframes > 16) {
            return error.TooManyBFrames;
        }

        if (self.gop.ref_frames == 0 or self.gop.ref_frames > 16) {
            return error.InvalidRefFrames;
        }
    }

    /// Create config for target file size
    pub fn forTargetSize(
        duration_seconds: f64,
        target_size_bytes: u64,
        audio_bitrate: u32,
    ) VideoEncoderConfig {
        // Calculate video bitrate to hit target size
        const duration_sec: u64 = @intFromFloat(duration_seconds);
        const audio_bytes = (audio_bitrate / 8) * duration_sec;
        const video_bytes = if (target_size_bytes > audio_bytes)
            target_size_bytes - audio_bytes
        else
            target_size_bytes;

        const video_bitrate: u32 = @intCast((video_bytes * 8) / duration_sec);

        return .{
            .rate_control = .abr,
            .bitrate = video_bitrate,
            .pass = .first, // Use two-pass for target size
        };
    }
};

// ============================================================================
// Audio Encoder Configuration
// ============================================================================

/// Audio encoder configuration
pub const AudioEncoderConfig = struct {
    /// Bitrate control mode
    mode: AudioBitrateMode = .vbr,

    /// Target bitrate in bits/second
    bitrate: u32 = 128000, // 128 kbps default

    /// VBR quality (0-10, codec-specific)
    /// AAC: 1-5 (TVBR), Vorbis: 0-10, Opus: 0-10
    quality: u8 = 5,

    /// Sample rate (Hz)
    /// Common: 44100, 48000, 96000
    sample_rate: u32 = 48000,

    /// Number of channels
    channels: u8 = 2,

    /// Channel layout
    channel_layout: ChannelLayout = .stereo,

    /// Compression level (codec-specific, 0-12)
    compression_level: u8 = 5,

    /// Enable joint stereo (for stereo encoding)
    joint_stereo: bool = true,

    /// Number of threads
    threads: u32 = 0,

    pub const ChannelLayout = enum {
        mono,
        stereo,
        @"2.1",
        @"3.0",
        @"4.0",
        @"5.0",
        @"5.1",
        @"7.1",

        pub fn getChannelCount(self: ChannelLayout) u8 {
            return switch (self) {
                .mono => 1,
                .stereo => 2,
                .@"2.1" => 3,
                .@"3.0" => 3,
                .@"4.0" => 4,
                .@"5.0" => 5,
                .@"5.1" => 6,
                .@"7.1" => 8,
            };
        }
    };

    /// Validate configuration
    pub fn validate(self: *const AudioEncoderConfig) !void {
        if (self.channels == 0 or self.channels > 8) {
            return error.InvalidChannelCount;
        }

        if (self.sample_rate < 8000 or self.sample_rate > 192000) {
            return error.InvalidSampleRate;
        }

        if (self.bitrate < 8000 or self.bitrate > 320000) {
            return error.InvalidBitrate;
        }
    }
};
