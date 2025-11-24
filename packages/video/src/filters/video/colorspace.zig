// Home Video Library - Color Space Conversion
// YUV <-> RGB conversion with various color space standards

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const VideoFrame = frame.VideoFrame;
const PixelFormat = types.PixelFormat;

// ============================================================================
// Color Space Standards
// ============================================================================

pub const ColorStandard = enum {
    /// ITU-R BT.601 (SD video)
    bt601,
    /// ITU-R BT.709 (HD video)
    bt709,
    /// ITU-R BT.2020 (UHD/HDR video)
    bt2020,
    /// JPEG/JFIF (full range)
    jpeg,
};

// ============================================================================
// Conversion Coefficients
// ============================================================================

const Coefficients = struct {
    kr: f32, // Red coefficient
    kg: f32, // Green coefficient (computed as 1 - kr - kb)
    kb: f32, // Blue coefficient

    pub fn fromStandard(standard: ColorStandard) Coefficients {
        return switch (standard) {
            .bt601 => .{ .kr = 0.299, .kg = 0.587, .kb = 0.114 },
            .bt709 => .{ .kr = 0.2126, .kg = 0.7152, .kb = 0.0722 },
            .bt2020 => .{ .kr = 0.2627, .kg = 0.6780, .kb = 0.0593 },
            .jpeg => .{ .kr = 0.299, .kg = 0.587, .kb = 0.114 },
        };
    }
};

// ============================================================================
// Color Space Converter
// ============================================================================

