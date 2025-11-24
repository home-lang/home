const std = @import("std");
const types = @import("../core/types.zig");
const frame = @import("../core/frame.zig");

/// Video source interface
pub const VideoSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getNextFrame: *const fn (ptr: *anyopaque) anyerror!?frame.VideoFrame,
        reset: *const fn (ptr: *anyopaque) anyerror!void,
        getDuration: *const fn (ptr: *anyopaque) u64,
        getFrameRate: *const fn (ptr: *anyopaque) types.Rational,
        getResolution: *const fn (ptr: *anyopaque) struct { width: u32, height: u32 },
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn getNextFrame(self: VideoSource) !?frame.VideoFrame {
        return self.vtable.getNextFrame(self.ptr);
    }

    pub fn reset(self: VideoSource) !void {
        return self.vtable.reset(self.ptr);
    }

    pub fn getDuration(self: VideoSource) u64 {
        return self.vtable.getDuration(self.ptr);
    }

    pub fn getFrameRate(self: VideoSource) types.Rational {
        return self.vtable.getFrameRate(self.ptr);
    }

    pub fn getResolution(self: VideoSource) struct { width: u32, height: u32 } {
        return self.vtable.getResolution(self.ptr);
    }

    pub fn deinit(self: VideoSource) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Audio source interface
pub const AudioSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getNextSamples: *const fn (ptr: *anyopaque, sample_count: usize) anyerror!?frame.AudioFrame,
        reset: *const fn (ptr: *anyopaque) anyerror!void,
        getSampleRate: *const fn (ptr: *anyopaque) u32,
        getChannelCount: *const fn (ptr: *anyopaque) u8,
        getDuration: *const fn (ptr: *anyopaque) u64,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn getNextSamples(self: AudioSource, sample_count: usize) !?frame.AudioFrame {
        return self.vtable.getNextSamples(self.ptr, sample_count);
    }

    pub fn reset(self: AudioSource) !void {
        return self.vtable.reset(self.ptr);
    }

    pub fn getSampleRate(self: AudioSource) u32 {
        return self.vtable.getSampleRate(self.ptr);
    }

    pub fn getChannelCount(self: AudioSource) u8 {
        return self.vtable.getChannelCount(self.ptr);
    }

    pub fn getDuration(self: AudioSource) u64 {
        return self.vtable.getDuration(self.ptr);
    }

    pub fn deinit(self: AudioSource) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Image sequence source (create video from images)
