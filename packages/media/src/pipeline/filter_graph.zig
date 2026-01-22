// Home Media Library - Filter Graph
// Filter chain management for video and audio processing

const std = @import("std");
const types = @import("../core/types.zig");
const err = @import("../core/error.zig");
const stream = @import("../core/stream.zig");
const pipeline = @import("pipeline.zig");

const MediaError = err.MediaError;
const Frame = stream.Frame;
const FrameFormat = stream.FrameFormat;
const FilterConfig = pipeline.FilterConfig;

// ============================================================================
// Filter Interface
// ============================================================================

pub const Filter = struct {
    name: []const u8,
    filter_type: FilterType,
    config: FilterConfig,
    input_format: ?FrameFormat = null,
    output_format: ?FrameFormat = null,

    // Processing function pointers
    processFn: ?*const fn (*Filter, *Frame, std.mem.Allocator) MediaError!*Frame = null,
    flushFn: ?*const fn (*Filter, std.mem.Allocator) MediaError!?*Frame = null,

    pub fn process(self: *Filter, input: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
        if (self.processFn) |func| {
            return func(self, input, allocator);
        }
        return input; // Pass through if no processing function
    }

    pub fn flush(self: *Filter, allocator: std.mem.Allocator) MediaError!?*Frame {
        if (self.flushFn) |func| {
            return func(self, allocator);
        }
        return null;
    }
};

pub const FilterType = enum {
    video,
    audio,
    video_audio, // Affects both
};

// ============================================================================
// Filter Graph
// ============================================================================

pub const FilterGraph = struct {
    allocator: std.mem.Allocator,
    video_filters: std.ArrayList(Filter),
    audio_filters: std.ArrayList(Filter),
    is_configured: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .video_filters = std.ArrayList(Filter).init(allocator),
            .audio_filters = std.ArrayList(Filter).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.video_filters.deinit();
        self.audio_filters.deinit();
    }

    /// Add a video filter to the chain
    pub fn addVideoFilter(self: *Self, config: FilterConfig) !void {
        const filter = Filter{
            .name = filterName(config),
            .filter_type = .video,
            .config = config,
            .processFn = getVideoProcessor(config),
        };
        try self.video_filters.append(filter);
    }

    /// Add an audio filter to the chain
    pub fn addAudioFilter(self: *Self, config: FilterConfig) !void {
        const filter = Filter{
            .name = filterName(config),
            .filter_type = .audio,
            .config = config,
            .processFn = getAudioProcessor(config),
        };
        try self.audio_filters.append(filter);
    }

    /// Configure the filter graph based on input format
    pub fn configure(self: *Self, video_format: ?FrameFormat, audio_format: ?FrameFormat) !void {
        // Set input/output formats for each filter
        var prev_video_format = video_format;
        for (self.video_filters.items) |*filter| {
            filter.input_format = prev_video_format;
            filter.output_format = getOutputFormat(filter.config, prev_video_format);
            prev_video_format = filter.output_format;
        }

        var prev_audio_format = audio_format;
        for (self.audio_filters.items) |*filter| {
            filter.input_format = prev_audio_format;
            filter.output_format = getOutputFormat(filter.config, prev_audio_format);
            prev_audio_format = filter.output_format;
        }

        self.is_configured = true;
    }

    /// Process a video frame through all video filters
    pub fn processVideoFrame(self: *Self, frame: *Frame) !*Frame {
        if (!self.is_configured) return MediaError.PipelineNotReady;

        var current = frame;
        for (self.video_filters.items) |*filter| {
            current = try filter.process(current, self.allocator);
        }
        return current;
    }

    /// Process an audio frame through all audio filters
    pub fn processAudioFrame(self: *Self, frame: *Frame) !*Frame {
        if (!self.is_configured) return MediaError.PipelineNotReady;

        var current = frame;
        for (self.audio_filters.items) |*filter| {
            current = try filter.process(current, self.allocator);
        }
        return current;
    }

    /// Flush all filters (for end of stream)
    pub fn flush(self: *Self) !void {
        for (self.video_filters.items) |*filter| {
            _ = try filter.flush(self.allocator);
        }
        for (self.audio_filters.items) |*filter| {
            _ = try filter.flush(self.allocator);
        }
    }

    /// Get the final output video format
    pub fn getOutputVideoFormat(self: *const Self) ?FrameFormat {
        if (self.video_filters.items.len == 0) return null;
        return self.video_filters.items[self.video_filters.items.len - 1].output_format;
    }

    /// Get the final output audio format
    pub fn getOutputAudioFormat(self: *const Self) ?FrameFormat {
        if (self.audio_filters.items.len == 0) return null;
        return self.audio_filters.items[self.audio_filters.items.len - 1].output_format;
    }
};

