// Home Media Library - Core Types
// Unified type system for video, audio, and image processing

const std = @import("std");
const video = @import("video");
const audio = @import("audio");
const image = @import("image");

// ============================================================================
// Media Type Enumeration
// ============================================================================

/// Primary media type classification
pub const MediaType = enum {
    video,
    audio,
    image,
    subtitle,
    attachment,
    unknown,

    pub fn fromExtension(ext: []const u8) MediaType {
        // Video extensions
        if (isVideoExtension(ext)) return .video;
        // Audio extensions
        if (isAudioExtension(ext)) return .audio;
        // Image extensions
        if (isImageExtension(ext)) return .image;
        // Subtitle extensions
        if (isSubtitleExtension(ext)) return .subtitle;
        return .unknown;
    }

    fn isVideoExtension(ext: []const u8) bool {
        const video_exts = [_][]const u8{
            ".mp4", ".mkv", ".webm", ".avi", ".mov", ".flv", ".wmv", ".m4v",
            ".ts", ".mts", ".m2ts", ".vob", ".ogv", ".3gp", ".3g2", ".mxf",
        };
        for (video_exts) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return true;
        }
        return false;
    }

    fn isAudioExtension(ext: []const u8) bool {
        const audio_exts = [_][]const u8{
            ".mp3", ".wav", ".flac", ".aac", ".ogg", ".opus", ".m4a", ".wma",
            ".aiff", ".aif", ".ape", ".tta", ".wv", ".dsd", ".dsf", ".dff",
            ".mid", ".midi", ".caf", ".mka",
        };
        for (audio_exts) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return true;
        }
        return false;
    }

    fn isImageExtension(ext: []const u8) bool {
        const image_exts = [_][]const u8{
            ".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tiff", ".tif",
            ".avif", ".heic", ".heif", ".jp2", ".j2k", ".jpx", ".svg", ".ico",
            ".tga", ".ppm", ".pgm", ".pbm", ".qoi", ".hdr", ".dds", ".psd",
            ".exr", ".jxl", ".flif", ".raw", ".dng", ".cr2", ".nef", ".arw",
        };
        for (image_exts) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return true;
        }
        return false;
    }

    fn isSubtitleExtension(ext: []const u8) bool {
        const sub_exts = [_][]const u8{
            ".srt", ".vtt", ".ass", ".ssa", ".sub", ".idx", ".ttml", ".dfxp",
        };
        for (sub_exts) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return true;
        }
        return false;
    }
};

// ============================================================================
// Video Codec Enumeration
// ============================================================================

pub const VideoCodec = enum {
    h264,
    hevc,
    vp8,
    vp9,
    av1,
    vvc,
    mpeg2,
    mpeg4,
    mjpeg,
    prores,
    dnxhd,
    theora,
    wmv,
    copy, // Stream copy (no re-encoding)
    unknown,

    pub fn displayName(self: VideoCodec) []const u8 {
        return switch (self) {
            .h264 => "H.264/AVC",
            .hevc => "H.265/HEVC",
            .vp8 => "VP8",
            .vp9 => "VP9",
            .av1 => "AV1",
            .vvc => "H.266/VVC",
            .mpeg2 => "MPEG-2",
            .mpeg4 => "MPEG-4",
            .mjpeg => "Motion JPEG",
            .prores => "Apple ProRes",
            .dnxhd => "Avid DNxHD",
            .theora => "Theora",
            .wmv => "Windows Media Video",
            .copy => "Copy (no encode)",
            .unknown => "Unknown",
        };
    }

    pub fn fourcc(self: VideoCodec) ?[4]u8 {
        return switch (self) {
            .h264 => .{ 'a', 'v', 'c', '1' },
            .hevc => .{ 'h', 'v', 'c', '1' },
            .vp8 => .{ 'V', 'P', '8', '0' },
            .vp9 => .{ 'v', 'p', '0', '9' },
            .av1 => .{ 'a', 'v', '0', '1' },
            .vvc => .{ 'v', 'v', 'c', '1' },
            .mpeg2 => .{ 'm', 'p', 'g', '2' },
            .mpeg4 => .{ 'm', 'p', '4', 'v' },
            .mjpeg => .{ 'm', 'j', 'p', 'g' },
            .prores => .{ 'a', 'p', 'c', 'h' },
            .dnxhd => .{ 'A', 'V', 'd', 'n' },
            else => null,
        };
    }
};

// ============================================================================
// Audio Codec Enumeration
// ============================================================================

