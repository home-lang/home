// Home Video Library - Color Adjustment Filters
// Brightness, contrast, saturation, and color manipulation

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const VideoFrame = frame.VideoFrame;
const PixelFormat = types.PixelFormat;

// ============================================================================
// Color Adjustment Parameters
// ============================================================================

pub const ColorAdjustment = struct {
    /// Brightness adjustment (-1.0 to 1.0, 0 = no change)
    brightness: f32 = 0,
    /// Contrast adjustment (0.0 to 3.0, 1.0 = no change)
    contrast: f32 = 1.0,
    /// Saturation adjustment (0.0 to 3.0, 1.0 = no change)
    saturation: f32 = 1.0,
    /// Gamma correction (0.1 to 3.0, 1.0 = no change)
    gamma: f32 = 1.0,
    /// Hue rotation in degrees (-180 to 180)
    hue: f32 = 0,

    pub fn isIdentity(self: *const ColorAdjustment) bool {
        return self.brightness == 0 and
            self.contrast == 1.0 and
            self.saturation == 1.0 and
            self.gamma == 1.0 and
            self.hue == 0;
    }
};

// ============================================================================
// Color Filter
// ============================================================================

pub const ColorFilter = struct {
    adjustment: ColorAdjustment,
    allocator: std.mem.Allocator,

    // Pre-computed lookup tables for performance
    lut: [256]u8,
    gamma_lut: [256]u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, adjustment: ColorAdjustment) Self {
        var filter = Self{
            .adjustment = adjustment,
            .allocator = allocator,
            .lut = undefined,
            .gamma_lut = undefined,
        };
        filter.buildLuts();
        return filter;
    }

    /// Create a brightness-only filter
    pub fn brightness(allocator: std.mem.Allocator, value: f32) Self {
        return init(allocator, .{ .brightness = value });
    }

    /// Create a contrast-only filter
    pub fn contrast(allocator: std.mem.Allocator, value: f32) Self {
        return init(allocator, .{ .contrast = value });
    }

    /// Create a saturation-only filter
    pub fn saturation(allocator: std.mem.Allocator, value: f32) Self {
        return init(allocator, .{ .saturation = value });
    }

    /// Create a gamma correction filter
    pub fn gamma(allocator: std.mem.Allocator, value: f32) Self {
        return init(allocator, .{ .gamma = value });
    }

    fn buildLuts(self: *Self) void {
        const adj = &self.adjustment;

        for (0..256) |i| {
            // Apply brightness and contrast
            var value = @as(f32, @floatFromInt(i));

            // Contrast (centered at 128)
            value = (value - 128) * adj.contrast + 128;

            // Brightness
            value += adj.brightness * 255;

            // Clamp
            value = @max(0, @min(255, value));

            self.lut[i] = @intFromFloat(@round(value));
        }

        // Build gamma LUT separately
        for (0..256) |i| {
            var value = @as(f32, @floatFromInt(i)) / 255.0;
            value = std.math.pow(f32, value, 1.0 / adj.gamma);
            value = @max(0, @min(1, value)) * 255;
            self.gamma_lut[i] = @intFromFloat(@round(value));
        }
    }

    /// Apply color adjustment to a video frame
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        if (self.adjustment.isIdentity()) {
            return try input.clone(self.allocator);
        }

        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        switch (input.format) {
            .rgb24, .bgr24 => try self.applyRgb(input, &output, 3),
            .rgba32, .bgra32, .argb32, .abgr32 => try self.applyRgb(input, &output, 4),
            .yuv420p, .yuv422p, .yuv444p => try self.applyYuv(input, &output),
            .gray8 => try self.applyGrayscale(input, &output),
            else => return VideoError.UnsupportedPixelFormat,
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn applyRgb(self: *const Self, input: *const VideoFrame, output: *VideoFrame, bytes_per_pixel: usize) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;
        const src_stride = input.linesize[0];
        const dst_stride = output.linesize[0];
        const adj = &self.adjustment;

        for (0..input.height) |y| {
            for (0..input.width) |x| {
                const src_offset = y * src_stride + x * bytes_per_pixel;
                const dst_offset = y * dst_stride + x * bytes_per_pixel;

                if (src_offset + bytes_per_pixel > src.len or
                    dst_offset + bytes_per_pixel > dst.len) continue;

                // Get RGB values
                const r = src[src_offset];
                const g = src[src_offset + 1];
                const b = src[src_offset + 2];

                // Apply brightness/contrast using LUT
                var r_f = @as(f32, @floatFromInt(self.lut[r]));
                var g_f = @as(f32, @floatFromInt(self.lut[g]));
                var b_f = @as(f32, @floatFromInt(self.lut[b]));

                // Apply saturation
                if (adj.saturation != 1.0) {
                    const luminance = 0.299 * r_f + 0.587 * g_f + 0.114 * b_f;
                    r_f = luminance + (r_f - luminance) * adj.saturation;
                    g_f = luminance + (g_f - luminance) * adj.saturation;
                    b_f = luminance + (b_f - luminance) * adj.saturation;
                }

                // Apply gamma
                if (adj.gamma != 1.0) {
                    r_f = @floatFromInt(self.gamma_lut[@intFromFloat(@round(@max(0, @min(255, r_f))))]);
                    g_f = @floatFromInt(self.gamma_lut[@intFromFloat(@round(@max(0, @min(255, g_f))))]);
                    b_f = @floatFromInt(self.gamma_lut[@intFromFloat(@round(@max(0, @min(255, b_f))))]);
                }

                // Clamp and write
                dst[dst_offset] = @intFromFloat(@round(@max(0, @min(255, r_f))));
                dst[dst_offset + 1] = @intFromFloat(@round(@max(0, @min(255, g_f))));
                dst[dst_offset + 2] = @intFromFloat(@round(@max(0, @min(255, b_f))));

                // Copy alpha if present
                if (bytes_per_pixel == 4) {
                    dst[dst_offset + 3] = src[src_offset + 3];
                }
            }
        }
    }

    fn applyYuv(self: *const Self, input: *const VideoFrame, output: *VideoFrame) !void {
        const adj = &self.adjustment;

        // Apply brightness and contrast to Y plane
        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                for (0..src.len) |i| {
                    if (i >= dst.len) break;

                    // Apply LUT (brightness/contrast)
                    var value = @as(f32, @floatFromInt(self.lut[src[i]]));

                    // Apply gamma
                    if (adj.gamma != 1.0) {
                        value = @floatFromInt(self.gamma_lut[@intFromFloat(@round(@max(0, @min(255, value))))]);
                    }

                    dst[i] = @intFromFloat(@round(@max(0, @min(255, value))));
                }
            }
        }

        // Apply saturation to UV planes
        for (1..3) |plane_idx| {
            if (input.data[plane_idx]) |src| {
                if (output.data[plane_idx]) |dst| {
                    for (0..src.len) |i| {
                        if (i >= dst.len) break;

                        if (adj.saturation != 1.0) {
                            // UV values are centered at 128
                            const uv = @as(f32, @floatFromInt(src[i])) - 128;
                            const adjusted = uv * adj.saturation + 128;
                            dst[i] = @intFromFloat(@round(@max(0, @min(255, adjusted))));
                        } else {
                            dst[i] = src[i];
                        }
                    }
                }
            }
        }
    }

    fn applyGrayscale(self: *const Self, input: *const VideoFrame, output: *VideoFrame) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;
        const adj = &self.adjustment;

        for (0..src.len) |i| {
            if (i >= dst.len) break;

            var value = @as(f32, @floatFromInt(self.lut[src[i]]));

            if (adj.gamma != 1.0) {
                value = @floatFromInt(self.gamma_lut[@intFromFloat(@round(@max(0, @min(255, value))))]);
            }

            dst[i] = @intFromFloat(@round(@max(0, @min(255, value))));
        }
    }
};

