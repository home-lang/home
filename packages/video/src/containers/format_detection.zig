// Home Video Library - Container Format Detection
// Format detection from magic bytes, file extensions, and MIME types

const std = @import("std");
const core = @import("../core.zig");

/// Detected container format
pub const ContainerFormat = enum {
    mp4,
    quicktime,
    webm,
    matroska,
    avi,
    wav,
    flac,
    ogg,
    mp3,
    aac,
    unknown,
};

/// Format detection result
pub const DetectionResult = struct {
    format: ContainerFormat,
    confidence: f32, // 0.0 to 1.0
    codec_hint: ?[]const u8 = null,
};

/// Detect format from magic bytes (file header)
pub fn detectFromMagicBytes(data: []const u8) DetectionResult {
    if (data.len < 12) {
        return .{ .format = .unknown, .confidence = 0.0 };
    }

    // MP4/QuickTime (ftyp box)
    if (data.len >= 8 and std.mem.eql(u8, data[4..8], "ftyp")) {
        // Check brand
        if (data.len >= 12) {
            const brand = data[8..12];

            // QuickTime brands
            if (std.mem.eql(u8, brand, "qt  ") or
                std.mem.eql(u8, brand, "qtif"))
            {
                return .{ .format = .quicktime, .confidence = 1.0 };
            }

            // MP4 brands
            if (std.mem.eql(u8, brand, "isom") or
                std.mem.eql(u8, brand, "iso2") or
                std.mem.eql(u8, brand, "mp41") or
                std.mem.eql(u8, brand, "mp42") or
                std.mem.eql(u8, brand, "M4A ") or
                std.mem.eql(u8, brand, "M4V "))
            {
                return .{ .format = .mp4, .confidence = 1.0 };
            }

            // Default to MP4 for unknown ftyp
            return .{ .format = .mp4, .confidence = 0.8 };
        }
    }

    // WebM/Matroska (EBML header)
    if (data.len >= 4 and data[0] == 0x1A and data[1] == 0x45 and data[2] == 0xDF and data[3] == 0xA3) {
        // Look for DocType
        if (std.mem.indexOf(u8, data[0..@min(data.len, 100)], "webm")) |_| {
            return .{ .format = .webm, .confidence = 1.0 };
        }
        if (std.mem.indexOf(u8, data[0..@min(data.len, 100)], "matroska")) |_| {
            return .{ .format = .matroska, .confidence = 1.0 };
        }
        // Default to Matroska
        return .{ .format = .matroska, .confidence = 0.9 };
    }

    // AVI (RIFF...AVI)
    if (data.len >= 12 and
        std.mem.eql(u8, data[0..4], "RIFF") and
        std.mem.eql(u8, data[8..12], "AVI "))
    {
        return .{ .format = .avi, .confidence = 1.0 };
    }

    // WAV (RIFF...WAVE)
    if (data.len >= 12 and
        std.mem.eql(u8, data[0..4], "RIFF") and
        std.mem.eql(u8, data[8..12], "WAVE"))
    {
        return .{ .format = .wav, .confidence = 1.0 };
    }

    // RF64 (for large WAV files)
    if (data.len >= 12 and
        std.mem.eql(u8, data[0..4], "RF64") and
        std.mem.eql(u8, data[8..12], "WAVE"))
    {
        return .{ .format = .wav, .confidence = 1.0 };
    }

    // FLAC
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "fLaC")) {
        return .{ .format = .flac, .confidence = 1.0 };
    }

    // Ogg
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "OggS")) {
        return .{ .format = .ogg, .confidence = 1.0 };
    }

    // MP3 (ID3v2 tag)
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "ID3")) {
        return .{ .format = .mp3, .confidence = 1.0 };
    }

    // MP3 (MPEG audio frame sync)
    if (data.len >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) {
        // Check if it looks like MPEG audio
        return .{ .format = .mp3, .confidence = 0.8 };
    }

    // AAC (ADTS sync word)
    if (data.len >= 2 and data[0] == 0xFF and (data[1] & 0xF0) == 0xF0) {
        return .{ .format = .aac, .confidence = 0.7 };
    }

    return .{ .format = .unknown, .confidence = 0.0 };
}

