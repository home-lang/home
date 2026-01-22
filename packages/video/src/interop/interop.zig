// Home Video Library - Interoperability Features
// Integration with packages/image, ML/CV pipelines, audio processing

const std = @import("std");
const frame = @import("../core/frame.zig");
const types = @import("../core/types.zig");

const VideoFrame = frame.VideoFrame;
const AudioFrame = frame.AudioFrame;

// ============================================================================
// Image Integration (packages/image compatible)
// ============================================================================

/// Image format for interop with packages/image
pub const ImageBuffer = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    width: u32,
    height: u32,
    format: ImageFormat,
    stride: u32,
    color_space: ColorSpace = .srgb,

    const Self = @This();

    pub const ImageFormat = enum {
        rgb24, // 3 bytes per pixel, RGB order
        rgba32, // 4 bytes per pixel, RGBA order
        bgr24, // 3 bytes per pixel, BGR order
        bgra32, // 4 bytes per pixel, BGRA order
        gray8, // 1 byte per pixel, grayscale
        gray16, // 2 bytes per pixel, grayscale
        rgb48, // 6 bytes per pixel, RGB 16-bit
        rgba64, // 8 bytes per pixel, RGBA 16-bit
    };

    pub const ColorSpace = enum {
        srgb,
        linear,
        bt709,
        bt2020,
        display_p3,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: ImageFormat) !Self {
        const bytes_per_pixel: u32 = switch (format) {
            .rgb24, .bgr24 => 3,
            .rgba32, .bgra32 => 4,
            .gray8 => 1,
            .gray16 => 2,
            .rgb48 => 6,
            .rgba64 => 8,
        };

        const stride = width * bytes_per_pixel;
        const size = stride * height;

        const data = try allocator.alloc(u8, size);
        @memset(data, 0);

        return .{
            .allocator = allocator,
            .data = data,
            .width = width,
            .height = height,
            .format = format,
            .stride = stride,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Get pixel at coordinates
    pub fn getPixel(self: *const Self, x: u32, y: u32) []const u8 {
        const bpp: u32 = switch (self.format) {
            .rgb24, .bgr24 => 3,
            .rgba32, .bgra32 => 4,
            .gray8 => 1,
            .gray16 => 2,
            .rgb48 => 6,
            .rgba64 => 8,
        };
        const offset = y * self.stride + x * bpp;
        return self.data[offset .. offset + bpp];
    }

    /// Set pixel at coordinates
    pub fn setPixel(self: *Self, x: u32, y: u32, pixel: []const u8) void {
        const bpp: u32 = switch (self.format) {
            .rgb24, .bgr24 => 3,
            .rgba32, .bgra32 => 4,
            .gray8 => 1,
            .gray16 => 2,
            .rgb48 => 6,
            .rgba64 => 8,
        };
        const offset = y * self.stride + x * bpp;
        @memcpy(self.data[offset .. offset + bpp], pixel[0..bpp]);
    }

    /// Get row data
    pub fn getRow(self: *const Self, y: u32) []const u8 {
        const offset = y * self.stride;
        return self.data[offset .. offset + self.stride];
    }
};

/// Convert VideoFrame to ImageBuffer (for packages/image integration)
pub fn videoFrameToImage(allocator: std.mem.Allocator, video_frame: *const VideoFrame) !ImageBuffer {
    // Determine output format based on video pixel format
    const img_format: ImageBuffer.ImageFormat = switch (video_frame.format) {
        .rgb24 => .rgb24,
        .rgba32 => .rgba32,
        .bgr24 => .bgr24,
        .bgra32 => .bgra32,
        .gray8 => .gray8,
        .gray16 => .gray16,
        else => .rgb24, // Default conversion target
    };

    var image = try ImageBuffer.init(allocator, video_frame.width, video_frame.height, img_format);
    errdefer image.deinit();

    // Convert pixel data
    if (video_frame.format == .yuv420p or video_frame.format == .yuv422p or video_frame.format == .yuv444p) {
        // YUV to RGB conversion
        try convertYuvToRgb(video_frame, &image);
    } else if (video_frame.format == .nv12 or video_frame.format == .nv21) {
        // NV12/NV21 to RGB conversion
        try convertNvToRgb(video_frame, &image);
    } else {
        // Direct copy for RGB formats
        const src_data = video_frame.getPlaneData(0) orelse return error.InvalidData;
        @memcpy(image.data, src_data[0..image.data.len]);
    }

    return image;
}

/// Convert ImageBuffer to VideoFrame (for packages/image integration)
pub fn imageToVideoFrame(allocator: std.mem.Allocator, image: *const ImageBuffer, target_format: types.PixelFormat) !VideoFrame {
    var video_frame = try VideoFrame.init(allocator, image.width, image.height, target_format);
    errdefer video_frame.deinit();

    if (target_format == .yuv420p or target_format == .yuv422p or target_format == .yuv444p) {
        // RGB to YUV conversion
        try convertRgbToYuv(image, &video_frame);
    } else {
        // Direct copy for RGB formats
        const dst_data = video_frame.getPlaneDataMut(0) orelse return error.InvalidData;
        @memcpy(dst_data[0..image.data.len], image.data);
    }

    return video_frame;
}

fn convertYuvToRgb(video_frame: *const VideoFrame, image: *ImageBuffer) !void {
    const y_data = video_frame.getPlaneData(0) orelse return error.InvalidData;
    const u_data = video_frame.getPlaneData(1) orelse return error.InvalidData;
    const v_data = video_frame.getPlaneData(2) orelse return error.InvalidData;

    const y_stride = video_frame.linesize[0];
    const u_stride = video_frame.linesize[1];
    const v_stride = video_frame.linesize[2];

    // Chroma subsampling factor
    const chroma_shift: u32 = switch (video_frame.format) {
        .yuv420p => 1,
        .yuv422p => 1,
        .yuv444p => 0,
        else => 1,
    };

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const y_val = @as(i32, y_data[y * y_stride + x]);
            const u_val = @as(i32, u_data[(y >> chroma_shift) * u_stride + (x >> chroma_shift)]) - 128;
            const v_val = @as(i32, v_data[(y >> chroma_shift) * v_stride + (x >> chroma_shift)]) - 128;

            // BT.709 YUV to RGB conversion
            const r = std.math.clamp(y_val + ((v_val * 1436) >> 10), 0, 255);
            const g = std.math.clamp(y_val - ((u_val * 352 + v_val * 731) >> 10), 0, 255);
            const b = std.math.clamp(y_val + ((u_val * 1815) >> 10), 0, 255);

            image.setPixel(x, y, &[_]u8{
                @intCast(r),
                @intCast(g),
                @intCast(b),
            });
        }
    }
}

