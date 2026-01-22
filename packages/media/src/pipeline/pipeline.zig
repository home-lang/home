// Home Media Library - Pipeline Builder
// Fluent, chainable API for media processing operations

const std = @import("std");
const types = @import("../core/types.zig");
const err = @import("../core/error.zig");
const stream = @import("../core/stream.zig");
const probe = @import("../core/probe.zig");

const MediaType = types.MediaType;
const MediaInfo = types.MediaInfo;
const ContainerFormat = types.ContainerFormat;
const VideoCodec = types.VideoCodec;
const AudioCodec = types.AudioCodec;
const VideoEncodingOptions = types.VideoEncodingOptions;
const AudioEncodingOptions = types.AudioEncodingOptions;
const VideoFilter = types.VideoFilter;
const AudioFilter = types.AudioFilter;
const Timestamp = types.Timestamp;
const Duration = types.Duration;
const Rational = types.Rational;
const QualityPreset = types.QualityPreset;
const MediaError = err.MediaError;

// ============================================================================
// Filter Configuration
// ============================================================================

pub const FilterConfig = union(enum) {
    // Video filters
    scale: ScaleConfig,
    crop: CropConfig,
    rotate: RotateConfig,
    flip_h: void,
    flip_v: void,
    transpose: TransposeConfig,
    blur: BlurConfig,
    sharpen: SharpenConfig,
    grayscale: void,
    brightness: f32,
    contrast: f32,
    saturation: f32,
    hue: f32,
    gamma: f32,
    denoise: DenoiseConfig,
    deinterlace: DeinterlaceConfig,
    overlay: OverlayConfig,
    text: TextConfig,
    fade: FadeConfig,

    // Audio filters
    volume: f32,
    normalize: NormalizeConfig,
    loudnorm: LoudnormConfig,
    equalizer: EqualizerConfig,
    compressor: CompressorConfig,
    reverb: ReverbConfig,
    pitch: f32,
    tempo: f32,
    fade_in: f64, // Duration in seconds
    fade_out: f64,
};

pub const ScaleConfig = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    algorithm: ScaleAlgorithm = .bilinear,
    maintain_aspect: bool = true,
};

pub const ScaleAlgorithm = enum {
    nearest,
    bilinear,
    bicubic,
    lanczos,
    spline,
};

pub const CropConfig = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
};

pub const RotateConfig = struct {
    degrees: f32,
    expand: bool = true, // Expand output to fit rotated content
};

pub const TransposeConfig = enum {
    clockwise,
    counter_clockwise,
    flip_vertical,
    flip_horizontal,
};

pub const BlurConfig = struct {
    sigma: f32 = 1.0,
    radius: ?u32 = null, // Auto-calculate from sigma if null
};

pub const SharpenConfig = struct {
    amount: f32 = 1.0,
    threshold: f32 = 0.0,
};

pub const DenoiseConfig = struct {
    strength: f32 = 0.5,
    temporal: bool = true,
};

pub const DeinterlaceConfig = struct {
    mode: DeinterlaceMode = .yadif,
    field_order: FieldOrder = .auto,
};

pub const DeinterlaceMode = enum {
    yadif,
    bwdif,
    bob,
    blend,
};

pub const FieldOrder = enum {
    auto,
    tff, // Top field first
    bff, // Bottom field first
};

pub const OverlayConfig = struct {
    path: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    opacity: f32 = 1.0,
    start_time: ?f64 = null,
    end_time: ?f64 = null,
};

pub const TextConfig = struct {
    text: []const u8,
    font: ?[]const u8 = null,
    font_size: u32 = 24,
    color: u32 = 0xFFFFFFFF, // RGBA
    x: i32 = 0,
    y: i32 = 0,
    start_time: ?f64 = null,
    end_time: ?f64 = null,
};

pub const FadeConfig = struct {
    fade_type: FadeType,
    start_time: f64,
    duration: f64,
};

pub const FadeType = enum {
    fade_in,
    fade_out,
};

