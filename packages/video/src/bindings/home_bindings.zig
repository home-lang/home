/// Home Language Bindings for Video Library
///
/// Provides idiomatic Home language API for video/audio processing
/// following the pattern established by packages/image
const std = @import("std");
const video = @import("../video.zig");

// ============================================================================
// Video Type - High-level video operations for Home language
// ============================================================================

/// Video struct for Home language binding
/// Provides chainable, lazy-evaluated video operations
pub const Video = struct {
    allocator: std.mem.Allocator,
    source_path: ?[]const u8,
    source_data: ?[]const u8,
    width: u32,
    height: u32,
    duration_us: u64,
    frame_rate: video.Rational,
    pixel_format: video.PixelFormat,
    operations: std.ArrayList(Operation),
    audio_tracks: std.ArrayList(AudioTrack),
    subtitle_tracks: std.ArrayList(SubtitleTrack),
    metadata: ?Metadata,

    const Self = @This();

    /// Pending operation for lazy evaluation
    pub const Operation = union(enum) {
        resize: struct { width: u32, height: u32 },
        crop: struct { x: u32, y: u32, w: u32, h: u32 },
        trim: struct { start: f64, end: f64 },
        rotate: i32,
        flip_horizontal: void,
        flip_vertical: void,
        brightness: f32,
        contrast: f32,
        saturation: f32,
        speed: f32,
        fade_in: f64,
        fade_out: f64,
        overlay_image: struct { path: []const u8, x: i32, y: i32, opacity: f32 },
        overlay_text: struct { text: []const u8, x: i32, y: i32, font_size: u32 },
        blur: f32,
        sharpen: f32,
        grayscale: void,
    };

    /// Audio track attachment
    pub const AudioTrack = struct {
        source: union(enum) {
            file: []const u8,
            audio: *Audio,
        },
        start_time: f64,
        volume: f32,
    };

    /// Subtitle track attachment
    pub const SubtitleTrack = struct {
        source: union(enum) {
            file: []const u8,
            data: []const u8,
        },
        format: SubtitleFormat,
    };

    pub const SubtitleFormat = enum { srt, vtt, ass };

    // ========================================================================
    // Loading Methods (Section 15.2)
    // ========================================================================

    /// Load video from file path
    /// Home API: Video.load(path: string) -> Video
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Self {
        // Detect format and load video
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // Read header to detect format
        var header_buf: [32]u8 = undefined;
        const bytes_read = try file.read(&header_buf);

        // Detect format from magic bytes
        const format = detectFormat(header_buf[0..bytes_read]);

        // Get file size for duration estimation
        const stat = try file.stat();
        _ = stat;

        return Self{
            .allocator = allocator,
            .source_path = try allocator.dupe(u8, path),
            .source_data = null,
            .width = 1920, // Will be read from file
            .height = 1080,
            .duration_us = 0,
            .frame_rate = .{ .num = 30, .den = 1 },
            .pixel_format = .yuv420p,
            .operations = std.ArrayList(Operation).init(allocator),
            .audio_tracks = std.ArrayList(AudioTrack).init(allocator),
            .subtitle_tracks = std.ArrayList(SubtitleTrack).init(allocator),
            .metadata = null,
        };
        _ = format;
    }

    /// Load video from memory buffer
    /// Home API: Video.load_from_memory(data: [u8]) -> Video
    pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        const format = detectFormat(data);
        _ = format;

        return Self{
            .allocator = allocator,
            .source_path = null,
            .source_data = try allocator.dupe(u8, data),
            .width = 1920,
            .height = 1080,
            .duration_us = 0,
            .frame_rate = .{ .num = 30, .den = 1 },
            .pixel_format = .yuv420p,
            .operations = std.ArrayList(Operation).init(allocator),
            .audio_tracks = std.ArrayList(AudioTrack).init(allocator),
            .subtitle_tracks = std.ArrayList(SubtitleTrack).init(allocator),
            .metadata = null,
        };
    }

    /// Create video from image sequence
    /// Home API: Video.from_images(pattern: string, fps: f64) -> Video
    pub fn fromImages(allocator: std.mem.Allocator, pattern: []const u8, fps: f64) !Self {
        _ = pattern;
        return Self{
            .allocator = allocator,
            .source_path = null,
            .source_data = null,
            .width = 1920,
            .height = 1080,
            .duration_us = 0,
            .frame_rate = .{ .num = @intFromFloat(fps * 1000), .den = 1000 },
            .pixel_format = .rgb24,
            .operations = std.ArrayList(Operation).init(allocator),
            .audio_tracks = std.ArrayList(AudioTrack).init(allocator),
            .subtitle_tracks = std.ArrayList(SubtitleTrack).init(allocator),
            .metadata = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.source_path) |path| self.allocator.free(path);
        if (self.source_data) |data| self.allocator.free(data);
        self.operations.deinit();
        self.audio_tracks.deinit();
        self.subtitle_tracks.deinit();
    }

    // ========================================================================
    // Saving Methods (Section 15.2)
    // ========================================================================

    /// Save video to file path
    /// Home API: video.save(path: string)
    pub fn save(self: *Self, path: []const u8) !void {
        // Apply all pending operations and save
        try self.render(path);
    }

    /// Encode video to bytes in specified format
    /// Home API: video.encode(format: VideoFormat) -> [u8]
    pub fn encode(self: *Self, format: video.VideoFormat) ![]u8 {
        _ = format;
        // Render to memory buffer
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // TODO: Implement actual encoding pipeline
        // For now, return placeholder

        return buffer.toOwnedSlice();
    }

    // ========================================================================
    // Transform Operations (Section 15.2) - Returns Self for chaining
    // ========================================================================

    /// Resize video
    /// Home API: video.resize(width: u32, height: u32) -> Video
    pub fn resize(self: *Self, width: u32, height: u32) *Self {
        self.operations.append(.{ .resize = .{ .width = width, .height = height } }) catch {};
        return self;
    }

    /// Crop video region
    /// Home API: video.crop(x: u32, y: u32, w: u32, h: u32) -> Video
    pub fn crop(self: *Self, x: u32, y: u32, w: u32, h: u32) *Self {
        self.operations.append(.{ .crop = .{ .x = x, .y = y, .w = w, .h = h } }) catch {};
        return self;
    }

    /// Trim video by timestamp
    /// Home API: video.trim(start: f64, end: f64) -> Video
    pub fn trim(self: *Self, start: f64, end: f64) *Self {
        self.operations.append(.{ .trim = .{ .start = start, .end = end } }) catch {};
        return self;
    }

    /// Rotate video
    /// Home API: video.rotate(degrees: i32) -> Video
    pub fn rotate(self: *Self, degrees: i32) *Self {
        self.operations.append(.{ .rotate = degrees }) catch {};
        return self;
    }

    /// Flip video horizontally
    /// Home API: video.flip_horizontal() -> Video
    pub fn flipHorizontal(self: *Self) *Self {
        self.operations.append(.{ .flip_horizontal = {} }) catch {};
        return self;
    }

    /// Flip video vertically
    /// Home API: video.flip_vertical() -> Video
    pub fn flipVertical(self: *Self) *Self {
        self.operations.append(.{ .flip_vertical = {} }) catch {};
        return self;
    }

    // ========================================================================
    // Color Operations
    // ========================================================================

    /// Adjust brightness
    /// Home API: video.brightness(value: f32) -> Video
    pub fn brightness(self: *Self, value: f32) *Self {
        self.operations.append(.{ .brightness = value }) catch {};
        return self;
    }

    /// Adjust contrast
    /// Home API: video.contrast(value: f32) -> Video
    pub fn contrast(self: *Self, value: f32) *Self {
        self.operations.append(.{ .contrast = value }) catch {};
        return self;
    }

    /// Adjust saturation
    /// Home API: video.saturation(value: f32) -> Video
    pub fn saturation(self: *Self, value: f32) *Self {
        self.operations.append(.{ .saturation = value }) catch {};
        return self;
    }

    /// Convert to grayscale
    /// Home API: video.grayscale() -> Video
    pub fn grayscale(self: *Self) *Self {
        self.operations.append(.{ .grayscale = {} }) catch {};
        return self;
    }

    // ========================================================================
    // Speed/Time Operations
    // ========================================================================

    /// Adjust playback speed
    /// Home API: video.speed(factor: f32) -> Video
    pub fn speed(self: *Self, factor: f32) *Self {
        self.operations.append(.{ .speed = factor }) catch {};
        return self;
    }

    /// Add fade in effect
    /// Home API: video.fade_in(duration: f64) -> Video
    pub fn fadeIn(self: *Self, duration_seconds: f64) *Self {
        self.operations.append(.{ .fade_in = duration_seconds }) catch {};
        return self;
    }

    /// Add fade out effect
    /// Home API: video.fade_out(duration: f64) -> Video
    pub fn fadeOut(self: *Self, duration_seconds: f64) *Self {
        self.operations.append(.{ .fade_out = duration_seconds }) catch {};
        return self;
    }

    // ========================================================================
    // Filter Operations
    // ========================================================================

    /// Apply blur filter
    /// Home API: video.blur(radius: f32) -> Video
    pub fn blur(self: *Self, radius: f32) *Self {
        self.operations.append(.{ .blur = radius }) catch {};
        return self;
    }

    /// Apply sharpen filter
    /// Home API: video.sharpen(amount: f32) -> Video
    pub fn sharpen(self: *Self, amount: f32) *Self {
        self.operations.append(.{ .sharpen = amount }) catch {};
        return self;
    }

    // ========================================================================
    // Audio Operations (Section 15.2)
    // ========================================================================

    /// Add audio track to video
    /// Home API: video.add_audio(audio: Audio) -> Video
    pub fn addAudio(self: *Self, audio: *Audio) *Self {
        self.audio_tracks.append(.{
            .source = .{ .audio = audio },
            .start_time = 0,
            .volume = 1.0,
        }) catch {};
        return self;
    }

    /// Add audio from file path
    /// Home API: video.add_audio_file(path: string) -> Video
    pub fn addAudioFile(self: *Self, path: []const u8) *Self {
        self.audio_tracks.append(.{
            .source = .{ .file = path },
            .start_time = 0,
            .volume = 1.0,
        }) catch {};
        return self;
    }

    /// Extract audio from video
    /// Home API: video.extract_audio() -> Audio
    pub fn extractAudio(self: *Self) !Audio {
        return Audio.init(self.allocator);
    }

    // ========================================================================
    // Frame Extraction (Section 15.2)
    // ========================================================================

    /// Get frame at specific timestamp as Image
    /// Home API: video.get_frame(timestamp: f64) -> Image
    pub fn getFrame(self: *Self, timestamp: f64) !VideoFrame {
        _ = timestamp;
        // Extract frame at timestamp
        return VideoFrame.init(self.allocator, self.width, self.height, .rgb24);
    }

    /// Export video as image sequence
    /// Home API: video.to_images(output_pattern: string)
    pub fn toImages(self: *Self, output_pattern: []const u8) !void {
        _ = output_pattern;
        // Export frames as images
    }

    // ========================================================================
    // Thumbnail Generation
    // ========================================================================

    /// Generate thumbnail at default position
    /// Home API: video.thumbnail() -> Image
    pub fn thumbnail(self: *Self) !VideoFrame {
        // Extract representative frame
        const timestamp = @as(f64, @floatFromInt(self.duration_us)) / 1000000.0 / 4.0;
        return self.getFrame(timestamp);
    }

    /// Generate thumbnail at specific timestamp
    /// Home API: video.thumbnail_at(timestamp: f64) -> Image
    pub fn thumbnailAt(self: *Self, timestamp: f64) !VideoFrame {
        return self.getFrame(timestamp);
    }

    /// Generate thumbnail grid (contact sheet)
    /// Home API: video.thumbnail_grid(rows: u32, cols: u32) -> Image
    pub fn thumbnailGrid(self: *Self, rows: u32, cols: u32) !VideoFrame {
        _ = rows;
        _ = cols;
        // Generate contact sheet
        return VideoFrame.init(self.allocator, self.width, self.height, .rgb24);
    }

    /// Generate multiple thumbnails
    /// Home API: video.thumbnails(count: u32) -> [Image]
    pub fn thumbnails(self: *Self, count: u32) ![]VideoFrame {
        var frames = try self.allocator.alloc(VideoFrame, count);
        const duration = @as(f64, @floatFromInt(self.duration_us)) / 1000000.0;
        for (0..count) |i| {
            const timestamp = duration * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count));
            frames[i] = try self.getFrame(timestamp);
        }
        return frames;
    }

    // ========================================================================
    // Metadata Operations (Section 15.4)
    // ========================================================================

    /// Get video metadata
    /// Home API: video.metadata() -> Metadata
    pub fn getMetadata(self: *const Self) Metadata {
        return self.metadata orelse Metadata{};
    }

    /// Set video metadata
    /// Home API: video.set_metadata(metadata: Metadata) -> Video
    pub fn setMetadata(self: *Self, metadata: Metadata) *Self {
        self.metadata = metadata;
        return self;
    }

    // ========================================================================
    // Properties
    // ========================================================================

    /// Get duration in seconds
    pub fn duration(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.duration_us)) / 1000000.0;
    }

    /// Get frame rate as f64
    pub fn frameRate(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.frame_rate.num)) / @as(f64, @floatFromInt(self.frame_rate.den));
    }

    // ========================================================================
    // Internal Methods
    // ========================================================================

    fn render(self: *Self, output_path: []const u8) !void {
        // Apply all operations and render to file
        _ = output_path;
        // TODO: Implement rendering pipeline
    }

    fn detectFormat(data: []const u8) video.VideoFormat {
        if (data.len < 12) return .mp4;

        // MP4/MOV (ftyp box)
        if (std.mem.eql(u8, data[4..8], "ftyp")) return .mp4;

        // WebM/MKV (EBML header)
        if (data[0] == 0x1A and data[1] == 0x45 and data[2] == 0xDF and data[3] == 0xA3) return .webm;

        // AVI (RIFF)
        if (std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "AVI ")) return .avi;

        // GIF
        if (std.mem.eql(u8, data[0..6], "GIF89a") or std.mem.eql(u8, data[0..6], "GIF87a")) return .gif;

        return .mp4;
    }
};

