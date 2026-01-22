// Home Media Library - Format Registry
// Registration and lookup of supported formats and codecs

const std = @import("std");
const types = @import("../core/types.zig");

const ContainerFormat = types.ContainerFormat;
const VideoCodec = types.VideoCodec;
const AudioCodec = types.AudioCodec;

// ============================================================================
// Format Information
// ============================================================================

pub const FormatInfo = struct {
    format: ContainerFormat,
    name: []const u8,
    long_name: []const u8,
    mime_type: []const u8,
    extensions: []const []const u8,
    can_read: bool = true,
    can_write: bool = true,
    supports_video: bool = false,
    supports_audio: bool = false,
    supports_subtitles: bool = false,
    supports_chapters: bool = false,
    supports_metadata: bool = true,
    default_video_codec: ?VideoCodec = null,
    default_audio_codec: ?AudioCodec = null,
    supported_video_codecs: []const VideoCodec = &.{},
    supported_audio_codecs: []const AudioCodec = &.{},
};

// ============================================================================
// Codec Information
// ============================================================================

pub const VideoCodecInfo = struct {
    codec: VideoCodec,
    name: []const u8,
    long_name: []const u8,
    can_decode: bool = true,
    can_encode: bool = true,
    is_lossless: bool = false,
    is_intra_only: bool = false,
    supported_pixel_formats: []const []const u8 = &.{},
    profiles: []const []const u8 = &.{},
};

pub const AudioCodecInfo = struct {
    codec: AudioCodec,
    name: []const u8,
    long_name: []const u8,
    can_decode: bool = true,
    can_encode: bool = true,
    is_lossless: bool = false,
    supported_sample_rates: []const u32 = &.{},
    supported_channels: u8 = 8,
};

// ============================================================================
// Format Registry
// ============================================================================