fn convertNvToRgb(video_frame: *const VideoFrame, image: *ImageBuffer) !void {
    const y_data = video_frame.getPlaneData(0) orelse return error.InvalidData;
    const uv_data = video_frame.getPlaneData(1) orelse return error.InvalidData;

    const y_stride = video_frame.linesize[0];
    const uv_stride = video_frame.linesize[1];

    const is_nv21 = video_frame.format == .nv21;

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const y_val = @as(i32, y_data[y * y_stride + x]);
            const uv_offset = (y >> 1) * uv_stride + (x & ~@as(u32, 1));

            const u_val: i32 = if (is_nv21)
                @as(i32, uv_data[uv_offset + 1]) - 128
            else
                @as(i32, uv_data[uv_offset]) - 128;

            const v_val: i32 = if (is_nv21)
                @as(i32, uv_data[uv_offset]) - 128
            else
                @as(i32, uv_data[uv_offset + 1]) - 128;

            const r = std.math.clamp(y_val + ((v_val * 1436) >> 10), 0, 255);
            const g = std.math.clamp(y_val - ((u_val * 352 + v_val * 731) >> 10), 0, 255);
            const b = std.math.clamp(y_val + ((u_val * 1815) >> 10), 0, 255);

            image.setPixel(x, y, &[_]u8{
                @intCast(r),
                @intCast(g),
                @intCast(b),
            });
        }
    }
}

