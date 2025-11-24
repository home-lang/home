// Home Video Library - Noise Reduction Filter
// Various denoising algorithms for video

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const VideoFrame = frame.VideoFrame;
const PixelFormat = types.PixelFormat;

// ============================================================================
// Denoise Methods
// ============================================================================

pub const DenoiseMethod = enum {
    /// Simple averaging (fast, blurs details)
    average,
    /// Median filter (good for salt-and-pepper noise)
    median,
    /// Bilateral filter (edge-preserving)
    bilateral,
    /// Non-local means (high quality, slow)
    nlm,
    /// Temporal denoising (uses previous frame)
    temporal,
};

// ============================================================================
// Denoise Filter
// ============================================================================

pub const DenoiseFilter = struct {
    method: DenoiseMethod,
    strength: f32, // 0.0 - 1.0
    radius: u8, // Kernel radius
    allocator: std.mem.Allocator,
    // For temporal denoising
    prev_frame: ?VideoFrame,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, method: DenoiseMethod, strength: f32) Self {
        return .{
            .method = method,
            .strength = @max(0.0, @min(1.0, strength)),
            .radius = 1,
            .allocator = allocator,
            .prev_frame = null,
        };
    }

    pub fn initWithRadius(allocator: std.mem.Allocator, method: DenoiseMethod, strength: f32, radius: u8) Self {
        return .{
            .method = method,
            .strength = @max(0.0, @min(1.0, strength)),
            .radius = @max(1, @min(5, radius)),
            .allocator = allocator,
            .prev_frame = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.prev_frame) |*pf| {
            pf.deinit();
        }
    }

    /// Apply denoising to a video frame
    pub fn apply(self: *Self, input: *const VideoFrame) !VideoFrame {
        return switch (self.method) {
            .average => try self.averageFilter(input),
            .median => try self.medianFilter(input),
            .bilateral => try self.bilateralFilter(input),
            .nlm => try self.nlmFilter(input),
            .temporal => try self.temporalFilter(input),
        };
    }

    // ========================================================================
    // Average Filter
    // ========================================================================

    fn averageFilter(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);
        const radius: i32 = @intCast(self.radius);
        const kernel_size = (radius * 2 + 1) * (radius * 2 + 1);

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const width: i32 = @intCast(input.width);
                const height: i32 = @intCast(input.height);

                for (0..input.height) |y_u| {
                    const y: i32 = @intCast(y_u);
                    for (0..input.width) |x_u| {
                        const x: i32 = @intCast(x_u);
                        for (0..bytes_per_pixel) |ch| {
                            // Skip alpha channel
                            if (bytes_per_pixel == 4 and ch == 3) {
                                const offset = y_u * dst_stride + x_u * bytes_per_pixel + ch;
                                const src_offset = y_u * src_stride + x_u * bytes_per_pixel + ch;
                                if (offset < dst.len and src_offset < src.len) {
                                    dst[offset] = src[src_offset];
                                }
                                continue;
                            }

                            var sum: u32 = 0;
                            var count: u32 = 0;

                            var ky: i32 = -radius;
                            while (ky <= radius) : (ky += 1) {
                                var kx: i32 = -radius;
                                while (kx <= radius) : (kx += 1) {
                                    const sy = @max(0, @min(height - 1, y + ky));
                                    const sx = @max(0, @min(width - 1, x + kx));

                                    const src_offset = @as(usize, @intCast(sy)) * src_stride +
                                        @as(usize, @intCast(sx)) * bytes_per_pixel + ch;

                                    if (src_offset < src.len) {
                                        sum += src[src_offset];
                                        count += 1;
                                    }
                                }
                            }

                            const dst_offset = y_u * dst_stride + x_u * bytes_per_pixel + ch;
                            if (dst_offset < dst.len and count > 0) {
                                const avg: u8 = @intCast(sum / count);
                                const orig = src[y_u * src_stride + x_u * bytes_per_pixel + ch];
                                // Blend based on strength
                                const strength_int: u32 = @intFromFloat(self.strength * 256);
                                const result = ((@as(u32, avg) * strength_int) +
                                    (@as(u32, orig) * (256 - strength_int))) / 256;
                                dst[dst_offset] = @intCast(result);
                            }
                        }
                    }
                }
                _ = kernel_size;
            }
        }

        copyChromaPlanes(input, &output);
        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    // ========================================================================
    // Median Filter
    // ========================================================================

    fn medianFilter(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);
        const radius: i32 = @intCast(self.radius);
        const kernel_size: usize = @intCast((radius * 2 + 1) * (radius * 2 + 1));

        // Buffer for sorting
        var values: [121]u8 = undefined; // Max 5x5 kernel = 25, but 11x11 = 121 just in case

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const width: i32 = @intCast(input.width);
                const height: i32 = @intCast(input.height);

                for (0..input.height) |y_u| {
                    const y: i32 = @intCast(y_u);
                    for (0..input.width) |x_u| {
                        const x: i32 = @intCast(x_u);
                        for (0..bytes_per_pixel) |ch| {
                            // Skip alpha channel
                            if (bytes_per_pixel == 4 and ch == 3) {
                                const offset = y_u * dst_stride + x_u * bytes_per_pixel + ch;
                                const src_offset = y_u * src_stride + x_u * bytes_per_pixel + ch;
                                if (offset < dst.len and src_offset < src.len) {
                                    dst[offset] = src[src_offset];
                                }
                                continue;
                            }

                            var count: usize = 0;

                            var ky: i32 = -radius;
                            while (ky <= radius) : (ky += 1) {
                                var kx: i32 = -radius;
                                while (kx <= radius) : (kx += 1) {
                                    const sy = @max(0, @min(height - 1, y + ky));
                                    const sx = @max(0, @min(width - 1, x + kx));

                                    const src_offset = @as(usize, @intCast(sy)) * src_stride +
                                        @as(usize, @intCast(sx)) * bytes_per_pixel + ch;

                                    if (src_offset < src.len and count < values.len) {
                                        values[count] = src[src_offset];
                                        count += 1;
                                    }
                                }
                            }

                            // Sort and get median
                            if (count > 0) {
                                std.mem.sort(u8, values[0..count], {}, std.sort.asc(u8));
                                const median = values[count / 2];

                                const dst_offset = y_u * dst_stride + x_u * bytes_per_pixel + ch;
                                if (dst_offset < dst.len) {
                                    const orig = src[y_u * src_stride + x_u * bytes_per_pixel + ch];
                                    const strength_int: u32 = @intFromFloat(self.strength * 256);
                                    const result = ((@as(u32, median) * strength_int) +
                                        (@as(u32, orig) * (256 - strength_int))) / 256;
                                    dst[dst_offset] = @intCast(result);
                                }
                            }
                        }
                    }
                }
                _ = kernel_size;
            }
        }

        copyChromaPlanes(input, &output);
        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    // ========================================================================
    // Bilateral Filter (Edge-Preserving)
    // ========================================================================

    fn bilateralFilter(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);
        const radius: i32 = @intCast(self.radius);
        const sigma_space: f32 = @floatFromInt(self.radius);
        const sigma_color: f32 = 30.0 * self.strength; // Color similarity threshold

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const width: i32 = @intCast(input.width);
                const height: i32 = @intCast(input.height);

                for (0..input.height) |y_u| {
                    const y: i32 = @intCast(y_u);
                    for (0..input.width) |x_u| {
                        const x: i32 = @intCast(x_u);
                        for (0..bytes_per_pixel) |ch| {
                            // Skip alpha channel
                            if (bytes_per_pixel == 4 and ch == 3) {
                                const offset = y_u * dst_stride + x_u * bytes_per_pixel + ch;
                                const src_offset = y_u * src_stride + x_u * bytes_per_pixel + ch;
                                if (offset < dst.len and src_offset < src.len) {
                                    dst[offset] = src[src_offset];
                                }
                                continue;
                            }

                            const center_offset = y_u * src_stride + x_u * bytes_per_pixel + ch;
                            if (center_offset >= src.len) continue;

                            const center_val: f32 = @floatFromInt(src[center_offset]);
                            var weighted_sum: f32 = 0;
                            var weight_sum: f32 = 0;

                            var ky: i32 = -radius;
                            while (ky <= radius) : (ky += 1) {
                                var kx: i32 = -radius;
                                while (kx <= radius) : (kx += 1) {
                                    const sy = @max(0, @min(height - 1, y + ky));
                                    const sx = @max(0, @min(width - 1, x + kx));

                                    const src_offset = @as(usize, @intCast(sy)) * src_stride +
                                        @as(usize, @intCast(sx)) * bytes_per_pixel + ch;

                                    if (src_offset < src.len) {
                                        const neighbor_val: f32 = @floatFromInt(src[src_offset]);

                                        // Spatial weight (Gaussian)
                                        const kx_f: f32 = @floatFromInt(kx);
                                        const ky_f: f32 = @floatFromInt(ky);
                                        const spatial_dist = @sqrt(kx_f * kx_f + ky_f * ky_f);
                                        const spatial_weight = @exp(-(spatial_dist * spatial_dist) / (2.0 * sigma_space * sigma_space));

                                        // Color weight (Gaussian)
                                        const color_diff = center_val - neighbor_val;
                                        const color_weight = @exp(-(color_diff * color_diff) / (2.0 * sigma_color * sigma_color));

                                        const weight = spatial_weight * color_weight;
                                        weighted_sum += neighbor_val * weight;
                                        weight_sum += weight;
                                    }
                                }
                            }

                            const dst_offset = y_u * dst_stride + x_u * bytes_per_pixel + ch;
                            if (dst_offset < dst.len and weight_sum > 0) {
                                const filtered = weighted_sum / weight_sum;
                                dst[dst_offset] = @intFromFloat(@round(@max(0, @min(255, filtered))));
                            }
                        }
                    }
                }
            }
        }

        copyChromaPlanes(input, &output);
        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    // ========================================================================
    // Non-Local Means (Simplified)
    // ========================================================================

    fn nlmFilter(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);
        const search_radius: i32 = @intCast(self.radius * 2); // Search window
        const patch_radius: i32 = 1; // Patch size for comparison
        const h: f32 = 10.0 * self.strength; // Filtering parameter

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const src_stride = input.linesize[0];
                const dst_stride = output.linesize[0];
                const width: i32 = @intCast(input.width);
                const height: i32 = @intCast(input.height);

                for (0..input.height) |y_u| {
                    const y: i32 = @intCast(y_u);
                    for (0..input.width) |x_u| {
                        const x: i32 = @intCast(x_u);
                        for (0..bytes_per_pixel) |ch| {
                            // Skip alpha channel
                            if (bytes_per_pixel == 4 and ch == 3) {
                                const offset = y_u * dst_stride + x_u * bytes_per_pixel + ch;
                                const src_offset = y_u * src_stride + x_u * bytes_per_pixel + ch;
                                if (offset < dst.len and src_offset < src.len) {
                                    dst[offset] = src[src_offset];
                                }
                                continue;
                            }

                            var weighted_sum: f32 = 0;
                            var weight_sum: f32 = 0;

                            // Search in neighborhood
                            var sy: i32 = -search_radius;
                            while (sy <= search_radius) : (sy += 1) {
                                var sx: i32 = -search_radius;
                                while (sx <= search_radius) : (sx += 1) {
                                    const ny = @max(0, @min(height - 1, y + sy));
                                    const nx = @max(0, @min(width - 1, x + sx));

                                    // Calculate patch difference
                                    var patch_diff: f32 = 0;
                                    var patch_count: u32 = 0;

                                    var py: i32 = -patch_radius;
                                    while (py <= patch_radius) : (py += 1) {
                                        var px: i32 = -patch_radius;
                                        while (px <= patch_radius) : (px += 1) {
                                            const y1 = @max(0, @min(height - 1, y + py));
                                            const x1 = @max(0, @min(width - 1, x + px));
                                            const y2 = @max(0, @min(height - 1, ny + py));
                                            const x2 = @max(0, @min(width - 1, nx + px));

                                            const offset1 = @as(usize, @intCast(y1)) * src_stride +
                                                @as(usize, @intCast(x1)) * bytes_per_pixel + ch;
                                            const offset2 = @as(usize, @intCast(y2)) * src_stride +
                                                @as(usize, @intCast(x2)) * bytes_per_pixel + ch;

                                            if (offset1 < src.len and offset2 < src.len) {
                                                const v1: f32 = @floatFromInt(src[offset1]);
                                                const v2: f32 = @floatFromInt(src[offset2]);
                                                const diff = v1 - v2;
                                                patch_diff += diff * diff;
                                                patch_count += 1;
                                            }
                                        }
                                    }

                                    if (patch_count > 0) {
                                        patch_diff /= @floatFromInt(patch_count);
                                        const weight = @exp(-patch_diff / (h * h));

                                        const neighbor_offset = @as(usize, @intCast(ny)) * src_stride +
                                            @as(usize, @intCast(nx)) * bytes_per_pixel + ch;

                                        if (neighbor_offset < src.len) {
                                            const neighbor_val: f32 = @floatFromInt(src[neighbor_offset]);
                                            weighted_sum += neighbor_val * weight;
                                            weight_sum += weight;
                                        }
                                    }
                                }
                            }

                            const dst_offset = y_u * dst_stride + x_u * bytes_per_pixel + ch;
                            if (dst_offset < dst.len and weight_sum > 0) {
                                const filtered = weighted_sum / weight_sum;
                                dst[dst_offset] = @intFromFloat(@round(@max(0, @min(255, filtered))));
                            }
                        }
                    }
                }
            }
        }

        copyChromaPlanes(input, &output);
        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    // ========================================================================
    // Temporal Denoising
    // ========================================================================

    fn temporalFilter(self: *Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        const bytes_per_pixel = getBytesPerPixel(input.format);

        if (self.prev_frame) |prev| {
            if (input.data[0]) |src| {
                if (prev.data[0]) |prev_src| {
                    if (output.data[0]) |dst| {
                        const src_stride = input.linesize[0];
                        const prev_stride = prev.linesize[0];
                        const dst_stride = output.linesize[0];

                        // Temporal blend with motion detection
                        for (0..input.height) |y| {
                            for (0..input.width) |x| {
                                for (0..bytes_per_pixel) |ch| {
                                    const offset = y * src_stride + x * bytes_per_pixel + ch;
                                    const prev_offset = y * prev_stride + x * bytes_per_pixel + ch;
                                    const dst_offset = y * dst_stride + x * bytes_per_pixel + ch;

                                    if (offset < src.len and prev_offset < prev_src.len and dst_offset < dst.len) {
                                        const curr: i32 = src[offset];
                                        const prev_val: i32 = prev_src[prev_offset];
                                        const diff = @abs(curr - prev_val);

                                        // Motion-adaptive blending
                                        // High difference = motion = use current frame
                                        // Low difference = static = blend with previous
                                        const motion_threshold: i32 = 20;
                                        const blend: f32 = if (diff > motion_threshold)
                                            1.0 // Full current frame
                                        else
                                            0.5 + 0.5 * self.strength; // Blend

                                        const result = @as(f32, @floatFromInt(curr)) * blend +
                                            @as(f32, @floatFromInt(prev_val)) * (1.0 - blend);
                                        dst[dst_offset] = @intFromFloat(@round(@max(0, @min(255, result))));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // No previous frame, just copy
            if (input.data[0]) |src| {
                if (output.data[0]) |dst| {
                    const len = @min(src.len, dst.len);
                    @memcpy(dst[0..len], src[0..len]);
                }
            }
        }

        copyChromaPlanes(input, &output);

        // Store current frame for next iteration
        if (self.prev_frame) |*pf| {
            pf.deinit();
        }
        self.prev_frame = try copyFrame(self.allocator, input);

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
        else => 1,
    };
}

fn isYuvPlanar(format: PixelFormat) bool {
    return switch (format) {
        .yuv420p, .yuv422p, .yuv444p => true,
        else => false,
    };
}

fn copyChromaPlanes(input: *const VideoFrame, output: *VideoFrame) void {
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
}

fn copyFrame(allocator: std.mem.Allocator, input: *const VideoFrame) !VideoFrame {
    var output = try VideoFrame.init(allocator, input.width, input.height, input.format);
    errdefer output.deinit();

    for (0..4) |i| {
        if (input.data[i]) |src| {
            if (output.data[i]) |dst| {
                const len = @min(src.len, dst.len);
                @memcpy(dst[0..len], src[0..len]);
            }
        }
    }

    output.pts = input.pts;
    output.dts = input.dts;
    output.duration = input.duration;
    return output;
}

// ============================================================================
// Tests
// ============================================================================

test "DenoiseFilter initialization" {
    const allocator = std.testing.allocator;

    var filter = DenoiseFilter.init(allocator, .median, 0.5);
    defer filter.deinit();

    try std.testing.expectEqual(DenoiseMethod.median, filter.method);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), filter.strength, 0.001);
    try std.testing.expectEqual(@as(u8, 1), filter.radius);
}

test "DenoiseFilter with radius" {
    const allocator = std.testing.allocator;

    var filter = DenoiseFilter.initWithRadius(allocator, .bilateral, 0.8, 3);
    defer filter.deinit();

    try std.testing.expectEqual(DenoiseMethod.bilateral, filter.method);
    try std.testing.expectEqual(@as(u8, 3), filter.radius);

    // Test clamping
    var filter2 = DenoiseFilter.initWithRadius(allocator, .nlm, 1.5, 10);
    defer filter2.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), filter2.strength, 0.001);
    try std.testing.expectEqual(@as(u8, 5), filter2.radius);
}

test "DenoiseMethod enum" {
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(DenoiseMethod).@"enum".fields.len);
}