/// Detect format from file extension
pub fn detectFromExtension(filename: []const u8) DetectionResult {
    const ext = getExtension(filename);

    if (std.ascii.eqlIgnoreCase(ext, ".mp4") or
        std.ascii.eqlIgnoreCase(ext, ".m4v") or
        std.ascii.eqlIgnoreCase(ext, ".m4a"))
    {
        return .{ .format = .mp4, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".mov") or
        std.ascii.eqlIgnoreCase(ext, ".qt"))
    {
        return .{ .format = .quicktime, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".webm")) {
        return .{ .format = .webm, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".mkv") or
        std.ascii.eqlIgnoreCase(ext, ".mka"))
    {
        return .{ .format = .matroska, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".avi")) {
        return .{ .format = .avi, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".wav")) {
        return .{ .format = .wav, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".flac")) {
        return .{ .format = .flac, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".ogg") or
        std.ascii.eqlIgnoreCase(ext, ".oga") or
        std.ascii.eqlIgnoreCase(ext, ".ogv"))
    {
        return .{ .format = .ogg, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".mp3")) {
        return .{ .format = .mp3, .confidence = 0.9 };
    }

    if (std.ascii.eqlIgnoreCase(ext, ".aac")) {
        return .{ .format = .aac, .confidence = 0.9 };
    }

    return .{ .format = .unknown, .confidence = 0.0 };
}

fn getExtension(filename: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_pos| {
        return filename[dot_pos..];
    }
    return "";
}

/// Generate MIME type with codec strings
pub fn generateMimeType(allocator: std.mem.Allocator, format: ContainerFormat, video_codec: ?core.VideoCodec, audio_codec: ?core.AudioCodec) ![]u8 {
    var mime = std.ArrayList(u8).init(allocator);
    errdefer mime.deinit();

    // Base MIME type
    switch (format) {
        .mp4 => {
            if (video_codec != null) {
                try mime.appendSlice("video/mp4");
            } else {
                try mime.appendSlice("audio/mp4");
            }
        },
        .quicktime => try mime.appendSlice("video/quicktime"),
        .webm => {
            if (video_codec != null) {
                try mime.appendSlice("video/webm");
            } else {
                try mime.appendSlice("audio/webm");
            }
        },
        .matroska => {
            if (video_codec != null) {
                try mime.appendSlice("video/x-matroska");
            } else {
                try mime.appendSlice("audio/x-matroska");
            }
        },
        .avi => try mime.appendSlice("video/x-msvideo"),
        .wav => try mime.appendSlice("audio/wav"),
        .flac => try mime.appendSlice("audio/flac"),
        .ogg => {
            if (video_codec != null) {
                try mime.appendSlice("video/ogg");
            } else {
                try mime.appendSlice("audio/ogg");
            }
        },
        .mp3 => try mime.appendSlice("audio/mpeg"),
        .aac => try mime.appendSlice("audio/aac"),
        .unknown => try mime.appendSlice("application/octet-stream"),
    }

    // Add codecs parameter
    if (video_codec != null or audio_codec != null) {
        try mime.appendSlice("; codecs=\"");

        var first = true;

        if (video_codec) |vc| {
            const codec_str = getVideoCodecString(vc);
            try mime.appendSlice(codec_str);
            first = false;
        }

        if (audio_codec) |ac| {
            if (!first) try mime.appendSlice(", ");
            const codec_str = getAudioCodecString(ac);
            try mime.appendSlice(codec_str);
        }

        try mime.append('"');
    }

    return mime.toOwnedSlice();
}

fn getVideoCodecString(codec: core.VideoCodec) []const u8 {
    return switch (codec) {
        .h264 => "avc1.42E01E", // Baseline profile
        .hevc => "hev1.1.6.L93.B0",
        .vp8 => "vp8",
        .vp9 => "vp9",
        .av1 => "av01.0.04M.08",
        .mpeg2 => "mp4v.20.9",
        .mpeg4 => "mp4v.20.3",
        .mjpeg => "mjpeg",
        .prores_422 => "apcn",
        .prores_4444 => "ap4h",
        .prores_422_hq => "apch",
        .prores_422_lt => "apcs",
        .prores_422_proxy => "apco",
        else => "unknown",
    };
}

fn getAudioCodecString(codec: core.AudioCodec) []const u8 {
    return switch (codec) {
        .aac => "mp4a.40.2",
        .opus => "opus",
        .vorbis => "vorbis",
        .flac => "flac",
        .pcm => "pcm",
        .mp3 => "mp3",
        else => "unknown",
    };
}

/// Query container capabilities
pub const ContainerCapabilities = struct {
    supports_video: bool,
    supports_audio: bool,
    supports_subtitles: bool,
    supports_chapters: bool,
    supports_attachments: bool,
    supports_metadata: bool,
    max_tracks: ?u32 = null, // null = unlimited
    supported_video_codecs: []const core.VideoCodec,
    supported_audio_codecs: []const core.AudioCodec,
};