fn convertRgbToYuv(image: *const ImageBuffer, video_frame: *VideoFrame) !void {
    const y_data = video_frame.getPlaneDataMut(0) orelse return error.InvalidData;
    const u_data = video_frame.getPlaneDataMut(1) orelse return error.InvalidData;
    const v_data = video_frame.getPlaneDataMut(2) orelse return error.InvalidData;

    const y_stride = video_frame.linesize[0];
    const u_stride = video_frame.linesize[1];
    const v_stride = video_frame.linesize[2];

    const chroma_shift: u32 = switch (video_frame.format) {
        .yuv420p => 1,
        .yuv422p => 1,
        .yuv444p => 0,
        else => 1,
    };

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const pixel = image.getPixel(x, y);
            const r = @as(i32, pixel[0]);
            const g = @as(i32, pixel[1]);
            const b = @as(i32, pixel[2]);

            // BT.709 RGB to YUV
            const y_val = ((r * 66 + g * 129 + b * 25 + 128) >> 8) + 16;
            y_data[y * y_stride + x] = @intCast(std.math.clamp(y_val, 16, 235));

            // Subsample chroma
            if ((x & ((@as(u32, 1) << chroma_shift) - 1)) == 0 and (y & ((@as(u32, 1) << chroma_shift) - 1)) == 0) {
                const u_val = ((-r * 38 - g * 74 + b * 112 + 128) >> 8) + 128;
                const v_val = ((r * 112 - g * 94 - b * 18 + 128) >> 8) + 128;

                u_data[(y >> chroma_shift) * u_stride + (x >> chroma_shift)] = @intCast(std.math.clamp(u_val, 16, 240));
                v_data[(y >> chroma_shift) * v_stride + (x >> chroma_shift)] = @intCast(std.math.clamp(v_val, 16, 240));
            }
        }
    }
}

// ============================================================================
// Raw Frame Export (for ML/CV pipelines)
// ============================================================================

/// Raw frame data format for ML/CV interop
pub const RawFrameData = struct {
    allocator: std.mem.Allocator,
    data: []f32, // Normalized [0.0, 1.0] float data
    width: u32,
    height: u32,
    channels: u8,
    layout: DataLayout,

    const Self = @This();

    pub const DataLayout = enum {
        hwc, // Height x Width x Channels (default)
        chw, // Channels x Height x Width (PyTorch)
        nhwc, // Batch x Height x Width x Channels (TensorFlow)
        nchw, // Batch x Channels x Height x Width
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, channels: u8, layout: DataLayout) !Self {
        const size = @as(usize, width) * height * channels;
        const data = try allocator.alloc(f32, size);
        @memset(data, 0);

        return .{
            .allocator = allocator,
            .data = data,
            .width = width,
            .height = height,
            .channels = channels,
            .layout = layout,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Get tensor shape for ML frameworks
    pub fn getShape(self: *const Self) [4]u32 {
        return switch (self.layout) {
            .hwc => .{ self.height, self.width, self.channels, 1 },
            .chw => .{ self.channels, self.height, self.width, 1 },
            .nhwc => .{ 1, self.height, self.width, self.channels },
            .nchw => .{ 1, self.channels, self.height, self.width },
        };
    }

    /// Get value at position
    pub fn get(self: *const Self, y: u32, x: u32, c: u8) f32 {
        const idx = self.getIndex(y, x, c);
        return self.data[idx];
    }

    /// Set value at position
    pub fn set(self: *Self, y: u32, x: u32, c: u8, value: f32) void {
        const idx = self.getIndex(y, x, c);
        self.data[idx] = value;
    }

    fn getIndex(self: *const Self, y: u32, x: u32, c: u8) usize {
        return switch (self.layout) {
            .hwc => @as(usize, y) * self.width * self.channels + x * self.channels + c,
            .chw => @as(usize, c) * self.height * self.width + y * self.width + x,
            .nhwc => @as(usize, y) * self.width * self.channels + x * self.channels + c,
            .nchw => @as(usize, c) * self.height * self.width + y * self.width + x,
        };
    }
};

/// Export VideoFrame to ML-friendly format
pub fn videoFrameToRawData(
    allocator: std.mem.Allocator,
    video_frame: *const VideoFrame,
    layout: RawFrameData.DataLayout,
    normalize: bool,
) !RawFrameData {
    // First convert to RGB image
    var image = try videoFrameToImage(allocator, video_frame);
    defer image.deinit();

    const channels: u8 = switch (image.format) {
        .gray8, .gray16 => 1,
        .rgb24, .bgr24, .rgb48 => 3,
        .rgba32, .bgra32, .rgba64 => 4,
    };

    var raw = try RawFrameData.init(allocator, image.width, image.height, channels, layout);
    errdefer raw.deinit();

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const pixel = image.getPixel(x, y);

            var c: u8 = 0;
            while (c < channels) : (c += 1) {
                var value: f32 = @as(f32, @floatFromInt(pixel[c]));
                if (normalize) {
                    value /= 255.0;
                }
                raw.set(y, x, c, value);
            }
        }
    }

    return raw;
}