// ============================================================================
// Filter Name Mapping
// ============================================================================

fn filterName(config: FilterConfig) []const u8 {
    return switch (config) {
        .scale => "scale",
        .crop => "crop",
        .rotate => "rotate",
        .flip_h => "hflip",
        .flip_v => "vflip",
        .transpose => "transpose",
        .blur => "blur",
        .sharpen => "sharpen",
        .grayscale => "grayscale",
        .brightness => "brightness",
        .contrast => "contrast",
        .saturation => "saturation",
        .hue => "hue",
        .gamma => "gamma",
        .denoise => "denoise",
        .deinterlace => "deinterlace",
        .overlay => "overlay",
        .text => "drawtext",
        .fade => "fade",
        .volume => "volume",
        .normalize => "normalize",
        .loudnorm => "loudnorm",
        .equalizer => "equalizer",
        .compressor => "compressor",
        .reverb => "reverb",
        .pitch => "pitch",
        .tempo => "tempo",
        .fade_in => "afade",
        .fade_out => "afade",
    };
}

// ============================================================================
// Filter Output Format Determination
// ============================================================================

fn getOutputFormat(config: FilterConfig, input_format: ?FrameFormat) ?FrameFormat {
    // Most filters preserve format, some change it
    _ = config;
    return input_format; // Default: preserve input format
}

// ============================================================================
// Video Filter Processors
// ============================================================================

fn getVideoProcessor(config: FilterConfig) ?*const fn (*Filter, *Frame, std.mem.Allocator) MediaError!*Frame {
    return switch (config) {
        .scale => processScale,
        .crop => processCrop,
        .rotate => processRotate,
        .flip_h => processFlipH,
        .flip_v => processFlipV,
        .blur => processBlur,
        .sharpen => processSharpen,
        .grayscale => processGrayscale,
        .brightness => processBrightness,
        .contrast => processContrast,
        .saturation => processSaturation,
        else => null,
    };
}

fn processScale(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    const config = filter.config.scale;
    const new_width = config.width orelse frame.width;
    const new_height = config.height orelse frame.height;

    // Create output frame with new dimensions
    var output = try Frame.initVideo(allocator, new_width, new_height, frame.format);
    output.pts = frame.pts;
    output.duration = frame.duration;

    // Perform scaling (simplified - real implementation would use proper algorithms)
    // For bilinear scaling:
    const x_ratio = @as(f32, @floatFromInt(frame.width)) / @as(f32, @floatFromInt(new_width));
    const y_ratio = @as(f32, @floatFromInt(frame.height)) / @as(f32, @floatFromInt(new_height));

    for (0..new_height) |y| {
        for (0..new_width) |x| {
            const src_x: u32 = @intFromFloat(@as(f32, @floatFromInt(x)) * x_ratio);
            const src_y: u32 = @intFromFloat(@as(f32, @floatFromInt(y)) * y_ratio);

            // Copy pixel (simplified - assumes RGBA format)
            const src_idx = (src_y * frame.linesize[0] + src_x * 4);
            const dst_idx = (@as(u32, @intCast(y)) * output.linesize[0] + @as(u32, @intCast(x)) * 4);

            if (src_idx + 4 <= frame.data[0].len and dst_idx + 4 <= output.data[0].len) {
                @memcpy(output.data[0][dst_idx..][0..4], frame.data[0][src_idx..][0..4]);
            }
        }
    }

    return &output;
}