pub const ImageSequenceSource = struct {
    allocator: std.mem.Allocator,
    image_paths: [][]const u8,
    current_index: usize,
    frame_rate: types.Rational,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, image_paths: [][]const u8, frame_rate: types.Rational) !ImageSequenceSource {
        if (image_paths.len == 0) return error.NoImages;

        // Would load first image to get dimensions
        return ImageSequenceSource{
            .allocator = allocator,
            .image_paths = image_paths,
            .current_index = 0,
            .frame_rate = frame_rate,
            .width = 1920, // Would get from first image
            .height = 1080,
        };
    }

    pub fn deinit(self: *ImageSequenceSource) void {
        _ = self;
    }

    pub fn asVideoSource(self: *ImageSequenceSource) VideoSource {
        return VideoSource{
            .ptr = self,
            .vtable = &.{
                .getNextFrame = getNextFrameImpl,
                .reset = resetImpl,
                .getDuration = getDurationImpl,
                .getFrameRate = getFrameRateImpl,
                .getResolution = getResolutionImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextFrameImpl(ptr: *anyopaque) !?frame.VideoFrame {
        const self: *ImageSequenceSource = @ptrCast(@alignCast(ptr));

        if (self.current_index >= self.image_paths.len) return null;

        const image_path = self.image_paths[self.current_index];

        // Load image file
        const file = try std.fs.cwd().openFile(image_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const image_data = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(image_data);

        _ = try file.readAll(image_data);

        // Create video frame (assuming RGB24 format from image decode)
        // In a real implementation, would use packages/image to decode
        var video_frame = try frame.VideoFrame.init(self.allocator, self.width, self.height, .rgb24);

        // Set timestamp based on frame index and frame rate
        const fps = @as(f64, @floatFromInt(self.frame_rate.num)) / @as(f64, @floatFromInt(self.frame_rate.den));
        const timestamp_us = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.current_index)) / fps * 1_000_000.0));
        video_frame.pts = types.Timestamp.fromMicroseconds(timestamp_us);

        const frame_duration_us = @as(u64, @intFromFloat(1_000_000.0 / fps));
        video_frame.duration = types.Duration.fromMicroseconds(frame_duration_us);

        video_frame.is_key_frame = true;
        video_frame.decode_order = self.current_index;
        video_frame.display_order = self.current_index;

        self.current_index += 1;

        return video_frame;
    }

    fn resetImpl(ptr: *anyopaque) !void {
        const self: *ImageSequenceSource = @ptrCast(@alignCast(ptr));
        self.current_index = 0;
    }

    fn getDurationImpl(ptr: *anyopaque) u64 {
        const self: *ImageSequenceSource = @ptrCast(@alignCast(ptr));
        const frame_count = self.image_paths.len;
        const fps = @as(f64, @floatFromInt(self.frame_rate.num)) / @as(f64, @floatFromInt(self.frame_rate.den));
        return @intFromFloat(@as(f64, @floatFromInt(frame_count)) / fps * 1_000_000.0);
    }

    fn getFrameRateImpl(ptr: *anyopaque) types.Rational {
        const self: *ImageSequenceSource = @ptrCast(@alignCast(ptr));
        return self.frame_rate;
    }

    fn getResolutionImpl(ptr: *anyopaque) struct { width: u32, height: u32 } {
        const self: *ImageSequenceSource = @ptrCast(@alignCast(ptr));
        return .{ .width = self.width, .height = self.height };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ImageSequenceSource = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Canvas source (procedural frame generation)
pub const CanvasSource = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    frame_rate: types.Rational,
    duration_us: u64,
    current_frame: u64,
    render_callback: *const fn (frame_number: u64, pixels: []u8, user_data: ?*anyopaque) anyerror!void,
    user_data: ?*anyopaque,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        frame_rate: types.Rational,
        duration_us: u64,
        render_callback: *const fn (frame_number: u64, pixels: []u8, user_data: ?*anyopaque) anyerror!void,
        user_data: ?*anyopaque,
    ) CanvasSource {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .frame_rate = frame_rate,
            .duration_us = duration_us,
            .current_frame = 0,
            .render_callback = render_callback,
            .user_data = user_data,
        };
    }

    pub fn deinit(self: *CanvasSource) void {
        _ = self;
    }

    pub fn asVideoSource(self: *CanvasSource) VideoSource {
        return VideoSource{
            .ptr = self,
            .vtable = &.{
                .getNextFrame = getNextFrameImpl,
                .reset = resetImpl,
                .getDuration = getDurationImpl,
                .getFrameRate = getFrameRateImpl,
                .getResolution = getResolutionImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextFrameImpl(ptr: *anyopaque) !?frame.VideoFrame {
        const self: *CanvasSource = @ptrCast(@alignCast(ptr));

        const fps = @as(f64, @floatFromInt(self.frame_rate.num)) / @as(f64, @floatFromInt(self.frame_rate.den));
        const total_frames = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.duration_us)) / 1_000_000.0 * fps));

        if (self.current_frame >= total_frames) return null;

        // Create video frame with RGBA format
        var video_frame = try frame.VideoFrame.init(self.allocator, self.width, self.height, .rgba32);
        errdefer video_frame.deinit();

        // Call render callback to fill the frame data
        try self.render_callback(self.current_frame, video_frame.data, self.user_data);

        // Set frame metadata
        const timestamp_us = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.current_frame)) / fps * 1_000_000.0));
        video_frame.pts = types.Timestamp.fromMicroseconds(timestamp_us);

        const frame_duration_us = @as(u64, @intFromFloat(1_000_000.0 / fps));
        video_frame.duration = types.Duration.fromMicroseconds(frame_duration_us);

        video_frame.is_key_frame = true;
        video_frame.decode_order = self.current_frame;
        video_frame.display_order = self.current_frame;

        self.current_frame += 1;

        return video_frame;
    }

    fn resetImpl(ptr: *anyopaque) !void {
        const self: *CanvasSource = @ptrCast(@alignCast(ptr));
        self.current_frame = 0;
    }

    fn getDurationImpl(ptr: *anyopaque) u64 {
        const self: *CanvasSource = @ptrCast(@alignCast(ptr));
        return self.duration_us;
    }

    fn getFrameRateImpl(ptr: *anyopaque) types.Rational {
        const self: *CanvasSource = @ptrCast(@alignCast(ptr));
        return self.frame_rate;
    }

    fn getResolutionImpl(ptr: *anyopaque) struct { width: u32, height: u32 } {
        const self: *CanvasSource = @ptrCast(@alignCast(ptr));
        return .{ .width = self.width, .height = self.height };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *CanvasSource = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Tone generator audio source
pub const ToneGeneratorSource = struct {
    allocator: std.mem.Allocator,
    frequency_hz: f32,
    sample_rate: u32,
    channels: u8,
    duration_us: u64,
    samples_generated: u64,
    amplitude: f32,

    pub fn init(allocator: std.mem.Allocator, frequency_hz: f32, sample_rate: u32, channels: u8, duration_us: u64) ToneGeneratorSource {
        return .{
            .allocator = allocator,
            .frequency_hz = frequency_hz,
            .sample_rate = sample_rate,
            .channels = channels,
            .duration_us = duration_us,
            .samples_generated = 0,
            .amplitude = 0.5, // -6dB
        };
    }

    pub fn deinit(self: *ToneGeneratorSource) void {
        _ = self;
    }

    pub fn asAudioSource(self: *ToneGeneratorSource) AudioSource {
        return AudioSource{
            .ptr = self,
            .vtable = &.{
                .getNextSamples = getNextSamplesImpl,
                .reset = resetImpl,
                .getSampleRate = getSampleRateImpl,
                .getChannelCount = getChannelCountImpl,
                .getDuration = getDurationImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextSamplesImpl(ptr: *anyopaque, sample_count: usize) !?frame.AudioFrame {
        const self: *ToneGeneratorSource = @ptrCast(@alignCast(ptr));

        const total_samples = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.duration_us)) / 1_000_000.0 * @as(f64, @floatFromInt(self.sample_rate))));

        if (self.samples_generated >= total_samples) return null;

        const samples_to_generate = @min(sample_count, @as(usize, @intCast(total_samples - self.samples_generated)));

        // Create audio frame (f32 planar format)
        var audio_frame = try frame.AudioFrame.init(
            self.allocator,
            @intCast(samples_to_generate),
            .f32p,
            self.channels,
            self.sample_rate,
        );
        errdefer audio_frame.deinit();

        const angular_frequency = 2.0 * std.math.pi * self.frequency_hz / @as(f32, @floatFromInt(self.sample_rate));

        // Generate sine wave for each channel
        for (0..self.channels) |ch| {
            for (0..samples_to_generate) |i| {
                const sample_index = self.samples_generated + i;
                const t = @as(f32, @floatFromInt(sample_index));
                const value = self.amplitude * @sin(angular_frequency * t);

                audio_frame.setSampleF32(@intCast(ch), @intCast(i), value);
            }
        }

        // Set timestamp
        const timestamp_us = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.samples_generated)) /
                                                     @as(f64, @floatFromInt(self.sample_rate)) * 1_000_000.0));
        audio_frame.pts = types.Timestamp.fromMicroseconds(timestamp_us);

        self.samples_generated += samples_to_generate;

        return audio_frame;
    }

    fn resetImpl(ptr: *anyopaque) !void {
        const self: *ToneGeneratorSource = @ptrCast(@alignCast(ptr));
        self.samples_generated = 0;
    }

    fn getSampleRateImpl(ptr: *anyopaque) u32 {
        const self: *ToneGeneratorSource = @ptrCast(@alignCast(ptr));
        return self.sample_rate;
    }

    fn getChannelCountImpl(ptr: *anyopaque) u8 {
        const self: *ToneGeneratorSource = @ptrCast(@alignCast(ptr));
        return self.channels;
    }

    fn getDurationImpl(ptr: *anyopaque) u64 {
        const self: *ToneGeneratorSource = @ptrCast(@alignCast(ptr));
        return self.duration_us;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ToneGeneratorSource = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Silence audio source
pub const SilenceSource = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    duration_us: u64,
    samples_generated: u64,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, duration_us: u64) SilenceSource {
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .duration_us = duration_us,
            .samples_generated = 0,
        };
    }

    pub fn deinit(self: *SilenceSource) void {
        _ = self;
    }

    pub fn asAudioSource(self: *SilenceSource) AudioSource {
        return AudioSource{
            .ptr = self,
            .vtable = &.{
                .getNextSamples = getNextSamplesImpl,
                .reset = resetImpl,
                .getSampleRate = getSampleRateImpl,
                .getChannelCount = getChannelCountImpl,
                .getDuration = getDurationImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextSamplesImpl(ptr: *anyopaque, sample_count: usize) !?frame.AudioFrame {
        const self: *SilenceSource = @ptrCast(@alignCast(ptr));

        const total_samples = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.duration_us)) / 1_000_000.0 * @as(f64, @floatFromInt(self.sample_rate))));

        if (self.samples_generated >= total_samples) return null;

        const samples_to_generate = @min(sample_count, @as(usize, @intCast(total_samples - self.samples_generated)));

        // Create audio frame (f32 planar format)
        var audio_frame = try frame.AudioFrame.init(
            self.allocator,
            @intCast(samples_to_generate),
            .f32p,
            self.channels,
            self.sample_rate,
        );
        errdefer audio_frame.deinit();

        // Frame is already zero-initialized, so silence is automatic
        // Just set timestamp
        const timestamp_us = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.samples_generated)) /
                                                     @as(f64, @floatFromInt(self.sample_rate)) * 1_000_000.0));
        audio_frame.pts = types.Timestamp.fromMicroseconds(timestamp_us);

        self.samples_generated += samples_to_generate;

        return audio_frame;
    }

    fn resetImpl(ptr: *anyopaque) !void {
        const self: *SilenceSource = @ptrCast(@alignCast(ptr));
        self.samples_generated = 0;
    }

    fn getSampleRateImpl(ptr: *anyopaque) u32 {
        const self: *SilenceSource = @ptrCast(@alignCast(ptr));
        return self.sample_rate;
    }

    fn getChannelCountImpl(ptr: *anyopaque) u8 {
        const self: *SilenceSource = @ptrCast(@alignCast(ptr));
        return self.channels;
    }

    fn getDurationImpl(ptr: *anyopaque) u64 {
        const self: *SilenceSource = @ptrCast(@alignCast(ptr));
        return self.duration_us;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *SilenceSource = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Raw video source (from pixel buffers)
pub const RawVideoSource = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixel_format: types.PixelFormat,
    frame_rate: types.Rational,
    frames: [][]const u8,
    current_frame: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        pixel_format: types.PixelFormat,
        frame_rate: types.Rational,
        frames: [][]const u8,
    ) RawVideoSource {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixel_format = pixel_format,
            .frame_rate = frame_rate,
            .frames = frames,
            .current_frame = 0,
        };
    }

    pub fn deinit(self: *RawVideoSource) void {
        _ = self;
    }

    pub fn asVideoSource(self: *RawVideoSource) VideoSource {
        return VideoSource{
            .ptr = self,
            .vtable = &.{
                .getNextFrame = getNextFrameImpl,
                .reset = resetImpl,
                .getDuration = getDurationImpl,
                .getFrameRate = getFrameRateImpl,
                .getResolution = getResolutionImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextFrameImpl(ptr: *anyopaque) !?frame.VideoFrame {
        const self: *RawVideoSource = @ptrCast(@alignCast(ptr));

        if (self.current_frame >= self.frames.len) return null;

        const pixel_data = self.frames[self.current_frame];

        // Create video frame and copy data
        var video_frame = try frame.VideoFrame.init(self.allocator, self.width, self.height, self.pixel_format);
        errdefer video_frame.deinit();

        // Copy pixel data into frame
        const copy_size = @min(pixel_data.len, video_frame.data.len);
        @memcpy(video_frame.data[0..copy_size], pixel_data[0..copy_size]);

        // Set frame metadata
        const fps = @as(f64, @floatFromInt(self.frame_rate.num)) / @as(f64, @floatFromInt(self.frame_rate.den));
        const timestamp_us = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.current_frame)) / fps * 1_000_000.0));
        video_frame.pts = types.Timestamp.fromMicroseconds(timestamp_us);

        const frame_duration_us = @as(u64, @intFromFloat(1_000_000.0 / fps));
        video_frame.duration = types.Duration.fromMicroseconds(frame_duration_us);

        video_frame.is_key_frame = true;
        video_frame.decode_order = @intCast(self.current_frame);
        video_frame.display_order = @intCast(self.current_frame);

        self.current_frame += 1;

        return video_frame;
    }

    fn resetImpl(ptr: *anyopaque) !void {
        const self: *RawVideoSource = @ptrCast(@alignCast(ptr));
        self.current_frame = 0;
    }

    fn getDurationImpl(ptr: *anyopaque) u64 {
        const self: *RawVideoSource = @ptrCast(@alignCast(ptr));
        const fps = @as(f64, @floatFromInt(self.frame_rate.num)) / @as(f64, @floatFromInt(self.frame_rate.den));
        return @intFromFloat(@as(f64, @floatFromInt(self.frames.len)) / fps * 1_000_000.0);
    }

    fn getFrameRateImpl(ptr: *anyopaque) types.Rational {
        const self: *RawVideoSource = @ptrCast(@alignCast(ptr));
        return self.frame_rate;
    }

    fn getResolutionImpl(ptr: *anyopaque) struct { width: u32, height: u32 } {
        const self: *RawVideoSource = @ptrCast(@alignCast(ptr));
        return .{ .width = self.width, .height = self.height };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *RawVideoSource = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Raw audio source (from sample buffers)
pub const RawAudioSource = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    samples: []f32,
    current_sample: usize,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, samples: []f32) RawAudioSource {
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .samples = samples,
            .current_sample = 0,
        };
    }

    pub fn deinit(self: *RawAudioSource) void {
        _ = self;
    }

    pub fn asAudioSource(self: *RawAudioSource) AudioSource {
        return AudioSource{
            .ptr = self,
            .vtable = &.{
                .getNextSamples = getNextSamplesImpl,
                .reset = resetImpl,
                .getSampleRate = getSampleRateImpl,
                .getChannelCount = getChannelCountImpl,
                .getDuration = getDurationImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextSamplesImpl(ptr: *anyopaque, sample_count: usize) !?frame.AudioFrame {
        const self: *RawAudioSource = @ptrCast(@alignCast(ptr));

        const total_frames = self.samples.len / self.channels;
        if (self.current_sample >= total_frames) return null;

        const frames_to_read = @min(sample_count, total_frames - self.current_sample);

        // Create audio frame (f32 interleaved format)
        var audio_frame = try frame.AudioFrame.init(
            self.allocator,
            @intCast(frames_to_read),
            .f32le,
            self.channels,
            self.sample_rate,
        );
        errdefer audio_frame.deinit();

        // Copy sample data from source buffer
        const start_idx = self.current_sample * self.channels;
        const sample_count_total = frames_to_read * self.channels;

        for (0..frames_to_read) |frame_idx| {
            for (0..self.channels) |ch| {
                const src_idx = start_idx + frame_idx * self.channels + ch;
                const sample_value = if (src_idx < self.samples.len) self.samples[src_idx] else 0.0;
                audio_frame.setSampleF32(@intCast(ch), @intCast(frame_idx), sample_value);
            }
        }

        // Set timestamp
        const timestamp_us = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.current_sample)) /
                                                     @as(f64, @floatFromInt(self.sample_rate)) * 1_000_000.0));
        audio_frame.pts = types.Timestamp.fromMicroseconds(timestamp_us);

        self.current_sample += frames_to_read;

        return audio_frame;
    }

    fn resetImpl(ptr: *anyopaque) !void {
        const self: *RawAudioSource = @ptrCast(@alignCast(ptr));
        self.current_sample = 0;
    }

    fn getSampleRateImpl(ptr: *anyopaque) u32 {
        const self: *RawAudioSource = @ptrCast(@alignCast(ptr));
        return self.sample_rate;
    }

    fn getChannelCountImpl(ptr: *anyopaque) u8 {
        const self: *RawAudioSource = @ptrCast(@alignCast(ptr));
        return self.channels;
    }

    fn getDurationImpl(ptr: *anyopaque) u64 {
        const self: *RawAudioSource = @ptrCast(@alignCast(ptr));
        const total_samples = self.samples.len / self.channels;
        return @intFromFloat(@as(f64, @floatFromInt(total_samples)) / @as(f64, @floatFromInt(self.sample_rate)) * 1_000_000.0);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *RawAudioSource = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};
