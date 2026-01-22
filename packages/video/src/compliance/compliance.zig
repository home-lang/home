// Home Video Library - Broadcast Compliance
// ITU-R BT.601, BT.709, BT.2020 compliance, SMPTE timecode, broadcast-safe levels

const std = @import("std");
const types = @import("../core/types.zig");
const frame = @import("../core/frame.zig");

// ============================================================================
// ITU-R BT Standards Compliance
// ============================================================================

/// Color standard specification
pub const ColorStandard = enum {
    bt601, // SD video (NTSC/PAL)
    bt709, // HD video
    bt2020, // UHD/4K/HDR video
    bt2100_pq, // HDR PQ (Perceptual Quantizer)
    bt2100_hlg, // HDR HLG (Hybrid Log-Gamma)
    smpte_170m, // NTSC
    smpte_240m, // Early HD
    smpte_st2084, // PQ EOTF
};

/// Color primaries
pub const ColorPrimaries = struct {
    red_x: f64,
    red_y: f64,
    green_x: f64,
    green_y: f64,
    blue_x: f64,
    blue_y: f64,
    white_x: f64,
    white_y: f64,

    pub const BT601_625 = ColorPrimaries{
        .red_x = 0.640,
        .red_y = 0.330,
        .green_x = 0.290,
        .green_y = 0.600,
        .blue_x = 0.150,
        .blue_y = 0.060,
        .white_x = 0.3127,
        .white_y = 0.3290,
    };

    pub const BT601_525 = ColorPrimaries{
        .red_x = 0.630,
        .red_y = 0.340,
        .green_x = 0.310,
        .green_y = 0.595,
        .blue_x = 0.155,
        .blue_y = 0.070,
        .white_x = 0.3127,
        .white_y = 0.3290,
    };

    pub const BT709 = ColorPrimaries{
        .red_x = 0.640,
        .red_y = 0.330,
        .green_x = 0.300,
        .green_y = 0.600,
        .blue_x = 0.150,
        .blue_y = 0.060,
        .white_x = 0.3127,
        .white_y = 0.3290,
    };

    pub const BT2020 = ColorPrimaries{
        .red_x = 0.708,
        .red_y = 0.292,
        .green_x = 0.170,
        .green_y = 0.797,
        .blue_x = 0.131,
        .blue_y = 0.046,
        .white_x = 0.3127,
        .white_y = 0.3290,
    };

    pub const DCI_P3 = ColorPrimaries{
        .red_x = 0.680,
        .red_y = 0.320,
        .green_x = 0.265,
        .green_y = 0.690,
        .blue_x = 0.150,
        .blue_y = 0.060,
        .white_x = 0.314,
        .white_y = 0.351,
    };
};

