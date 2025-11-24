// Home Video Library - Frame Types
// VideoFrame and AudioFrame structures for raw decoded media

const std = @import("std");
const types = @import("types.zig");

pub const PixelFormat = types.PixelFormat;
pub const SampleFormat = types.SampleFormat;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const ChannelLayout = types.ChannelLayout;
pub const ColorSpace = types.ColorSpace;
pub const ColorRange = types.ColorRange;
pub const ColorPrimaries = types.ColorPrimaries;
pub const ColorTransfer = types.ColorTransfer;

// ============================================================================
// VideoFrame
// ============================================================================

pub const VideoFrame = struct {
    /// Frame dimensions
    width: u32,
    height: u32,

    /// Pixel format
    format: PixelFormat,

    /// Pixel data
    /// For planar formats: Y plane, then U plane, then V plane (or UV for NV12)
    /// For packed formats: single data buffer
    data: []u8,

    /// Stride (bytes per row) for each plane
    /// For packed formats, only stride[0] is used
    strides: [4]u32,

    /// Number of planes
    num_planes: u8,

    /// Presentation timestamp
    pts: Timestamp,

    /// Duration of this frame
    duration: Duration,

    /// Color properties
    color_space: ColorSpace,
    color_range: ColorRange,
    color_primaries: ColorPrimaries,
    color_transfer: ColorTransfer,

    /// Rotation in degrees (0, 90, 180, 270)
    rotation: u16,

    /// Is this a keyframe?
    is_key_frame: bool,

    /// Frame number in decode order
    decode_order: u64,

    /// Frame number in display order
    display_order: u64,

    /// Memory allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new video frame with allocated memory
    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        format: PixelFormat,
    ) !Self {
        const allocation = try calculateAllocation(width, height, format);
        const data = try allocator.alloc(u8, allocation.total_size);
        @memset(data, 0);

        return Self{
            .width = width,
            .height = height,
            .format = format,
            .data = data,
            .strides = allocation.strides,
            .num_planes = allocation.num_planes,
            .pts = Timestamp.ZERO,
            .duration = Duration.ZERO,
            .color_space = .unknown,
            .color_range = .unknown,
            .color_primaries = .unknown,
            .color_transfer = .unknown,
            .rotation = 0,
            .is_key_frame = false,
            .decode_order = 0,
            .display_order = 0,
            .allocator = allocator,
        };
    }

    /// Create from existing data (takes ownership)
    pub fn fromData(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        format: PixelFormat,
        data: []u8,
        strides: [4]u32,
    ) Self {
        const num_planes: u8 = if (format.isPlanar()) switch (format) {
            .nv12, .nv21 => 2,
            else => 3,
        } else 1;

        return Self{
            .width = width,
            .height = height,
            .format = format,
            .data = data,
            .strides = strides,
            .num_planes = num_planes,
            .pts = Timestamp.ZERO,
            .duration = Duration.ZERO,
            .color_space = .unknown,
            .color_range = .unknown,
            .color_primaries = .unknown,
            .color_transfer = .unknown,
            .rotation = 0,
            .is_key_frame = false,
            .decode_order = 0,
            .display_order = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Clone this frame
    pub fn clone(self: *const Self) !Self {
        const new_data = try self.allocator.alloc(u8, self.data.len);
        @memcpy(new_data, self.data);

        var new_frame = self.*;
        new_frame.data = new_data;
        return new_frame;
    }

    /// Get a pointer to the start of a plane
    pub fn getPlane(self: *const Self, plane: u8) ?[]u8 {
        if (plane >= self.num_planes) return null;

        var offset: usize = 0;
        for (0..plane) |p| {
            offset += self.getPlaneSize(@intCast(p));
        }

        const size = self.getPlaneSize(plane);
        return self.data[offset .. offset + size];
    }

    /// Get the size of a plane in bytes
    pub fn getPlaneSize(self: *const Self, plane: u8) usize {
        if (plane >= self.num_planes) return 0;

        const height = self.getPlaneHeight(plane);
        return @as(usize, self.strides[plane]) * @as(usize, height);
    }

    /// Get the height of a plane (accounts for chroma subsampling)
    pub fn getPlaneHeight(self: *const Self, plane: u8) u32 {
        if (plane == 0) return self.height;

        // Chroma planes for 4:2:0 are half height
        return switch (self.format) {
            .yuv420p, .yuv420p10le, .yuv420p10be, .nv12, .nv21 => (self.height + 1) / 2,
            else => self.height,
        };
    }

    /// Get the width of a plane (accounts for chroma subsampling)
    pub fn getPlaneWidth(self: *const Self, plane: u8) u32 {
        if (plane == 0) return self.width;

        // Chroma planes for 4:2:0 and 4:2:2 are half width
        return switch (self.format) {
            .yuv420p, .yuv420p10le, .yuv420p10be, .yuv422p, .yuv422p10le, .nv12, .nv21 => (self.width + 1) / 2,
            else => self.width,
        };
    }

    /// Get pixel at (x, y) as RGBA
    pub fn getPixelRGBA(self: *const Self, x: u32, y: u32) ?[4]u8 {
        if (x >= self.width or y >= self.height) return null;

        switch (self.format) {
            .rgba32 => {
                const idx = (@as(usize, y) * @as(usize, self.strides[0]) + @as(usize, x) * 4);
                return .{
                    self.data[idx],
                    self.data[idx + 1],
                    self.data[idx + 2],
                    self.data[idx + 3],
                };
            },
            .rgb24 => {
                const idx = (@as(usize, y) * @as(usize, self.strides[0]) + @as(usize, x) * 3);
                return .{
                    self.data[idx],
                    self.data[idx + 1],
                    self.data[idx + 2],
                    255,
                };
            },
            .yuv420p => {
                const y_plane = self.getPlane(0) orelse return null;
                const u_plane = self.getPlane(1) orelse return null;
                const v_plane = self.getPlane(2) orelse return null;

                const y_idx = @as(usize, y) * @as(usize, self.strides[0]) + @as(usize, x);
                const uv_x = x / 2;
                const uv_y = y / 2;
                const uv_stride = self.strides[1];
                const uv_idx = @as(usize, uv_y) * @as(usize, uv_stride) + @as(usize, uv_x);

                const Y: i32 = @as(i32, y_plane[y_idx]);
                const U: i32 = @as(i32, u_plane[uv_idx]) - 128;
                const V: i32 = @as(i32, v_plane[uv_idx]) - 128;

                // BT.601 conversion
                const R = std.math.clamp(Y + @divTrunc(V * 1436, 1024), 0, 255);
                const G = std.math.clamp(Y - @divTrunc(U * 352, 1024) - @divTrunc(V * 731, 1024), 0, 255);
                const B = std.math.clamp(Y + @divTrunc(U * 1815, 1024), 0, 255);

                return .{ @intCast(R), @intCast(G), @intCast(B), 255 };
            },
            else => return null,
        }
    }

    /// Set pixel at (x, y) from RGBA
    pub fn setPixelRGBA(self: *Self, x: u32, y: u32, rgba: [4]u8) void {
        if (x >= self.width or y >= self.height) return;

        switch (self.format) {
            .rgba32 => {
                const idx = (@as(usize, y) * @as(usize, self.strides[0]) + @as(usize, x) * 4);
                self.data[idx] = rgba[0];
                self.data[idx + 1] = rgba[1];
                self.data[idx + 2] = rgba[2];
                self.data[idx + 3] = rgba[3];
            },
            .rgb24 => {
                const idx = (@as(usize, y) * @as(usize, self.strides[0]) + @as(usize, x) * 3);
                self.data[idx] = rgba[0];
                self.data[idx + 1] = rgba[1];
                self.data[idx + 2] = rgba[2];
            },
            else => {},
        }
    }

    /// Total size in bytes
    pub fn byteSize(self: *const Self) usize {
        return self.data.len;
    }

    /// Get display dimensions (accounting for rotation)
    pub fn displayDimensions(self: *const Self) struct { width: u32, height: u32 } {
        if (self.rotation == 90 or self.rotation == 270) {
            return .{ .width = self.height, .height = self.width };
        }
        return .{ .width = self.width, .height = self.height };
    }

    const Allocation = struct {
        total_size: usize,
        strides: [4]u32,
        num_planes: u8,
    };

    fn calculateAllocation(width: u32, height: u32, format: PixelFormat) !Allocation {
        var result = Allocation{
            .total_size = 0,
            .strides = .{ 0, 0, 0, 0 },
            .num_planes = 1,
        };

        // Align stride to 16 bytes for SIMD
        const align_stride = struct {
            fn f(stride: u32) u32 {
                return (stride + 15) & ~@as(u32, 15);
            }
        }.f;

        switch (format) {
            .yuv420p => {
                result.num_planes = 3;
                result.strides[0] = align_stride(width);
                result.strides[1] = align_stride((width + 1) / 2);
                result.strides[2] = result.strides[1];

                const y_size = @as(usize, result.strides[0]) * @as(usize, height);
                const uv_height = (height + 1) / 2;
                const u_size = @as(usize, result.strides[1]) * @as(usize, uv_height);
                const v_size = u_size;

                result.total_size = y_size + u_size + v_size;
            },
            .yuv422p => {
                result.num_planes = 3;
                result.strides[0] = align_stride(width);
                result.strides[1] = align_stride((width + 1) / 2);
                result.strides[2] = result.strides[1];

                const y_size = @as(usize, result.strides[0]) * @as(usize, height);
                const u_size = @as(usize, result.strides[1]) * @as(usize, height);
                const v_size = u_size;

                result.total_size = y_size + u_size + v_size;
            },
            .yuv444p => {
                result.num_planes = 3;
                result.strides[0] = align_stride(width);
                result.strides[1] = result.strides[0];
                result.strides[2] = result.strides[0];

                const plane_size = @as(usize, result.strides[0]) * @as(usize, height);
                result.total_size = plane_size * 3;
            },
            .nv12, .nv21 => {
                result.num_planes = 2;
                result.strides[0] = align_stride(width);
                result.strides[1] = align_stride(width); // UV interleaved

                const y_size = @as(usize, result.strides[0]) * @as(usize, height);
                const uv_height = (height + 1) / 2;
                const uv_size = @as(usize, result.strides[1]) * @as(usize, uv_height);

                result.total_size = y_size + uv_size;
            },
            .rgb24, .bgr24 => {
                result.num_planes = 1;
                result.strides[0] = align_stride(width * 3);
                result.total_size = @as(usize, result.strides[0]) * @as(usize, height);
            },
            .rgba32, .bgra32, .argb32, .abgr32 => {
                result.num_planes = 1;
                result.strides[0] = align_stride(width * 4);
                result.total_size = @as(usize, result.strides[0]) * @as(usize, height);
            },
            .gray8 => {
                result.num_planes = 1;
                result.strides[0] = align_stride(width);
                result.total_size = @as(usize, result.strides[0]) * @as(usize, height);
            },
            .gray16le => {
                result.num_planes = 1;
                result.strides[0] = align_stride(width * 2);
                result.total_size = @as(usize, result.strides[0]) * @as(usize, height);
            },
            else => {
                // Generic calculation using bytesPerPixel
                if (format.bytesPerPixel()) |bpp| {
                    result.num_planes = 1;
                    result.strides[0] = align_stride(@intFromFloat(@as(f32, @floatFromInt(width)) * bpp));
                    result.total_size = @as(usize, result.strides[0]) * @as(usize, height);
                } else {
                    return error.UnsupportedFormat;
                }
            },
        }

        return result;
    }
};

// ============================================================================
// AudioFrame
// ============================================================================

pub const AudioFrame = struct {
    /// Number of samples per channel
    num_samples: u32,

    /// Sample format
    format: SampleFormat,

    /// Number of channels
    channels: u8,

    /// Sample rate in Hz
    sample_rate: u32,

    /// Channel layout
    channel_layout: ChannelLayout,

    /// Audio data
    /// For interleaved: single buffer with samples [L0 R0 L1 R1 ...]
    /// For planar: separate buffer per channel
    data: []u8,

    /// For planar formats, pointers to each channel's data
    channel_data: [8]?[]u8,

    /// Presentation timestamp
    pts: Timestamp,

    /// Duration of this frame
    duration: Duration,

    /// Memory allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new audio frame with allocated memory
    pub fn init(
        allocator: std.mem.Allocator,
        num_samples: u32,
        format: SampleFormat,
        channels: u8,
        sample_rate: u32,
    ) !Self {
        const bytes_per_sample = format.bytesPerSample();
        const total_size = @as(usize, num_samples) * @as(usize, channels) * @as(usize, bytes_per_sample);
        const data = try allocator.alloc(u8, total_size);
        @memset(data, 0);

        var channel_data: [8]?[]u8 = .{ null, null, null, null, null, null, null, null };

        if (format.isPlanar()) {
            const channel_size = @as(usize, num_samples) * @as(usize, bytes_per_sample);
            for (0..channels) |ch| {
                const start = ch * channel_size;
                channel_data[ch] = data[start .. start + channel_size];
            }
        }

        // Calculate duration
        const duration_us = @as(u64, num_samples) * 1_000_000 / @as(u64, sample_rate);

        return Self{
            .num_samples = num_samples,
            .format = format,
            .channels = channels,
            .sample_rate = sample_rate,
            .channel_layout = ChannelLayout.fromChannelCount(channels),
            .data = data,
            .channel_data = channel_data,
            .pts = Timestamp.ZERO,
            .duration = Duration.fromMicroseconds(duration_us),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Clone this frame
    pub fn clone(self: *const Self) !Self {
        var new_frame = try Self.init(
            self.allocator,
            self.num_samples,
            self.format,
            self.channels,
            self.sample_rate,
        );
        @memcpy(new_frame.data, self.data);
        new_frame.pts = self.pts;
        new_frame.channel_layout = self.channel_layout;
        return new_frame;
    }

    /// Get sample as f32 (normalized -1.0 to 1.0)
    pub fn getSampleF32(self: *const Self, channel: u8, sample_idx: u32) ?f32 {
        if (channel >= self.channels or sample_idx >= self.num_samples) return null;

        const bps = self.format.bytesPerSample();

        const offset: usize = if (self.format.isPlanar())
            @as(usize, sample_idx) * @as(usize, bps)
        else
            (@as(usize, sample_idx) * @as(usize, self.channels) + @as(usize, channel)) * @as(usize, bps);

        const data_ptr = if (self.format.isPlanar())
            self.channel_data[channel] orelse return null
        else
            self.data;

        return switch (self.format) {
            .s16le, .s16p => blk: {
                const sample = std.mem.readInt(i16, data_ptr[offset..][0..2], .little);
                break :blk @as(f32, @floatFromInt(sample)) / 32768.0;
            },
            .s16be => blk: {
                const sample = std.mem.readInt(i16, data_ptr[offset..][0..2], .big);
                break :blk @as(f32, @floatFromInt(sample)) / 32768.0;
            },
            .s32le, .s32p => blk: {
                const sample = std.mem.readInt(i32, data_ptr[offset..][0..4], .little);
                break :blk @as(f32, @floatFromInt(sample)) / 2147483648.0;
            },
            .f32le, .f32p => blk: {
                const bytes = data_ptr[offset..][0..4];
                break :blk @bitCast(std.mem.readInt(u32, bytes, .little));
            },
            .u8 => blk: {
                const sample = data_ptr[offset];
                break :blk (@as(f32, @floatFromInt(sample)) - 128.0) / 128.0;
            },
            else => null,
        };
    }

    /// Set sample from f32 (normalized -1.0 to 1.0)
    pub fn setSampleF32(self: *Self, channel: u8, sample_idx: u32, value: f32) void {
        if (channel >= self.channels or sample_idx >= self.num_samples) return;

        const bps = self.format.bytesPerSample();
        const clamped = std.math.clamp(value, -1.0, 1.0);

        const offset: usize = if (self.format.isPlanar())
            @as(usize, sample_idx) * @as(usize, bps)
        else
            (@as(usize, sample_idx) * @as(usize, self.channels) + @as(usize, channel)) * @as(usize, bps);

        const data_ptr = if (self.format.isPlanar())
            self.channel_data[channel] orelse return
        else
            self.data;

        switch (self.format) {
            .s16le, .s16p => {
                const sample: i16 = @intFromFloat(clamped * 32767.0);
                std.mem.writeInt(i16, data_ptr[offset..][0..2], sample, .little);
            },
            .s16be => {
                const sample: i16 = @intFromFloat(clamped * 32767.0);
                std.mem.writeInt(i16, data_ptr[offset..][0..2], sample, .big);
            },
            .s32le, .s32p => {
                const sample: i32 = @intFromFloat(clamped * 2147483647.0);
                std.mem.writeInt(i32, data_ptr[offset..][0..4], sample, .little);
            },
            .f32le, .f32p => {
                const int_val: u32 = @bitCast(clamped);
                std.mem.writeInt(u32, data_ptr[offset..][0..4], int_val, .little);
            },
            .u8 => {
                data_ptr[offset] = @intFromFloat((clamped + 1.0) * 127.5);
            },
            else => {},
        }
    }

    /// Total size in bytes
    pub fn byteSize(self: *const Self) usize {
        return self.data.len;
    }

    /// Duration in seconds
    pub fn durationSeconds(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.num_samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "VideoFrame creation" {
    var frame = try VideoFrame.init(std.testing.allocator, 1920, 1080, .yuv420p);
    defer frame.deinit();

    try std.testing.expectEqual(@as(u32, 1920), frame.width);
    try std.testing.expectEqual(@as(u32, 1080), frame.height);
    try std.testing.expectEqual(@as(u8, 3), frame.num_planes);

    // Check plane heights
    try std.testing.expectEqual(@as(u32, 1080), frame.getPlaneHeight(0));
    try std.testing.expectEqual(@as(u32, 540), frame.getPlaneHeight(1));
}

test "VideoFrame RGBA" {
    var frame = try VideoFrame.init(std.testing.allocator, 10, 10, .rgba32);
    defer frame.deinit();

    frame.setPixelRGBA(5, 5, .{ 255, 128, 64, 255 });
    const pixel = frame.getPixelRGBA(5, 5);

    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?[0]);
    try std.testing.expectEqual(@as(u8, 128), pixel.?[1]);
    try std.testing.expectEqual(@as(u8, 64), pixel.?[2]);
}

test "AudioFrame creation" {
    var frame = try AudioFrame.init(std.testing.allocator, 1024, .s16le, 2, 44100);
    defer frame.deinit();

    try std.testing.expectEqual(@as(u32, 1024), frame.num_samples);
    try std.testing.expectEqual(@as(u8, 2), frame.channels);
    try std.testing.expectEqual(@as(u32, 44100), frame.sample_rate);

    // Duration should be ~23.2ms
    const duration = frame.durationSeconds();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0232), duration, 0.001);
}

test "AudioFrame sample access" {
    var frame = try AudioFrame.init(std.testing.allocator, 100, .s16le, 2, 44100);
    defer frame.deinit();

    frame.setSampleF32(0, 0, 0.5);
    frame.setSampleF32(1, 0, -0.5);

    const left = frame.getSampleF32(0, 0);
    const right = frame.getSampleF32(1, 0);

    try std.testing.expect(left != null);
    try std.testing.expect(right != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), left.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), right.?, 0.001);
}