fn processCrop(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    const config = filter.config.crop;

    // Validate crop region
    if (config.x + config.width > frame.width or config.y + config.height > frame.height) {
        return MediaError.InvalidArgument;
    }

    var output = try Frame.initVideo(allocator, config.width, config.height, frame.format);
    output.pts = frame.pts;
    output.duration = frame.duration;

    // Copy cropped region
    for (0..config.height) |y| {
        const src_offset = ((config.y + @as(u32, @intCast(y))) * frame.linesize[0]) + (config.x * 4);
        const dst_offset = @as(u32, @intCast(y)) * output.linesize[0];
        const row_bytes = config.width * 4;

        if (src_offset + row_bytes <= frame.data[0].len and dst_offset + row_bytes <= output.data[0].len) {
            @memcpy(output.data[0][dst_offset..][0..row_bytes], frame.data[0][src_offset..][0..row_bytes]);
        }
    }

    return &output;
}

fn processRotate(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = filter;
    _ = allocator;
    // Rotation implementation
    return frame; // Placeholder
}

fn processFlipH(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = filter;
    _ = allocator;

    // Flip horizontally in place
    for (0..frame.height) |y| {
        var left: u32 = 0;
        var right: u32 = frame.width - 1;

        while (left < right) {
            const left_idx = (@as(u32, @intCast(y)) * frame.linesize[0]) + (left * 4);
            const right_idx = (@as(u32, @intCast(y)) * frame.linesize[0]) + (right * 4);

            // Swap pixels
            var temp: [4]u8 = undefined;
            @memcpy(&temp, frame.data[0][left_idx..][0..4]);
            @memcpy(frame.data[0][left_idx..][0..4], frame.data[0][right_idx..][0..4]);
            @memcpy(frame.data[0][right_idx..][0..4], &temp);

            left += 1;
            right -= 1;
        }
    }

    return frame;
}

fn processFlipV(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = filter;
    _ = allocator;

    // Flip vertically by swapping rows
    var top: u32 = 0;
    var bottom: u32 = frame.height - 1;
    const row_bytes = frame.linesize[0];

    const temp_row = allocator.alloc(u8, row_bytes) catch return MediaError.OutOfMemory;
    defer allocator.free(temp_row);

    while (top < bottom) {
        const top_offset = top * row_bytes;
        const bottom_offset = bottom * row_bytes;

        // Swap rows
        @memcpy(temp_row, frame.data[0][top_offset..][0..row_bytes]);
        @memcpy(frame.data[0][top_offset..][0..row_bytes], frame.data[0][bottom_offset..][0..row_bytes]);
        @memcpy(frame.data[0][bottom_offset..][0..row_bytes], temp_row);

        top += 1;
        bottom -= 1;
    }

    return frame;
}

fn processBlur(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = filter;
    _ = allocator;
    // Gaussian blur implementation using convolution
    return frame; // Placeholder
}

fn processSharpen(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = filter;
    _ = allocator;
    // Sharpening using unsharp mask
    return frame; // Placeholder
}

fn processGrayscale(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = filter;
    _ = allocator;

    // Convert to grayscale (RGBA format assumed)
    for (0..frame.height) |y| {
        for (0..frame.width) |x| {
            const idx = (@as(u32, @intCast(y)) * frame.linesize[0]) + (@as(u32, @intCast(x)) * 4);

            const r = frame.data[0][idx];
            const g = frame.data[0][idx + 1];
            const b = frame.data[0][idx + 2];

            // ITU-R BT.601 luma coefficients
            const gray: u8 = @intFromFloat(0.299 * @as(f32, @floatFromInt(r)) +
                0.587 * @as(f32, @floatFromInt(g)) +
                0.114 * @as(f32, @floatFromInt(b)));

            frame.data[0][idx] = gray;
            frame.data[0][idx + 1] = gray;
            frame.data[0][idx + 2] = gray;
            // Alpha channel unchanged
        }
    }

    return frame;
}

