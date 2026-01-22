// Home Media Library
// A unified, high-level API for video, audio, and image processing
// in the Home programming language.
//
// Features:
// - Fluent, chainable API similar to FFmpeg/Sharp.js
// - Native support for all popular media formats
// - Video: H.264, HEVC, VP8, VP9, AV1, VVC, MPEG-2, ProRes, DNxHD
// - Audio: AAC, MP3, Opus, FLAC, Vorbis, AC-3, DTS, PCM
// - Image: PNG, JPEG, WebP, GIF, AVIF, HEIC, TIFF, BMP, and more
// - Containers: MP4, MKV, WebM, AVI, MOV, FLV, MPEG-TS, MXF
// - Comprehensive filter system for transformations
// - Streaming and batch processing support

const std = @import("std");

// ============================================================================
// Core Types
// ============================================================================

pub const types = @import("core/types.zig");
pub const MediaType = types.MediaType;
pub const MediaInfo = types.MediaInfo;
pub const ContainerFormat = types.ContainerFormat;
pub const VideoCodec = types.VideoCodec;
pub const AudioCodec = types.AudioCodec;
pub const VideoEncodingOptions = types.VideoEncodingOptions;
pub const AudioEncodingOptions = types.AudioEncodingOptions;
pub const VideoFilter = types.VideoFilter;
pub const AudioFilter = types.AudioFilter;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const Rational = types.Rational;
pub const QualityPreset = types.QualityPreset;

// ============================================================================
// Error Types
// ============================================================================

pub const err = @import("core/error.zig");
pub const MediaError = err.MediaError;
pub const ErrorCode = err.ErrorCode;
pub const ErrorContext = err.ErrorContext;
pub const ErrorCategory = err.ErrorCategory;
pub const isRecoverable = err.isRecoverable;
pub const getUserMessage = err.getUserMessage;
pub const makeError = err.makeError;
pub const Result = err.Result;

// ============================================================================
// Probing
// ============================================================================

pub const probe_mod = @import("core/probe.zig");
pub const detectFormat = probe_mod.detectFormat;
pub const detectMediaType = probe_mod.detectMediaType;

/// Probe a media file and get detailed information
pub fn probe(allocator: std.mem.Allocator, path: []const u8) !MediaInfo {
    return probe_mod.probe(allocator, path);
}

/// Probe media from memory buffer
pub fn probeFromMemory(allocator: std.mem.Allocator, data: []const u8) !MediaInfo {
    return probe_mod.probeFromMemory(allocator, data);
}

// ============================================================================
// Stream Types
// ============================================================================

pub const stream = @import("core/stream.zig");
pub const StreamType = stream.StreamType;
pub const StreamInfo = stream.StreamInfo;
pub const VideoStreamInfo = stream.VideoStreamInfo;
pub const AudioStreamInfo = stream.AudioStreamInfo;
pub const SubtitleStreamInfo = stream.SubtitleStreamInfo;
pub const MediaStream = stream.MediaStream;
pub const Packet = stream.Packet;
pub const PacketFlags = stream.PacketFlags;
pub const Frame = stream.Frame;
pub const FrameFlags = stream.FrameFlags;
pub const FrameFormat = stream.FrameFormat;
pub const StreamSource = stream.StreamSource;
pub const StreamSink = stream.StreamSink;

// ============================================================================
// Pipeline Builder
// ============================================================================

pub const pipeline_mod = @import("pipeline/pipeline.zig");
pub const Pipeline = pipeline_mod.Pipeline;
pub const FilterConfig = pipeline_mod.FilterConfig;
pub const ScaleConfig = pipeline_mod.ScaleConfig;
pub const ScaleAlgorithm = pipeline_mod.ScaleAlgorithm;
pub const CropConfig = pipeline_mod.CropConfig;
pub const RotateConfig = pipeline_mod.RotateConfig;
pub const BlurConfig = pipeline_mod.BlurConfig;
pub const SharpenConfig = pipeline_mod.SharpenConfig;
pub const DenoiseConfig = pipeline_mod.DenoiseConfig;
pub const DeinterlaceConfig = pipeline_mod.DeinterlaceConfig;
pub const DeinterlaceMode = pipeline_mod.DeinterlaceMode;
pub const OverlayConfig = pipeline_mod.OverlayConfig;
pub const TextConfig = pipeline_mod.TextConfig;
pub const FadeConfig = pipeline_mod.FadeConfig;
pub const FadeType = pipeline_mod.FadeType;
pub const NormalizeConfig = pipeline_mod.NormalizeConfig;
pub const LoudnormConfig = pipeline_mod.LoudnormConfig;
pub const EqualizerConfig = pipeline_mod.EqualizerConfig;
pub const EqualizerBand = pipeline_mod.EqualizerBand;
pub const CompressorConfig = pipeline_mod.CompressorConfig;
pub const ReverbConfig = pipeline_mod.ReverbConfig;
pub const ProgressCallback = pipeline_mod.ProgressCallback;
pub const ProgressInfo = pipeline_mod.ProgressInfo;