/// Transfer characteristics (gamma/EOTF)
pub const TransferCharacteristics = struct {
    standard: ColorStandard,

    const Self = @This();

    /// Apply forward transfer (linear to display)
    pub fn apply(self: Self, linear: f64) f64 {
        return switch (self.standard) {
            .bt709, .bt601 => self.applyBT709(linear),
            .bt2020 => self.applyBT2020(linear),
            .bt2100_pq, .smpte_st2084 => self.applyPQ(linear),
            .bt2100_hlg => self.applyHLG(linear),
            else => self.applyBT709(linear),
        };
    }

    /// Apply inverse transfer (display to linear)
    pub fn applyInverse(self: Self, value: f64) f64 {
        return switch (self.standard) {
            .bt709, .bt601 => self.applyBT709Inverse(value),
            .bt2020 => self.applyBT2020Inverse(value),
            .bt2100_pq, .smpte_st2084 => self.applyPQInverse(value),
            .bt2100_hlg => self.applyHLGInverse(value),
            else => self.applyBT709Inverse(value),
        };
    }

    fn applyBT709(self: Self, linear: f64) f64 {
        _ = self;
        if (linear < 0.018) {
            return 4.500 * linear;
        }
        return 1.099 * std.math.pow(f64, linear, 0.45) - 0.099;
    }

    fn applyBT709Inverse(self: Self, value: f64) f64 {
        _ = self;
        if (value < 0.081) {
            return value / 4.500;
        }
        return std.math.pow(f64, (value + 0.099) / 1.099, 1.0 / 0.45);
    }

    fn applyBT2020(self: Self, linear: f64) f64 {
        _ = self;
        const alpha = 1.09929682680944;
        const beta = 0.018053968510807;
        if (linear < beta) {
            return 4.5 * linear;
        }
        return alpha * std.math.pow(f64, linear, 0.45) - (alpha - 1.0);
    }

    fn applyBT2020Inverse(self: Self, value: f64) f64 {
        _ = self;
        const alpha = 1.09929682680944;
        const beta_prime = 0.081242858298635;
        if (value < beta_prime) {
            return value / 4.5;
        }
        return std.math.pow(f64, (value + (alpha - 1.0)) / alpha, 1.0 / 0.45);
    }

    fn applyPQ(self: Self, linear: f64) f64 {
        _ = self;
        const m1: f64 = 2610.0 / 16384.0;
        const m2: f64 = 2523.0 / 4096.0 * 128.0;
        const c1: f64 = 3424.0 / 4096.0;
        const c2: f64 = 2413.0 / 4096.0 * 32.0;
        const c3: f64 = 2392.0 / 4096.0 * 32.0;

        const y = linear / 10000.0; // Normalize to 10000 nits
        const ym1 = std.math.pow(f64, y, m1);
        return std.math.pow(f64, (c1 + c2 * ym1) / (1.0 + c3 * ym1), m2);
    }

    fn applyPQInverse(self: Self, value: f64) f64 {
        _ = self;
        const m1: f64 = 2610.0 / 16384.0;
        const m2: f64 = 2523.0 / 4096.0 * 128.0;
        const c1: f64 = 3424.0 / 4096.0;
        const c2: f64 = 2413.0 / 4096.0 * 32.0;
        const c3: f64 = 2392.0 / 4096.0 * 32.0;

        const vm2 = std.math.pow(f64, value, 1.0 / m2);
        const y = std.math.pow(f64, @max(vm2 - c1, 0.0) / (c2 - c3 * vm2), 1.0 / m1);
        return y * 10000.0;
    }

    fn applyHLG(self: Self, linear: f64) f64 {
        _ = self;
        const a: f64 = 0.17883277;
        const b: f64 = 1.0 - 4.0 * a;
        const c: f64 = 0.5 - a * @log(@as(f64, 4.0 * a));

        if (linear <= 1.0 / 12.0) {
            return @sqrt(3.0 * linear);
        }
        return a * @log(12.0 * linear - b) + c;
    }

    fn applyHLGInverse(self: Self, value: f64) f64 {
        _ = self;
        const a: f64 = 0.17883277;
        const b: f64 = 1.0 - 4.0 * a;
        const c: f64 = 0.5 - a * @log(@as(f64, 4.0 * a));

        if (value <= 0.5) {
            return value * value / 3.0;
        }
        return (@exp((value - c) / a) + b) / 12.0;
    }
};

/// YCbCr matrix coefficients
pub const MatrixCoefficients = struct {
    kr: f64, // Red coefficient
    kg: f64, // Green coefficient (computed as 1 - kr - kb)
    kb: f64, // Blue coefficient

    pub const BT601 = MatrixCoefficients{
        .kr = 0.299,
        .kg = 0.587,
        .kb = 0.114,
    };

    pub const BT709 = MatrixCoefficients{
        .kr = 0.2126,
        .kg = 0.7152,
        .kb = 0.0722,
    };

    pub const BT2020 = MatrixCoefficients{
        .kr = 0.2627,
        .kg = 0.6780,
        .kb = 0.0593,
    };

    pub const BT2020_NCL = MatrixCoefficients{
        .kr = 0.2627,
        .kg = 0.6780,
        .kb = 0.0593,
    };

    pub const BT2020_CL = MatrixCoefficients{
        .kr = 0.2627,
        .kg = 0.6780,
        .kb = 0.0593,
    };

    /// Convert RGB to YCbCr
    pub fn rgbToYcbcr(self: MatrixCoefficients, r: f64, g: f64, b: f64) struct { y: f64, cb: f64, cr: f64 } {
        const y = self.kr * r + self.kg * g + self.kb * b;
        const cb = (b - y) / (2.0 * (1.0 - self.kb));
        const cr = (r - y) / (2.0 * (1.0 - self.kr));
        return .{ .y = y, .cb = cb, .cr = cr };
    }

    /// Convert YCbCr to RGB
    pub fn ycbcrToRgb(self: MatrixCoefficients, y: f64, cb: f64, cr: f64) struct { r: f64, g: f64, b: f64 } {
        const r = y + 2.0 * (1.0 - self.kr) * cr;
        const b = y + 2.0 * (1.0 - self.kb) * cb;
        const g = (y - self.kr * r - self.kb * b) / self.kg;
        return .{ .r = r, .g = g, .b = b };
    }
};

