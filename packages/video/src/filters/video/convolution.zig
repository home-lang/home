// Home Video Library - Convolution Filters
// Blur, sharpen, edge detection and other kernel-based filters

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const VideoFrame = frame.VideoFrame;
const PixelFormat = types.PixelFormat;

// ============================================================================
// Convolution Kernel
// ============================================================================

pub const Kernel = struct {
    data: []const f32,
    width: usize,
    height: usize,
    divisor: f32,
    bias: f32,

    pub fn init(data: []const f32, width: usize, height: usize) Kernel {
        var sum: f32 = 0;
        for (data) |v| sum += v;
        const divisor = if (sum != 0) sum else 1;

        return .{
            .data = data,
            .width = width,
            .height = height,
            .divisor = divisor,
            .bias = 0,
        };
    }

    pub fn initWithDivisor(data: []const f32, width: usize, height: usize, divisor: f32, bias: f32) Kernel {
        return .{
            .data = data,
            .width = width,
            .height = height,
            .divisor = divisor,
            .bias = bias,
        };
    }

    pub fn get(self: *const Kernel, x: usize, y: usize) f32 {
        return self.data[y * self.width + x];
    }
};

// ============================================================================
// Predefined Kernels
// ============================================================================

pub const Kernels = struct {
    /// Box blur 3x3
    pub const box_blur_3x3 = Kernel.init(&[_]f32{
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
    }, 3, 3);

    /// Box blur 5x5
    pub const box_blur_5x5 = Kernel.init(&[_]f32{
        1, 1, 1, 1, 1,
        1, 1, 1, 1, 1,
        1, 1, 1, 1, 1,
        1, 1, 1, 1, 1,
        1, 1, 1, 1, 1,
    }, 5, 5);

    /// Gaussian blur 3x3
    pub const gaussian_blur_3x3 = Kernel.initWithDivisor(&[_]f32{
        1, 2, 1,
        2, 4, 2,
        1, 2, 1,
    }, 3, 3, 16, 0);

    /// Gaussian blur 5x5
    pub const gaussian_blur_5x5 = Kernel.initWithDivisor(&[_]f32{
        1,  4,  6,  4,  1,
        4,  16, 24, 16, 4,
        6,  24, 36, 24, 6,
        4,  16, 24, 16, 4,
        1,  4,  6,  4,  1,
    }, 5, 5, 256, 0);

    /// Sharpen
    pub const sharpen = Kernel.initWithDivisor(&[_]f32{
        0,  -1, 0,
        -1, 5,  -1,
        0,  -1, 0,
    }, 3, 3, 1, 0);

    /// Sharpen (strong)
    pub const sharpen_strong = Kernel.initWithDivisor(&[_]f32{
        -1, -1, -1,
        -1, 9,  -1,
        -1, -1, -1,
    }, 3, 3, 1, 0);

    /// Edge detection (Sobel X)
    pub const sobel_x = Kernel.initWithDivisor(&[_]f32{
        -1, 0, 1,
        -2, 0, 2,
        -1, 0, 1,
    }, 3, 3, 1, 128);

    /// Edge detection (Sobel Y)
    pub const sobel_y = Kernel.initWithDivisor(&[_]f32{
        -1, -2, -1,
        0,  0,  0,
        1,  2,  1,
    }, 3, 3, 1, 128);

    /// Edge detection (Laplacian)
    pub const laplacian = Kernel.initWithDivisor(&[_]f32{
        0,  1,  0,
        1,  -4, 1,
        0,  1,  0,
    }, 3, 3, 1, 128);

    /// Emboss
    pub const emboss = Kernel.initWithDivisor(&[_]f32{
        -2, -1, 0,
        -1, 1,  1,
        0,  1,  2,
    }, 3, 3, 1, 128);

    /// Unsharp mask
    pub const unsharp_mask = Kernel.initWithDivisor(&[_]f32{
        1,  4,  6,    4,  1,
        4,  16, 24,   16, 4,
        6,  24, -476, 24, 6,
        4,  16, 24,   16, 4,
        1,  4,  6,    4,  1,
    }, 5, 5, -256, 0);
};

// ============================================================================
// Convolution Filter
// ============================================================================