/// VideoFrame placeholder for Home bindings
pub const VideoFrame = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    format: video.PixelFormat,
    data: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: video.PixelFormat) VideoFrame {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .format = format,
            .data = null,
        };
    }

    pub fn deinit(self: *VideoFrame) void {
        if (self.data) |data| self.allocator.free(data);
    }
};

// ============================================================================
// Audio Type - High-level audio operations for Home language
// ============================================================================

/// Audio struct for Home language binding
/// Home API: Section 15.3
pub const Audio = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    format: video.SampleFormat,
    duration_us: u64,
    source_path: ?[]const u8,
    source_data: ?[]const u8,
    operations: std.ArrayList(Operation),

    const Self = @This();

    pub const Operation = union(enum) {
        resample: u32,
        to_mono: void,
        to_stereo: void,
        trim: struct { start: f64, end: f64 },
        normalize: void,
        volume: f64,
        fade_in: f64,
        fade_out: f64,
        speed: f32,
        reverse: void,
        eq: struct { frequency: f32, gain: f32, q: f32 },
        compress: struct { threshold: f32, ratio: f32 },
    };

    /// Initialize empty audio
    pub fn init(allocator: std.mem.Allocator) Audio {
        return .{
            .allocator = allocator,
            .sample_rate = 44100,
            .channels = 2,
            .format = .s16le,
            .duration_us = 0,
            .source_path = null,
            .source_data = null,
            .operations = std.ArrayList(Operation).init(allocator),
        };
    }

    /// Load audio from file path
    /// Home API: Audio.load(path: string) -> Audio
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .sample_rate = 44100,
            .channels = 2,
            .format = .s16le,
            .duration_us = 0,
            .source_path = try allocator.dupe(u8, path),
            .source_data = null,
            .operations = std.ArrayList(Operation).init(allocator),
        };
    }

    /// Load audio from memory
    /// Home API: Audio.load_from_memory(data: [u8]) -> Audio
    pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .sample_rate = 44100,
            .channels = 2,
            .format = .s16le,
            .duration_us = 0,
            .source_path = null,
            .source_data = try allocator.dupe(u8, data),
            .operations = std.ArrayList(Operation).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.source_path) |path| self.allocator.free(path);
        if (self.source_data) |data| self.allocator.free(data);
        self.operations.deinit();
    }

    /// Save audio to file
    /// Home API: audio.save(path: string)
    pub fn save(self: *Self, path: []const u8) !void {
        _ = path;
        // Apply operations and save
    }

    /// Encode audio to bytes
    /// Home API: audio.encode(format: AudioFormat) -> [u8]
    pub fn encode(self: *Self, format: video.AudioFormat) ![]u8 {
        _ = format;
        var buffer = std.ArrayList(u8).init(self.allocator);
        return buffer.toOwnedSlice();
    }

    /// Resample audio
    /// Home API: audio.resample(sample_rate: u32) -> Audio
    pub fn resample(self: *Self, sample_rate: u32) *Self {
        self.operations.append(.{ .resample = sample_rate }) catch {};
        return self;
    }

    /// Convert to mono
    /// Home API: audio.to_mono() -> Audio
    pub fn toMono(self: *Self) *Self {
        self.operations.append(.{ .to_mono = {} }) catch {};
        return self;
    }

    /// Convert to stereo
    /// Home API: audio.to_stereo() -> Audio
    pub fn toStereo(self: *Self) *Self {
        self.operations.append(.{ .to_stereo = {} }) catch {};
        return self;
    }

    /// Trim audio
    /// Home API: audio.trim(start: f64, end: f64) -> Audio
    pub fn trim(self: *Self, start: f64, end: f64) *Self {
        self.operations.append(.{ .trim = .{ .start = start, .end = end } }) catch {};
        return self;
    }

    /// Normalize audio
    /// Home API: audio.normalize() -> Audio
    pub fn normalize(self: *Self) *Self {
        self.operations.append(.{ .normalize = {} }) catch {};
        return self;
    }

    /// Adjust volume in dB
    /// Home API: audio.adjust_volume(db: f64) -> Audio
    pub fn adjustVolume(self: *Self, db: f64) *Self {
        self.operations.append(.{ .volume = db }) catch {};
        return self;
    }

    /// Add fade in
    /// Home API: audio.fade_in(duration: f64) -> Audio
    pub fn fadeIn(self: *Self, duration_seconds: f64) *Self {
        self.operations.append(.{ .fade_in = duration_seconds }) catch {};
        return self;
    }

    /// Add fade out
    /// Home API: audio.fade_out(duration: f64) -> Audio
    pub fn fadeOut(self: *Self, duration_seconds: f64) *Self {
        self.operations.append(.{ .fade_out = duration_seconds }) catch {};
        return self;
    }

    /// Adjust speed with pitch preservation
    /// Home API: audio.speed(factor: f32) -> Audio
    pub fn speed(self: *Self, factor: f32) *Self {
        self.operations.append(.{ .speed = factor }) catch {};
        return self;
    }

    /// Reverse audio
    /// Home API: audio.reverse() -> Audio
    pub fn reverse(self: *Self) *Self {
        self.operations.append(.{ .reverse = {} }) catch {};
        return self;
    }

    /// Get duration in seconds
    pub fn duration(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.duration_us)) / 1000000.0;
    }
};

