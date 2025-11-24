const std = @import("std");
const types = @import("../core/types.zig");

/// Conversion mode
pub const ConversionMode = enum {
    transmux, // Change container only, keep codecs
    transcode, // Re-encode media
    passthrough, // Copy specific streams without re-encoding
    mixed, // Transcode some streams, passthrough others
};

/// Progress callback
pub const ProgressCallback = *const fn (progress: f32, user_data: ?*anyopaque) void;

/// Cancellation token
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool),

    pub fn init() CancellationToken {
        return .{
            .cancelled = std.atomic.Value(bool).init(false),
        };
    }

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }
};

/// Stream action
pub const StreamAction = enum {
    copy, // Passthrough without re-encoding
    transcode, // Re-encode
    discard, // Remove stream
};

/// Video encoding options
pub const VideoEncodingOptions = struct {
    codec: []const u8, // e.g., "h264", "hevc", "vp9"
    bitrate_kbps: ?u32 = null,
    crf: ?u8 = null, // Constant Rate Factor (0-51 for x264/x265)
    preset: []const u8 = "medium", // ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow
    width: ?u32 = null,
    height: ?u32 = null,
    frame_rate: ?types.Rational = null,
    keyframe_interval: u32 = 250,
    b_frames: u8 = 3,
    pixel_format: []const u8 = "yuv420p",
};

/// Audio encoding options
pub const AudioEncodingOptions = struct {
    codec: []const u8, // e.g., "aac", "opus", "mp3"
    bitrate_kbps: ?u32 = null,
    sample_rate: ?u32 = null,
    channels: ?u8 = null,
    quality: ?u8 = null, // Codec-specific quality (e.g., 0-10 for Opus)
};

/// Subtitle handling
pub const SubtitleAction = enum {
    copy, // Copy subtitle stream
    burn_in, // Render subtitles onto video
    discard, // Remove subtitles
};

/// Conversion options
pub const ConversionOptions = struct {
    allocator: std.mem.Allocator,

    // Mode
    mode: ConversionMode = .transcode,

    // Input/Output
    input_path: []const u8,
    output_path: []const u8,

    // Video options
    video_action: StreamAction = .transcode,
    video_encoding: ?VideoEncodingOptions = null,
    video_stream_index: ?usize = null, // Which video stream to use (null = first)

    // Audio options
    audio_action: StreamAction = .transcode,
    audio_encoding: ?AudioEncodingOptions = null,
    audio_stream_indices: ?[]const usize = null, // Which audio streams to include

    // Subtitle options
    subtitle_action: SubtitleAction = .copy,
    subtitle_stream_indices: ?[]const usize = null,

    // Metadata
    copy_metadata: bool = true,
    metadata_overrides: ?std.StringHashMap([]const u8) = null,

    // Progress
    progress_callback: ?ProgressCallback = null,
    progress_user_data: ?*anyopaque = null,
    cancellation_token: ?*CancellationToken = null,

    // Two-pass encoding
    two_pass: bool = false,

    // Target file size (will calculate bitrate)
    target_size_mb: ?u32 = null,

    // Time range (trim)
    start_time_us: ?u64 = null,
    end_time_us: ?u64 = null,

    // Hardware acceleration
    use_hardware_accel: bool = false,
};

/// Conversion result
pub const ConversionResult = struct {
    success: bool,
    output_size_bytes: u64,
    duration_us: u64,
    video_codec: ?[]const u8,
    audio_codec: ?[]const u8,
    error_message: ?[]const u8,
};

/// High-level conversion API
pub const Converter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Converter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Converter) void {
        _ = self;
    }

    /// Convert a video file with given options
    pub fn convert(self: *Converter, options: ConversionOptions) !ConversionResult {
        // Use full pipeline implementation
        const pipeline_mod = @import("pipeline.zig");
        var pipeline = pipeline_mod.ConversionPipeline.init(self.allocator, options);
        defer pipeline.deinit();

        return try pipeline.execute();
    }

    /// Quick transmux (change container without re-encoding)
    pub fn transmux(self: *Converter, input_path: []const u8, output_path: []const u8) !ConversionResult {
        const options = ConversionOptions{
            .allocator = self.allocator,
            .input_path = input_path,
            .output_path = output_path,
            .mode = .transmux,
            .video_action = .copy,
            .audio_action = .copy,
        };

        return try self.convert(options);
    }

    /// Extract audio from video
    pub fn extractAudio(self: *Converter, input_path: []const u8, output_path: []const u8, audio_options: ?AudioEncodingOptions) !ConversionResult {
        const options = ConversionOptions{
            .allocator = self.allocator,
            .input_path = input_path,
            .output_path = output_path,
            .video_action = .discard,
            .audio_action = if (audio_options != null) .transcode else .copy,
            .audio_encoding = audio_options,
        };

        return try self.convert(options);
    }

    /// Create video from images
    pub fn imagesToVideo(self: *Converter, image_pattern: []const u8, output_path: []const u8, frame_rate: types.Rational, video_options: VideoEncodingOptions) !ConversionResult {
        // Create conversion options for image sequence
        const options = ConversionOptions{
            .allocator = self.allocator,
            .input_path = image_pattern,
            .output_path = output_path,
            .mode = .transcode,
            .video_action = .transcode,
            .video_encoding = video_options,
            .audio_action = .discard,
        };

        _ = frame_rate; // Would be used in source configuration
        return try self.convert(options);
    }

    /// Calculate optimal bitrate for target file size
    pub fn calculateBitrate(duration_us: u64, target_size_mb: u32, audio_bitrate_kbps: u32) u32 {
        const duration_sec = @as(f64, @floatFromInt(duration_us)) / 1_000_000.0;
        const target_size_bits = @as(f64, @floatFromInt(target_size_mb)) * 8.0 * 1024.0 * 1024.0;
        const audio_bits = @as(f64, @floatFromInt(audio_bitrate_kbps)) * 1000.0 * duration_sec;
        const video_bits = target_size_bits - audio_bits;
        const video_bitrate_kbps = video_bits / (duration_sec * 1000.0);

        return @intFromFloat(@max(100.0, video_bitrate_kbps)); // Minimum 100 kbps
    }
};