// ============================================================================
// Broadcast-Safe Levels
// ============================================================================

/// Broadcast level ranges
pub const LevelRange = enum {
    full, // 0-255 (PC levels)
    limited, // 16-235 (broadcast levels)
    super_white, // Allow values above 235 (up to 254)
};

/// Broadcast-safe level enforcement
pub const BroadcastLevels = struct {
    range: LevelRange = .limited,
    allow_super_white: bool = false,
    allow_super_black: bool = false,

    // Level limits for 8-bit
    pub const LEVEL_8_BLACK: u8 = 16;
    pub const LEVEL_8_WHITE: u8 = 235;
    pub const LEVEL_8_SUPER_WHITE: u8 = 254;
    pub const LEVEL_8_CHROMA_MIN: u8 = 16;
    pub const LEVEL_8_CHROMA_MAX: u8 = 240;

    // Level limits for 10-bit
    pub const LEVEL_10_BLACK: u16 = 64;
    pub const LEVEL_10_WHITE: u16 = 940;
    pub const LEVEL_10_SUPER_WHITE: u16 = 1019;
    pub const LEVEL_10_CHROMA_MIN: u16 = 64;
    pub const LEVEL_10_CHROMA_MAX: u16 = 960;

    const Self = @This();

    /// Clamp luma value to broadcast-safe range (8-bit)
    pub fn clampLuma8(self: Self, value: u8) u8 {
        if (self.range == .full) return value;

        const min_val: u8 = if (self.allow_super_black) 1 else LEVEL_8_BLACK;
        const max_val: u8 = if (self.allow_super_white) LEVEL_8_SUPER_WHITE else LEVEL_8_WHITE;

        return std.math.clamp(value, min_val, max_val);
    }

    /// Clamp chroma value to broadcast-safe range (8-bit)
    pub fn clampChroma8(self: Self, value: u8) u8 {
        if (self.range == .full) return value;
        return std.math.clamp(value, LEVEL_8_CHROMA_MIN, LEVEL_8_CHROMA_MAX);
    }

    /// Clamp luma value to broadcast-safe range (10-bit)
    pub fn clampLuma10(self: Self, value: u16) u16 {
        if (self.range == .full) return value;

        const min_val: u16 = if (self.allow_super_black) 4 else LEVEL_10_BLACK;
        const max_val: u16 = if (self.allow_super_white) LEVEL_10_SUPER_WHITE else LEVEL_10_WHITE;

        return std.math.clamp(value, min_val, max_val);
    }

    /// Clamp chroma value to broadcast-safe range (10-bit)
    pub fn clampChroma10(self: Self, value: u16) u16 {
        if (self.range == .full) return value;
        return std.math.clamp(value, LEVEL_10_CHROMA_MIN, LEVEL_10_CHROMA_MAX);
    }

    /// Convert full range to limited range (8-bit)
    pub fn fullToLimited8(self: Self, value: u8) u8 {
        _ = self;
        // Y' = 16 + (219 * Y / 255)
        return @intCast(16 + (@as(u32, value) * 219) / 255);
    }

    /// Convert limited range to full range (8-bit)
    pub fn limitedToFull8(self: Self, value: u8) u8 {
        _ = self;
        // Y = (Y' - 16) * 255 / 219
        if (value <= 16) return 0;
        if (value >= 235) return 255;
        return @intCast(((@as(u32, value) - 16) * 255) / 219);
    }

    /// Check if value is within broadcast-safe limits (8-bit luma)
    pub fn isLumaSafe8(self: Self, value: u8) bool {
        if (self.range == .full) return true;
        const min_val: u8 = if (self.allow_super_black) 1 else LEVEL_8_BLACK;
        const max_val: u8 = if (self.allow_super_white) LEVEL_8_SUPER_WHITE else LEVEL_8_WHITE;
        return value >= min_val and value <= max_val;
    }
};