pub const AudioCodec = enum {
    aac,
    mp3,
    opus,
    flac,
    vorbis,
    pcm,
    ac3,
    eac3,
    dts,
    alac,
    wma,
    copy, // Stream copy (no re-encoding)
    unknown,

    pub fn displayName(self: AudioCodec) []const u8 {
        return switch (self) {
            .aac => "AAC",
            .mp3 => "MP3",
            .opus => "Opus",
            .flac => "FLAC",
            .vorbis => "Vorbis",
            .pcm => "PCM",
            .ac3 => "AC-3/Dolby Digital",
            .eac3 => "E-AC-3/Dolby Digital Plus",
            .dts => "DTS",
            .alac => "Apple Lossless",
            .wma => "Windows Media Audio",
            .copy => "Copy (no encode)",
            .unknown => "Unknown",
        };
    }

    pub fn isLossless(self: AudioCodec) bool {
        return switch (self) {
            .flac, .pcm, .alac => true,
            else => false,
        };
    }
};

// ============================================================================
// Container Format Enumeration
// ============================================================================

pub const ContainerFormat = enum {
    mp4,
    mov,
    mkv,
    webm,
    avi,
    flv,
    ts,
    m2ts,
    ogg,
    wav,
    mp3,
    flac,
    aac,
    mxf,
    gif,
    png,
    jpeg,
    webp,
    avif,
    heic,
    unknown,

    pub fn fromExtension(ext: []const u8) ContainerFormat {
        if (std.mem.eql(u8, ext, ".mp4") or std.mem.eql(u8, ext, ".m4v")) return .mp4;
        if (std.mem.eql(u8, ext, ".mov")) return .mov;
        if (std.mem.eql(u8, ext, ".mkv") or std.mem.eql(u8, ext, ".mka")) return .mkv;
        if (std.mem.eql(u8, ext, ".webm")) return .webm;
        if (std.mem.eql(u8, ext, ".avi")) return .avi;
        if (std.mem.eql(u8, ext, ".flv")) return .flv;
        if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".mts")) return .ts;
        if (std.mem.eql(u8, ext, ".m2ts")) return .m2ts;
        if (std.mem.eql(u8, ext, ".ogg") or std.mem.eql(u8, ext, ".ogv")) return .ogg;
        if (std.mem.eql(u8, ext, ".wav")) return .wav;
        if (std.mem.eql(u8, ext, ".mp3")) return .mp3;
        if (std.mem.eql(u8, ext, ".flac")) return .flac;
        if (std.mem.eql(u8, ext, ".aac") or std.mem.eql(u8, ext, ".m4a")) return .aac;
        if (std.mem.eql(u8, ext, ".mxf")) return .mxf;
        if (std.mem.eql(u8, ext, ".gif")) return .gif;
        if (std.mem.eql(u8, ext, ".png")) return .png;
        if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return .jpeg;
        if (std.mem.eql(u8, ext, ".webp")) return .webp;
        if (std.mem.eql(u8, ext, ".avif")) return .avif;
        if (std.mem.eql(u8, ext, ".heic") or std.mem.eql(u8, ext, ".heif")) return .heic;
        return .unknown;
    }

    pub fn mimeType(self: ContainerFormat) []const u8 {
        return switch (self) {
            .mp4 => "video/mp4",
            .mov => "video/quicktime",
            .mkv => "video/x-matroska",
            .webm => "video/webm",
            .avi => "video/x-msvideo",
            .flv => "video/x-flv",
            .ts, .m2ts => "video/mp2t",
            .ogg => "video/ogg",
            .wav => "audio/wav",
            .mp3 => "audio/mpeg",
            .flac => "audio/flac",
            .aac => "audio/aac",
            .mxf => "application/mxf",
            .gif => "image/gif",
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .avif => "image/avif",
            .heic => "image/heic",
            .unknown => "application/octet-stream",
        };
    }

    pub fn supportsVideo(self: ContainerFormat) bool {
        return switch (self) {
            .mp4, .mov, .mkv, .webm, .avi, .flv, .ts, .m2ts, .ogg, .mxf, .gif => true,
            else => false,
        };
    }

    pub fn supportsAudio(self: ContainerFormat) bool {
        return switch (self) {
            .mp4, .mov, .mkv, .webm, .avi, .flv, .ts, .m2ts, .ogg, .mxf,
            .wav, .mp3, .flac, .aac,
            => true,
            else => false,
        };
    }
};

// ============================================================================
// Time Representation
// ============================================================================