/// Batch conversion queue
pub const BatchConverter = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(ConversionOptions),
    results: std.ArrayList(ConversionResult),
    converter: Converter,

    pub fn init(allocator: std.mem.Allocator) BatchConverter {
        return .{
            .allocator = allocator,
            .queue = std.ArrayList(ConversionOptions).init(allocator),
            .results = std.ArrayList(ConversionResult).init(allocator),
            .converter = Converter.init(allocator),
        };
    }

    pub fn deinit(self: *BatchConverter) void {
        self.queue.deinit();
        self.results.deinit();
        self.converter.deinit();
    }

    pub fn addJob(self: *BatchConverter, options: ConversionOptions) !void {
        try self.queue.append(options);
    }

    pub fn processAll(self: *BatchConverter) !void {
        for (self.queue.items) |options| {
            const result = try self.converter.convert(options);
            try self.results.append(result);
        }
    }

    pub fn processParallel(self: *BatchConverter, thread_count: usize) !void {
        // Use parallel processor
        const pipeline_mod = @import("pipeline.zig");
        var processor = try pipeline_mod.ParallelBatchProcessor.init(self.allocator, thread_count);
        defer processor.deinit();

        // Add all jobs
        for (self.queue.items) |options| {
            try processor.addJob(options);
        }

        // Process in parallel
        try processor.processAll();

        // Collect results
        const results = processor.getResults();
        for (results) |result| {
            try self.results.append(result);
        }
    }

    pub fn getResult(self: *const BatchConverter, index: usize) ?ConversionResult {
        if (index < self.results.items.len) {
            return self.results.items[index];
        }
        return null;
    }

    pub fn getOverallProgress(self: *const BatchConverter) f32 {
        if (self.queue.items.len == 0) return 1.0;

        const completed = self.results.items.len;
        const total = self.queue.items.len;

        return @as(f32, @floatFromInt(completed)) / @as(f32, @floatFromInt(total));
    }
};

/// Preset configurations
pub const Presets = struct {
    /// H.264 presets for different use cases
    pub fn h264WebOptimized() VideoEncodingOptions {
        return .{
            .codec = "h264",
            .crf = 23,
            .preset = "medium",
            .pixel_format = "yuv420p",
            .keyframe_interval = 60,
            .b_frames = 2,
        };
    }

    pub fn h264HighQuality() VideoEncodingOptions {
        return .{
            .codec = "h264",
            .crf = 18,
            .preset = "slow",
            .pixel_format = "yuv420p",
            .keyframe_interval = 250,
            .b_frames = 3,
        };
    }

    pub fn h264LowLatency() VideoEncodingOptions {
        return .{
            .codec = "h264",
            .bitrate_kbps = 2000,
            .preset = "ultrafast",
            .pixel_format = "yuv420p",
            .keyframe_interval = 30,
            .b_frames = 0,
        };
    }

    /// AAC presets
    pub fn aacStandard() AudioEncodingOptions {
        return .{
            .codec = "aac",
            .bitrate_kbps = 128,
            .sample_rate = 48000,
            .channels = 2,
        };
    }

    pub fn aacHighQuality() AudioEncodingOptions {
        return .{
            .codec = "aac",
            .bitrate_kbps = 256,
            .sample_rate = 48000,
            .channels = 2,
        };
    }

    /// Opus presets
    pub fn opusVoice() AudioEncodingOptions {
        return .{
            .codec = "opus",
            .bitrate_kbps = 64,
            .sample_rate = 48000,
            .channels = 1,
        };
    }

    pub fn opusMusic() AudioEncodingOptions {
        return .{
            .codec = "opus",
            .bitrate_kbps = 128,
            .sample_rate = 48000,
            .channels = 2,
        };
    }
};