pub const ColorSpaceConverter = struct {
    source_format: PixelFormat,
    target_format: PixelFormat,
    standard: ColorStandard,
    full_range: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        source_format: PixelFormat,
        target_format: PixelFormat,
        standard: ColorStandard,
    ) Self {
        return .{
            .source_format = source_format,
            .target_format = target_format,
            .standard = standard,
            .full_range = standard == .jpeg,
            .allocator = allocator,
        };
    }

    /// Convert a video frame to a different color space
    pub fn convert(self: *const Self, input: *const VideoFrame) !VideoFrame {
        if (input.format == self.target_format) {
            return try input.clone(self.allocator);
        }

        // Determine conversion direction
        const is_yuv_to_rgb = isYuvFormat(self.source_format) and isRgbFormat(self.target_format);
        const is_rgb_to_yuv = isRgbFormat(self.source_format) and isYuvFormat(self.target_format);

        if (is_yuv_to_rgb) {
            return try self.yuvToRgb(input);
        } else if (is_rgb_to_yuv) {
            return try self.rgbToYuv(input);
        }

        return VideoError.UnsupportedColorConversion;
    }

    fn yuvToRgb(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            self.target_format,
        );
        errdefer output.deinit();

        const coef = Coefficients.fromStandard(self.standard);

        // Get planes
        const y_plane = input.data[0] orelse return VideoError.CorruptFrame;
        const u_plane = input.data[1] orelse return VideoError.CorruptFrame;
        const v_plane = input.data[2] orelse return VideoError.CorruptFrame;
        const out_plane = output.data[0] orelse return VideoError.CorruptFrame;

        const y_stride = input.linesize[0];
        const u_stride = input.linesize[1];
        const v_stride = input.linesize[2];
        const out_stride = output.linesize[0];

        const bytes_per_pixel: usize = switch (self.target_format) {
            .rgba32, .bgra32, .argb32, .abgr32 => 4,
            else => 3,
        };

        const is_bgr = self.target_format == .bgr24 or self.target_format == .bgra32;
        const chroma_subsample_x = getChromaSubsampleX(input.format);
        const chroma_subsample_y = getChromaSubsampleY(input.format);

        for (0..input.height) |y| {
            const chroma_y = y / chroma_subsample_y;

            for (0..input.width) |x| {
                const chroma_x = x / chroma_subsample_x;

                // Get YUV values
                const y_val = @as(f32, @floatFromInt(y_plane[y * y_stride + x]));
                const u_val = @as(f32, @floatFromInt(u_plane[chroma_y * u_stride + chroma_x])) - 128;
                const v_val = @as(f32, @floatFromInt(v_plane[chroma_y * v_stride + chroma_x])) - 128;

                // Convert to RGB
                const y_norm = if (self.full_range) y_val else (y_val - 16) * 255.0 / 219.0;

                const r = y_norm + (2.0 * (1.0 - coef.kr)) * v_val;
                const g = y_norm - (2.0 * coef.kb * (1.0 - coef.kb) / coef.kg) * u_val -
                    (2.0 * coef.kr * (1.0 - coef.kr) / coef.kg) * v_val;
                const b = y_norm + (2.0 * (1.0 - coef.kb)) * u_val;

                // Clamp and write
                const out_offset = y * out_stride + x * bytes_per_pixel;

                if (is_bgr) {
                    out_plane[out_offset] = clampU8(b);
                    out_plane[out_offset + 1] = clampU8(g);
                    out_plane[out_offset + 2] = clampU8(r);
                } else {
                    out_plane[out_offset] = clampU8(r);
                    out_plane[out_offset + 1] = clampU8(g);
                    out_plane[out_offset + 2] = clampU8(b);
                }

                if (bytes_per_pixel == 4) {
                    out_plane[out_offset + 3] = 255; // Full alpha
                }
            }
        }

        output.pts = input.pts;
        output.dts = input.dts;
        output.duration = input.duration;
        return output;
    }

    fn rgbToYuv(self: *const Self, input: *const VideoFrame) !VideoFrame {
        var output = try VideoFrame.init(
            self.allocator,
            input.width,
            input.height,
            self.target_format,
        );
        errdefer output.deinit();

        const coef = Coefficients.fromStandard(self.standard);

        const in_plane = input.data[0] orelse return VideoError.CorruptFrame;
        const y_plane = output.data[0] orelse return VideoError.CorruptFrame;
        const u_plane = output.data[1] orelse return VideoError.CorruptFrame;
        const v_plane = output.data[2] orelse return VideoError.CorruptFrame;

        const in_stride = input.linesize[0];
        const y_stride = output.linesize[0];
        const u_stride = output.linesize[1];
        const v_stride = output.linesize[2];

        const bytes_per_pixel: usize = switch (input.format) {
            .rgba32, .bgra32, .argb32, .abgr32 => 4,
            else => 3,
        };

        const is_bgr = input.format == .bgr24 or input.format == .bgra32;
        const chroma_subsample_x = getChromaSubsampleX(self.target_format);
        const chroma_subsample_y = getChromaSubsampleY(self.target_format);

        const chroma_width = input.width / chroma_subsample_x;
        const chroma_height = input.height / chroma_subsample_y;

        // Initialize U/V accumulators for subsampling
        var u_accum = try self.allocator.alloc(f32, chroma_width * chroma_height);
        defer self.allocator.free(u_accum);
        var v_accum = try self.allocator.alloc(f32, chroma_width * chroma_height);
        defer self.allocator.free(v_accum);
        var count = try self.allocator.alloc(u32, chroma_width * chroma_height);
        defer self.allocator.free(count);

        @memset(u_accum, 0);
        @memset(v_accum, 0);
        @memset(count, 0);

        // First pass: compute Y and accumulate U/V
        for (0..input.height) |y| {
            for (0..input.width) |x| {
                const in_offset = y * in_stride + x * bytes_per_pixel;

                const r: f32 = @floatFromInt(in_plane[in_offset + if (is_bgr) 2 else 0]);
                const g: f32 = @floatFromInt(in_plane[in_offset + 1]);
                const b: f32 = @floatFromInt(in_plane[in_offset + if (is_bgr) 0 else 2]);

                // Compute Y
                const y_val = coef.kr * r + coef.kg * g + coef.kb * b;
                const y_out = if (self.full_range) y_val else 16 + (219.0 / 255.0) * y_val;
                y_plane[y * y_stride + x] = clampU8(y_out);

                // Compute Cb (U) and Cr (V)
                const cb = (b - y_val) / (2.0 * (1.0 - coef.kb));
                const cr = (r - y_val) / (2.0 * (1.0 - coef.kr));

                // Accumulate for chroma subsampling
                const chroma_x = x / chroma_subsample_x;
                const chroma_y = y / chroma_subsample_y;
                const chroma_idx = chroma_y * chroma_width + chroma_x;

                if (chroma_idx < u_accum.len) {
                    u_accum[chroma_idx] += cb;
                    v_accum[chroma_idx] += cr;
                    count[chroma_idx] += 1;
                }
            }
        }

        // Second pass: write averaged U/V
        for (0..chroma_height) |cy| {
            for (0..chroma_width) |cx| {
                const idx = cy * chroma_width + cx;
                const n = @as(f32, @floatFromInt(count[idx]));

                if (n > 0) {
                    const u_avg = u_accum[idx] / n + 128;
                    const v_avg = v_accum[idx] / n + 128;

                    u_plane[cy * u_stride + cx] = clampU8(u_avg);
                    v_plane[cy * v_stride + cx] = clampU8(v_avg);
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
// Convenience Functions
// ============================================================================

/// Convert YUV420P to RGB24
pub fn yuv420pToRgb24(allocator: std.mem.Allocator, input: *const VideoFrame) !VideoFrame {
    const converter = ColorSpaceConverter.init(allocator, .yuv420p, .rgb24, .bt709);
    return try converter.convert(input);
}

/// Convert RGB24 to YUV420P
pub fn rgb24ToYuv420p(allocator: std.mem.Allocator, input: *const VideoFrame) !VideoFrame {
    const converter = ColorSpaceConverter.init(allocator, .rgb24, .yuv420p, .bt709);
    return try converter.convert(input);
}

/// Convert YUV420P to RGBA32
pub fn yuv420pToRgba32(allocator: std.mem.Allocator, input: *const VideoFrame) !VideoFrame {
    const converter = ColorSpaceConverter.init(allocator, .yuv420p, .rgba32, .bt709);
    return try converter.convert(input);
}

// ============================================================================
// Helper Functions
// ============================================================================

fn isYuvFormat(format: PixelFormat) bool {
    return switch (format) {
        .yuv420p, .yuv422p, .yuv444p, .nv12, .nv21 => true,
        else => false,
    };
}

fn isRgbFormat(format: PixelFormat) bool {
    return switch (format) {
        .rgb24, .bgr24, .rgba32, .bgra32, .argb32, .abgr32 => true,
        else => false,
    };
}

fn getChromaSubsampleX(format: PixelFormat) usize {
    return switch (format) {
        .yuv420p, .yuv422p, .nv12, .nv21 => 2,
        else => 1,
    };
}

fn getChromaSubsampleY(format: PixelFormat) usize {
    return switch (format) {
        .yuv420p, .nv12, .nv21 => 2,
        else => 1,
    };
}

fn clampU8(val: f32) u8 {
    return @intFromFloat(@round(@max(0, @min(255, val))));
}

// ============================================================================
// Tests
// ============================================================================

test "ColorStandard coefficients" {
    const bt601 = Coefficients.fromStandard(.bt601);
    try std.testing.expectApproxEqAbs(@as(f32, 0.299), bt601.kr, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.114), bt601.kb, 0.001);

    const bt709 = Coefficients.fromStandard(.bt709);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2126), bt709.kr, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0722), bt709.kb, 0.001);
}

