// Home Video Library - Conformance Testing
// Standard video/audio conformance test vectors and validation

const std = @import("std");
const core = @import("../core.zig");

/// Conformance test vector
pub const TestVector = struct {
    name: []const u8,
    codec: core.VideoCodec,
    width: u32,
    height: u32,
    fps: core.Rational,
    frame_count: u32,
    expected_file_size: ?usize = null,
    expected_checksum: ?u32 = null,

    pub fn format(self: *const TestVector, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{s}: {s} {d}x{d} @{d}/{d}fps, {d} frames",
            .{
                self.name,
                @tagName(self.codec),
                self.width,
                self.height,
                self.fps.num,
                self.fps.den,
                self.frame_count,
            },
        );
    }
};

/// Standard test vectors
pub const StandardVectors = struct {
    /// HD test vectors
    pub const hd_1080p_h264 = TestVector{
        .name = "HD 1080p H.264",
        .codec = .h264,
        .width = 1920,
        .height = 1080,
        .fps = .{ .num = 24, .den = 1 },
        .frame_count = 100,
    };

    pub const hd_720p_h264 = TestVector{
        .name = "HD 720p H.264",
        .codec = .h264,
        .width = 1280,
        .height = 720,
        .fps = .{ .num = 30, .den = 1 },
        .frame_count = 100,
    };

    /// 4K test vectors
    pub const uhd_4k_hevc = TestVector{
        .name = "UHD 4K HEVC",
        .codec = .hevc,
        .width = 3840,
        .height = 2160,
        .fps = .{ .num = 60, .den = 1 },
        .frame_count = 50,
    };

    /// VP9 test vectors
    pub const hd_1080p_vp9 = TestVector{
        .name = "HD 1080p VP9",
        .codec = .vp9,
        .width = 1920,
        .height = 1080,
        .fps = .{ .num = 30, .den = 1 },
        .frame_count = 100,
    };

    /// AV1 test vectors
    pub const hd_1080p_av1 = TestVector{
        .name = "HD 1080p AV1",
        .codec = .av1,
        .width = 1920,
        .height = 1080,
        .fps = .{ .num = 24, .den = 1 },
        .frame_count = 100,
    };

    pub fn getAll() []const TestVector {
        return &[_]TestVector{
            hd_1080p_h264,
            hd_720p_h264,
            uhd_4k_hevc,
            hd_1080p_vp9,
            hd_1080p_av1,
        };
    }
};

/// Container format validation
pub const ContainerValidator = struct {
    const Self = @This();

    pub fn validateMP4(data: []const u8) !void {
        if (data.len < 8) return error.FileTooSmall;

        // Check for ftyp box
        if (!std.mem.eql(u8, data[4..8], "ftyp")) {
            return error.InvalidMP4Header;
        }
    }

    pub fn validateWebM(data: []const u8) !void {
        if (data.len < 4) return error.FileTooSmall;

        // Check for EBML header
        if (data[0] != 0x1A or data[1] != 0x45 or data[2] != 0xDF or data[3] != 0xA3) {
            return error.InvalidWebMHeader;
        }
    }

    pub fn validateMatroska(data: []const u8) !void {
        try validateWebM(data); // Matroska uses same header as WebM
    }
};

/// Codec conformance checker
pub const CodecConformance = struct {
    const Self = @This();

    pub fn checkH264Level(width: u32, height: u32, fps: core.Rational) !u8 {
        const mb_width = (width + 15) / 16;
        const mb_height = (height + 15) / 16;
        const mb_count = mb_width * mb_height;

        const fps_f = @as(f64, @floatFromInt(fps.num)) / @as(f64, @floatFromInt(fps.den));
        const mb_per_sec = @as(f64, @floatFromInt(mb_count)) * fps_f;

        // Simplified level determination
        if (mb_per_sec <= 11880 and mb_count <= 99) return 10; // Level 1.0
        if (mb_per_sec <= 40500 and mb_count <= 396) return 21; // Level 2.1
        if (mb_per_sec <= 108000 and mb_count <= 1620) return 30; // Level 3.0
        if (mb_per_sec <= 245760 and mb_count <= 3600) return 40; // Level 4.0
        if (mb_per_sec <= 522240 and mb_count <= 5120) return 50; // Level 5.0
        if (mb_per_sec <= 983040 and mb_count <= 8192) return 51; // Level 5.1

        return error.UnsupportedLevel;
    }

    pub fn checkHEVCTier(width: u32, height: u32, fps: core.Rational) !struct { tier: u8, level: u8 } {
        const pixels = width * height;
        const fps_f = @as(f64, @floatFromInt(fps.num)) / @as(f64, @floatFromInt(fps.den));
        const pixels_per_sec = @as(f64, @floatFromInt(pixels)) * fps_f;

        // Main tier
        if (pixels_per_sec <= 552_960) return .{ .tier = 0, .level = 30 }; // Level 3.0
        if (pixels_per_sec <= 3_686_400) return .{ .tier = 0, .level = 40 }; // Level 4.0
        if (pixels_per_sec <= 16_588_800) return .{ .tier = 0, .level = 50 }; // Level 5.0

        // High tier
        if (pixels_per_sec <= 66_846_720) return .{ .tier = 1, .level = 51 }; // Level 5.1
        if (pixels_per_sec <= 267_386_880) return .{ .tier = 1, .level = 60 }; // Level 6.0

        return error.UnsupportedTierLevel;
    }
};