/// Import raw data to VideoFrame
pub fn rawDataToVideoFrame(
    allocator: std.mem.Allocator,
    raw: *const RawFrameData,
    target_format: types.PixelFormat,
    denormalize: bool,
) !VideoFrame {
    // Create intermediate RGB image
    const img_format: ImageBuffer.ImageFormat = if (raw.channels == 1)
        .gray8
    else if (raw.channels == 3)
        .rgb24
    else
        .rgba32;

    var image = try ImageBuffer.init(allocator, raw.width, raw.height, img_format);
    defer image.deinit();

    var y: u32 = 0;
    while (y < raw.height) : (y += 1) {
        var x: u32 = 0;
        while (x < raw.width) : (x += 1) {
            var pixel: [4]u8 = undefined;

            var c: u8 = 0;
            while (c < raw.channels) : (c += 1) {
                var value = raw.get(y, x, c);
                if (denormalize) {
                    value *= 255.0;
                }
                pixel[c] = @intFromFloat(std.math.clamp(value, 0, 255));
            }

            image.setPixel(x, y, pixel[0..raw.channels]);
        }
    }

    return imageToVideoFrame(allocator, &image, target_format);
}

// ============================================================================
// Audio Buffer Export (for audio processing libraries)
// ============================================================================

/// Raw audio buffer for external processing
pub const AudioBuffer = struct {
    allocator: std.mem.Allocator,
    samples: []f32, // Always normalized [-1.0, 1.0]
    channels: u8,
    sample_rate: u32,
    num_samples: u64, // Per channel
    layout: ChannelLayout,

    const Self = @This();

    pub const ChannelLayout = enum {
        interleaved, // L R L R L R...
        planar, // LLL... RRR...
    };

    pub fn init(allocator: std.mem.Allocator, num_samples: u64, channels: u8, sample_rate: u32, layout: ChannelLayout) !Self {
        const total_samples = num_samples * channels;
        const samples = try allocator.alloc(f32, @intCast(total_samples));
        @memset(samples, 0);

        return .{
            .allocator = allocator,
            .samples = samples,
            .channels = channels,
            .sample_rate = sample_rate,
            .num_samples = num_samples,
            .layout = layout,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.samples);
    }

    /// Get sample at position
    pub fn getSample(self: *const Self, channel: u8, index: u64) f32 {
        const idx = self.getIndex(channel, index);
        return self.samples[idx];
    }

    /// Set sample at position
    pub fn setSample(self: *Self, channel: u8, index: u64, value: f32) void {
        const idx = self.getIndex(channel, index);
        self.samples[idx] = value;
    }

    fn getIndex(self: *const Self, channel: u8, index: u64) usize {
        return switch (self.layout) {
            .interleaved => @intCast(index * self.channels + channel),
            .planar => @intCast(@as(u64, channel) * self.num_samples + index),
        };
    }

    /// Get duration in seconds
    pub fn getDurationSeconds(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.num_samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Get channel data slice (planar layout only)
    pub fn getChannelSlice(self: *Self, channel: u8) ?[]f32 {
        if (self.layout != .planar) return null;
        const start = @as(usize, channel) * @as(usize, @intCast(self.num_samples));
        const end = start + @as(usize, @intCast(self.num_samples));
        return self.samples[start..end];
    }
};

/// Export AudioFrame to AudioBuffer
pub fn audioFrameToBuffer(
    allocator: std.mem.Allocator,
    audio_frame: *const AudioFrame,
    layout: AudioBuffer.ChannelLayout,
) !AudioBuffer {
    var buffer = try AudioBuffer.init(
        allocator,
        audio_frame.num_samples,
        audio_frame.channels,
        audio_frame.sample_rate,
        layout,
    );
    errdefer buffer.deinit();

    var i: u64 = 0;
    while (i < audio_frame.num_samples) : (i += 1) {
        var ch: u8 = 0;
        while (ch < audio_frame.channels) : (ch += 1) {
            const sample = audio_frame.getSampleF32(ch, @intCast(i)) orelse 0.0;
            buffer.setSample(ch, i, sample);
        }
    }

    return buffer;
}

/// Import AudioBuffer to AudioFrame
pub fn bufferToAudioFrame(
    allocator: std.mem.Allocator,
    buffer: *const AudioBuffer,
    target_format: types.SampleFormat,
) !AudioFrame {
    var audio_frame = try AudioFrame.init(
        allocator,
        buffer.channels,
        @intCast(buffer.num_samples),
        buffer.sample_rate,
        target_format,
    );
    errdefer audio_frame.deinit();

    var i: u64 = 0;
    while (i < buffer.num_samples) : (i += 1) {
        var ch: u8 = 0;
        while (ch < buffer.channels) : (ch += 1) {
            const sample = buffer.getSample(ch, i);
            audio_frame.setSampleF32(ch, @intCast(i), sample);
        }
    }

    return audio_frame;
}

// ============================================================================
// Tests
// ============================================================================

test "ImageBuffer basic operations" {
    const allocator = std.testing.allocator;
    var image = try ImageBuffer.init(allocator, 100, 100, .rgb24);
    defer image.deinit();

    image.setPixel(50, 50, &[_]u8{ 255, 128, 64 });
    const pixel = image.getPixel(50, 50);

    try std.testing.expectEqual(@as(u8, 255), pixel[0]);
    try std.testing.expectEqual(@as(u8, 128), pixel[1]);
    try std.testing.expectEqual(@as(u8, 64), pixel[2]);
}

test "RawFrameData layouts" {
    const allocator = std.testing.allocator;

    // Test HWC layout
    var hwc = try RawFrameData.init(allocator, 10, 10, 3, .hwc);
    defer hwc.deinit();

    hwc.set(5, 5, 0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hwc.get(5, 5, 0), 0.0001);

    // Test CHW layout
    var chw = try RawFrameData.init(allocator, 10, 10, 3, .chw);
    defer chw.deinit();

    chw.set(5, 5, 2, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), chw.get(5, 5, 2), 0.0001);
}

test "AudioBuffer basic operations" {
    const allocator = std.testing.allocator;
    var buffer = try AudioBuffer.init(allocator, 1000, 2, 44100, .interleaved);
    defer buffer.deinit();

    buffer.setSample(0, 500, 0.5);
    buffer.setSample(1, 500, -0.5);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buffer.getSample(0, 500), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), buffer.getSample(1, 500), 0.0001);

    const duration = buffer.getDurationSeconds();
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0 / 44100.0), duration, 0.0001);
}