// ============================================================================
// Filter Graph
// ============================================================================

pub const filter_graph = @import("pipeline/filter_graph.zig");
pub const Filter = filter_graph.Filter;
pub const FilterType = filter_graph.FilterType;
pub const FilterGraph = filter_graph.FilterGraph;

// ============================================================================
// Transcoder
// ============================================================================

pub const transcoder_mod = @import("pipeline/transcoder.zig");
pub const Transcoder = transcoder_mod.Transcoder;
pub const TranscoderConfig = transcoder_mod.TranscoderConfig;
pub const TranscoderStats = transcoder_mod.TranscoderStats;
pub const BatchTranscoder = transcoder_mod.BatchTranscoder;

// ============================================================================
// Format Registry
// ============================================================================

pub const registry = @import("formats/registry.zig");
pub const FormatInfo = registry.FormatInfo;
pub const VideoCodecInfo = registry.VideoCodecInfo;
pub const AudioCodecInfo = registry.AudioCodecInfo;
pub const Registry = registry.Registry;

// ============================================================================
// Convenience Functions
// ============================================================================

/// Quick transcode (format conversion)
pub fn transcode(allocator: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    return pipeline_mod.transcode(allocator, input, output);
}

/// Quick transmux (container change only, no re-encoding)
pub fn transmux(allocator: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    return pipeline_mod.transmux(allocator, input, output);
}

/// Extract audio from video
pub fn extractAudio(allocator: std.mem.Allocator, input: []const u8, output: []const u8) !void {
    return pipeline_mod.extractAudio(allocator, input, output);
}

/// Create thumbnail from video at specified time
pub fn thumbnail(allocator: std.mem.Allocator, input: []const u8, output: []const u8, time_seconds: f64) !void {
    return pipeline_mod.thumbnail(allocator, input, output, time_seconds);
}

// ============================================================================
// High-Level Media Struct
// ============================================================================

/// Unified media object for simple operations
pub const Media = struct {
    allocator: std.mem.Allocator,
    path: ?[]const u8 = null,
    info: ?MediaInfo = null,
    data: ?[]u8 = null,

    const Self = @This();

    /// Open media file
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
        var media = Self{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
        };
        media.info = try probe(allocator, path);
        return media;
    }

    /// Load media from memory
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        var media = Self{
            .allocator = allocator,
            .data = try allocator.dupe(u8, data),
        };
        media.info = try probeFromMemory(allocator, data);
        return media;
    }

    pub fn deinit(self: *Self) void {
        if (self.path) |p| self.allocator.free(p);
        if (self.data) |d| self.allocator.free(d);
    }

    /// Get media information
    pub fn getInfo(self: *const Self) ?MediaInfo {
        return self.info;
    }

    /// Check if media has video
    pub fn hasVideo(self: *const Self) bool {
        if (self.info) |info| return info.has_video;
        return false;
    }

    /// Check if media has audio
    pub fn hasAudio(self: *const Self) bool {
        if (self.info) |info| return info.has_audio;
        return false;
    }

    /// Get duration in seconds
    pub fn duration(self: *const Self) f64 {
        if (self.info) |info| return info.duration.toSeconds();
        return 0;
    }

    /// Get video dimensions
    pub fn dimensions(self: *const Self) ?struct { width: u32, height: u32 } {
        if (self.info) |info| {
            if (info.width > 0 and info.height > 0) {
                return .{ .width = info.width, .height = info.height };
            }
        }
        return null;
    }

    /// Create a processing pipeline from this media
    pub fn pipeline(self: *const Self) !Pipeline {
        var p = Pipeline.init(self.allocator);
        if (self.path) |path| {
            _ = try p.input(path);
        }
        return p;
    }

    /// Convert to another format
    pub fn convertTo(self: *const Self, output_path: []const u8) !void {
        if (self.path == null) return MediaError.InvalidInput;
        try transcode(self.allocator, self.path.?, output_path);
    }

    /// Convert with options
    pub fn convertWithOptions(
        self: *const Self,
        output_path: []const u8,
        video_codec: ?VideoCodec,
        audio_codec: ?AudioCodec,
        quality: ?QualityPreset,
    ) !void {
        if (self.path == null) return MediaError.InvalidInput;

        var p = Pipeline.init(self.allocator);
        defer p.deinit();

        _ = try p.input(self.path.?);
        _ = try p.output(output_path);

        if (video_codec) |vc| _ = p.videoCodec(vc);
        if (audio_codec) |ac| _ = p.audioCodec(ac);
        if (quality) |q| _ = p.quality(q);

        try p.run();
    }
};