pub const NormalizeConfig = struct {
    target_level: f32 = -14.0, // LUFS
    true_peak: f32 = -1.0, // dBTP
};

pub const LoudnormConfig = struct {
    target_loudness: f32 = -14.0, // LUFS
    target_range: f32 = 7.0, // LU
    target_true_peak: f32 = -1.0, // dBTP
};

pub const EqualizerConfig = struct {
    bands: []const EqualizerBand,
};

pub const EqualizerBand = struct {
    frequency: f32,
    gain: f32, // dB
    q: f32 = 1.0,
};

pub const CompressorConfig = struct {
    threshold: f32 = -20.0, // dB
    ratio: f32 = 4.0,
    attack: f32 = 20.0, // ms
    release: f32 = 200.0, // ms
    makeup_gain: f32 = 0.0, // dB
};

pub const ReverbConfig = struct {
    room_size: f32 = 0.5,
    damping: f32 = 0.5,
    wet_level: f32 = 0.33,
    dry_level: f32 = 0.4,
};

// ============================================================================
// Pipeline State
// ============================================================================

const PipelineState = enum {
    created,
    configured,
    running,
    completed,
    failed,
    cancelled,
};

// ============================================================================
// Progress Callback
// ============================================================================

pub const ProgressCallback = *const fn (progress: f32, context: ?*anyopaque) void;

pub const ProgressInfo = struct {
    progress: f32, // 0.0 to 1.0
    frames_processed: u64,
    frames_total: u64,
    time_elapsed_ms: u64,
    time_remaining_ms: u64,
    current_fps: f32,
    current_bitrate: u32,
};