/// Gamut warning - detect out-of-gamut colors
pub const GamutChecker = struct {
    primaries: ColorPrimaries,
    tolerance: f64 = 0.001,

    const Self = @This();

    pub fn init(standard: ColorStandard) Self {
        const primaries = switch (standard) {
            .bt601 => ColorPrimaries.BT601_625,
            .bt709 => ColorPrimaries.BT709,
            .bt2020, .bt2100_pq, .bt2100_hlg => ColorPrimaries.BT2020,
            else => ColorPrimaries.BT709,
        };

        return .{
            .primaries = primaries,
        };
    }

    /// Check if RGB value is within gamut
    pub fn isInGamut(self: Self, r: f64, g: f64, b: f64) bool {
        // Simple check: all values should be in [0, 1]
        return r >= -self.tolerance and r <= 1.0 + self.tolerance and
            g >= -self.tolerance and g <= 1.0 + self.tolerance and
            b >= -self.tolerance and b <= 1.0 + self.tolerance;
    }

    /// Clamp RGB to gamut
    pub fn clampToGamut(self: Self, r: f64, g: f64, b: f64) struct { r: f64, g: f64, b: f64 } {
        _ = self;
        return .{
            .r = std.math.clamp(r, 0.0, 1.0),
            .g = std.math.clamp(g, 0.0, 1.0),
            .b = std.math.clamp(b, 0.0, 1.0),
        };
    }
};

// ============================================================================
// SMPTE Timecode Support
// ============================================================================