pub fn getContainerCapabilities(format: ContainerFormat) ContainerCapabilities {
    return switch (format) {
        .mp4 => .{
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .supports_chapters = true,
            .supports_attachments = false,
            .supports_metadata = true,
            .max_tracks = null,
            .supported_video_codecs = &[_]core.VideoCodec{
                .h264, .hevc, .av1, .mpeg4, .mpeg2,
            },
            .supported_audio_codecs = &[_]core.AudioCodec{
                .aac, .mp3, .opus, .flac, .pcm,
            },
        },
        .quicktime => .{
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .supports_chapters = true,
            .supports_attachments = false,
            .supports_metadata = true,
            .max_tracks = null,
            .supported_video_codecs = &[_]core.VideoCodec{
                .h264, .hevc, .prores_422, .prores_4444,
                .prores_422_hq, .prores_422_lt, .prores_422_proxy,
            },
            .supported_audio_codecs = &[_]core.AudioCodec{
                .aac, .pcm, .opus,
            },
        },
        .webm => .{
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .supports_chapters = false,
            .supports_attachments = false,
            .supports_metadata = true,
            .max_tracks = null,
            .supported_video_codecs = &[_]core.VideoCodec{
                .vp8, .vp9, .av1,
            },
            .supported_audio_codecs = &[_]core.AudioCodec{
                .opus, .vorbis,
            },
        },
        .matroska => .{
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .supports_chapters = true,
            .supports_attachments = true,
            .supports_metadata = true,
            .max_tracks = null,
            .supported_video_codecs = &[_]core.VideoCodec{
                .h264, .hevc, .vp8, .vp9, .av1, .mpeg2, .mpeg4,
            },
            .supported_audio_codecs = &[_]core.AudioCodec{
                .aac, .opus, .vorbis, .flac, .pcm, .mp3,
            },
        },
        .avi => .{
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = true,
            .supports_chapters = false,
            .supports_attachments = false,
            .supports_metadata = true,
            .max_tracks = null,
            .supported_video_codecs = &[_]core.VideoCodec{
                .h264, .mpeg4, .mpeg2, .mjpeg,
            },
            .supported_audio_codecs = &[_]core.AudioCodec{
                .mp3, .aac, .pcm,
            },
        },
        .wav => .{
            .supports_video = false,
            .supports_audio = true,
            .supports_subtitles = false,
            .supports_chapters = false,
            .supports_attachments = false,
            .supports_metadata = true,
            .max_tracks = 1,
            .supported_video_codecs = &[_]core.VideoCodec{},
            .supported_audio_codecs = &[_]core.AudioCodec{
                .pcm,
            },
        },
        .flac => .{
            .supports_video = false,
            .supports_audio = true,
            .supports_subtitles = false,
            .supports_chapters = false,
            .supports_attachments = false,
            .supports_metadata = true,
            .max_tracks = 1,
            .supported_video_codecs = &[_]core.VideoCodec{},
            .supported_audio_codecs = &[_]core.AudioCodec{
                .flac,
            },
        },
        .ogg => .{
            .supports_video = true,
            .supports_audio = true,
            .supports_subtitles = false,
            .supports_chapters = false,
            .supports_attachments = false,
            .supports_metadata = true,
            .max_tracks = null,
            .supported_video_codecs = &[_]core.VideoCodec{
                .vp8, .vp9,
            },
            .supported_audio_codecs = &[_]core.AudioCodec{
                .vorbis, .opus, .flac,
            },
        },
        .mp3 => .{
            .supports_video = false,
            .supports_audio = true,
            .supports_subtitles = false,
            .supports_chapters = false,
            .supports_attachments = false,
            .supports_metadata = true,
            .max_tracks = 1,
            .supported_video_codecs = &[_]core.VideoCodec{},
            .supported_audio_codecs = &[_]core.AudioCodec{
                .mp3,
            },
        },
        .aac => .{
            .supports_video = false,
            .supports_audio = true,
            .supports_subtitles = false,
            .supports_chapters = false,
            .supports_attachments = false,
            .supports_metadata = false,
            .max_tracks = 1,
            .supported_video_codecs = &[_]core.VideoCodec{},
            .supported_audio_codecs = &[_]core.AudioCodec{
                .aac,
            },
        },
        .unknown => .{
            .supports_video = false,
            .supports_audio = false,
            .supports_subtitles = false,
            .supports_chapters = false,
            .supports_attachments = false,
            .supports_metadata = false,
            .max_tracks = 0,
            .supported_video_codecs = &[_]core.VideoCodec{},
            .supported_audio_codecs = &[_]core.AudioCodec{},
        },
    };
}
