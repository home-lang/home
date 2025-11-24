// Home Video Library - Scale Filter
// High-quality image scaling using various interpolation methods

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const VideoFrame = frame.VideoFrame;
const PixelFormat = types.PixelFormat;

// ============================================================================
// Scaling Algorithm
// ============================================================================

pub const ScaleAlgorithm = enum {
    /// Nearest neighbor - fast but blocky
    nearest,
    /// Bilinear interpolation - smooth, balanced
    bilinear,
    /// Bicubic interpolation - sharper than bilinear
    bicubic,
    /// Lanczos resampling - highest quality, slowest
    lanczos,
    /// Area averaging - best for downscaling
    area,
};

// ============================================================================
// Scale Filter
// ============================================================================

pub const ScaleFilter = struct {
    width: u32,
    height: u32,
    algorithm: ScaleAlgorithm,
    allocator: std.mem.Allocator,

    // Pre-computed weights for Lanczos
    lanczos_a: f32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, algorithm: ScaleAlgorithm) Self {
        return .{
            .width = width,
            .height = height,
            .algorithm = algorithm,
            .allocator = allocator,
            .lanczos_a = 3.0, // Lanczos-3
        };
    }

    /// Scale a video frame to the target dimensions
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        if (input.width == self.width and input.height == self.height) {
            // No scaling needed, return a copy
            return try input.clone(self.allocator);
        }

        return switch (self.algorithm) {
            .nearest => try self.scaleNearest(input),
            .bilinear => try self.scaleBilinear(input),
            .bicubic => try self.scaleBicubic(input),
            .lanczos => try self.scaleLanczos(input),
            .area => try self.scaleArea(input),
        };
    }

    /// Nearest neighbor scaling - fastest
    fn scaleNearest(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            @intCast(self.width),
            @intCast(self.height),
            input.format,
        );
        errdefer output.deinit();

        const src_width = input.width;
        const src_height = input.height;
        const dst_width = self.width;
        const dst_height = self.height;

        // Process Y plane (or RGB if not planar)
        if (input.data[0]) |src_plane| {
            if (output.data[0]) |dst_plane| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];

                for (0..dst_height) |dst_y| {
                    const src_y = @min((dst_y * src_height) / dst_height, src_height - 1);

                    for (0..dst_width) |dst_x| {
                        const src_x = @min((dst_x * src_width) / dst_width, src_width - 1);

                        // For RGB, we need to handle multiple bytes per pixel
                        const bytes_per_pixel = getBytesPerPixel(input.format);
                        const src_offset = src_y * src_stride + src_x * bytes_per_pixel;
                        const dst_offset = dst_y * dst_stride + dst_x * bytes_per_pixel;

                        for (0..bytes_per_pixel) |i| {
                            if (src_offset + i < src_plane.len and dst_offset + i < dst_plane.len) {
                                dst_plane[dst_offset + i] = src_plane[src_offset + i];
                            }
                        }
                    }
                }
            }
        }

        // Process UV planes for YUV formats
        if (input.format == .yuv420p or input.format == .yuv422p or input.format == .yuv444p) {
            const chroma_width = getChromaWidth(input.format, dst_width);
            const chroma_height = getChromaHeight(input.format, dst_height);
            const src_chroma_width = getChromaWidth(input.format, src_width);
            const src_chroma_height = getChromaHeight(input.format, src_height);

            for (1..3) |plane_idx| {
                if (input.data[plane_idx]) |src_plane| {
                    if (output.data[plane_idx]) |dst_plane| {
                        const src_stride = input.linesize[plane_idx];
                        const dst_stride = output.linesize[plane_idx];

                        for (0..chroma_height) |dst_y| {
                            const src_y = @min((dst_y * src_chroma_height) / chroma_height, src_chroma_height - 1);

                            for (0..chroma_width) |dst_x| {
                                const src_x = @min((dst_x * src_chroma_width) / chroma_width, src_chroma_width - 1);

                                const src_offset = src_y * src_stride + src_x;
                                const dst_offset = dst_y * dst_stride + dst_x;

                                if (src_offset < src_plane.len and dst_offset < dst_plane.len) {
                                    dst_plane[dst_offset] = src_plane[src_offset];
                                }
                            }
                        }
                    }
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    /// Bilinear interpolation - good quality/speed balance
    fn scaleBilinear(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            @intCast(self.width),
            @intCast(self.height),
            input.format,
        );
        errdefer output.deinit();

        const src_width: f32 = @floatFromInt(input.width);
        const src_height: f32 = @floatFromInt(input.height);
        const dst_width: f32 = @floatFromInt(self.width);
        const dst_height: f32 = @floatFromInt(self.height);

        const scale_x = src_width / dst_width;
        const scale_y = src_height / dst_height;

        // Process Y plane (or RGB)
        if (input.data[0]) |src_plane| {
            if (output.data[0]) |dst_plane| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const bytes_per_pixel = getBytesPerPixel(input.format);

                for (0..self.height) |dst_y| {
                    const src_yf = @as(f32, @floatFromInt(dst_y)) * scale_y;
                    const src_y0: usize = @intFromFloat(@floor(src_yf));
                    const src_y1: usize = @min(src_y0 + 1, input.height - 1);
                    const y_frac = src_yf - @floor(src_yf);

                    for (0..self.width) |dst_x| {
                        const src_xf = @as(f32, @floatFromInt(dst_x)) * scale_x;
                        const src_x0: usize = @intFromFloat(@floor(src_xf));
                        const src_x1: usize = @min(src_x0 + 1, input.width - 1);
                        const x_frac = src_xf - @floor(src_xf);

                        for (0..bytes_per_pixel) |i| {
                            const p00 = getPixel(src_plane, src_x0, src_y0, src_stride, bytes_per_pixel, i);
                            const p10 = getPixel(src_plane, src_x1, src_y0, src_stride, bytes_per_pixel, i);
                            const p01 = getPixel(src_plane, src_x0, src_y1, src_stride, bytes_per_pixel, i);
                            const p11 = getPixel(src_plane, src_x1, src_y1, src_stride, bytes_per_pixel, i);

                            const top = lerp(p00, p10, x_frac);
                            const bottom = lerp(p01, p11, x_frac);
                            const result = lerp(top, bottom, y_frac);

                            const dst_offset = dst_y * dst_stride + dst_x * bytes_per_pixel + i;
                            if (dst_offset < dst_plane.len) {
                                dst_plane[dst_offset] = @intFromFloat(@round(@max(0, @min(255, result))));
                            }
                        }
                    }
                }
            }
        }

        // Process UV planes for YUV formats
        if (input.format == .yuv420p or input.format == .yuv422p or input.format == .yuv444p) {
            try self.scaleChromaBilinear(input, &output);
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn scaleChromaBilinear(self: *const Self, input: *const VideoFrame, output: *VideoFrame) !void {
        const chroma_width = getChromaWidth(input.format, self.width);
        const chroma_height = getChromaHeight(input.format, self.height);
        const src_chroma_width = getChromaWidth(input.format, input.width);
        const src_chroma_height = getChromaHeight(input.format, input.height);

        const scale_x = @as(f32, @floatFromInt(src_chroma_width)) / @as(f32, @floatFromInt(chroma_width));
        const scale_y = @as(f32, @floatFromInt(src_chroma_height)) / @as(f32, @floatFromInt(chroma_height));

        for (1..3) |plane_idx| {
            if (input.data[plane_idx]) |src_plane| {
                if (output.data[plane_idx]) |dst_plane| {
                    const src_stride = input.linesize[plane_idx];
                    const dst_stride = output.linesize[plane_idx];

                    for (0..chroma_height) |dst_y| {
                        const src_yf = @as(f32, @floatFromInt(dst_y)) * scale_y;
                        const src_y0: usize = @intFromFloat(@floor(src_yf));
                        const src_y1: usize = @min(src_y0 + 1, src_chroma_height - 1);
                        const y_frac = src_yf - @floor(src_yf);

                        for (0..chroma_width) |dst_x| {
                            const src_xf = @as(f32, @floatFromInt(dst_x)) * scale_x;
                            const src_x0: usize = @intFromFloat(@floor(src_xf));
                            const src_x1: usize = @min(src_x0 + 1, src_chroma_width - 1);
                            const x_frac = src_xf - @floor(src_xf);

                            const p00 = getPixel(src_plane, src_x0, src_y0, src_stride, 1, 0);
                            const p10 = getPixel(src_plane, src_x1, src_y0, src_stride, 1, 0);
                            const p01 = getPixel(src_plane, src_x0, src_y1, src_stride, 1, 0);
                            const p11 = getPixel(src_plane, src_x1, src_y1, src_stride, 1, 0);

                            const top = lerp(p00, p10, x_frac);
                            const bottom = lerp(p01, p11, x_frac);
                            const result = lerp(top, bottom, y_frac);

                            const dst_offset = dst_y * dst_stride + dst_x;
                            if (dst_offset < dst_plane.len) {
                                dst_plane[dst_offset] = @intFromFloat(@round(@max(0, @min(255, result))));
                            }
                        }
                    }
                }
            }
        }
    }

    /// Bicubic interpolation - sharper than bilinear
    fn scaleBicubic(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            @intCast(self.width),
            @intCast(self.height),
            input.format,
        );
        errdefer output.deinit();

        const src_width: f32 = @floatFromInt(input.width);
        const src_height: f32 = @floatFromInt(input.height);
        const dst_width: f32 = @floatFromInt(self.width);
        const dst_height: f32 = @floatFromInt(self.height);

        const scale_x = src_width / dst_width;
        const scale_y = src_height / dst_height;

        if (input.data[0]) |src_plane| {
            if (output.data[0]) |dst_plane| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const bytes_per_pixel = getBytesPerPixel(input.format);

                for (0..self.height) |dst_y| {
                    const src_yf = @as(f32, @floatFromInt(dst_y)) * scale_y;
                    const src_y_int: i32 = @intFromFloat(@floor(src_yf));
                    const y_frac = src_yf - @floor(src_yf);

                    for (0..self.width) |dst_x| {
                        const src_xf = @as(f32, @floatFromInt(dst_x)) * scale_x;
                        const src_x_int: i32 = @intFromFloat(@floor(src_xf));
                        const x_frac = src_xf - @floor(src_xf);

                        for (0..bytes_per_pixel) |ch| {
                            var result: f32 = 0;

                            // 4x4 kernel
                            for (0..4) |j| {
                                const y_idx = clamp(src_y_int - 1 + @as(i32, @intCast(j)), 0, @as(i32, @intCast(input.height)) - 1);
                                const wy = cubicWeight(@as(f32, @floatFromInt(j)) - 1 - y_frac);

                                for (0..4) |i| {
                                    const x_idx = clamp(src_x_int - 1 + @as(i32, @intCast(i)), 0, @as(i32, @intCast(input.width)) - 1);
                                    const wx = cubicWeight(@as(f32, @floatFromInt(i)) - 1 - x_frac);

                                    const pixel = getPixel(src_plane, @intCast(x_idx), @intCast(y_idx), src_stride, bytes_per_pixel, ch);
                                    result += pixel * wx * wy;
                                }
                            }

                            const dst_offset = dst_y * dst_stride + dst_x * bytes_per_pixel + ch;
                            if (dst_offset < dst_plane.len) {
                                dst_plane[dst_offset] = @intFromFloat(@round(@max(0, @min(255, result))));
                            }
                        }
                    }
                }
            }
        }

        // Handle chroma planes
        if (input.format == .yuv420p or input.format == .yuv422p or input.format == .yuv444p) {
            try self.scaleChromaBilinear(input, &output); // Use bilinear for chroma
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    /// Lanczos resampling - highest quality
    fn scaleLanczos(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            @intCast(self.width),
            @intCast(self.height),
            input.format,
        );
        errdefer output.deinit();

        const src_width: f32 = @floatFromInt(input.width);
        const src_height: f32 = @floatFromInt(input.height);
        const dst_width: f32 = @floatFromInt(self.width);
        const dst_height: f32 = @floatFromInt(self.height);

        const scale_x = src_width / dst_width;
        const scale_y = src_height / dst_height;

        const a: i32 = @intFromFloat(self.lanczos_a);

        if (input.data[0]) |src_plane| {
            if (output.data[0]) |dst_plane| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const bytes_per_pixel = getBytesPerPixel(input.format);

                for (0..self.height) |dst_y| {
                    const src_yf = @as(f32, @floatFromInt(dst_y)) * scale_y;
                    const src_y_int: i32 = @intFromFloat(@floor(src_yf));
                    const y_frac = src_yf - @floor(src_yf);

                    for (0..self.width) |dst_x| {
                        const src_xf = @as(f32, @floatFromInt(dst_x)) * scale_x;
                        const src_x_int: i32 = @intFromFloat(@floor(src_xf));
                        const x_frac = src_xf - @floor(src_xf);

                        for (0..bytes_per_pixel) |ch| {
                            var result: f32 = 0;
                            var weight_sum: f32 = 0;

                            // 2a x 2a kernel
                            var j: i32 = -a + 1;
                            while (j <= a) : (j += 1) {
                                const y_idx = clamp(src_y_int + j, 0, @as(i32, @intCast(input.height)) - 1);
                                const dy = @as(f32, @floatFromInt(j)) - y_frac;
                                const wy = lanczosKernel(dy, self.lanczos_a);

                                var i: i32 = -a + 1;
                                while (i <= a) : (i += 1) {
                                    const x_idx = clamp(src_x_int + i, 0, @as(i32, @intCast(input.width)) - 1);
                                    const dx = @as(f32, @floatFromInt(i)) - x_frac;
                                    const wx = lanczosKernel(dx, self.lanczos_a);

                                    const w = wx * wy;
                                    const pixel = getPixel(src_plane, @intCast(x_idx), @intCast(y_idx), src_stride, bytes_per_pixel, ch);
                                    result += pixel * w;
                                    weight_sum += w;
                                }
                            }

                            if (weight_sum > 0) {
                                result /= weight_sum;
                            }

                            const dst_offset = dst_y * dst_stride + dst_x * bytes_per_pixel + ch;
                            if (dst_offset < dst_plane.len) {
                                dst_plane[dst_offset] = @intFromFloat(@round(@max(0, @min(255, result))));
                            }
                        }
                    }
                }
            }
        }

        if (input.format == .yuv420p or input.format == .yuv422p or input.format == .yuv444p) {
            try self.scaleChromaBilinear(input, &output);
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    /// Area averaging - best for downscaling
    fn scaleArea(self: *const Self, input: *const VideoFrame) !VideoFrame {
        // For downscaling, use area averaging
        // For upscaling, fall back to bilinear
        if (self.width >= input.width and self.height >= input.height) {
            return try self.scaleBilinear(input);
        }

        var output = try VideoFrame.init(
            self.allocator,
            @intCast(self.width),
            @intCast(self.height),
            input.format,
        );
        errdefer output.deinit();

        const scale_x = @as(f32, @floatFromInt(input.width)) / @as(f32, @floatFromInt(self.width));
        const scale_y = @as(f32, @floatFromInt(input.height)) / @as(f32, @floatFromInt(self.height));

        if (input.data[0]) |src_plane| {
            if (output.data[0]) |dst_plane| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const bytes_per_pixel = getBytesPerPixel(input.format);

                for (0..self.height) |dst_y| {
                    const src_y0: f32 = @as(f32, @floatFromInt(dst_y)) * scale_y;
                    const src_y1: f32 = src_y0 + scale_y;

                    for (0..self.width) |dst_x| {
                        const src_x0: f32 = @as(f32, @floatFromInt(dst_x)) * scale_x;
                        const src_x1: f32 = src_x0 + scale_x;

                        for (0..bytes_per_pixel) |ch| {
                            var sum: f32 = 0;
                            var count: f32 = 0;

                            const y_start: usize = @intFromFloat(@floor(src_y0));
                            const y_end: usize = @min(@as(usize, @intFromFloat(@ceil(src_y1))), input.height);
                            const x_start: usize = @intFromFloat(@floor(src_x0));
                            const x_end: usize = @min(@as(usize, @intFromFloat(@ceil(src_x1))), input.width);

                            for (y_start..y_end) |sy| {
                                for (x_start..x_end) |sx| {
                                    const pixel = getPixel(src_plane, sx, sy, src_stride, bytes_per_pixel, ch);
                                    sum += pixel;
                                    count += 1;
                                }
                            }

                            const result = if (count > 0) sum / count else 0;
                            const dst_offset = dst_y * dst_stride + dst_x * bytes_per_pixel + ch;
                            if (dst_offset < dst_plane.len) {
                                dst_plane[dst_offset] = @intFromFloat(@round(@max(0, @min(255, result))));
                            }
                        }
                    }
                }
            }
        }

        if (input.format == .yuv420p or input.format == .yuv422p or input.format == .yuv444p) {
            try self.scaleChromaBilinear(input, &output);
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
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
        .gray8 => 1,
        else => 1, // Planar formats (Y plane)
    };
}

fn getChromaWidth(format: PixelFormat, luma_width: u32) usize {
    return switch (format) {
        .yuv420p, .yuv422p, .nv12, .nv21 => luma_width / 2,
        else => luma_width,
    };
}

fn getChromaHeight(format: PixelFormat, luma_height: u32) usize {
    return switch (format) {
        .yuv420p, .nv12, .nv21 => luma_height / 2,
        else => luma_height,
    };
}

fn getPixel(plane: []u8, x: usize, y: usize, stride: usize, bytes_per_pixel: usize, channel: usize) f32 {
    const offset = y * stride + x * bytes_per_pixel + channel;
    if (offset < plane.len) {
        return @floatFromInt(plane[offset]);
    }
    return 0;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn clamp(val: i32, min_val: i32, max_val: i32) i32 {
    return @max(min_val, @min(max_val, val));
}

/// Cubic interpolation weight (Catmull-Rom)
fn cubicWeight(x: f32) f32 {
    const abs_x = @abs(x);
    if (abs_x < 1) {
        return 1.5 * abs_x * abs_x * abs_x - 2.5 * abs_x * abs_x + 1;
    } else if (abs_x < 2) {
        return -0.5 * abs_x * abs_x * abs_x + 2.5 * abs_x * abs_x - 4 * abs_x + 2;
    }
    return 0;
}

/// Lanczos kernel
fn lanczosKernel(x: f32, a: f32) f32 {
    if (x == 0) return 1;
    if (@abs(x) >= a) return 0;

    const pi_x = std.math.pi * x;
    const sinc = @sin(pi_x) / pi_x;
    const window = @sin(pi_x / a) / (pi_x / a);
    return sinc * window;
}

// ============================================================================
// Tests
// ============================================================================

test "ScaleFilter initialization" {
    const allocator = std.testing.allocator;
    const filter = ScaleFilter.init(allocator, 1920, 1080, .bilinear);

    try std.testing.expectEqual(@as(u32, 1920), filter.width);
    try std.testing.expectEqual(@as(u32, 1080), filter.height);
    try std.testing.expectEqual(ScaleAlgorithm.bilinear, filter.algorithm);
}

test "Helper functions" {
    try std.testing.expectEqual(@as(usize, 3), getBytesPerPixel(.rgb24));
    try std.testing.expectEqual(@as(usize, 4), getBytesPerPixel(.rgba32));
    try std.testing.expectEqual(@as(usize, 1), getBytesPerPixel(.yuv420p));

    try std.testing.expectEqual(@as(usize, 960), getChromaWidth(.yuv420p, 1920));
    try std.testing.expectEqual(@as(usize, 540), getChromaHeight(.yuv420p, 1080));
}

test "Cubic weight function" {
    // At x=0, weight should be 1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cubicWeight(0), 0.001);
    // At x=2, weight should be 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cubicWeight(2), 0.001);
}

test "Lanczos kernel" {
    // At x=0, kernel should be 1
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lanczosKernel(0, 3), 0.001);
    // At x=a, kernel should be 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lanczosKernel(3, 3), 0.001);
}

test "Linear interpolation" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lerp(0, 10, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), lerp(0, 10, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), lerp(0, 10, 1.0), 0.001);
}