/// SMPTE timecode with full specification support
pub const SmptTimecode = struct {
    hours: u8,
    minutes: u8,
    seconds: u8,
    frames: u8,
    drop_frame: bool,
    frame_rate: FrameRate,
    color_frame: bool = false,
    field_phase: FieldPhase = .even,

    const Self = @This();

    pub const FrameRate = enum {
        fps_23_976, // 24000/1001
        fps_24,
        fps_25,
        fps_29_97_ndf, // 30000/1001 non-drop
        fps_29_97_df, // 30000/1001 drop-frame
        fps_30,
        fps_50,
        fps_59_94_ndf,
        fps_59_94_df,
        fps_60,

        pub fn toRational(self: FrameRate) types.Rational {
            return switch (self) {
                .fps_23_976 => .{ .num = 24000, .den = 1001 },
                .fps_24 => .{ .num = 24, .den = 1 },
                .fps_25 => .{ .num = 25, .den = 1 },
                .fps_29_97_ndf, .fps_29_97_df => .{ .num = 30000, .den = 1001 },
                .fps_30 => .{ .num = 30, .den = 1 },
                .fps_50 => .{ .num = 50, .den = 1 },
                .fps_59_94_ndf, .fps_59_94_df => .{ .num = 60000, .den = 1001 },
                .fps_60 => .{ .num = 60, .den = 1 },
            };
        }

        pub fn framesPerSecond(self: FrameRate) u8 {
            return switch (self) {
                .fps_23_976, .fps_24 => 24,
                .fps_25 => 25,
                .fps_29_97_ndf, .fps_29_97_df, .fps_30 => 30,
                .fps_50 => 50,
                .fps_59_94_ndf, .fps_59_94_df, .fps_60 => 60,
            };
        }

        pub fn isDropFrame(self: FrameRate) bool {
            return self == .fps_29_97_df or self == .fps_59_94_df;
        }
    };

    pub const FieldPhase = enum { even, odd };

    /// Create timecode from frame count
    pub fn fromFrameCount(frame_count: u64, rate: FrameRate) Self {
        const fps = rate.framesPerSecond();
        const is_df = rate.isDropFrame();

        if (is_df) {
            return fromFrameCountDropFrame(frame_count, fps);
        } else {
            return fromFrameCountNonDropFrame(frame_count, fps, rate);
        }
    }

    fn fromFrameCountNonDropFrame(frame_count: u64, fps: u8, rate: FrameRate) Self {
        var remaining = frame_count;
        const frames_per_minute = @as(u64, fps) * 60;
        const frames_per_hour = frames_per_minute * 60;

        const hours: u8 = @intCast(remaining / frames_per_hour);
        remaining %= frames_per_hour;

        const minutes: u8 = @intCast(remaining / frames_per_minute);
        remaining %= frames_per_minute;

        const seconds: u8 = @intCast(remaining / fps);
        const frames: u8 = @intCast(remaining % fps);

        return .{
            .hours = hours,
            .minutes = minutes,
            .seconds = seconds,
            .frames = frames,
            .drop_frame = false,
            .frame_rate = rate,
        };
    }

    fn fromFrameCountDropFrame(frame_count: u64, fps: u8) Self {
        // Drop-frame timecode skips frames 0 and 1 at the start of each minute,
        // except every 10th minute
        const drop_frames: u64 = if (fps == 30) 2 else 4;
        const frames_per_10_min: u64 = @as(u64, fps) * 60 * 10 - 9 * drop_frames;
        const frames_per_min: u64 = @as(u64, fps) * 60 - drop_frames;

        var d = frame_count;
        const d10 = d / frames_per_10_min;
        var m = d % frames_per_10_min;

        if (m >= drop_frames) {
            m -= drop_frames;
            const d1 = m / frames_per_min;
            m = m % frames_per_min + drop_frames;
            d = d10 * 10 + d1 + 1;
        } else {
            d = d10 * 10;
        }

        const hours: u8 = @intCast(d / 60);
        const minutes: u8 = @intCast(d % 60);
        const frames_this_min = m;
        const seconds: u8 = @intCast(frames_this_min / fps);
        const frames: u8 = @intCast(frames_this_min % fps);

        return .{
            .hours = hours,
            .minutes = minutes,
            .seconds = seconds,
            .frames = frames,
            .drop_frame = true,
            .frame_rate = if (fps == 30) .fps_29_97_df else .fps_59_94_df,
        };
    }

    /// Convert to frame count
    pub fn toFrameCount(self: Self) u64 {
        const fps = self.frame_rate.framesPerSecond();

        if (self.drop_frame) {
            return self.toFrameCountDropFrame(fps);
        } else {
            return self.toFrameCountNonDropFrame(fps);
        }
    }

    fn toFrameCountNonDropFrame(self: Self, fps: u8) u64 {
        const frames_per_minute = @as(u64, fps) * 60;
        const frames_per_hour = frames_per_minute * 60;

        return @as(u64, self.hours) * frames_per_hour +
            @as(u64, self.minutes) * frames_per_minute +
            @as(u64, self.seconds) * fps +
            self.frames;
    }

    fn toFrameCountDropFrame(self: Self, fps: u8) u64 {
        const drop_frames: u64 = if (fps == 30) 2 else 4;

        const total_minutes = @as(u64, self.hours) * 60 + self.minutes;
        const frames_per_minute = @as(u64, fps) * 60;

        var frame_count = total_minutes * frames_per_minute +
            @as(u64, self.seconds) * fps +
            self.frames;

        // Subtract dropped frames
        const drop_adjustment = drop_frames * (total_minutes - total_minutes / 10);
        frame_count -= drop_adjustment;

        return frame_count;
    }

    /// Convert to timestamp in microseconds
    pub fn toMicroseconds(self: Self) u64 {
        const frame_count = self.toFrameCount();
        const fps = self.frame_rate.toRational();
        // timestamp_us = frame_count * 1000000 * den / num
        return (frame_count * 1000000 * fps.den) / fps.num;
    }

    /// Format as string "HH:MM:SS:FF" or "HH:MM:SS;FF" (drop-frame)
    pub fn toString(self: Self, buf: []u8) []u8 {
        const sep: u8 = if (self.drop_frame) ';' else ':';
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}", .{
            self.hours,
            self.minutes,
            self.seconds,
            sep,
            self.frames,
        }) catch buf[0..0];
    }

    /// Parse from string
    pub fn fromString(str: []const u8) ?Self {
        if (str.len < 11) return null;

        const drop_frame = str[8] == ';';

        const hours = std.fmt.parseInt(u8, str[0..2], 10) catch return null;
        const minutes = std.fmt.parseInt(u8, str[3..5], 10) catch return null;
        const seconds = std.fmt.parseInt(u8, str[6..8], 10) catch return null;
        const frames = std.fmt.parseInt(u8, str[9..11], 10) catch return null;

        return .{
            .hours = hours,
            .minutes = minutes,
            .seconds = seconds,
            .frames = frames,
            .drop_frame = drop_frame,
            .frame_rate = if (drop_frame) .fps_29_97_df else .fps_30,
        };
    }

    /// Add frames to timecode
    pub fn addFrames(self: Self, frame_delta: i64) Self {
        const current = self.toFrameCount();
        const new_count = if (frame_delta < 0)
            current -| @as(u64, @intCast(-frame_delta))
        else
            current + @as(u64, @intCast(frame_delta));

        return fromFrameCount(new_count, self.frame_rate);
    }
};