pub const Registry = struct {
    const video_formats = [_]FormatInfo{
        .{
            .format = .mp4,
            .name = "mp4",
            .long_name = "MPEG-4 Part 14",
            .mime_type = "video/mp4",
            .extensions = &.{ ".mp4", ".m4v", ".m4a" },
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .supports_chapters = true,
            .default_video_codec = .h264,
            .default_audio_codec = .aac,
            .supported_video_codecs = &.{ .h264, .hevc, .av1, .vvc },
            .supported_audio_codecs = &.{ .aac, .mp3, .ac3, .eac3, .alac },
        },
        .{
            .format = .mov,
            .name = "mov",
            .long_name = "QuickTime Movie",
            .mime_type = "video/quicktime",
            .extensions = &.{".mov"},
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .supports_chapters = true,
            .default_video_codec = .h264,
            .default_audio_codec = .aac,
            .supported_video_codecs = &.{ .h264, .hevc, .prores, .av1 },
            .supported_audio_codecs = &.{ .aac, .pcm, .alac },
        },
        .{
            .format = .mkv,
            .name = "mkv",
            .long_name = "Matroska Video",
            .mime_type = "video/x-matroska",
            .extensions = &.{ ".mkv", ".mka", ".mks" },
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .supports_chapters = true,
            .default_video_codec = .h264,
            .default_audio_codec = .aac,
            .supported_video_codecs = &.{ .h264, .hevc, .vp8, .vp9, .av1, .vvc, .mpeg2, .mpeg4 },
            .supported_audio_codecs = &.{ .aac, .mp3, .opus, .vorbis, .flac, .ac3, .dts, .pcm },
        },
        .{
            .format = .webm,
            .name = "webm",
            .long_name = "WebM",
            .mime_type = "video/webm",
            .extensions = &.{".webm"},
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .default_video_codec = .vp9,
            .default_audio_codec = .opus,
            .supported_video_codecs = &.{ .vp8, .vp9, .av1 },
            .supported_audio_codecs = &.{ .opus, .vorbis },
        },
        .{
            .format = .avi,
            .name = "avi",
            .long_name = "Audio Video Interleave",
            .mime_type = "video/x-msvideo",
            .extensions = &.{".avi"},
            .supports_video = true,
            .supports_audio = true,
            .default_video_codec = .mpeg4,
            .default_audio_codec = .mp3,
            .supported_video_codecs = &.{ .h264, .mpeg4, .mjpeg, .mpeg2 },
            .supported_audio_codecs = &.{ .mp3, .pcm, .ac3 },
        },
        .{
            .format = .flv,
            .name = "flv",
            .long_name = "Flash Video",
            .mime_type = "video/x-flv",
            .extensions = &.{".flv"},
            .supports_video = true,
            .supports_audio = true,
            .default_video_codec = .h264,
            .default_audio_codec = .aac,
            .supported_video_codecs = &.{ .h264, .vp6 },
            .supported_audio_codecs = &.{ .aac, .mp3 },
        },
        .{
            .format = .ts,
            .name = "mpegts",
            .long_name = "MPEG Transport Stream",
            .mime_type = "video/mp2t",
            .extensions = &.{ ".ts", ".mts" },
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .default_video_codec = .h264,
            .default_audio_codec = .aac,
            .supported_video_codecs = &.{ .h264, .hevc, .mpeg2 },
            .supported_audio_codecs = &.{ .aac, .mp3, .ac3, .dts },
        },
        .{
            .format = .mxf,
            .name = "mxf",
            .long_name = "Material Exchange Format",
            .mime_type = "application/mxf",
            .extensions = &.{".mxf"},
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .default_video_codec = .prores,
            .default_audio_codec = .pcm,
            .supported_video_codecs = &.{ .prores, .dnxhd, .h264, .hevc },
            .supported_audio_codecs = &.{.pcm},
        },
    };

    const audio_formats = [_]FormatInfo{
        .{
            .format = .wav,
            .name = "wav",
            .long_name = "Waveform Audio",
            .mime_type = "audio/wav",
            .extensions = &.{".wav"},
            .supports_audio = true,
            .default_audio_codec = .pcm,
            .supported_audio_codecs = &.{.pcm},
        },
        .{
            .format = .mp3,
            .name = "mp3",
            .long_name = "MPEG Audio Layer III",
            .mime_type = "audio/mpeg",
            .extensions = &.{".mp3"},
            .supports_audio = true,
            .default_audio_codec = .mp3,
            .supported_audio_codecs = &.{.mp3},
        },
        .{
            .format = .flac,
            .name = "flac",
            .long_name = "Free Lossless Audio Codec",
            .mime_type = "audio/flac",
            .extensions = &.{".flac"},
            .supports_audio = true,
            .default_audio_codec = .flac,
            .supported_audio_codecs = &.{.flac},
        },
        .{
            .format = .aac,
            .name = "aac",
            .long_name = "Advanced Audio Coding",
            .mime_type = "audio/aac",
            .extensions = &.{ ".aac", ".m4a" },
            .supports_audio = true,
            .default_audio_codec = .aac,
            .supported_audio_codecs = &.{ .aac, .alac },
        },
        .{
            .format = .ogg,
            .name = "ogg",
            .long_name = "Ogg Container",
            .mime_type = "audio/ogg",
            .extensions = &.{ ".ogg", ".oga", ".opus" },
            .supports_audio = true,
            .supports_video = true,
            .default_audio_codec = .opus,
            .supported_audio_codecs = &.{ .opus, .vorbis, .flac },
            .supported_video_codecs = &.{.theora},
        },
    };

    const image_formats = [_]FormatInfo{
        .{
            .format = .png,
            .name = "png",
            .long_name = "Portable Network Graphics",
            .mime_type = "image/png",
            .extensions = &.{".png"},
        },
        .{
            .format = .jpeg,
            .name = "jpeg",
            .long_name = "JPEG Image",
            .mime_type = "image/jpeg",
            .extensions = &.{ ".jpg", ".jpeg" },
        },
        .{
            .format = .webp,
            .name = "webp",
            .long_name = "WebP Image",
            .mime_type = "image/webp",
            .extensions = &.{".webp"},
        },
        .{
            .format = .gif,
            .name = "gif",
            .long_name = "Graphics Interchange Format",
            .mime_type = "image/gif",
            .extensions = &.{".gif"},
            .supports_video = true, // Animated GIF
        },
        .{
            .format = .avif,
            .name = "avif",
            .long_name = "AV1 Image File Format",
            .mime_type = "image/avif",
            .extensions = &.{".avif"},
        },
        .{
            .format = .heic,
            .name = "heic",
            .long_name = "High Efficiency Image Container",
            .mime_type = "image/heic",
            .extensions = &.{ ".heic", ".heif" },
        },
    };

    const video_codecs = [_]VideoCodecInfo{
        .{
            .codec = .h264,
            .name = "h264",
            .long_name = "H.264 / AVC / MPEG-4 Part 10",
            .supported_pixel_formats = &.{ "yuv420p", "yuv422p", "yuv444p", "yuv420p10le" },
            .profiles = &.{ "baseline", "main", "high", "high10", "high422", "high444" },
        },
        .{
            .codec = .hevc,
            .name = "hevc",
            .long_name = "H.265 / HEVC",
            .supported_pixel_formats = &.{ "yuv420p", "yuv420p10le", "yuv422p10le", "yuv444p10le" },
            .profiles = &.{ "main", "main10", "main12", "mainstillpicture" },
        },
        .{
            .codec = .vp8,
            .name = "vp8",
            .long_name = "VP8",
            .supported_pixel_formats = &.{"yuv420p"},
        },
        .{
            .codec = .vp9,
            .name = "vp9",
            .long_name = "VP9",
            .supported_pixel_formats = &.{ "yuv420p", "yuv420p10le", "yuv422p", "yuv444p" },
            .profiles = &.{ "profile0", "profile1", "profile2", "profile3" },
        },
        .{
            .codec = .av1,
            .name = "av1",
            .long_name = "AV1 (AOMedia Video 1)",
            .supported_pixel_formats = &.{ "yuv420p", "yuv420p10le", "yuv422p", "yuv444p" },
            .profiles = &.{ "main", "high", "professional" },
        },
        .{
            .codec = .vvc,
            .name = "vvc",
            .long_name = "H.266 / VVC",
            .supported_pixel_formats = &.{ "yuv420p", "yuv420p10le" },
            .profiles = &.{ "main10", "main10stillpicture" },
        },
        .{
            .codec = .prores,
            .name = "prores",
            .long_name = "Apple ProRes",
            .supported_pixel_formats = &.{ "yuv422p10le", "yuv444p10le" },
            .profiles = &.{ "proxy", "lt", "standard", "hq", "4444", "4444xq" },
        },
        .{
            .codec = .dnxhd,
            .name = "dnxhd",
            .long_name = "Avid DNxHD / DNxHR",
            .supported_pixel_formats = &.{ "yuv422p", "yuv422p10le" },
        },
    };

    const audio_codecs = [_]AudioCodecInfo{
        .{
            .codec = .aac,
            .name = "aac",
            .long_name = "Advanced Audio Coding",
            .supported_sample_rates = &.{ 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000 },
        },
        .{
            .codec = .mp3,
            .name = "mp3",
            .long_name = "MPEG Audio Layer III",
            .supported_sample_rates = &.{ 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000 },
            .supported_channels = 2,
        },
        .{
            .codec = .opus,
            .name = "opus",
            .long_name = "Opus Audio",
            .supported_sample_rates = &.{ 8000, 12000, 16000, 24000, 48000 },
            .supported_channels = 255,
        },
        .{
            .codec = .flac,
            .name = "flac",
            .long_name = "Free Lossless Audio Codec",
            .is_lossless = true,
            .supported_sample_rates = &.{ 8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000 },
        },
        .{
            .codec = .vorbis,
            .name = "vorbis",
            .long_name = "Vorbis",
            .supported_sample_rates = &.{ 8000, 11025, 16000, 22050, 32000, 44100, 48000, 96000, 192000 },
        },
        .{
            .codec = .pcm,
            .name = "pcm",
            .long_name = "PCM (uncompressed)",
            .is_lossless = true,
            .supported_sample_rates = &.{}, // All sample rates
            .supported_channels = 255,
        },
        .{
            .codec = .ac3,
            .name = "ac3",
            .long_name = "Dolby Digital (AC-3)",
            .supported_sample_rates = &.{ 32000, 44100, 48000 },
            .supported_channels = 6,
        },
        .{
            .codec = .dts,
            .name = "dts",
            .long_name = "DTS",
            .can_encode = false,
            .supported_sample_rates = &.{ 44100, 48000 },
            .supported_channels = 6,
        },
    };

    /// Get format information
    pub fn getFormatInfo(format: ContainerFormat) ?FormatInfo {
        for (video_formats) |info| {
            if (info.format == format) return info;
        }
        for (audio_formats) |info| {
            if (info.format == format) return info;
        }
        for (image_formats) |info| {
            if (info.format == format) return info;
        }
        return null;
    }

    /// Get video codec information
    pub fn getVideoCodecInfo(codec: VideoCodec) ?VideoCodecInfo {
        for (video_codecs) |info| {
            if (info.codec == codec) return info;
        }
        return null;
    }

    /// Get audio codec information
    pub fn getAudioCodecInfo(codec: AudioCodec) ?AudioCodecInfo {
        for (audio_codecs) |info| {
            if (info.codec == codec) return info;
        }
        return null;
    }

    /// Check if codec is supported by format
    pub fn isCodecSupported(format: ContainerFormat, video_codec: ?VideoCodec, audio_codec: ?AudioCodec) bool {
        const info = getFormatInfo(format) orelse return false;

        if (video_codec) |vc| {
            var found = false;
            for (info.supported_video_codecs) |supported| {
                if (supported == vc) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        if (audio_codec) |ac| {
            var found = false;
            for (info.supported_audio_codecs) |supported| {
                if (supported == ac) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }

    /// Get all supported container formats
    pub fn getSupportedFormats() []const FormatInfo {
        // Combine all format arrays
        var all: [video_formats.len + audio_formats.len + image_formats.len]FormatInfo = undefined;
        var i: usize = 0;
        for (video_formats) |f| {
            all[i] = f;
            i += 1;
        }
        for (audio_formats) |f| {
            all[i] = f;
            i += 1;
        }
        for (image_formats) |f| {
            all[i] = f;
            i += 1;
        }
        return &all;
    }

    /// Get all supported video codecs
    pub fn getSupportedVideoCodecs() []const VideoCodecInfo {
        return &video_codecs;
    }

    /// Get all supported audio codecs
    pub fn getSupportedAudioCodecs() []const AudioCodecInfo {
        return &audio_codecs;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Registry format lookup" {
    const mp4_info = Registry.getFormatInfo(.mp4);
    try std.testing.expect(mp4_info != null);
    try std.testing.expectEqualStrings("mp4", mp4_info.?.name);
    try std.testing.expect(mp4_info.?.supports_video);
    try std.testing.expect(mp4_info.?.supports_audio);
}

test "Registry codec lookup" {
    const h264_info = Registry.getVideoCodecInfo(.h264);
    try std.testing.expect(h264_info != null);
    try std.testing.expectEqualStrings("h264", h264_info.?.name);

    const aac_info = Registry.getAudioCodecInfo(.aac);
    try std.testing.expect(aac_info != null);
    try std.testing.expectEqualStrings("aac", aac_info.?.name);
}

test "Registry codec compatibility" {
    try std.testing.expect(Registry.isCodecSupported(.mp4, .h264, .aac));
    try std.testing.expect(Registry.isCodecSupported(.webm, .vp9, .opus));
    try std.testing.expect(!Registry.isCodecSupported(.webm, .h264, null));
}