/// Bitstream validator
pub const BitstreamValidator = struct {
    const Self = @This();

    pub fn validateH264NAL(data: []const u8) !void {
        if (data.len < 1) return error.NALTooSmall;

        const nal_type = data[0] & 0x1F;

        // Valid NAL unit types (1-12, 14-18)
        if (nal_type == 0 or nal_type == 13 or nal_type > 18) {
            return error.InvalidNALType;
        }
    }

    pub fn validateH264SPS(data: []const u8) !void {
        if (data.len < 4) return error.SPSTooSmall;

        const nal_type = data[0] & 0x1F;
        if (nal_type != 7) {
            return error.NotSPS;
        }

        // Basic validation - real implementation would parse full SPS
    }

    pub fn validateH264PPS(data: []const u8) !void {
        if (data.len < 2) return error.PPSTooSmall;

        const nal_type = data[0] & 0x1F;
        if (nal_type != 8) {
            return error.NotPPS;
        }
    }
};

/// Quality metrics validator
pub const QualityValidator = struct {
    const Self = @This();

    pub const QualityThresholds = struct {
        min_psnr: f64 = 30.0,
        min_ssim: f64 = 0.90,
        max_bitrate_variance: f64 = 0.20, // 20%
    };

    pub fn validatePSNR(psnr: f64, thresholds: QualityThresholds) !void {
        if (psnr < thresholds.min_psnr) {
            std.debug.print("PSNR {d:.2} dB below threshold {d:.2} dB\n", .{ psnr, thresholds.min_psnr });
            return error.PSNRTooLow;
        }
    }

    pub fn validateSSIM(ssim: f64, thresholds: QualityThresholds) !void {
        if (ssim < thresholds.min_ssim) {
            std.debug.print("SSIM {d:.4} below threshold {d:.4}\n", .{ ssim, thresholds.min_ssim });
            return error.SSIMTooLow;
        }
    }

    pub fn validateBitrate(actual: u32, target: u32, thresholds: QualityThresholds) !void {
        const variance = @abs(@as(f64, @floatFromInt(actual)) - @as(f64, @floatFromInt(target))) / @as(f64, @floatFromInt(target));

        if (variance > thresholds.max_bitrate_variance) {
            std.debug.print("Bitrate variance {d:.2}% exceeds {d:.2}%\n", .{ variance * 100.0, thresholds.max_bitrate_variance * 100.0 });
            return error.BitrateVarianceTooHigh;
        }
    }
};

/// Timing validator
pub const TimingValidator = struct {
    const Self = @This();

    pub fn validateFrameTiming(pts: []const core.Timestamp, fps: core.Rational) !void {
        if (pts.len < 2) return;

        const expected_delta_us = @as(i64, @intCast(@as(u64, fps.den) * 1_000_000 / @as(u64, fps.num)));
        const tolerance_us = expected_delta_us / 10; // 10% tolerance

        for (pts[0 .. pts.len - 1], pts[1..]) |current, next| {
            const delta = next.toMicroseconds() - current.toMicroseconds();
            const diff = @abs(delta - expected_delta_us);

            if (diff > tolerance_us) {
                std.debug.print("Frame timing error: delta={d}us, expected={d}us\n", .{ delta, expected_delta_us });
                return error.FrameTimingError;
            }
        }
    }

    pub fn validateMonotonic(timestamps: []const core.Timestamp) !void {
        for (timestamps[0 .. timestamps.len - 1], timestamps[1..]) |current, next| {
            if (current.compare(next) != .lt) {
                return error.NonMonotonicTimestamps;
            }
        }
    }
};

/// Audio conformance
pub const AudioConformance = struct {
    const Self = @This();

    pub fn validateSampleRate(sample_rate: u32) !void {
        // Standard sample rates
        const valid_rates = [_]u32{ 8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000 };

        for (valid_rates) |rate| {
            if (sample_rate == rate) return;
        }

        return error.InvalidSampleRate;
    }

    pub fn validateChannelCount(channels: u16) !void {
        if (channels == 0 or channels > 8) {
            return error.InvalidChannelCount;
        }
    }

    pub fn validateSampleFormat(format: core.AudioSampleFormat) !void {
        _ = format;
        // All formats are valid for now
    }
};