// ============================================================================
// Compliance Checker
// ============================================================================

/// Check media for broadcast compliance
pub const ComplianceChecker = struct {
    allocator: std.mem.Allocator,
    color_standard: ColorStandard,
    broadcast_levels: BroadcastLevels,
    gamut_checker: GamutChecker,
    issues: std.ArrayList(ComplianceIssue),

    const Self = @This();

    pub const ComplianceIssue = struct {
        severity: Severity,
        category: Category,
        message: []const u8,
        frame_number: ?u64 = null,
        timestamp_us: ?u64 = null,

        pub const Severity = enum { info, warning, error_ };
        pub const Category = enum {
            level_out_of_range,
            gamut_violation,
            frame_rate_issue,
            timecode_error,
            color_space_mismatch,
            resolution_non_standard,
        };
    };

    pub fn init(allocator: std.mem.Allocator, standard: ColorStandard) Self {
        return .{
            .allocator = allocator,
            .color_standard = standard,
            .broadcast_levels = .{},
            .gamut_checker = GamutChecker.init(standard),
            .issues = std.ArrayList(ComplianceIssue).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.issues.deinit();
    }

    /// Check a video frame for compliance
    pub fn checkFrame(self: *Self, video_frame: *const frame.VideoFrame, frame_number: u64) !void {
        // Check level ranges
        const y_data = video_frame.getPlaneData(0) orelse return;

        var level_violations: u32 = 0;
        for (y_data) |pixel| {
            if (!self.broadcast_levels.isLumaSafe8(pixel)) {
                level_violations += 1;
            }
        }

        if (level_violations > 0) {
            try self.issues.append(.{
                .severity = .warning,
                .category = .level_out_of_range,
                .message = "Luma levels outside broadcast-safe range",
                .frame_number = frame_number,
            });
        }
    }

    /// Check frame rate compliance
    pub fn checkFrameRate(self: *Self, fps: types.Rational) !void {
        // Standard broadcast frame rates
        const standard_rates = [_]types.Rational{
            .{ .num = 24, .den = 1 },
            .{ .num = 24000, .den = 1001 },
            .{ .num = 25, .den = 1 },
            .{ .num = 30, .den = 1 },
            .{ .num = 30000, .den = 1001 },
            .{ .num = 50, .den = 1 },
            .{ .num = 60, .den = 1 },
            .{ .num = 60000, .den = 1001 },
        };

        var is_standard = false;
        for (standard_rates) |rate| {
            if (fps.num == rate.num and fps.den == rate.den) {
                is_standard = true;
                break;
            }
        }

        if (!is_standard) {
            try self.issues.append(.{
                .severity = .info,
                .category = .frame_rate_issue,
                .message = "Non-standard frame rate detected",
            });
        }
    }

    /// Check resolution compliance
    pub fn checkResolution(self: *Self, width: u32, height: u32) !void {
        // Standard broadcast resolutions
        const standard_resolutions = [_]struct { w: u32, h: u32, name: []const u8 }{
            .{ .w = 720, .h = 480, .name = "SD NTSC" },
            .{ .w = 720, .h = 576, .name = "SD PAL" },
            .{ .w = 1280, .h = 720, .name = "HD 720p" },
            .{ .w = 1920, .h = 1080, .name = "HD 1080" },
            .{ .w = 2048, .h = 1080, .name = "2K" },
            .{ .w = 3840, .h = 2160, .name = "UHD 4K" },
            .{ .w = 4096, .h = 2160, .name = "DCI 4K" },
            .{ .w = 7680, .h = 4320, .name = "8K" },
        };

        var is_standard = false;
        for (standard_resolutions) |res| {
            if (width == res.w and height == res.h) {
                is_standard = true;
                break;
            }
        }

        if (!is_standard) {
            try self.issues.append(.{
                .severity = .info,
                .category = .resolution_non_standard,
                .message = "Non-standard resolution",
            });
        }
    }

    /// Get all compliance issues
    pub fn getIssues(self: *const Self) []const ComplianceIssue {
        return self.issues.items;
    }

    /// Check if media passes compliance
    pub fn passes(self: *const Self) bool {
        for (self.issues.items) |issue| {
            if (issue.severity == .error_) return false;
        }
        return true;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MatrixCoefficients BT.709" {
    const matrix = MatrixCoefficients.BT709;

    // Test white
    const white = matrix.rgbToYcbcr(1.0, 1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), white.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), white.cb, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), white.cr, 0.001);

    // Round-trip
    const rgb = matrix.ycbcrToRgb(white.y, white.cb, white.cr);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rgb.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rgb.g, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), rgb.b, 0.001);
}