// ============================================================================
// Invert Filter
// ============================================================================

pub const InvertFilter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        // Invert Y/RGB plane
        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const bytes_per_pixel = switch (input.format) {
                    .rgba32, .bgra32, .argb32, .abgr32 => 4,
                    .rgb24, .bgr24 => 3,
                    else => 1,
                };

                for (0..src.len) |i| {
                    if (i >= dst.len) break;

                    // Don't invert alpha channel
                    if (bytes_per_pixel == 4 and (i % 4) == 3) {
                        dst[i] = src[i];
                    } else {
                        dst[i] = 255 - src[i];
                    }
                }
            }
        }

        // Copy UV planes unchanged (invert only luminance)
        for (1..3) |plane_idx| {
            if (input.data[plane_idx]) |src| {
                if (output.data[plane_idx]) |dst| {
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
};

// ============================================================================
// Grayscale Filter
// ============================================================================

pub const GrayscaleFilter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Convert RGB to grayscale
    pub fn apply(self: *const Self, input: *const VideoFrame) !VideoFrame {
        // YUV formats are already "grayscale" in Y plane
        if (input.format == .yuv420p or input.format == .yuv422p or input.format == .yuv444p) {
            return try self.desaturateYuv(input);
        }

        if (input.format != .rgb24 and input.format != .rgba32 and
            input.format != .bgr24 and input.format != .bgra32)
        {
            return VideoError.UnsupportedPixelFormat;
        }

        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const bytes_per_pixel: usize = switch (input.format) {
                    .rgba32, .bgra32, .argb32, .abgr32 => 4,
                    else => 3,
                };

                const is_bgr = input.format == .bgr24 or input.format == .bgra32;

                var i: usize = 0;
                while (i + bytes_per_pixel <= src.len and i + bytes_per_pixel <= dst.len) {
                    const r: f32 = @floatFromInt(src[i + if (is_bgr) 2 else 0]);
                    const g: f32 = @floatFromInt(src[i + 1]);
                    const b: f32 = @floatFromInt(src[i + if (is_bgr) 0 else 2]);

                    // ITU-R BT.601 luminance weights
                    const gray: u8 = @intFromFloat(@round(0.299 * r + 0.587 * g + 0.114 * b));

                    dst[i] = gray;
                    dst[i + 1] = gray;
                    dst[i + 2] = gray;

                    if (bytes_per_pixel == 4) {
                        dst[i + 3] = src[i + 3];
                    }

                    i += bytes_per_pixel;
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn desaturateYuv(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            input.format,
        );
        errdefer output.deinit();

        // Copy Y plane
        if (input.data[0]) |src| {
            if (output.data[0]) |dst| {
                const len = @min(src.len, dst.len);
                @memcpy(dst[0..len], src[0..len]);
            }
        }

        // Set UV planes to neutral (128)
        for (1..3) |plane_idx| {
            if (output.data[plane_idx]) |dst| {
                @memset(dst, 128);
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ColorAdjustment identity" {
    const adj = ColorAdjustment{};
    try std.testing.expect(adj.isIdentity());

    const adj2 = ColorAdjustment{ .brightness = 0.1 };
    try std.testing.expect(!adj2.isIdentity());
}

test "ColorFilter initialization" {
    const allocator = std.testing.allocator;
    const filter = ColorFilter.init(allocator, .{ .brightness = 0.5, .contrast = 1.2 });

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), filter.adjustment.brightness, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), filter.adjustment.contrast, 0.001);
}

test "ColorFilter convenience constructors" {
    const allocator = std.testing.allocator;

    const bright = ColorFilter.brightness(allocator, 0.3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), bright.adjustment.brightness, 0.001);

    const contr = ColorFilter.contrast(allocator, 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), contr.adjustment.contrast, 0.001);

    const sat = ColorFilter.saturation(allocator, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sat.adjustment.saturation, 0.001);
}

test "InvertFilter initialization" {
    const allocator = std.testing.allocator;
    _ = InvertFilter.init(allocator);
}

test "GrayscaleFilter initialization" {
    const allocator = std.testing.allocator;
    _ = GrayscaleFilter.init(allocator);
}