// ============================================================================
// Presets
// ============================================================================

pub const Presets = struct {
    /// Web-optimized H.264 video settings
    pub fn webVideo() VideoEncodingOptions {
        return .{
            .codec = .h264,
            .crf = 23,
            .preset = .medium,
            .pixel_format = "yuv420p",
        };
    }

    /// High quality HEVC settings
    pub fn hqVideo() VideoEncodingOptions {
        return .{
            .codec = .hevc,
            .crf = 18,
            .preset = .slow,
            .pixel_format = "yuv420p10le",
        };
    }

    /// 4K/UHD HEVC settings
    pub fn uhdVideo() VideoEncodingOptions {
        return .{
            .codec = .hevc,
            .crf = 20,
            .preset = .medium,
            .pixel_format = "yuv420p10le",
        };
    }

    /// Archive quality (near-lossless)
    pub fn archiveVideo() VideoEncodingOptions {
        return .{
            .codec = .hevc,
            .crf = 15,
            .preset = .veryslow,
        };
    }

    /// Standard AAC audio settings
    pub fn standardAudio() AudioEncodingOptions {
        return .{
            .codec = .aac,
            .bitrate = 128,
            .sample_rate = 48000,
            .channels = 2,
        };
    }

    /// High quality Opus audio settings
    pub fn hqAudio() AudioEncodingOptions {
        return .{
            .codec = .opus,
            .bitrate = 192,
            .sample_rate = 48000,
            .channels = 2,
        };
    }

    /// Lossless FLAC audio settings
    pub fn losslessAudio() AudioEncodingOptions {
        return .{
            .codec = .flac,
            .sample_rate = 48000,
            .channels = 2,
        };
    }
};

// ============================================================================
// Version Information
// ============================================================================

pub const VERSION = struct {
    pub const MAJOR: u32 = 0;
    pub const MINOR: u32 = 1;
    pub const PATCH: u32 = 0;

    pub fn string() []const u8 {
        return "0.1.0";
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Media library imports" {
    // Verify all modules can be imported
    _ = types;
    _ = err;
    _ = probe_mod;
    _ = stream;
    _ = pipeline_mod;
    _ = filter_graph;
    _ = transcoder_mod;
    _ = registry;
}

test "Pipeline basic configuration" {
    const allocator = std.testing.allocator;
    var p = Pipeline.init(allocator);
    defer p.deinit();

    _ = try p.input("test.mp4");
    _ = try p.output("output.webm");
    _ = p.videoCodec(.vp9);
    _ = p.audioCodec(.opus);
    _ = try p.resize(1920, 1080);
    _ = try p.blur(0.5);

    try std.testing.expectEqual(VideoCodec.vp9, p.video_options.codec);
    try std.testing.expectEqual(AudioCodec.opus, p.audio_options.codec);
}

test "Quality presets" {
    const web = QualityPreset.medium.videoSettings();
    try std.testing.expectEqual(@as(u8, 23), web.crf);

    const hq = QualityPreset.high.videoSettings();
    try std.testing.expectEqual(@as(u8, 18), hq.crf);
}

test "Format detection" {
    try std.testing.expectEqual(ContainerFormat.mp4, ContainerFormat.fromExtension(".mp4"));
    try std.testing.expectEqual(ContainerFormat.webm, ContainerFormat.fromExtension(".webm"));
    try std.testing.expectEqual(ContainerFormat.mkv, ContainerFormat.fromExtension(".mkv"));
}

test "Timestamp operations" {
    const ts = Timestamp.fromSeconds(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ts.toSeconds(), 0.0001);
}

test "Duration operations" {
    const d = Duration.fromSeconds(60.0);
    try std.testing.expectEqual(@as(u64, 60000), d.toMilliseconds());
}

test "Registry lookup" {
    const info = Registry.getFormatInfo(.mp4);
    try std.testing.expect(info != null);
    try std.testing.expect(info.?.supports_video);

    const codec_info = Registry.getVideoCodecInfo(.h264);
    try std.testing.expect(codec_info != null);
}