test "isYuvFormat" {
    try std.testing.expect(isYuvFormat(.yuv420p));
    try std.testing.expect(isYuvFormat(.yuv422p));
    try std.testing.expect(!isYuvFormat(.rgb24));
    try std.testing.expect(!isYuvFormat(.rgba32));
}

test "isRgbFormat" {
    try std.testing.expect(isRgbFormat(.rgb24));
    try std.testing.expect(isRgbFormat(.rgba32));
    try std.testing.expect(!isRgbFormat(.yuv420p));
}

test "getChromaSubsample" {
    try std.testing.expectEqual(@as(usize, 2), getChromaSubsampleX(.yuv420p));
    try std.testing.expectEqual(@as(usize, 2), getChromaSubsampleY(.yuv420p));
    try std.testing.expectEqual(@as(usize, 2), getChromaSubsampleX(.yuv422p));
    try std.testing.expectEqual(@as(usize, 1), getChromaSubsampleY(.yuv422p));
}

test "clampU8" {
    try std.testing.expectEqual(@as(u8, 0), clampU8(-10));
    try std.testing.expectEqual(@as(u8, 128), clampU8(128));
    try std.testing.expectEqual(@as(u8, 255), clampU8(300));
}

test "ColorSpaceConverter initialization" {
    const allocator = std.testing.allocator;
    const converter = ColorSpaceConverter.init(allocator, .yuv420p, .rgb24, .bt709);

    try std.testing.expectEqual(PixelFormat.yuv420p, converter.source_format);
    try std.testing.expectEqual(PixelFormat.rgb24, converter.target_format);
    try std.testing.expectEqual(ColorStandard.bt709, converter.standard);
}
