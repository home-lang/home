/// Home Language Bindings for Unified Media Library
///
/// Provides idiomatic Home language API for media processing
/// combining video, audio, and image capabilities with a fluent API
const std = @import("std");
const media = @import("../media.zig");

// Re-export core types for Home language
pub const MediaType = media.MediaType;
pub const MediaInfo = media.MediaInfo;
pub const ContainerFormat = media.ContainerFormat;
pub const VideoCodec = media.VideoCodec;
pub const AudioCodec = media.AudioCodec;
pub const MediaError = media.MediaError;
pub const QualityPreset = media.QualityPreset;

// ============================================================================
// Media Type - High-level unified media operations for Home language
// ============================================================================

/// Unified Media struct for Home language binding
/// Provides chainable, lazy-evaluated media operations
/// Home API: Section 15 - Media Processing
pub const Media = struct {
    allocator: std.mem.Allocator,
    source_path: ?[]const u8,
    source_data: ?[]const u8,
    info: ?MediaInfo,
    pipeline: ?media.Pipeline,

    const Self = @This();

    // ========================================================================
    // Loading Methods
    // ========================================================================

    /// Open media from file path
    /// Home API: Media.open(path: string) -> Result<Media, MediaError>
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
        var m = Self{
            .allocator = allocator,
            .source_path = try allocator.dupe(u8, path),
            .source_data = null,
            .info = null,
            .pipeline = null,
        };

        // Probe the file to get media info
        m.info = media.probe(allocator, path) catch null;

        return m;
    }

    /// Load media from memory buffer
    /// Home API: Media.from_memory(data: [u8]) -> Result<Media, MediaError>
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        var m = Self{
            .allocator = allocator,
            .source_path = null,
            .source_data = try allocator.dupe(u8, data),
            .info = null,
            .pipeline = null,
        };

        m.info = media.probeFromMemory(allocator, data) catch null;

        return m;
    }

    /// Probe a file without loading it
    /// Home API: Media.probe(path: string) -> Result<MediaInfo, MediaError>
    pub fn probeFile(allocator: std.mem.Allocator, path: []const u8) !MediaInfo {
        return media.probe(allocator, path);
    }

    pub fn deinit(self: *Self) void {
        if (self.source_path) |p| self.allocator.free(p);
        if (self.source_data) |d| self.allocator.free(d);
        if (self.pipeline) |*p| p.deinit();
    }

    // ========================================================================
    // Information Methods
    // ========================================================================

    /// Get media information
    /// Home API: media.info() -> MediaInfo?
    pub fn getInfo(self: *const Self) ?MediaInfo {
        return self.info;
    }

    /// Check if media has video stream
    /// Home API: media.has_video() -> bool
    pub fn hasVideo(self: *const Self) bool {
        if (self.info) |info| return info.has_video;
        return false;
    }

    /// Check if media has audio stream
    /// Home API: media.has_audio() -> bool
    pub fn hasAudio(self: *const Self) bool {
        if (self.info) |info| return info.has_audio;
        return false;
    }

    /// Get duration in seconds
    /// Home API: media.duration() -> f64
    pub fn duration(self: *const Self) f64 {
        if (self.info) |info| return info.duration.toSeconds();
        return 0;
    }

    /// Get video dimensions
    /// Home API: media.dimensions() -> (u32, u32)?
    pub fn dimensions(self: *const Self) ?struct { width: u32, height: u32 } {
        if (self.info) |info| {
            if (info.width > 0 and info.height > 0) {
                return .{ .width = info.width, .height = info.height };
            }
        }
        return null;
    }

    /// Get media type
    /// Home API: media.media_type() -> MediaType
    pub fn mediaType(self: *const Self) MediaType {
        if (self.info) |info| return info.media_type;
        return .unknown;
    }

    // ========================================================================
    // Pipeline Creation
    // ========================================================================

    /// Create a processing pipeline from this media
    /// Home API: media.process() -> Pipeline
    pub fn process(self: *Self) !*media.Pipeline {
        if (self.pipeline == null) {
            self.pipeline = media.Pipeline.init(self.allocator);
            if (self.source_path) |path| {
                _ = try self.pipeline.?.input(path);
            }
        }
        return &self.pipeline.?;
    }

    // ========================================================================
    // Convenience Methods
    // ========================================================================

    /// Convert to another format (simple transcode)
    /// Home API: media.convert_to(output_path: string) -> Result<(), MediaError>
    pub fn convertTo(self: *const Self, output_path: []const u8) !void {
        if (self.source_path == null) return MediaError.InvalidInput;
        try media.transcode(self.allocator, self.source_path.?, output_path);
    }

    /// Extract audio from video
    /// Home API: media.extract_audio(output_path: string) -> Result<(), MediaError>
    pub fn extractAudioTo(self: *const Self, output_path: []const u8) !void {
        if (self.source_path == null) return MediaError.InvalidInput;
        try media.extractAudio(self.allocator, self.source_path.?, output_path);
    }

    /// Generate thumbnail at specified time
    /// Home API: media.thumbnail(output_path: string, time: f64) -> Result<(), MediaError>
    pub fn thumbnailAt(self: *const Self, output_path: []const u8, time_seconds: f64) !void {
        if (self.source_path == null) return MediaError.InvalidInput;
        try media.thumbnail(self.allocator, self.source_path.?, output_path, time_seconds);
    }
};