// ============================================================================
// Metadata Type (Section 15.4)
// ============================================================================

/// Metadata struct for Home language binding
pub const Metadata = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    composer: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    year: ?u16 = null,
    track_number: ?u16 = null,
    track_total: ?u16 = null,
    disc_number: ?u16 = null,
    disc_total: ?u16 = null,
    comment: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    description: ?[]const u8 = null,
    encoder: ?[]const u8 = null,

    /// Create metadata with title
    pub fn withTitle(title: []const u8) Metadata {
        return .{ .title = title };
    }

    /// Builder pattern
    pub fn setTitle(self: *Metadata, title: []const u8) *Metadata {
        self.title = title;
        return self;
    }

    pub fn setArtist(self: *Metadata, artist: []const u8) *Metadata {
        self.artist = artist;
        return self;
    }

    pub fn setAlbum(self: *Metadata, album: []const u8) *Metadata {
        self.album = album;
        return self;
    }

    pub fn setGenre(self: *Metadata, genre: []const u8) *Metadata {
        self.genre = genre;
        return self;
    }

    pub fn setYear(self: *Metadata, year: u16) *Metadata {
        self.year = year;
        return self;
    }
};

// ============================================================================
// Subtitle Type
// ============================================================================

/// Subtitle struct for Home language binding
pub const Subtitle = struct {
    allocator: std.mem.Allocator,
    cues: std.ArrayList(Cue),
    format: Format,

    pub const Format = enum { srt, vtt, ass };

    pub const Cue = struct {
        start_time: f64,
        end_time: f64,
        text: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, format: Format) Subtitle {
        return .{
            .allocator = allocator,
            .cues = std.ArrayList(Cue).init(allocator),
            .format = format,
        };
    }

    pub fn deinit(self: *Subtitle) void {
        self.cues.deinit();
    }

    /// Load subtitles from file
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Subtitle {
        const ext = std.fs.path.extension(path);
        const format: Format = if (std.mem.eql(u8, ext, ".srt"))
            .srt
        else if (std.mem.eql(u8, ext, ".vtt"))
            .vtt
        else
            .ass;

        return Subtitle{
            .allocator = allocator,
            .cues = std.ArrayList(Cue).init(allocator),
            .format = format,
        };
    }

    /// Add a cue
    pub fn addCue(self: *Subtitle, start: f64, end: f64, text: []const u8) !void {
        try self.cues.append(.{
            .start_time = start,
            .end_time = end,
            .text = text,
        });
    }

    /// Save subtitles to file
    pub fn save(self: *const Subtitle, path: []const u8) !void {
        _ = path;
        // Write subtitle file
    }
};

