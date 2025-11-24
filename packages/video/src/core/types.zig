// Home Video Library - Core Types
// Foundational types for video/audio processing

const std = @import("std");

// ============================================================================
// Video Formats (Container Formats)
// ============================================================================

pub const VideoFormat = enum {
    mp4,
    mov,
    webm,
    mkv,
    avi,
    flv,
    ts, // MPEG-TS
    m2ts, // Blu-ray
    unknown,

    pub fn fromExtension(ext: []const u8) VideoFormat {
        const lower = blk: {
            var buf: [16]u8 = undefined;
            const len = @min(ext.len, buf.len);
            for (ext[0..len], 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            break :blk buf[0..len];
        };

        if (std.mem.eql(u8, lower, ".mp4") or std.mem.eql(u8, lower, ".m4v")) return .mp4;
        if (std.mem.eql(u8, lower, ".mov")) return .mov;
        if (std.mem.eql(u8, lower, ".webm")) return .webm;
        if (std.mem.eql(u8, lower, ".mkv")) return .mkv;
        if (std.mem.eql(u8, lower, ".avi")) return .avi;
        if (std.mem.eql(u8, lower, ".flv")) return .flv;
        if (std.mem.eql(u8, lower, ".ts") or std.mem.eql(u8, lower, ".mts")) return .ts;
        if (std.mem.eql(u8, lower, ".m2ts")) return .m2ts;
        return .unknown;
    }

    pub fn mimeType(self: VideoFormat) []const u8 {
        return switch (self) {
            .mp4 => "video/mp4",
            .mov => "video/quicktime",
            .webm => "video/webm",
            .mkv => "video/x-matroska",
            .avi => "video/x-msvideo",
            .flv => "video/x-flv",
            .ts => "video/mp2t",
            .m2ts => "video/mp2t",
            .unknown => "application/octet-stream",
        };
    }

    pub fn extension(self: VideoFormat) []const u8 {
        return switch (self) {
            .mp4 => ".mp4",
            .mov => ".mov",
            .webm => ".webm",
            .mkv => ".mkv",
            .avi => ".avi",
            .flv => ".flv",
            .ts => ".ts",
            .m2ts => ".m2ts",
            .unknown => "",
        };
    }
};

// ============================================================================
// Audio Formats (Container Formats)
// ============================================================================

pub const AudioFormat = enum {
    mp3,
    aac,
    ogg,
    wav,
    flac,
    m4a,
    wma,
    aiff,
    unknown,

    pub fn fromExtension(ext: []const u8) AudioFormat {
        const lower = blk: {
            var buf: [16]u8 = undefined;
            const len = @min(ext.len, buf.len);
            for (ext[0..len], 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            break :blk buf[0..len];
        };

        if (std.mem.eql(u8, lower, ".mp3")) return .mp3;
        if (std.mem.eql(u8, lower, ".aac")) return .aac;
        if (std.mem.eql(u8, lower, ".ogg") or std.mem.eql(u8, lower, ".oga")) return .ogg;
        if (std.mem.eql(u8, lower, ".wav") or std.mem.eql(u8, lower, ".wave")) return .wav;
        if (std.mem.eql(u8, lower, ".flac")) return .flac;
        if (std.mem.eql(u8, lower, ".m4a")) return .m4a;
        if (std.mem.eql(u8, lower, ".wma")) return .wma;
        if (std.mem.eql(u8, lower, ".aiff") or std.mem.eql(u8, lower, ".aif")) return .aiff;
        return .unknown;
    }

    pub fn mimeType(self: AudioFormat) []const u8 {
        return switch (self) {
            .mp3 => "audio/mpeg",
            .aac => "audio/aac",
            .ogg => "audio/ogg",
            .wav => "audio/wav",
            .flac => "audio/flac",
            .m4a => "audio/mp4",
            .wma => "audio/x-ms-wma",
            .aiff => "audio/aiff",
            .unknown => "application/octet-stream",
        };
    }
};

// ============================================================================
// Pixel Formats
// ============================================================================

pub const PixelFormat = enum {
    // YUV planar formats (most common for video)
    yuv420p, // 4:2:0 planar, 12 bpp (most common: H.264, VP9)
    yuv422p, // 4:2:2 planar, 16 bpp (ProRes, broadcast)
    yuv444p, // 4:4:4 planar, 24 bpp (high quality)
    yuv420p10le, // 4:2:0 10-bit (HDR content)
    yuv420p10be,
    yuv422p10le,
    yuv444p10le,

    // NV12/NV21 (semi-planar, common for hardware)
    nv12, // Y plane + interleaved UV (most hardware decoders)
    nv21, // Y plane + interleaved VU (Android cameras)

    // RGB formats
    rgb24, // 24 bpp, packed RGB
    bgr24, // 24 bpp, packed BGR (Windows bitmap order)
    rgba32, // 32 bpp, packed RGBA
    bgra32, // 32 bpp, packed BGRA
    argb32, // 32 bpp, packed ARGB
    abgr32, // 32 bpp, packed ABGR

    // RGB 10-bit
    rgb48le, // 48 bpp, 16 bits per component
    rgba64le, // 64 bpp, 16 bits per component

    // Grayscale
    gray8, // 8-bit grayscale
    gray16le, // 16-bit grayscale

    // Packed YUV
    yuyv422, // YUYV 4:2:2 packed (webcams)
    uyvy422, // UYVY 4:2:2 packed

    pub fn bytesPerPixel(self: PixelFormat) ?f32 {
        return switch (self) {
            .yuv420p => 1.5,
            .yuv422p => 2.0,
            .yuv444p => 3.0,
            .yuv420p10le, .yuv420p10be => 1.875, // 15 bits
            .yuv422p10le => 2.5,
            .yuv444p10le => 3.75,
            .nv12, .nv21 => 1.5,
            .rgb24, .bgr24 => 3.0,
            .rgba32, .bgra32, .argb32, .abgr32 => 4.0,
            .rgb48le => 6.0,
            .rgba64le => 8.0,
            .gray8 => 1.0,
            .gray16le => 2.0,
            .yuyv422, .uyvy422 => 2.0,
        };
    }

    pub fn isPlanar(self: PixelFormat) bool {
        return switch (self) {
            .yuv420p, .yuv422p, .yuv444p, .yuv420p10le, .yuv420p10be, .yuv422p10le, .yuv444p10le => true,
            .nv12, .nv21 => true, // semi-planar
            else => false,
        };
    }

    pub fn hasAlpha(self: PixelFormat) bool {
        return switch (self) {
            .rgba32, .bgra32, .argb32, .abgr32, .rgba64le => true,
            else => false,
        };
    }

    pub fn bitDepth(self: PixelFormat) u8 {
        return switch (self) {
            .yuv420p10le, .yuv420p10be, .yuv422p10le, .yuv444p10le => 10,
            .rgb48le, .rgba64le, .gray16le => 16,
            else => 8,
        };
    }
};

// ============================================================================
// Sample Formats (Audio)
// ============================================================================

pub const SampleFormat = enum {
    // Signed integers
    s8, // 8-bit signed
    s16le, // 16-bit signed, little-endian (most common)
    s16be, // 16-bit signed, big-endian
    s24le, // 24-bit signed, little-endian (pro audio)
    s24be, // 24-bit signed, big-endian
    s32le, // 32-bit signed, little-endian
    s32be, // 32-bit signed, big-endian

    // Unsigned
    u8, // 8-bit unsigned (WAV)

    // Float
    f32le, // 32-bit float, little-endian (most processing)
    f32be, // 32-bit float, big-endian
    f64le, // 64-bit float, little-endian
    f64be, // 64-bit float, big-endian

    // Planar variants (each channel in separate buffer)
    s16p, // 16-bit signed planar
    s32p, // 32-bit signed planar
    f32p, // 32-bit float planar
    f64p, // 64-bit float planar

    pub fn bytesPerSample(self: SampleFormat) u8 {
        return switch (self) {
            .s8, .u8 => 1,
            .s16le, .s16be, .s16p => 2,
            .s24le, .s24be => 3,
            .s32le, .s32be, .f32le, .f32be, .s32p, .f32p => 4,
            .f64le, .f64be, .f64p => 8,
        };
    }

    pub fn isPlanar(self: SampleFormat) bool {
        return switch (self) {
            .s16p, .s32p, .f32p, .f64p => true,
            else => false,
        };
    }

    pub fn isFloat(self: SampleFormat) bool {
        return switch (self) {
            .f32le, .f32be, .f64le, .f64be, .f32p, .f64p => true,
            else => false,
        };
    }

    pub fn isBigEndian(self: SampleFormat) bool {
        return switch (self) {
            .s16be, .s24be, .s32be, .f32be, .f64be => true,
            else => false,
        };
    }

    pub fn bitDepth(self: SampleFormat) u8 {
        return self.bytesPerSample() * 8;
    }
};

// ============================================================================
// Timestamp (Microsecond precision internally)
// ============================================================================

pub const Timestamp = struct {
    /// Timestamp in microseconds
    us: i64,

    const Self = @This();

    pub const ZERO = Self{ .us = 0 };
    pub const INVALID = Self{ .us = std.math.minInt(i64) };

    /// Create from seconds (f64)
    pub fn fromSeconds(seconds: f64) Self {
        return .{ .us = @intFromFloat(seconds * 1_000_000.0) };
    }

    /// Create from milliseconds
    pub fn fromMilliseconds(ms: i64) Self {
        return .{ .us = ms * 1_000 };
    }

    /// Create from microseconds
    pub fn fromMicroseconds(us: i64) Self {
        return .{ .us = us };
    }

    /// Create from a time base (pts * time_base)
    pub fn fromTimeBase(pts: i64, time_base: Rational) Self {
        const us = @divFloor(pts * time_base.num * 1_000_000, time_base.denom);
        return .{ .us = us };
    }

    /// Convert to seconds (f64)
    pub fn toSeconds(self: Self) f64 {
        return @as(f64, @floatFromInt(self.us)) / 1_000_000.0;
    }

    /// Convert to milliseconds
    pub fn toMilliseconds(self: Self) i64 {
        return @divFloor(self.us, 1_000);
    }

    /// Convert to microseconds
    pub fn toMicroseconds(self: Self) i64 {
        return self.us;
    }

    /// Convert to a time base
    pub fn toTimeBase(self: Self, time_base: Rational) i64 {
        return @divFloor(self.us * time_base.denom, time_base.num * 1_000_000);
    }

    pub fn isValid(self: Self) bool {
        return self.us != INVALID.us;
    }

    pub fn add(self: Self, other: Self) Self {
        return .{ .us = self.us + other.us };
    }

    pub fn sub(self: Self, other: Self) Self {
        return .{ .us = self.us - other.us };
    }

    pub fn lessThan(self: Self, other: Self) bool {
        return self.us < other.us;
    }

    pub fn greaterThan(self: Self, other: Self) bool {
        return self.us > other.us;
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.us == other.us;
    }
};

// ============================================================================
// Duration
// ============================================================================

pub const Duration = struct {
    /// Duration in microseconds
    us: u64,

    const Self = @This();

    pub const ZERO = Self{ .us = 0 };

    pub fn fromSeconds(seconds: f64) Self {
        return .{ .us = @intFromFloat(@abs(seconds) * 1_000_000.0) };
    }

    pub fn fromMilliseconds(ms: u64) Self {
        return .{ .us = ms * 1_000 };
    }

    pub fn fromMicroseconds(us: u64) Self {
        return .{ .us = us };
    }

    pub fn toSeconds(self: Self) f64 {
        return @as(f64, @floatFromInt(self.us)) / 1_000_000.0;
    }

    pub fn toMilliseconds(self: Self) u64 {
        return self.us / 1_000;
    }

    pub fn toMicroseconds(self: Self) u64 {
        return self.us;
    }

    pub fn add(self: Self, other: Self) Self {
        return .{ .us = self.us + other.us };
    }

    pub fn sub(self: Self, other: Self) Self {
        return .{ .us = self.us -| other.us };
    }
};

// ============================================================================
// Rational (for frame rates, time bases)
// ============================================================================

pub const Rational = struct {
    num: i64,
    denom: i64,

    const Self = @This();

    pub fn init(num: i64, denom: i64) Self {
        var r = Self{ .num = num, .denom = denom };
        r.reduce();
        return r;
    }

    /// Common frame rates
    pub const FPS_24 = Self{ .num = 24, .denom = 1 };
    pub const FPS_25 = Self{ .num = 25, .denom = 1 };
    pub const FPS_30 = Self{ .num = 30, .denom = 1 };
    pub const FPS_50 = Self{ .num = 50, .denom = 1 };
    pub const FPS_60 = Self{ .num = 60, .denom = 1 };
    pub const FPS_23_976 = Self{ .num = 24000, .denom = 1001 };
    pub const FPS_29_97 = Self{ .num = 30000, .denom = 1001 };
    pub const FPS_59_94 = Self{ .num = 60000, .denom = 1001 };

    /// Common time bases
    pub const TIME_BASE_MS = Self{ .num = 1, .denom = 1000 };
    pub const TIME_BASE_US = Self{ .num = 1, .denom = 1000000 };
    pub const TIME_BASE_90K = Self{ .num = 1, .denom = 90000 }; // MPEG-TS

    pub fn toFloat(self: Self) f64 {
        if (self.denom == 0) return 0.0;
        return @as(f64, @floatFromInt(self.num)) / @as(f64, @floatFromInt(self.denom));
    }

    pub fn fromFloat(value: f64) Self {
        // Convert to rational with reasonable precision
        const precision: i64 = 1000000;
        const num: i64 = @intFromFloat(value * @as(f64, @floatFromInt(precision)));
        return Self.init(num, precision);
    }

    pub fn invert(self: Self) Self {
        return Self{ .num = self.denom, .denom = self.num };
    }

    pub fn multiply(self: Self, other: Self) Self {
        return Self.init(self.num * other.num, self.denom * other.denom);
    }

    pub fn divide(self: Self, other: Self) Self {
        return Self.init(self.num * other.denom, self.denom * other.num);
    }

    fn gcd(a: i64, b: i64) i64 {
        var x = if (a < 0) -a else a;
        var y = if (b < 0) -b else b;
        while (y != 0) {
            const t = y;
            y = @mod(x, y);
            x = t;
        }
        return x;
    }

    fn reduce(self: *Self) void {
        if (self.denom == 0) {
            self.num = 0;
            self.denom = 1;
            return;
        }

        const g = gcd(self.num, self.denom);
        if (g > 1) {
            self.num = @divExact(self.num, g);
            self.denom = @divExact(self.denom, g);
        }

        // Ensure denominator is positive
        if (self.denom < 0) {
            self.num = -self.num;
            self.denom = -self.denom;
        }
    }
};

// ============================================================================
// Color Space
// ============================================================================

pub const ColorSpace = enum {
    bt601, // SD video (NTSC/PAL)
    bt709, // HD video
    bt2020, // UHD/HDR video
    srgb, // Computer displays
    display_p3, // Wide gamut displays
    adobe_rgb, // Photography
    unknown,

    pub fn isHDR(self: ColorSpace) bool {
        return self == .bt2020;
    }
};

pub const ColorRange = enum {
    limited, // 16-235 (video)
    full, // 0-255 (PC)
    unknown,
};

pub const ColorPrimaries = enum {
    bt709,
    bt470m,
    bt470bg,
    smpte170m,
    smpte240m,
    film,
    bt2020,
    smpte428,
    smpte431, // DCI-P3
    smpte432, // Display P3
    unknown,
};

pub const ColorTransfer = enum {
    bt709,
    gamma22,
    gamma28,
    smpte170m,
    smpte240m,
    linear,
    log,
    log_sqrt,
    iec61966_2_4,
    bt1361e,
    iec61966_2_1, // sRGB
    bt2020_10,
    bt2020_12,
    smpte2084, // PQ (HDR10)
    smpte428,
    arib_std_b67, // HLG
    unknown,
};

pub const ChromaLocation = enum {
    unspecified,
    left,
    center,
    topleft,
    top,
    bottomleft,
    bottom,
};

// ============================================================================
// Channel Layout (Audio)
// ============================================================================

pub const ChannelLayout = enum {
    mono,
    stereo,
    stereo_downmix, // Lt/Rt
    layout_2_1, // FL FR LFE
    layout_3_0, // FL FR FC
    layout_3_1, // FL FR FC LFE
    layout_4_0, // FL FR FC BC
    layout_quad, // FL FR BL BR
    layout_5_0, // FL FR FC BL BR
    layout_5_1, // FL FR FC LFE BL BR
    layout_6_0, // FL FR FC BC SL SR
    layout_6_1, // FL FR FC LFE BC SL SR
    layout_7_0, // FL FR FC BL BR SL SR
    layout_7_1, // FL FR FC LFE BL BR SL SR

    pub fn channelCount(self: ChannelLayout) u8 {
        return switch (self) {
            .mono => 1,
            .stereo, .stereo_downmix => 2,
            .layout_2_1, .layout_3_0 => 3,
            .layout_3_1, .layout_4_0, .layout_quad => 4,
            .layout_5_0 => 5,
            .layout_5_1, .layout_6_0 => 6,
            .layout_6_1, .layout_7_0 => 7,
            .layout_7_1 => 8,
        };
    }

    pub fn fromChannelCount(count: u8) ChannelLayout {
        return switch (count) {
            1 => .mono,
            2 => .stereo,
            3 => .layout_3_0,
            4 => .layout_quad,
            5 => .layout_5_0,
            6 => .layout_5_1,
            7 => .layout_6_1,
            8 => .layout_7_1,
            else => .mono,
        };
    }
};

// ============================================================================
// Video Codec
// ============================================================================

pub const VideoCodec = enum {
    h264, // AVC
    hevc, // H.265
    vp8,
    vp9,
    av1,
    mpeg2,
    mpeg4, // MPEG-4 Part 2
    mjpeg,
    prores,
    raw,
    unknown,

    pub fn fourCC(self: VideoCodec) [4]u8 {
        return switch (self) {
            .h264 => "avc1".*,
            .hevc => "hvc1".*,
            .vp8 => "vp08".*,
            .vp9 => "vp09".*,
            .av1 => "av01".*,
            .mpeg2 => "mp2v".*,
            .mpeg4 => "mp4v".*,
            .mjpeg => "mjpg".*,
            .prores => "apcn".*,
            .raw => "raw ".*,
            .unknown => "\x00\x00\x00\x00".*,
        };
    }
};

// ============================================================================
// Audio Codec
// ============================================================================

pub const AudioCodec = enum {
    aac,
    mp3,
    opus,
    vorbis,
    flac,
    pcm, // Uncompressed
    ac3,
    eac3, // E-AC3 / Dolby Digital Plus
    dts,
    alac, // Apple Lossless
    alaw,
    ulaw,
    unknown,

    pub fn isLossless(self: AudioCodec) bool {
        return switch (self) {
            .flac, .pcm, .alac => true,
            else => false,
        };
    }
};

// ============================================================================
// Quality Presets
// ============================================================================

pub const QualityPreset = enum {
    very_low, // Fast encoding, small file
    low,
    medium,
    high,
    very_high, // Slow encoding, best quality

    /// Get CRF value for H.264/HEVC/VP9
    pub fn toCRF(self: QualityPreset) u8 {
        return switch (self) {
            .very_low => 35,
            .low => 28,
            .medium => 23,
            .high => 18,
            .very_high => 14,
        };
    }

    /// Get approximate bitrate multiplier (relative to medium)
    pub fn bitrateMultiplier(self: QualityPreset) f32 {
        return switch (self) {
            .very_low => 0.25,
            .low => 0.5,
            .medium => 1.0,
            .high => 2.0,
            .very_high => 4.0,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Timestamp conversions" {
    const ts = Timestamp.fromSeconds(1.5);
    try std.testing.expectEqual(@as(i64, 1500000), ts.us);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ts.toSeconds(), 0.0001);
    try std.testing.expectEqual(@as(i64, 1500), ts.toMilliseconds());
}

test "Rational reduction" {
    const r = Rational.init(30000, 1001);
    try std.testing.expectApproxEqAbs(@as(f64, 29.97), r.toFloat(), 0.01);
}

test "Duration" {
    const d = Duration.fromSeconds(60.5);
    try std.testing.expectEqual(@as(u64, 60500000), d.us);
    try std.testing.expectApproxEqAbs(@as(f64, 60.5), d.toSeconds(), 0.0001);
}

test "PixelFormat properties" {
    try std.testing.expect(!PixelFormat.yuv420p.hasAlpha());
    try std.testing.expect(PixelFormat.rgba32.hasAlpha());
    try std.testing.expectEqual(@as(u8, 8), PixelFormat.yuv420p.bitDepth());
    try std.testing.expectEqual(@as(u8, 10), PixelFormat.yuv420p10le.bitDepth());
}

test "ChannelLayout" {
    try std.testing.expectEqual(@as(u8, 2), ChannelLayout.stereo.channelCount());
    try std.testing.expectEqual(@as(u8, 6), ChannelLayout.layout_5_1.channelCount());
    try std.testing.expectEqual(ChannelLayout.stereo, ChannelLayout.fromChannelCount(2));
}
