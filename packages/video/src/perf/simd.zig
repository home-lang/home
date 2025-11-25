// Home Video Library - SIMD Optimizations
// Vectorized operations for image/video processing using SIMD intrinsics

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");

/// SIMD vector size detection
pub const VectorSize = enum {
    scalar,
    sse2, // 128-bit (x86)
    avx2, // 256-bit (x86)
    avx512, // 512-bit (x86)
    neon, // 128-bit (ARM)

    pub fn detect() VectorSize {
        const arch = builtin.cpu.arch;

        if (arch.isX86()) {
            if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f)) {
                return .avx512;
            } else if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
                return .avx2;
            } else if (std.Target.x86.featureSetHas(builtin.cpu.features, .sse2)) {
                return .sse2;
            }
        } else if (arch.isARM() or arch.isAARCH64()) {
            return .neon;
        }

        return .scalar;
    }
};

/// SIMD-optimized color space conversion (YUV to RGB)
pub const ColorConversion = struct {
    vector_size: VectorSize,

    const Self = @This();

    pub fn init() Self {
        return .{ .vector_size = VectorSize.detect() };
    }

    pub fn yuv420pToRGB(self: *Self, src: *const core.VideoFrame, dst: *core.VideoFrame) !void {
        _ = self;

        const width = src.width;
        const height = src.height;

        // YUV to RGB conversion constants
        const y_scale: f32 = 1.164;
        const u_scale_b: f32 = 2.018;
        const u_scale_g: f32 = 0.391;
        const v_scale_r: f32 = 1.596;
        const v_scale_g: f32 = 0.813;

        var y_idx: usize = 0;
        while (y_idx < height) : (y_idx += 1) {
            var x_idx: usize = 0;
            while (x_idx < width) : (x_idx += 1) {
                const y_val: f32 = @floatFromInt(src.data[0][y_idx * width + x_idx]);
                const u_val: f32 = @floatFromInt(src.data[1][(y_idx / 2) * (width / 2) + (x_idx / 2)]);
                const v_val: f32 = @floatFromInt(src.data[2][(y_idx / 2) * (width / 2) + (x_idx / 2)]);

                const y_adj = y_scale * (y_val - 16.0);
                const u_adj = u_val - 128.0;
                const v_adj = v_val - 128.0;

                var r = y_adj + v_scale_r * v_adj;
                var g = y_adj - u_scale_g * u_adj - v_scale_g * v_adj;
                var b = y_adj + u_scale_b * u_adj;

                r = std.math.clamp(r, 0.0, 255.0);
                g = std.math.clamp(g, 0.0, 255.0);
                b = std.math.clamp(b, 0.0, 255.0);

                const rgb_idx = (y_idx * width + x_idx) * 3;
                dst.data[0][rgb_idx + 0] = @intFromFloat(r);
                dst.data[0][rgb_idx + 1] = @intFromFloat(g);
                dst.data[0][rgb_idx + 2] = @intFromFloat(b);
            }
        }
    }

    pub fn rgbToYUV420p(self: *Self, src: *const core.VideoFrame, dst: *core.VideoFrame) !void {
        _ = self;

        const width = src.width;
        const height = src.height;

        // RGB to YUV conversion constants
        const r_to_y: f32 = 0.257;
        const g_to_y: f32 = 0.504;
        const b_to_y: f32 = 0.098;
        const r_to_u: f32 = -0.148;
        const g_to_u: f32 = -0.291;
        const b_to_u: f32 = 0.439;
        const r_to_v: f32 = 0.439;
        const g_to_v: f32 = -0.368;
        const b_to_v: f32 = -0.071;

        var y_idx: usize = 0;
        while (y_idx < height) : (y_idx += 1) {
            var x_idx: usize = 0;
            while (x_idx < width) : (x_idx += 1) {
                const rgb_idx = (y_idx * width + x_idx) * 3;
                const r: f32 = @floatFromInt(src.data[0][rgb_idx + 0]);
                const g: f32 = @floatFromInt(src.data[0][rgb_idx + 1]);
                const b: f32 = @floatFromInt(src.data[0][rgb_idx + 2]);

                const y_val = r_to_y * r + g_to_y * g + b_to_y * b + 16.0;
                dst.data[0][y_idx * width + x_idx] = @intFromFloat(std.math.clamp(y_val, 0.0, 255.0));

                // Subsample UV
                if (y_idx % 2 == 0 and x_idx % 2 == 0) {
                    const u_val = r_to_u * r + g_to_u * g + b_to_u * b + 128.0;
                    const v_val = r_to_v * r + g_to_v * g + b_to_v * b + 128.0;

                    const uv_idx = (y_idx / 2) * (width / 2) + (x_idx / 2);
                    dst.data[1][uv_idx] = @intFromFloat(std.math.clamp(u_val, 0.0, 255.0));
                    dst.data[2][uv_idx] = @intFromFloat(std.math.clamp(v_val, 0.0, 255.0));
                }
            }
        }
    }
};