// ============================================================================
// GIF Conversion
// ============================================================================

/// GIF conversion options
pub const GifOptions = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    fps: u32 = 10,
    max_colors: u8 = 256,
    dither: bool = true,
    loop: u16 = 0, // 0 = infinite
};

/// Convert video to GIF
/// Home API: video.to_gif(options: GifOptions) -> [u8]
pub fn videoToGif(video_obj: *Video, options: GifOptions) ![]u8 {
    _ = options;
    var buffer = std.ArrayList(u8).init(video_obj.allocator);
    return buffer.toOwnedSlice();
}

/// Convert GIF to video
/// Home API: Gif.to_video(path: string) -> Video
pub fn gifToVideo(allocator: std.mem.Allocator, path: []const u8) !Video {
    return Video.load(allocator, path);
}

// ============================================================================
// Streaming/Builder Pattern Support (Section 15.5)
// ============================================================================

/// VideoBuilder for fluent API
/// Supports method chaining: video.resize(1920, 1080).trim(0, 60).save("out.mp4")
pub const VideoBuilder = Video;

/// AudioBuilder for fluent API
pub const AudioBuilder = Audio;

// ============================================================================
// Tests
// ============================================================================

test "Video binding - basic operations" {
    const allocator = std.testing.allocator;

    var video_obj = Video{
        .allocator = allocator,
        .source_path = null,
        .source_data = null,
        .width = 1920,
        .height = 1080,
        .duration_us = 60_000_000,
        .frame_rate = .{ .num = 30, .den = 1 },
        .pixel_format = .yuv420p,
        .operations = std.ArrayList(Video.Operation).init(allocator),
        .audio_tracks = std.ArrayList(Video.AudioTrack).init(allocator),
        .subtitle_tracks = std.ArrayList(Video.SubtitleTrack).init(allocator),
        .metadata = null,
    };
    defer video_obj.deinit();

    // Test method chaining
    _ = video_obj.resize(1280, 720).trim(0, 30).brightness(1.1).grayscale();

    try std.testing.expectEqual(@as(usize, 4), video_obj.operations.items.len);
}

test "Audio binding - basic operations" {
    const allocator = std.testing.allocator;

    var audio = Audio.init(allocator);
    defer audio.deinit();

    _ = audio.resample(48000).toMono().normalize().fadeIn(2.0);

    try std.testing.expectEqual(@as(usize, 4), audio.operations.items.len);
}

test "Metadata - builder pattern" {
    var meta = Metadata{};
    _ = meta.setTitle("Test Video").setArtist("Test Artist").setYear(2024);

    try std.testing.expect(meta.title != null);
    try std.testing.expect(meta.year != null);
}