test "BroadcastLevels clamping" {
    const levels = BroadcastLevels{};

    try std.testing.expectEqual(@as(u8, 16), levels.clampLuma8(0));
    try std.testing.expectEqual(@as(u8, 235), levels.clampLuma8(255));
    try std.testing.expectEqual(@as(u8, 128), levels.clampLuma8(128));
}

test "BroadcastLevels conversion" {
    const levels = BroadcastLevels{};

    // Full to limited
    try std.testing.expectEqual(@as(u8, 16), levels.fullToLimited8(0));
    try std.testing.expectEqual(@as(u8, 235), levels.fullToLimited8(255));

    // Limited to full
    try std.testing.expectEqual(@as(u8, 0), levels.limitedToFull8(16));
    try std.testing.expectEqual(@as(u8, 255), levels.limitedToFull8(235));
}

test "SmptTimecode non-drop-frame" {
    const tc = SmptTimecode.fromFrameCount(108000, .fps_30);

    try std.testing.expectEqual(@as(u8, 1), tc.hours);
    try std.testing.expectEqual(@as(u8, 0), tc.minutes);
    try std.testing.expectEqual(@as(u8, 0), tc.seconds);
    try std.testing.expectEqual(@as(u8, 0), tc.frames);

    // Round-trip
    const frame_count = tc.toFrameCount();
    try std.testing.expectEqual(@as(u64, 108000), frame_count);
}

test "SmptTimecode string format" {
    var tc = SmptTimecode{
        .hours = 1,
        .minutes = 23,
        .seconds = 45,
        .frames = 12,
        .drop_frame = false,
        .frame_rate = .fps_30,
    };

    var buf: [12]u8 = undefined;
    const str = tc.toString(&buf);
    try std.testing.expectEqualStrings("01:23:45:12", str);

    tc.drop_frame = true;
    tc.frame_rate = .fps_29_97_df;
    const str_df = tc.toString(&buf);
    try std.testing.expectEqualStrings("01:23:45;12", str_df);
}

test "SmptTimecode parse" {
    const tc = SmptTimecode.fromString("01:23:45:12");
    try std.testing.expect(tc != null);
    try std.testing.expectEqual(@as(u8, 1), tc.?.hours);
    try std.testing.expectEqual(@as(u8, 23), tc.?.minutes);
    try std.testing.expectEqual(@as(u8, 45), tc.?.seconds);
    try std.testing.expectEqual(@as(u8, 12), tc.?.frames);
    try std.testing.expect(!tc.?.drop_frame);

    const tc_df = SmptTimecode.fromString("01:23:45;12");
    try std.testing.expect(tc_df != null);
    try std.testing.expect(tc_df.?.drop_frame);
}

test "TransferCharacteristics BT.709" {
    const transfer = TransferCharacteristics{ .standard = .bt709 };

    // Round-trip test
    const original: f64 = 0.5;
    const encoded = transfer.apply(original);
    const decoded = transfer.applyInverse(encoded);
    try std.testing.expectApproxEqAbs(original, decoded, 0.001);
}