fn processBrightness(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = allocator;
    const factor = filter.config.brightness;
    const adjustment: i16 = @intFromFloat(factor * 255.0);

    for (0..frame.height) |y| {
        for (0..frame.width) |x| {
            const idx = (@as(u32, @intCast(y)) * frame.linesize[0]) + (@as(u32, @intCast(x)) * 4);

            for (0..3) |c| {
                const val: i16 = @as(i16, frame.data[0][idx + c]) + adjustment;
                frame.data[0][idx + c] = @intCast(std.math.clamp(val, 0, 255));
            }
        }
    }

    return frame;
}

fn processContrast(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = allocator;
    const factor = filter.config.contrast;

    for (0..frame.height) |y| {
        for (0..frame.width) |x| {
            const idx = (@as(u32, @intCast(y)) * frame.linesize[0]) + (@as(u32, @intCast(x)) * 4);

            for (0..3) |c| {
                const val = @as(f32, @floatFromInt(frame.data[0][idx + c]));
                const adjusted = (val - 128.0) * factor + 128.0;
                frame.data[0][idx + c] = @intFromFloat(std.math.clamp(adjusted, 0.0, 255.0));
            }
        }
    }

    return frame;
}

fn processSaturation(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = allocator;
    const factor = filter.config.saturation;

    for (0..frame.height) |y| {
        for (0..frame.width) |x| {
            const idx = (@as(u32, @intCast(y)) * frame.linesize[0]) + (@as(u32, @intCast(x)) * 4);

            const r = @as(f32, @floatFromInt(frame.data[0][idx]));
            const g = @as(f32, @floatFromInt(frame.data[0][idx + 1]));
            const b = @as(f32, @floatFromInt(frame.data[0][idx + 2]));

            // Calculate luminance
            const lum = 0.299 * r + 0.587 * g + 0.114 * b;

            // Adjust saturation
            const new_r = lum + (r - lum) * factor;
            const new_g = lum + (g - lum) * factor;
            const new_b = lum + (b - lum) * factor;

            frame.data[0][idx] = @intFromFloat(std.math.clamp(new_r, 0.0, 255.0));
            frame.data[0][idx + 1] = @intFromFloat(std.math.clamp(new_g, 0.0, 255.0));
            frame.data[0][idx + 2] = @intFromFloat(std.math.clamp(new_b, 0.0, 255.0));
        }
    }

    return frame;
}

// ============================================================================
// Audio Filter Processors
// ============================================================================

fn getAudioProcessor(config: FilterConfig) ?*const fn (*Filter, *Frame, std.mem.Allocator) MediaError!*Frame {
    return switch (config) {
        .volume => processVolume,
        else => null,
    };
}

fn processVolume(filter: *Filter, frame: *Frame, allocator: std.mem.Allocator) MediaError!*Frame {
    _ = allocator;
    const factor = filter.config.volume;

    // Process samples (assumes float format)
    if (frame.format == .flt or frame.format == .fltp) {
        const samples: [*]f32 = @ptrCast(@alignCast(frame.data[0].ptr));
        const num_samples = frame.num_samples * frame.channels;

        for (0..num_samples) |i| {
            samples[i] *= factor;
            // Clamp to prevent clipping
            samples[i] = std.math.clamp(samples[i], -1.0, 1.0);
        }
    }

    return frame;
}

// ============================================================================
// Tests
// ============================================================================

test "FilterGraph initialization" {
    const allocator = std.testing.allocator;
    var graph = FilterGraph.init(allocator);
    defer graph.deinit();

    try std.testing.expect(!graph.is_configured);
}

test "FilterGraph add filters" {
    const allocator = std.testing.allocator;
    var graph = FilterGraph.init(allocator);
    defer graph.deinit();

    try graph.addVideoFilter(.{ .scale = .{ .width = 1920, .height = 1080 } });
    try graph.addVideoFilter(.{ .grayscale = {} });

    try std.testing.expectEqual(@as(usize, 2), graph.video_filters.items.len);
}