// ============================================================================
// Pipeline Builder
// ============================================================================

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    state: PipelineState = .created,

    // Input/Output
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    input_info: ?MediaInfo = null,

    // Encoding options
    video_options: VideoEncodingOptions = .{},
    audio_options: AudioEncodingOptions = .{},

    // Stream actions
    copy_video: bool = false,
    copy_audio: bool = false,
    remove_video: bool = false,
    remove_audio: bool = false,

    // Time range
    start_time: ?f64 = null,
    end_time: ?f64 = null,
    duration_limit: ?f64 = null,
    speed_factor: f32 = 1.0,

    // Filters
    video_filters: std.ArrayList(FilterConfig),
    audio_filters: std.ArrayList(FilterConfig),

    // Metadata
    metadata: std.StringHashMap([]const u8),
    copy_metadata: bool = true,
    strip_metadata: bool = false,

    // Callbacks
    progress_callback: ?ProgressCallback = null,
    progress_context: ?*anyopaque = null,

    // Cancellation
    cancelled: bool = false,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .video_filters = std.ArrayList(FilterConfig).init(allocator),
            .audio_filters = std.ArrayList(FilterConfig).init(allocator),
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.input_path) |p| self.allocator.free(p);
        if (self.output_path) |p| self.allocator.free(p);
        self.video_filters.deinit();
        self.audio_filters.deinit();

        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }

    // ========================================================================
    // Input/Output Configuration
    // ========================================================================

    /// Set input file path
    pub fn input(self: *Self, path: []const u8) !*Self {
        if (self.input_path) |p| self.allocator.free(p);
        self.input_path = try self.allocator.dupe(u8, path);
        self.state = .configured;
        return self;
    }

    /// Set output file path
    pub fn output(self: *Self, path: []const u8) !*Self {
        if (self.output_path) |p| self.allocator.free(p);
        self.output_path = try self.allocator.dupe(u8, path);
        return self;
    }

    // ========================================================================
    // Video Encoding Options
    // ========================================================================

    /// Set video codec
    pub fn videoCodec(self: *Self, codec: VideoCodec) *Self {
        self.video_options.codec = codec;
        self.copy_video = (codec == .copy);
        return self;
    }

    /// Set video bitrate (kbps)
    pub fn videoBitrate(self: *Self, kbps: u32) *Self {
        self.video_options.bitrate = kbps;
        return self;
    }

    /// Set video quality (CRF: 0-51, lower = better)
    pub fn videoQuality(self: *Self, crf: u8) *Self {
        self.video_options.crf = crf;
        return self;
    }

    /// Set encoding preset
    pub fn preset(self: *Self, p: VideoEncodingOptions.Preset) *Self {
        self.video_options.preset = p;
        return self;
    }

    /// Set frame rate
    pub fn fps(self: *Self, rate: f64) *Self {
        self.video_options.frame_rate = Rational.fromFloat(rate);
        return self;
    }

    /// Set pixel format
    pub fn pixelFormat(self: *Self, format: []const u8) !*Self {
        self.video_options.pixel_format = try self.allocator.dupe(u8, format);
        return self;
    }

    // ========================================================================
    // Audio Encoding Options
    // ========================================================================

    /// Set audio codec
    pub fn audioCodec(self: *Self, codec: AudioCodec) *Self {
        self.audio_options.codec = codec;
        self.copy_audio = (codec == .copy);
        return self;
    }

    /// Set audio bitrate (kbps)
    pub fn audioBitrate(self: *Self, kbps: u32) *Self {
        self.audio_options.bitrate = kbps;
        return self;
    }

    /// Set sample rate (Hz)
    pub fn sampleRate(self: *Self, hz: u32) *Self {
        self.audio_options.sample_rate = hz;
        return self;
    }

    /// Set channel count
    pub fn channels(self: *Self, count: u8) *Self {
        self.audio_options.channels = count;
        return self;
    }

    // ========================================================================
    // Quality Presets
    // ========================================================================

    /// Apply quality preset
    pub fn quality(self: *Self, q: QualityPreset) *Self {
        self.video_options = q.videoSettings();
        self.audio_options = q.audioSettings();
        return self;
    }

    // ========================================================================
    // Video Filters (Chainable)
    // ========================================================================

    /// Scale/resize video
    pub fn resize(self: *Self, width: u32, height: u32) !*Self {
        try self.video_filters.append(.{ .scale = .{ .width = width, .height = height, .maintain_aspect = false } });
        return self;
    }

    /// Scale video maintaining aspect ratio
    pub fn scale(self: *Self, width: u32) !*Self {
        try self.video_filters.append(.{ .scale = .{ .width = width, .maintain_aspect = true } });
        return self;
    }

    /// Scale with specific algorithm
    pub fn scaleWith(self: *Self, width: ?u32, height: ?u32, algorithm: ScaleAlgorithm) !*Self {
        try self.video_filters.append(.{ .scale = .{ .width = width, .height = height, .algorithm = algorithm } });
        return self;
    }

    /// Crop video
    pub fn crop(self: *Self, x: u32, y: u32, width: u32, height: u32) !*Self {
        try self.video_filters.append(.{ .crop = .{ .x = x, .y = y, .width = width, .height = height } });
        return self;
    }

    /// Rotate video
    pub fn rotate(self: *Self, degrees: f32) !*Self {
        try self.video_filters.append(.{ .rotate = .{ .degrees = degrees } });
        return self;
    }

    /// Flip horizontally
    pub fn flipH(self: *Self) !*Self {
        try self.video_filters.append(.{ .flip_h = {} });
        return self;
    }

    /// Flip vertically
    pub fn flipV(self: *Self) !*Self {
        try self.video_filters.append(.{ .flip_v = {} });
        return self;
    }

    /// Apply blur
    pub fn blur(self: *Self, sigma: f32) !*Self {
        try self.video_filters.append(.{ .blur = .{ .sigma = sigma } });
        return self;
    }

    /// Apply sharpening
    pub fn sharpen(self: *Self, amount: f32) !*Self {
        try self.video_filters.append(.{ .sharpen = .{ .amount = amount } });
        return self;
    }

    /// Convert to grayscale
    pub fn grayscale(self: *Self) !*Self {
        try self.video_filters.append(.{ .grayscale = {} });
        return self;
    }

    /// Adjust brightness (-1.0 to 1.0)
    pub fn brightness(self: *Self, factor: f32) !*Self {
        try self.video_filters.append(.{ .brightness = factor });
        return self;
    }

    /// Adjust contrast (0.0 to 2.0, 1.0 = no change)
    pub fn contrast(self: *Self, factor: f32) !*Self {
        try self.video_filters.append(.{ .contrast = factor });
        return self;
    }

    /// Adjust saturation (0.0 to 2.0, 1.0 = no change)
    pub fn saturation(self: *Self, factor: f32) !*Self {
        try self.video_filters.append(.{ .saturation = factor });
        return self;
    }

    /// Adjust hue (-180 to 180 degrees)
    pub fn hue(self: *Self, degrees: f32) !*Self {
        try self.video_filters.append(.{ .hue = degrees });
        return self;
    }

    /// Apply denoise filter
    pub fn denoise(self: *Self) !*Self {
        try self.video_filters.append(.{ .denoise = .{} });
        return self;
    }

    /// Deinterlace video
    pub fn deinterlace(self: *Self) !*Self {
        try self.video_filters.append(.{ .deinterlace = .{} });
        return self;
    }

    /// Add image overlay
    pub fn overlay(self: *Self, image_path: []const u8, x: i32, y: i32) !*Self {
        const path_copy = try self.allocator.dupe(u8, image_path);
        try self.video_filters.append(.{ .overlay = .{ .path = path_copy, .x = x, .y = y } });
        return self;
    }

    /// Add text overlay
    pub fn text(self: *Self, txt: []const u8, x: i32, y: i32) !*Self {
        const text_copy = try self.allocator.dupe(u8, txt);
        try self.video_filters.append(.{ .text = .{ .text = text_copy, .x = x, .y = y } });
        return self;
    }

    /// Add fade effect
    pub fn fade(self: *Self, fade_type: FadeType, start: f64, dur: f64) !*Self {
        try self.video_filters.append(.{ .fade = .{ .fade_type = fade_type, .start_time = start, .duration = dur } });
        return self;
    }

    // ========================================================================
    // Audio Filters (Chainable)
    // ========================================================================

    /// Adjust volume (0.0 to 2.0, 1.0 = no change)
    pub fn volume(self: *Self, factor: f32) !*Self {
        try self.audio_filters.append(.{ .volume = factor });
        return self;
    }

    /// Normalize audio to target loudness
    pub fn normalize(self: *Self) !*Self {
        try self.audio_filters.append(.{ .normalize = .{} });
        return self;
    }

    /// Apply loudness normalization (EBU R128)
    pub fn loudnorm(self: *Self) !*Self {
        try self.audio_filters.append(.{ .loudnorm = .{} });
        return self;
    }

    /// Apply compressor
    pub fn compressor(self: *Self, threshold: f32, ratio: f32) !*Self {
        try self.audio_filters.append(.{ .compressor = .{ .threshold = threshold, .ratio = ratio } });
        return self;
    }

    /// Apply reverb
    pub fn reverb(self: *Self, room_size: f32, damping: f32) !*Self {
        try self.audio_filters.append(.{ .reverb = .{ .room_size = room_size, .damping = damping } });
        return self;
    }

    /// Adjust pitch (semitones: -12 to +12)
    pub fn pitch(self: *Self, semitones: f32) !*Self {
        try self.audio_filters.append(.{ .pitch = semitones });
        return self;
    }

    /// Adjust tempo without changing pitch (0.5 to 2.0)
    pub fn tempo(self: *Self, factor: f32) !*Self {
        try self.audio_filters.append(.{ .tempo = factor });
        return self;
    }

    /// Add audio fade in
    pub fn fadeIn(self: *Self, dur: f64) !*Self {
        try self.audio_filters.append(.{ .fade_in = dur });
        return self;
    }

    /// Add audio fade out
    pub fn fadeOut(self: *Self, dur: f64) !*Self {
        try self.audio_filters.append(.{ .fade_out = dur });
        return self;
    }

    // ========================================================================
    // Time Operations
    // ========================================================================

    /// Set start time (seconds)
    pub fn start(self: *Self, seconds: f64) *Self {
        self.start_time = seconds;
        return self;
    }

    /// Set duration (seconds)
    pub fn duration(self: *Self, seconds: f64) *Self {
        self.duration_limit = seconds;
        return self;
    }

    /// Set end time (seconds)
    pub fn end(self: *Self, seconds: f64) *Self {
        self.end_time = seconds;
        return self;
    }

    /// Set speed factor (0.5 = half speed, 2.0 = double speed)
    pub fn speed(self: *Self, factor: f32) *Self {
        self.speed_factor = factor;
        return self;
    }

    // ========================================================================
    // Stream Selection
    // ========================================================================

    /// Copy video stream without re-encoding
    pub fn copyVideo(self: *Self) *Self {
        self.copy_video = true;
        self.video_options.codec = .copy;
        return self;
    }

    /// Copy audio stream without re-encoding
    pub fn copyAudio(self: *Self) *Self {
        self.copy_audio = true;
        self.audio_options.codec = .copy;
        return self;
    }

    /// Remove video stream
    pub fn noVideo(self: *Self) *Self {
        self.remove_video = true;
        return self;
    }

    /// Remove audio stream
    pub fn noAudio(self: *Self) *Self {
        self.remove_audio = true;
        return self;
    }

    // ========================================================================
    // Metadata
    // ========================================================================

    /// Set metadata key-value pair
    pub fn setMetadata(self: *Self, key: []const u8, value: []const u8) !*Self {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.metadata.put(key_copy, value_copy);
        return self;
    }

    /// Copy all metadata from input
    pub fn copyAllMetadata(self: *Self) *Self {
        self.copy_metadata = true;
        self.strip_metadata = false;
        return self;
    }

    /// Strip all metadata
    pub fn stripAllMetadata(self: *Self) *Self {
        self.strip_metadata = true;
        self.copy_metadata = false;
        return self;
    }

    // ========================================================================
    // Progress and Cancellation
    // ========================================================================

    /// Set progress callback
    pub fn onProgress(self: *Self, callback: ProgressCallback, context: ?*anyopaque) *Self {
        self.progress_callback = callback;
        self.progress_context = context;
        return self;
    }

    /// Cancel the pipeline
    pub fn cancel(self: *Self) void {
        self.cancelled = true;
    }

    // ========================================================================
    // Validation
    // ========================================================================

    fn validate(self: *const Self) MediaError!void {
        if (self.input_path == null) return MediaError.InputNotSet;
        if (self.output_path == null) return MediaError.OutputNotSet;

        // Check for conflicting options
        if (self.copy_video and self.video_filters.items.len > 0) {
            return MediaError.InvalidArgument;
        }
        if (self.copy_audio and self.audio_filters.items.len > 0) {
            return MediaError.InvalidArgument;
        }
    }

    // ========================================================================
    // Execution
    // ========================================================================

    /// Execute pipeline synchronously
    pub fn run(self: *Self) !void {
        try self.validate();

        self.state = .running;

        // Probe input file
        self.input_info = try probe.probe(self.allocator, self.input_path.?);

        // Execute pipeline
        try self.executePipeline();

        self.state = .completed;
    }

    /// Execute pipeline asynchronously
    pub fn runAsync(self: *Self) !std.Thread {
        try self.validate();

        return try std.Thread.spawn(.{}, runAsyncWorker, .{self});
    }

    fn runAsyncWorker(self: *Self) void {
        self.run() catch |e| {
            self.state = .failed;
            _ = e;
            return;
        };
    }

    fn executePipeline(self: *Self) !void {
        // This is the core pipeline execution
        // In a full implementation, this would:
        // 1. Open input file using video/audio/image decoders
        // 2. Apply filters in sequence
        // 3. Encode output using specified codecs
        // 4. Write to output file

        // For now, we'll use the underlying video/audio/image packages
        // This is a placeholder that shows the structure

        if (self.cancelled) return;

        const input_info = self.input_info orelse return MediaError.InvalidInput;

        // Report progress
        if (self.progress_callback) |cb| {
            cb(0.0, self.progress_context);
        }

        // Determine processing type based on input
        if (input_info.has_video) {
            try self.processVideo();
        } else if (input_info.has_audio) {
            try self.processAudio();
        } else {
            try self.processImage();
        }

        // Report completion
        if (self.progress_callback) |cb| {
            cb(1.0, self.progress_context);
        }
    }

    fn processVideo(self: *Self) !void {
        // Video processing using video package
        _ = self;
        // Implementation would use video.Converter
    }

    fn processAudio(self: *Self) !void {
        // Audio processing using audio package
        _ = self;
        // Implementation would use audio.Audio
    }

    fn processImage(self: *Self) !void {
        // Image processing using image package
        _ = self;
        // Implementation would use image.Image
    }

    // ========================================================================
    // Result Information
    // ========================================================================

    /// Get output file info after pipeline completion
    pub fn getOutputInfo(self: *Self) !MediaInfo {
        if (self.state != .completed) return MediaError.PipelineNotReady;
        if (self.output_path == null) return MediaError.OutputNotSet;
        return probe.probe(self.allocator, self.output_path.?);
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Quick transcode (format conversion)
pub fn transcode(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    _ = try pipeline.input(input_path);
    _ = try pipeline.output(output_path);
    try pipeline.run();
}

/// Quick transmux (container change only, no re-encoding)
pub fn transmux(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    _ = try pipeline.input(input_path);
    _ = pipeline.copyVideo();
    _ = pipeline.copyAudio();
    _ = try pipeline.output(output_path);
    try pipeline.run();
}

/// Extract audio from video
pub fn extractAudio(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    _ = try pipeline.input(input_path);
    _ = pipeline.noVideo();
    _ = try pipeline.output(output_path);
    try pipeline.run();
}

/// Create thumbnail from video
pub fn thumbnail(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8, time_seconds: f64) !void {
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    _ = try pipeline.input(input_path);
    _ = pipeline.start(time_seconds);
    _ = pipeline.duration(0.001); // Single frame
    _ = pipeline.noAudio();
    _ = try pipeline.output(output_path);
    try pipeline.run();
}

// ============================================================================
// Tests
// ============================================================================

test "Pipeline initialization" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    try std.testing.expectEqual(PipelineState.created, pipeline.state);
}