pub const ConvolutionFilter = struct {
    kernel: Kernel,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, kernel: Kernel) Self {
        return .{
            .kernel = kernel,
            .allocator = allocator,
        };
    }

    /// Apply convolution to a video frame
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                const kw = self.kernel.width;
                const kh = self.kernel.height;
                const kw_half = kw / 2;
                const kh_half = kh / 2;

                for (0..input.height) |y| {
                    for (0..input.width) |x| {
                        for (0..bytes_per_pixel) |ch| {
                            // Skip alpha channel
                            if (bytes_per_pixel == 4 and ch == 3) {
                                const offset = y * dst_stride + x * bytes_per_pixel + ch;
                                const src_offset = y * src_stride + x * bytes_per_pixel + ch;
                                if (offset < dst.len and src_offset < src.len) {
                                    dst[offset] = src[src_offset];
                                }
                                continue;
                            }

                            var sum: f32 = 0;

                            for (0..kh) |ky| {
                                for (0..kw) |kx| {
                                    const sy = @as(i64, @intCast(y)) + @as(i64, @intCast(ky)) - @as(i64, @intCast(kh_half));
                                    const sx = @as(i64, @intCast(x)) + @as(i64, @intCast(kx)) - @as(i64, @intCast(kw_half));

                                    // Clamp to image bounds
                                    const csy: usize = @intCast(@max(0, @min(@as(i64, @intCast(input.height)) - 1, sy)));
                                    const csx: usize = @intCast(@max(0, @min(@as(i64, @intCast(input.width)) - 1, sx)));

                                    const src_offset = csy * src_stride + csx * bytes_per_pixel + ch;
                                    if (src_offset < src.len) {
                                        const pixel: f32 = @floatFromInt(src[src_offset]);
                                        sum += pixel * self.kernel.get(kx, ky);
                                    }
                                }
                            }

                            const result = sum / self.kernel.divisor + self.kernel.bias;
                            const dst_offset = y * dst_stride + x * bytes_per_pixel + ch;
                            if (dst_offset < dst.len) {
                                dst[dst_offset] = @intFromFloat(@round(@max(0, @min(255, result))));
                            }
                        }
                    }
                }
            }
        }

        // Copy chroma planes unchanged for YUV formats
        if (isYuvPlanar(input.format)) {
            for (1..3) |plane_idx| {
                if (input.data[plane_idx]) |src_plane| {
                    if (output.data[plane_idx]) |dst_plane| {
                        const len = @min(src_plane.len, dst_plane.len);
                        @memcpy(dst_plane[0..len], src_plane[0..len]);
                    }
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }
};

// ============================================================================
// Blur Filter
// ============================================================================

pub const BlurFilter = struct {
    radius: u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, radius: u8) Self {
        return .{
            .radius = @max(1, @min(radius, 10)),
            .allocator = allocator,
        };
    }

    /// Apply box blur
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        const kernel = switch (self.radius) {
            1, 2 => Kernels.box_blur_3x3,
            else => Kernels.box_blur_5x5,
        };

        var filter = ConvolutionFilter.init(self.allocator, kernel);

        // Apply multiple times for larger radius
        var result = try filter.apply(input);
        errdefer result.deinit();

        const iterations = (self.radius - 1) / 2;
        for (0..iterations) |_| {
            const next = try filter.apply(&result);
            result.deinit();
            result = next;
        }

        return result;
    }

    /// Apply Gaussian blur
    pub fn applyGaussian(self: *const Self, input: *const VideoFrame) !VideoFrame {
        const kernel = switch (self.radius) {
            1, 2 => Kernels.gaussian_blur_3x3,
            else => Kernels.gaussian_blur_5x5,
        };

        var filter = ConvolutionFilter.init(self.allocator, kernel);
        return try filter.apply(input);
    }
};

// ============================================================================
// Sharpen Filter
// ============================================================================

pub const SharpenFilter = struct {
    strength: f32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, strength: f32) Self {
        return .{
            .strength = @max(0, @min(2, strength)),
            .allocator = allocator,
        };
    }

    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        const kernel = if (self.strength > 1.0) Kernels.sharpen_strong else Kernels.sharpen;
        var filter = ConvolutionFilter.init(self.allocator, kernel);
        return try filter.apply(input);
    }
};

// ============================================================================
// Edge Detection Filter
// ============================================================================

pub const EdgeDetectionMode = enum {
    sobel,
    laplacian,
};