// ============================================================================
// Pipeline Builder - Fluent API for Home language
// ============================================================================

/// Pipeline builder with fluent/chainable API
/// Home API: Pipeline.new() -> Pipeline
pub const Pipeline = struct {
    inner: media.Pipeline,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new pipeline
    /// Home API: Pipeline.new() -> Pipeline
    pub fn new(allocator: std.mem.Allocator) Self {
        return .{
            .inner = media.Pipeline.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit();
    }

    // ========================================================================
    // Input/Output
    // ========================================================================

    /// Set input file
    /// Home API: pipeline.input(path: string) -> Pipeline
    pub fn input(self: *Self, path: []const u8) !*Self {
        _ = try self.inner.input(path);
        return self;
    }

    /// Set output file
    /// Home API: pipeline.output(path: string) -> Pipeline
    pub fn output(self: *Self, path: []const u8) !*Self {
        _ = try self.inner.output(path);
        return self;
    }

    // ========================================================================
    // Video Settings
    // ========================================================================

    /// Set video codec
    /// Home API: pipeline.video_codec(codec: VideoCodec) -> Pipeline
    pub fn videoCodec(self: *Self, codec: VideoCodec) *Self {
        _ = self.inner.videoCodec(codec);
        return self;
    }

    /// Set video bitrate in kbps
    /// Home API: pipeline.video_bitrate(kbps: u32) -> Pipeline
    pub fn videoBitrate(self: *Self, kbps: u32) *Self {
        _ = self.inner.videoBitrate(kbps);
        return self;
    }

    /// Set video quality (CRF)
    /// Home API: pipeline.video_quality(crf: u8) -> Pipeline
    pub fn videoQuality(self: *Self, crf: u8) *Self {
        _ = self.inner.crf(crf);
        return self;
    }

    /// Set quality preset
    /// Home API: pipeline.quality(preset: QualityPreset) -> Pipeline
    pub fn quality(self: *Self, preset: QualityPreset) *Self {
        _ = self.inner.quality(preset);
        return self;
    }

    /// Set frame rate
    /// Home API: pipeline.fps(rate: f64) -> Pipeline
    pub fn fps(self: *Self, rate: f64) *Self {
        _ = self.inner.fps(rate);
        return self;
    }

    // ========================================================================
    // Audio Settings
    // ========================================================================

    /// Set audio codec
    /// Home API: pipeline.audio_codec(codec: AudioCodec) -> Pipeline
    pub fn audioCodec(self: *Self, codec: AudioCodec) *Self {
        _ = self.inner.audioCodec(codec);
        return self;
    }

    /// Set audio bitrate in kbps
    /// Home API: pipeline.audio_bitrate(kbps: u32) -> Pipeline
    pub fn audioBitrate(self: *Self, kbps: u32) *Self {
        _ = self.inner.audioBitrate(kbps);
        return self;
    }

    /// Set sample rate
    /// Home API: pipeline.sample_rate(hz: u32) -> Pipeline
    pub fn sampleRate(self: *Self, hz: u32) *Self {
        _ = self.inner.sampleRate(hz);
        return self;
    }

    /// Set number of audio channels
    /// Home API: pipeline.channels(count: u8) -> Pipeline
    pub fn channels(self: *Self, count: u8) *Self {
        _ = self.inner.channels(count);
        return self;
    }

    // ========================================================================
    // Video Transforms
    // ========================================================================

    /// Resize video to specific dimensions
    /// Home API: pipeline.resize(width: u32, height: u32) -> Pipeline
    pub fn resize(self: *Self, width: u32, height: u32) !*Self {
        _ = try self.inner.resize(width, height);
        return self;
    }

    /// Scale video maintaining aspect ratio
    /// Home API: pipeline.scale(width: u32) -> Pipeline
    pub fn scale(self: *Self, width: u32) !*Self {
        _ = try self.inner.scale(width);
        return self;
    }

    /// Crop video
    /// Home API: pipeline.crop(x: u32, y: u32, width: u32, height: u32) -> Pipeline
    pub fn crop(self: *Self, x: u32, y: u32, width: u32, height: u32) !*Self {
        _ = try self.inner.crop(x, y, width, height);
        return self;
    }

    /// Rotate video (90, 180, 270 degrees)
    /// Home API: pipeline.rotate(degrees: i32) -> Pipeline
    pub fn rotate(self: *Self, degrees: i32) !*Self {
        _ = try self.inner.rotate(degrees);
        return self;
    }

    /// Flip video horizontally
    /// Home API: pipeline.flip_horizontal() -> Pipeline
    pub fn flipHorizontal(self: *Self) !*Self {
        _ = try self.inner.flipHorizontal();
        return self;
    }

    /// Flip video vertically
    /// Home API: pipeline.flip_vertical() -> Pipeline
    pub fn flipVertical(self: *Self) !*Self {
        _ = try self.inner.flipVertical();
        return self;
    }

    // ========================================================================
    // Visual Filters
    // ========================================================================

    /// Apply blur filter
    /// Home API: pipeline.blur(sigma: f32) -> Pipeline
    pub fn blur(self: *Self, sigma: f32) !*Self {
        _ = try self.inner.blur(sigma);
        return self;
    }

    /// Apply sharpen filter
    /// Home API: pipeline.sharpen(amount: f32) -> Pipeline
    pub fn sharpen(self: *Self, amount: f32) !*Self {
        _ = try self.inner.sharpen(amount);
        return self;
    }

    /// Apply denoise filter
    /// Home API: pipeline.denoise() -> Pipeline
    pub fn denoise(self: *Self) !*Self {
        _ = try self.inner.denoise();
        return self;
    }

    /// Apply deinterlace filter
    /// Home API: pipeline.deinterlace() -> Pipeline
    pub fn deinterlace(self: *Self) !*Self {
        _ = try self.inner.deinterlace();
        return self;
    }

    /// Convert to grayscale
    /// Home API: pipeline.grayscale() -> Pipeline
    pub fn grayscale(self: *Self) !*Self {
        _ = try self.inner.grayscale();
        return self;
    }

    /// Adjust brightness
    /// Home API: pipeline.brightness(factor: f32) -> Pipeline
    pub fn brightness(self: *Self, factor: f32) !*Self {
        _ = try self.inner.brightness(factor);
        return self;
    }

    /// Adjust contrast
    /// Home API: pipeline.contrast(factor: f32) -> Pipeline
    pub fn contrast(self: *Self, factor: f32) !*Self {
        _ = try self.inner.contrast(factor);
        return self;
    }

    /// Adjust saturation
    /// Home API: pipeline.saturation(factor: f32) -> Pipeline
    pub fn saturation(self: *Self, factor: f32) !*Self {
        _ = try self.inner.saturation(factor);
        return self;
    }

    // ========================================================================
    // Audio Filters
    // ========================================================================

    /// Adjust volume
    /// Home API: pipeline.volume(factor: f32) -> Pipeline
    pub fn volume(self: *Self, factor: f32) !*Self {
        _ = try self.inner.volume(factor);
        return self;
    }

    /// Normalize audio
    /// Home API: pipeline.normalize() -> Pipeline
    pub fn normalize(self: *Self) !*Self {
        _ = try self.inner.normalize();
        return self;
    }

    /// Apply loudness normalization
    /// Home API: pipeline.loudnorm() -> Pipeline
    pub fn loudnorm(self: *Self) !*Self {
        _ = try self.inner.loudnorm();
        return self;
    }

    // ========================================================================
    // Time Operations
    // ========================================================================

    /// Set start time
    /// Home API: pipeline.start(seconds: f64) -> Pipeline
    pub fn start(self: *Self, seconds: f64) *Self {
        _ = self.inner.seek(seconds);
        return self;
    }

    /// Set duration
    /// Home API: pipeline.duration(seconds: f64) -> Pipeline
    pub fn durationSecs(self: *Self, seconds: f64) *Self {
        _ = self.inner.duration(seconds);
        return self;
    }

    /// Set end time
    /// Home API: pipeline.end(seconds: f64) -> Pipeline
    pub fn end(self: *Self, seconds: f64) *Self {
        _ = self.inner.to(seconds);
        return self;
    }

    /// Adjust playback speed
    /// Home API: pipeline.speed(factor: f32) -> Pipeline
    pub fn speed(self: *Self, factor: f32) *Self {
        _ = self.inner.speed(factor);
        return self;
    }

    // ========================================================================
    // Stream Selection
    // ========================================================================

    /// Copy video stream without re-encoding
    /// Home API: pipeline.copy_video() -> Pipeline
    pub fn copyVideo(self: *Self) *Self {
        _ = self.inner.copyVideo();
        return self;
    }

    /// Copy audio stream without re-encoding
    /// Home API: pipeline.copy_audio() -> Pipeline
    pub fn copyAudio(self: *Self) *Self {
        _ = self.inner.copyAudio();
        return self;
    }

    /// Remove video stream
    /// Home API: pipeline.no_video() -> Pipeline
    pub fn noVideo(self: *Self) *Self {
        _ = self.inner.noVideo();
        return self;
    }

    /// Remove audio stream
    /// Home API: pipeline.no_audio() -> Pipeline
    pub fn noAudio(self: *Self) *Self {
        _ = self.inner.noAudio();
        return self;
    }

    // ========================================================================
    // Execution
    // ========================================================================

    /// Run the pipeline synchronously
    /// Home API: pipeline.run() -> Result<(), MediaError>
    pub fn run(self: *Self) !void {
        try self.inner.run();
    }

    /// Run the pipeline with progress callback
    /// Home API: pipeline.run_with_progress(callback: fn(f32)) -> Result<(), MediaError>
    pub fn runWithProgress(self: *Self, callback: media.ProgressCallback) !void {
        _ = self.inner.onProgress(callback);
        try self.inner.run();
    }
};

// ============================================================================
// Convenience Functions for Home language
// ============================================================================

/// Quick transcode from one format to another
/// Home API: media.transcode(input: string, output: string) -> Result<(), MediaError>
pub fn transcode(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    return media.transcode(allocator, input_path, output_path);
}

/// Quick transmux (change container without re-encoding)
/// Home API: media.transmux(input: string, output: string) -> Result<(), MediaError>
pub fn transmux(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    return media.transmux(allocator, input_path, output_path);
}

/// Extract audio from video
/// Home API: media.extract_audio(input: string, output: string) -> Result<(), MediaError>
pub fn extractAudio(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    return media.extractAudio(allocator, input_path, output_path);
}

/// Generate thumbnail at specified time
/// Home API: media.thumbnail(input: string, output: string, time: f64) -> Result<(), MediaError>
pub fn thumbnail(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, time_seconds: f64) !void {
    return media.thumbnail(allocator, input_path, output_path, time_seconds);
}

/// Probe media file and get info
/// Home API: media.probe(path: string) -> Result<MediaInfo, MediaError>
pub fn probe(allocator: std.mem.Allocator, path: []const u8) !MediaInfo {
    return media.probe(allocator, path);
}

/// Detect media format from path
/// Home API: media.detect_format(path: string) -> ContainerFormat
pub fn detectFormat(path: []const u8) ContainerFormat {
    return media.detectFormat(path);
}

/// Detect media type from path
/// Home API: media.detect_type(path: string) -> MediaType
pub fn detectMediaType(path: []const u8) MediaType {
    return media.detectMediaType(path);
}

// ============================================================================
// Presets for common use cases
// ============================================================================

/// Encoding presets for common scenarios
pub const Presets = struct {
    /// Web-optimized H.264 video settings
    /// Home API: Presets.web_video() -> VideoEncodingOptions
    pub fn webVideo() media.VideoEncodingOptions {
        return media.Presets.webVideo();
    }

    /// High quality HEVC settings
    /// Home API: Presets.hq_video() -> VideoEncodingOptions
    pub fn hqVideo() media.VideoEncodingOptions {
        return media.Presets.hqVideo();
    }

    /// 4K/UHD HEVC settings
    /// Home API: Presets.uhd_video() -> VideoEncodingOptions
    pub fn uhdVideo() media.VideoEncodingOptions {
        return media.Presets.uhdVideo();
    }

    /// Archive quality (near-lossless)
    /// Home API: Presets.archive_video() -> VideoEncodingOptions
    pub fn archiveVideo() media.VideoEncodingOptions {
        return media.Presets.archiveVideo();
    }

    /// Standard AAC audio settings
    /// Home API: Presets.standard_audio() -> AudioEncodingOptions
    pub fn standardAudio() media.AudioEncodingOptions {
        return media.Presets.standardAudio();
    }

    /// High quality Opus audio settings
    /// Home API: Presets.hq_audio() -> AudioEncodingOptions
    pub fn hqAudio() media.AudioEncodingOptions {
        return media.Presets.hqAudio();
    }

    /// Lossless FLAC audio settings
    /// Home API: Presets.lossless_audio() -> AudioEncodingOptions
    pub fn losslessAudio() media.AudioEncodingOptions {
        return media.Presets.losslessAudio();
    }
};

// ============================================================================
// Batch Processing
// ============================================================================

/// Batch transcoder for processing multiple files
pub const BatchProcessor = struct {
    inner: media.BatchTranscoder,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new batch processor
    /// Home API: BatchProcessor.new() -> BatchProcessor
    pub fn new(allocator: std.mem.Allocator) Self {
        return .{
            .inner = media.BatchTranscoder.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.inner.deinit();
    }

    /// Add a transcoding job
    /// Home API: batch.add(input: string, output: string) -> BatchProcessor
    pub fn add(self: *Self, input_path: []const u8, output_path: []const u8) !*Self {
        try self.inner.addJob(.{
            .input_path = input_path,
            .output_path = output_path,
        });
        return self;
    }

    /// Add a job with video codec
    /// Home API: batch.add_with_codec(input: string, output: string, codec: VideoCodec) -> BatchProcessor
    pub fn addWithCodec(self: *Self, input_path: []const u8, output_path: []const u8, codec: VideoCodec) !*Self {
        try self.inner.addJob(.{
            .input_path = input_path,
            .output_path = output_path,
            .video_codec = codec,
        });
        return self;
    }

    /// Set maximum parallel jobs
    /// Home API: batch.parallel(count: u32) -> BatchProcessor
    pub fn parallel(self: *Self, count: u32) *Self {
        self.inner.setMaxParallel(count);
        return self;
    }

    /// Run all jobs
    /// Home API: batch.run() -> Result<[BatchResult], MediaError>
    pub fn run(self: *Self) ![]const media.BatchTranscoder.BatchResult {
        try self.inner.run();
        return self.inner.getResults();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Media binding - open and probe" {
    const allocator = std.testing.allocator;

    // Test that types are correctly exported
    _ = MediaType.video;
    _ = ContainerFormat.mp4;
    _ = VideoCodec.h264;
    _ = AudioCodec.aac;

    // Test Pipeline creation
    var p = Pipeline.new(allocator);
    defer p.deinit();

    _ = try p.input("test.mp4");
    _ = try p.output("output.webm");
    _ = p.videoCodec(.vp9);
    _ = p.audioCodec(.opus);
    _ = try p.resize(1920, 1080);
}

test "Pipeline - fluent API" {
    const allocator = std.testing.allocator;

    var p = Pipeline.new(allocator);
    defer p.deinit();

    // Test method chaining
    _ = try (try (try p.input("input.mp4")).output("output.mp4")).resize(1280, 720);
    _ = try p.blur(0.5);
    _ = try p.grayscale();
    _ = p.start(10.0);
    _ = p.durationSecs(60.0);
    _ = p.videoCodec(.hevc);
    _ = p.videoQuality(18);
}

test "BatchProcessor - basic operations" {
    const allocator = std.testing.allocator;

    var batch = BatchProcessor.new(allocator);
    defer batch.deinit();

    _ = try batch.add("video1.mp4", "video1.webm");
    _ = try batch.add("video2.mp4", "video2.webm");
    _ = batch.parallel(4);
}

test "Presets" {
    const web = Presets.webVideo();
    try std.testing.expectEqual(VideoCodec.h264, web.codec);

    const hq = Presets.hqVideo();
    try std.testing.expectEqual(VideoCodec.hevc, hq.codec);

    const audio = Presets.standardAudio();
    try std.testing.expectEqual(AudioCodec.aac, audio.codec);
}