test "Pipeline configuration" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    _ = try pipeline.input("test.mp4");
    try std.testing.expectEqual(PipelineState.configured, pipeline.state);

    _ = pipeline.videoCodec(.hevc);
    try std.testing.expectEqual(VideoCodec.hevc, pipeline.video_options.codec);

    _ = pipeline.videoQuality(20);
    try std.testing.expectEqual(@as(u8, 20), pipeline.video_options.crf);

    _ = pipeline.audioCodec(.opus);
    try std.testing.expectEqual(AudioCodec.opus, pipeline.audio_options.codec);
}

test "Pipeline filters" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    _ = try pipeline.resize(1920, 1080);
    _ = try pipeline.blur(1.5);
    _ = try pipeline.grayscale();

    try std.testing.expectEqual(@as(usize, 3), pipeline.video_filters.items.len);
}

test "Pipeline time operations" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    _ = pipeline.start(10.0);
    _ = pipeline.duration(30.0);
    _ = pipeline.speed(2.0);

    try std.testing.expectEqual(@as(f64, 10.0), pipeline.start_time.?);
    try std.testing.expectEqual(@as(f64, 30.0), pipeline.duration_limit.?);
    try std.testing.expectEqual(@as(f32, 2.0), pipeline.speed_factor);
}

test "Pipeline stream selection" {
    const allocator = std.testing.allocator;
    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    _ = pipeline.copyVideo();
    try std.testing.expect(pipeline.copy_video);

    _ = pipeline.noAudio();
    try std.testing.expect(pipeline.remove_audio);
}