pub const EdgeDetectionFilter = struct {
    mode: EdgeDetectionMode,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, mode: EdgeDetectionMode) Self {
        return .{
            .mode = mode,
            .allocator = allocator,
        };
    }

    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        switch (self.mode) {
            .sobel => {
                // Apply Sobel X and Y, combine results
                var filter_x = ConvolutionFilter.init(self.allocator, Kernels.sobel_x);
                var filter_y = ConvolutionFilter.init(self.allocator, Kernels.sobel_y);

                var result_x = try filter_x.apply(input);
                defer result_x.deinit();
                var result_y = try filter_y.apply(input);
                defer result_y.deinit();

                // Combine: sqrt(x^2 + y^2)
                return try self.combineSobel(&result_x, &result_y);
            },
            .laplacian => {
                var filter = ConvolutionFilter.init(self.allocator, Kernels.laplacian);
                return try filter.apply(input);
            },
        }
    }

    fn combineSobel(self: *const Self, frame_x: *const VideoFrame, frame_y: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            frame_x.width,
            frame_x.height,
            frame_x.format,
        );
        errdefer output.deinit();

        if (frame_x.data[0]) |src_x| {
            if (frame_y.data[0]) |src_y| {
                if (output.data[0]) |dst| {
                    for (0..@min(src_x.len, @min(src_y.len, dst.len))) |i| {
                        const vx = @as(f32, @floatFromInt(src_x[i])) - 128;
                        const vy = @as(f32, @floatFromInt(src_y[i])) - 128;
                        const magnitude = @sqrt(vx * vx + vy * vy);
                        dst[i] = @intFromFloat(@round(@min(255, magnitude)));
                    }
                }
            }
        }

        output.pts = frame_x.pts;
        output.dts = frame_x.dts;
        output.duration = frame_x.duration;
        return output;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn getBytesPerPixel(format: PixelFormat) usize {
    return switch (format) {
        .rgb24, .bgr24 => 3,
        .rgba32, .bgra32, .argb32, .abgr32 => 4,
        else => 1,
    };
}

fn isYuvPlanar(format: PixelFormat) bool {
    return switch (format) {
        .yuv420p, .yuv422p, .yuv444p => true,
        else => false,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Kernel initialization" {
    const data = [_]f32{ 1, 2, 1, 2, 4, 2, 1, 2, 1 };
    const kernel = Kernel.init(&data, 3, 3);

    try std.testing.expectEqual(@as(usize, 3), kernel.width);
    try std.testing.expectEqual(@as(usize, 3), kernel.height);
    try std.testing.expectApproxEqAbs(@as(f32, 16), kernel.divisor, 0.001);
}

test "Kernel get" {
    const kernel = Kernels.gaussian_blur_3x3;
    try std.testing.expectApproxEqAbs(@as(f32, 4), kernel.get(1, 1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), kernel.get(0, 0), 0.001);
}

test "BlurFilter initialization" {
    const allocator = std.testing.allocator;
    const filter = BlurFilter.init(allocator, 3);
    try std.testing.expectEqual(@as(u8, 3), filter.radius);

    // Test clamping
    const filter_high = BlurFilter.init(allocator, 100);
    try std.testing.expectEqual(@as(u8, 10), filter_high.radius);
}

test "SharpenFilter initialization" {
    const allocator = std.testing.allocator;
    const filter = SharpenFilter.init(allocator, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), filter.strength, 0.001);

    // Test clamping
    const filter_high = SharpenFilter.init(allocator, 10);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), filter_high.strength, 0.001);
}

test "EdgeDetectionFilter initialization" {
    const allocator = std.testing.allocator;
    const sobel = EdgeDetectionFilter.init(allocator, .sobel);
    try std.testing.expectEqual(EdgeDetectionMode.sobel, sobel.mode);

    const laplacian = EdgeDetectionFilter.init(allocator, .laplacian);
    try std.testing.expectEqual(EdgeDetectionMode.laplacian, laplacian.mode);
}

test "Predefined kernels" {
    try std.testing.expectEqual(@as(usize, 3), Kernels.sharpen.width);
    try std.testing.expectEqual(@as(usize, 5), Kernels.gaussian_blur_5x5.width);
    try std.testing.expectApproxEqAbs(@as(f32, 256), Kernels.gaussian_blur_5x5.divisor, 0.001);
}