/// Rational number for precise time representation
pub const Rational = struct {
    num: i64,
    den: i64,

    pub const ZERO = Rational{ .num = 0, .den = 1 };
    pub const ONE = Rational{ .num = 1, .den = 1 };

    pub fn init(num: i64, den: i64) Rational {
        if (den == 0) return .{ .num = 0, .den = 1 };
        return .{ .num = num, .den = den };
    }

    pub fn fromFloat(value: f64) Rational {
        const scale: i64 = 1000000;
        return .{
            .num = @intFromFloat(value * @as(f64, @floatFromInt(scale))),
            .den = scale,
        };
    }

    pub fn toFloat(self: Rational) f64 {
        if (self.den == 0) return 0;
        return @as(f64, @floatFromInt(self.num)) / @as(f64, @floatFromInt(self.den));
    }

    pub fn reduce(self: Rational) Rational {
        if (self.num == 0) return .{ .num = 0, .den = 1 };
        const g = gcd(@abs(self.num), @abs(self.den));
        return .{
            .num = @divExact(self.num, @as(i64, @intCast(g))),
            .den = @divExact(self.den, @as(i64, @intCast(g))),
        };
    }

    fn gcd(a: u64, b: u64) u64 {
        var x = a;
        var y = b;
        while (y != 0) {
            const t = y;
            y = x % y;
            x = t;
        }
        return x;
    }
};

/// Timestamp in microseconds
pub const Timestamp = struct {
    us: i64,

    pub const ZERO = Timestamp{ .us = 0 };

    pub fn fromSeconds(seconds: f64) Timestamp {
        return .{ .us = @intFromFloat(seconds * 1_000_000.0) };
    }

    pub fn fromMilliseconds(ms: i64) Timestamp {
        return .{ .us = ms * 1000 };
    }

    pub fn toSeconds(self: Timestamp) f64 {
        return @as(f64, @floatFromInt(self.us)) / 1_000_000.0;
    }

    pub fn toMilliseconds(self: Timestamp) i64 {
        return @divFloor(self.us, 1000);
    }

    pub fn add(self: Timestamp, other: Timestamp) Timestamp {
        return .{ .us = self.us + other.us };
    }

    pub fn sub(self: Timestamp, other: Timestamp) Timestamp {
        return .{ .us = self.us - other.us };
    }
};

/// Duration in microseconds
pub const Duration = struct {
    us: u64,

    pub const ZERO = Duration{ .us = 0 };

    pub fn fromSeconds(seconds: f64) Duration {
        return .{ .us = @intFromFloat(seconds * 1_000_000.0) };
    }

    pub fn fromMilliseconds(ms: u64) Duration {
        return .{ .us = ms * 1000 };
    }

    pub fn toSeconds(self: Duration) f64 {
        return @as(f64, @floatFromInt(self.us)) / 1_000_000.0;
    }

    pub fn toMilliseconds(self: Duration) u64 {
        return self.us / 1000;
    }
};

// ============================================================================
// Media Information
// ============================================================================

/// Comprehensive media file information
pub const MediaInfo = struct {
    // General
    path: ?[]const u8 = null,
    format: ContainerFormat = .unknown,
    duration: Duration = Duration.ZERO,
    bitrate: u32 = 0, // Total bitrate in kbps
    size_bytes: u64 = 0,

    // Video stream info
    has_video: bool = false,
    video_codec: VideoCodec = .unknown,
    video_codec_name: ?[]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    frame_rate: Rational = Rational.ZERO,
    video_bitrate: u32 = 0,
    pixel_format: ?[]const u8 = null,
    color_space: ?[]const u8 = null,
    hdr_format: ?[]const u8 = null,

    // Audio stream info
    has_audio: bool = false,
    audio_codec: AudioCodec = .unknown,
    audio_codec_name: ?[]const u8 = null,
    sample_rate: u32 = 0,
    channels: u8 = 0,
    channel_layout: ?[]const u8 = null,
    audio_bitrate: u32 = 0,

    // Subtitle info
    has_subtitles: bool = false,
    subtitle_count: u32 = 0,

    // Metadata
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    year: ?u32 = null,
    comment: ?[]const u8 = null,

    pub fn aspectRatio(self: *const MediaInfo) Rational {
        if (self.width == 0 or self.height == 0) return Rational.ZERO;
        return Rational.init(@intCast(self.width), @intCast(self.height)).reduce();
    }

    pub fn resolution(self: *const MediaInfo) []const u8 {
        if (self.height >= 2160) return "4K/UHD";
        if (self.height >= 1440) return "1440p/QHD";
        if (self.height >= 1080) return "1080p/FHD";
        if (self.height >= 720) return "720p/HD";
        if (self.height >= 480) return "480p/SD";
        return "Low";
    }
};

// ============================================================================
// Encoding Options
// ============================================================================