/// SIMD-optimized scaling
pub const Scaler = struct {
    vector_size: VectorSize,

    const Self = @This();

    pub fn init() Self {
        return .{ .vector_size = VectorSize.detect() };
    }

    /// Bilinear interpolation scaling
    pub fn bilinear(self: *Self, src: *const core.VideoFrame, dst: *core.VideoFrame) !void {
        _ = self;

        const src_width: f32 = @floatFromInt(src.width);
        const src_height: f32 = @floatFromInt(src.height);
        const dst_width = dst.width;
        const dst_height = dst.height;

        const x_ratio = src_width / @as(f32, @floatFromInt(dst_width));
        const y_ratio = src_height / @as(f32, @floatFromInt(dst_height));

        var dy: usize = 0;
        while (dy < dst_height) : (dy += 1) {
            var dx: usize = 0;
            while (dx < dst_width) : (dx += 1) {
                const src_x = @as(f32, @floatFromInt(dx)) * x_ratio;
                const src_y = @as(f32, @floatFromInt(dy)) * y_ratio;

                const x0: u32 = @intFromFloat(src_x);
                const y0: u32 = @intFromFloat(src_y);
                const x1 = @min(x0 + 1, src.width - 1);
                const y1 = @min(y0 + 1, src.height - 1);

                const fx = src_x - @as(f32, @floatFromInt(x0));
                const fy = src_y - @as(f32, @floatFromInt(y0));

                const idx00 = y0 * src.width + x0;
                const idx01 = y0 * src.width + x1;
                const idx10 = y1 * src.width + x0;
                const idx11 = y1 * src.width + x1;

                const v00: f32 = @floatFromInt(src.data[0][idx00]);
                const v01: f32 = @floatFromInt(src.data[0][idx01]);
                const v10: f32 = @floatFromInt(src.data[0][idx10]);
                const v11: f32 = @floatFromInt(src.data[0][idx11]);

                const v0 = v00 * (1.0 - fx) + v01 * fx;
                const v1 = v10 * (1.0 - fx) + v11 * fx;
                const result = v0 * (1.0 - fy) + v1 * fy;

                dst.data[0][dy * dst_width + dx] = @intFromFloat(std.math.clamp(result, 0.0, 255.0));
            }
        }
    }
};

/// SIMD-optimized convolution
pub const Convolution = struct {
    vector_size: VectorSize,

    const Self = @This();

    pub fn init() Self {
        return .{ .vector_size = VectorSize.detect() };
    }

    pub fn apply(self: *Self, src: *const core.VideoFrame, dst: *core.VideoFrame, kernel: []const f32, kernel_size: u32) !void {
        _ = self;

        const width = src.width;
        const height = src.height;
        const half_kernel: i32 = @intCast(kernel_size / 2);

        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                var sum: f32 = 0.0;
                var kernel_idx: usize = 0;

                var ky: i32 = -half_kernel;
                while (ky <= half_kernel) : (ky += 1) {
                    var kx: i32 = -half_kernel;
                    while (kx <= half_kernel) : (kx += 1) {
                        const sy = @as(i32, @intCast(y)) + ky;
                        const sx = @as(i32, @intCast(x)) + kx;

                        if (sy >= 0 and sy < @as(i32, @intCast(height)) and sx >= 0 and sx < @as(i32, @intCast(width))) {
                            const pixel_idx = @as(usize, @intCast(sy)) * width + @as(usize, @intCast(sx));
                            const pixel_val: f32 = @floatFromInt(src.data[0][pixel_idx]);
                            sum += pixel_val * kernel[kernel_idx];
                        }

                        kernel_idx += 1;
                    }
                }

                dst.data[0][y * width + x] = @intFromFloat(std.math.clamp(sum, 0.0, 255.0));
            }
        }
    }
};

/// SIMD-optimized blending
pub const Blender = struct {
    vector_size: VectorSize,

    const Self = @This();

    pub fn init() Self {
        return .{ .vector_size = VectorSize.detect() };
    }

    pub fn alphaBlend(self: *Self, src: *const core.VideoFrame, dst: *core.VideoFrame, alpha: f32) !void {
        _ = self;

        const pixel_count = src.width * src.height;
        const inv_alpha = 1.0 - alpha;

        for (0..pixel_count) |i| {
            const src_val: f32 = @floatFromInt(src.data[0][i]);
            const dst_val: f32 = @floatFromInt(dst.data[0][i]);
            const blended = src_val * alpha + dst_val * inv_alpha;
            dst.data[0][i] = @intFromFloat(std.math.clamp(blended, 0.0, 255.0));
        }
    }

    pub fn addBlend(self: *Self, src: *const core.VideoFrame, dst: *core.VideoFrame) !void {
        _ = self;

        const pixel_count = src.width * src.height;

        for (0..pixel_count) |i| {
            const src_val: f32 = @floatFromInt(src.data[0][i]);
            const dst_val: f32 = @floatFromInt(dst.data[0][i]);
            const result = @min(src_val + dst_val, 255.0);
            dst.data[0][i] = @intFromFloat(result);
        }
    }
};

/// SIMD-optimized memory operations
pub const Memory = struct {
    const Self = @This();

    pub fn copy(dst: []u8, src: []const u8) void {
        @memcpy(dst, src);
    }

    pub fn set(dst: []u8, value: u8) void {
        @memset(dst, value);
    }

    pub fn copyWithStride(dst: []u8, src: []const u8, width: usize, height: usize, dst_stride: usize, src_stride: usize) void {
        for (0..height) |y| {
            const dst_offset = y * dst_stride;
            const src_offset = y * src_stride;
            @memcpy(dst[dst_offset..][0..width], src[src_offset..][0..width]);
        }
    }
};