/// Video encoding options
pub const VideoEncodingOptions = struct {
    codec: VideoCodec = .h264,
    width: ?u32 = null, // null = preserve original
    height: ?u32 = null,
    bitrate: ?u32 = null, // kbps, null = use CRF
    crf: u8 = 23, // Constant rate factor (0-51, lower = better)
    preset: Preset = .medium,
    profile: ?Profile = null,
    pixel_format: ?[]const u8 = null,
    frame_rate: ?Rational = null,
    keyint: u32 = 250, // Keyframe interval

    pub const Preset = enum {
        ultrafast,
        superfast,
        veryfast,
        faster,
        fast,
        medium,
        slow,
        slower,
        veryslow,
        placebo,

        pub fn toString(self: Preset) []const u8 {
            return switch (self) {
                .ultrafast => "ultrafast",
                .superfast => "superfast",
                .veryfast => "veryfast",
                .faster => "faster",
                .fast => "fast",
                .medium => "medium",
                .slow => "slow",
                .slower => "slower",
                .veryslow => "veryslow",
                .placebo => "placebo",
            };
        }
    };

    pub const Profile = enum {
        baseline,
        main,
        high,
        high10,
        high422,
        high444,
    };
};

/// Audio encoding options
pub const AudioEncodingOptions = struct {
    codec: AudioCodec = .aac,
    bitrate: u32 = 128, // kbps
    sample_rate: ?u32 = null, // null = preserve original
    channels: ?u8 = null,
    quality: ?f32 = null, // VBR quality (0.0-1.0)
};

// ============================================================================
// Filter Types
// ============================================================================

/// Video filter types
pub const VideoFilter = enum {
    scale,
    crop,
    rotate,
    flip_h,
    flip_v,
    transpose,
    blur,
    sharpen,
    grayscale,
    brightness,
    contrast,
    saturation,
    hue,
    gamma,
    denoise,
    deinterlace,
    stabilize,
    overlay,
    text,
    fade,
    custom,
};

/// Audio filter types
pub const AudioFilter = enum {
    volume,
    normalize,
    loudnorm,
    equalizer,
    compressor,
    limiter,
    reverb,
    echo,
    pitch,
    tempo,
    fade_in,
    fade_out,
    silence_remove,
    custom,
};

// ============================================================================
// Quality Presets
// ============================================================================

pub const QualityPreset = enum {
    low,
    medium,
    high,
    very_high,
    lossless,

    pub fn videoSettings(self: QualityPreset) VideoEncodingOptions {
        return switch (self) {
            .low => .{ .crf = 28, .preset = .veryfast },
            .medium => .{ .crf = 23, .preset = .medium },
            .high => .{ .crf = 18, .preset = .slow },
            .very_high => .{ .crf = 15, .preset = .slower },
            .lossless => .{ .crf = 0, .preset = .veryslow },
        };
    }

    pub fn audioSettings(self: QualityPreset) AudioEncodingOptions {
        return switch (self) {
            .low => .{ .bitrate = 96 },
            .medium => .{ .bitrate = 128 },
            .high => .{ .bitrate = 192 },
            .very_high => .{ .bitrate = 320 },
            .lossless => .{ .codec = .flac },
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MediaType from extension" {
    try std.testing.expectEqual(MediaType.video, MediaType.fromExtension(".mp4"));
    try std.testing.expectEqual(MediaType.audio, MediaType.fromExtension(".mp3"));
    try std.testing.expectEqual(MediaType.image, MediaType.fromExtension(".png"));
    try std.testing.expectEqual(MediaType.subtitle, MediaType.fromExtension(".srt"));
    try std.testing.expectEqual(MediaType.unknown, MediaType.fromExtension(".xyz"));
}

test "Rational operations" {
    const r = Rational.init(30000, 1001);
    const f = r.toFloat();
    try std.testing.expectApproxEqAbs(@as(f64, 29.97), f, 0.01);

    const r2 = Rational.init(4, 8).reduce();
    try std.testing.expectEqual(@as(i64, 1), r2.num);
    try std.testing.expectEqual(@as(i64, 2), r2.den);
}

test "Timestamp conversions" {
    const ts = Timestamp.fromSeconds(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ts.toSeconds(), 0.0001);
    try std.testing.expectEqual(@as(i64, 1500), ts.toMilliseconds());
}

test "Duration conversions" {
    const d = Duration.fromSeconds(60.0);
    try std.testing.expectEqual(@as(u64, 60000), d.toMilliseconds());
}

test "ContainerFormat detection" {
    try std.testing.expectEqual(ContainerFormat.mp4, ContainerFormat.fromExtension(".mp4"));
    try std.testing.expectEqual(ContainerFormat.mkv, ContainerFormat.fromExtension(".mkv"));
    try std.testing.expectEqual(ContainerFormat.webm, ContainerFormat.fromExtension(".webm"));
}
