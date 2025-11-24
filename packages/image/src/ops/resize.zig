// Image Resizing Operations
// Implements various resampling algorithms

const std = @import("std");
const image = @import("../image.zig");
const Image = image.Image;
const Color = image.Color;
const PixelFormat = image.PixelFormat;

// ============================================================================
// Resize Algorithms
// ============================================================================

pub const ResizeAlgorithm = enum {
    nearest, // Nearest neighbor - fast, pixelated
    bilinear, // Bilinear interpolation - smooth, fast
    bicubic, // Bicubic interpolation - smoother, slower
    lanczos2, // Lanczos with a=2 - sharp, good for downscaling
    lanczos3, // Lanczos with a=3 - sharper, best quality
};

pub const FitMode = enum {
    fill, // Stretch to fill exactly (may distort aspect ratio)
    contain, // Fit within bounds, maintaining aspect ratio (may have letterboxing)
    cover, // Fill bounds, maintaining aspect ratio (may crop)
    inside, // Like contain, but never upscale
    outside, // Like cover, but never downscale
};

// ============================================================================
// Main Resize Function
// ============================================================================

pub fn resize(img: *const Image, new_width: u32, new_height: u32, algorithm: ResizeAlgorithm) !Image {
    if (new_width == 0 or new_height == 0) {
        return error.InvalidDimensions;
    }

    if (new_width == img.width and new_height == img.height) {
        return img.clone();
    }

    var result = try Image.init(img.allocator, new_width, new_height, img.format);
    errdefer result.deinit();

    switch (algorithm) {
        .nearest => resizeNearest(img, &result),
        .bilinear => resizeBilinear(img, &result),
        .bicubic => resizeBicubic(img, &result),
        .lanczos2 => resizeLanczos(img, &result, 2),
        .lanczos3 => resizeLanczos(img, &result, 3),
    }

    return result;
}

pub fn resizeWithFit(img: *const Image, max_width: u32, max_height: u32, mode: FitMode, algorithm: ResizeAlgorithm, background: Color) !Image {
    const target = calculateTargetSize(img.width, img.height, max_width, max_height, mode);

    if (target.width == img.width and target.height == img.height) {
        return img.clone();
    }

    // First resize
    var resized = try resize(img, target.width, target.height, algorithm);

    // If contain or inside mode, add padding
    if ((mode == .contain or mode == .inside) and (target.width < max_width or target.height < max_height)) {
        defer resized.deinit();

        var final = try Image.init(img.allocator, max_width, max_height, img.format);
        errdefer final.deinit();

        // Fill with background
        var y: u32 = 0;
        while (y < max_height) : (y += 1) {
            var x: u32 = 0;
            while (x < max_width) : (x += 1) {
                final.setPixel(x, y, background);
            }
        }

        // Center the resized image
        const offset_x = (max_width - target.width) / 2;
        const offset_y = (max_height - target.height) / 2;

        y = 0;
        while (y < target.height) : (y += 1) {
            var x: u32 = 0;
            while (x < target.width) : (x += 1) {
                if (resized.getPixel(x, y)) |color| {
                    final.setPixel(offset_x + x, offset_y + y, color);
                }
            }
        }

        return final;
    }

    return resized;
}

fn calculateTargetSize(src_width: u32, src_height: u32, max_width: u32, max_height: u32, mode: FitMode) struct { width: u32, height: u32 } {
    const src_ratio = @as(f64, @floatFromInt(src_width)) / @as(f64, @floatFromInt(src_height));
    const target_ratio = @as(f64, @floatFromInt(max_width)) / @as(f64, @floatFromInt(max_height));

    return switch (mode) {
        .fill => .{ .width = max_width, .height = max_height },
        .contain, .inside => {
            if (mode == .inside and src_width <= max_width and src_height <= max_height) {
                return .{ .width = src_width, .height = src_height };
            }

            if (src_ratio > target_ratio) {
                // Width constrained
                return .{
                    .width = max_width,
                    .height = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(max_width)) / src_ratio))),
                };
            } else {
                // Height constrained
                return .{
                    .width = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(max_height)) * src_ratio))),
                    .height = max_height,
                };
            }
        },
        .cover, .outside => {
            if (mode == .outside and src_width >= max_width and src_height >= max_height) {
                return .{ .width = src_width, .height = src_height };
            }

            if (src_ratio > target_ratio) {
                // Height constrained
                return .{
                    .width = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(max_height)) * src_ratio))),
                    .height = max_height,
                };
            } else {
                // Width constrained
                return .{
                    .width = max_width,
                    .height = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(max_width)) / src_ratio))),
                };
            }
        },
    };
}

// ============================================================================
// Nearest Neighbor Resampling
// ============================================================================

fn resizeNearest(src: *const Image, dst: *Image) void {
    const scale_x = @as(f64, @floatFromInt(src.width)) / @as(f64, @floatFromInt(dst.width));
    const scale_y = @as(f64, @floatFromInt(src.height)) / @as(f64, @floatFromInt(dst.height));

    var y: u32 = 0;
    while (y < dst.height) : (y += 1) {
        const src_y: u32 = @intFromFloat(@as(f64, @floatFromInt(y)) * scale_y);

        var x: u32 = 0;
        while (x < dst.width) : (x += 1) {
            const src_x: u32 = @intFromFloat(@as(f64, @floatFromInt(x)) * scale_x);

            if (src.getPixel(@min(src_x, src.width - 1), @min(src_y, src.height - 1))) |color| {
                dst.setPixel(x, y, color);
            }
        }
    }
}

// ============================================================================
// Bilinear Interpolation
// ============================================================================

fn resizeBilinear(src: *const Image, dst: *Image) void {
    const scale_x = @as(f64, @floatFromInt(src.width - 1)) / @as(f64, @floatFromInt(@max(1, dst.width - 1)));
    const scale_y = @as(f64, @floatFromInt(src.height - 1)) / @as(f64, @floatFromInt(@max(1, dst.height - 1)));

    var y: u32 = 0;
    while (y < dst.height) : (y += 1) {
        const src_y_f = @as(f64, @floatFromInt(y)) * scale_y;
        const src_y0: u32 = @intFromFloat(src_y_f);
        const src_y1: u32 = @min(src_y0 + 1, src.height - 1);
        const y_frac = src_y_f - @as(f64, @floatFromInt(src_y0));

        var x: u32 = 0;
        while (x < dst.width) : (x += 1) {
            const src_x_f = @as(f64, @floatFromInt(x)) * scale_x;
            const src_x0: u32 = @intFromFloat(src_x_f);
            const src_x1: u32 = @min(src_x0 + 1, src.width - 1);
            const x_frac = src_x_f - @as(f64, @floatFromInt(src_x0));

            // Get four surrounding pixels
            const c00 = src.getPixel(src_x0, src_y0) orelse Color.BLACK;
            const c10 = src.getPixel(src_x1, src_y0) orelse Color.BLACK;
            const c01 = src.getPixel(src_x0, src_y1) orelse Color.BLACK;
            const c11 = src.getPixel(src_x1, src_y1) orelse Color.BLACK;

            // Bilinear interpolation
            const r = bilinearInterp(c00.r, c10.r, c01.r, c11.r, x_frac, y_frac);
            const g = bilinearInterp(c00.g, c10.g, c01.g, c11.g, x_frac, y_frac);
            const b = bilinearInterp(c00.b, c10.b, c01.b, c11.b, x_frac, y_frac);
            const a = bilinearInterp(c00.a, c10.a, c01.a, c11.a, x_frac, y_frac);

            dst.setPixel(x, y, Color{ .r = r, .g = g, .b = b, .a = a });
        }
    }
}

fn bilinearInterp(c00: u8, c10: u8, c01: u8, c11: u8, x_frac: f64, y_frac: f64) u8 {
    const top = @as(f64, @floatFromInt(c00)) * (1 - x_frac) + @as(f64, @floatFromInt(c10)) * x_frac;
    const bottom = @as(f64, @floatFromInt(c01)) * (1 - x_frac) + @as(f64, @floatFromInt(c11)) * x_frac;
    const result = top * (1 - y_frac) + bottom * y_frac;
    return @intFromFloat(std.math.clamp(result, 0, 255));
}

// ============================================================================
// Bicubic Interpolation
// ============================================================================

fn resizeBicubic(src: *const Image, dst: *Image) void {
    const scale_x = @as(f64, @floatFromInt(src.width)) / @as(f64, @floatFromInt(dst.width));
    const scale_y = @as(f64, @floatFromInt(src.height)) / @as(f64, @floatFromInt(dst.height));

    var y: u32 = 0;
    while (y < dst.height) : (y += 1) {
        const src_y_f = (@as(f64, @floatFromInt(y)) + 0.5) * scale_y - 0.5;
        const src_y: i32 = @intFromFloat(@floor(src_y_f));
        const y_frac = src_y_f - @as(f64, @floatFromInt(src_y));

        var x: u32 = 0;
        while (x < dst.width) : (x += 1) {
            const src_x_f = (@as(f64, @floatFromInt(x)) + 0.5) * scale_x - 0.5;
            const src_x: i32 = @intFromFloat(@floor(src_x_f));
            const x_frac = src_x_f - @as(f64, @floatFromInt(src_x));

            var r: f64 = 0;
            var g: f64 = 0;
            var b: f64 = 0;
            var a: f64 = 0;

            // Sample 4x4 neighborhood
            var j: i32 = -1;
            while (j <= 2) : (j += 1) {
                const weight_y = cubicWeight(y_frac - @as(f64, @floatFromInt(j)));
                const py = std.math.clamp(src_y + j, 0, @as(i32, @intCast(src.height - 1)));

                var i: i32 = -1;
                while (i <= 2) : (i += 1) {
                    const weight_x = cubicWeight(x_frac - @as(f64, @floatFromInt(i)));
                    const px = std.math.clamp(src_x + i, 0, @as(i32, @intCast(src.width - 1)));

                    const color = src.getPixel(@intCast(px), @intCast(py)) orelse Color.BLACK;
                    const weight = weight_x * weight_y;

                    r += @as(f64, @floatFromInt(color.r)) * weight;
                    g += @as(f64, @floatFromInt(color.g)) * weight;
                    b += @as(f64, @floatFromInt(color.b)) * weight;
                    a += @as(f64, @floatFromInt(color.a)) * weight;
                }
            }

            dst.setPixel(x, y, Color{
                .r = @intFromFloat(std.math.clamp(r, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b, 0, 255)),
                .a = @intFromFloat(std.math.clamp(a, 0, 255)),
            });
        }
    }
}

fn cubicWeight(x: f64) f64 {
    // Mitchell-Netravali cubic (B=1/3, C=1/3)
    const B: f64 = 1.0 / 3.0;
    const C: f64 = 1.0 / 3.0;

    const ax = @abs(x);

    if (ax < 1.0) {
        return ((12 - 9 * B - 6 * C) * ax * ax * ax + (-18 + 12 * B + 6 * C) * ax * ax + (6 - 2 * B)) / 6.0;
    } else if (ax < 2.0) {
        return ((-B - 6 * C) * ax * ax * ax + (6 * B + 30 * C) * ax * ax + (-12 * B - 48 * C) * ax + (8 * B + 24 * C)) / 6.0;
    }
    return 0;
}

// ============================================================================
// Lanczos Resampling
// ============================================================================

fn resizeLanczos(src: *const Image, dst: *Image, a: u8) void {
    const scale_x = @as(f64, @floatFromInt(src.width)) / @as(f64, @floatFromInt(dst.width));
    const scale_y = @as(f64, @floatFromInt(src.height)) / @as(f64, @floatFromInt(dst.height));

    const a_f64: f64 = @floatFromInt(a);

    var y: u32 = 0;
    while (y < dst.height) : (y += 1) {
        const src_y_f = (@as(f64, @floatFromInt(y)) + 0.5) * scale_y - 0.5;
        const src_y: i32 = @intFromFloat(@floor(src_y_f));
        const y_frac = src_y_f - @as(f64, @floatFromInt(src_y));

        var x: u32 = 0;
        while (x < dst.width) : (x += 1) {
            const src_x_f = (@as(f64, @floatFromInt(x)) + 0.5) * scale_x - 0.5;
            const src_x: i32 = @intFromFloat(@floor(src_x_f));
            const x_frac = src_x_f - @as(f64, @floatFromInt(src_x));

            var r: f64 = 0;
            var g: f64 = 0;
            var b: f64 = 0;
            var alpha: f64 = 0;
            var weight_sum: f64 = 0;

            // Sample (2*a) x (2*a) neighborhood
            const range: i32 = @intCast(a);
            var j: i32 = -range + 1;
            while (j <= range) : (j += 1) {
                const weight_y = lanczosWeight(y_frac - @as(f64, @floatFromInt(j)), a_f64);
                const py = std.math.clamp(src_y + j, 0, @as(i32, @intCast(src.height - 1)));

                var i: i32 = -range + 1;
                while (i <= range) : (i += 1) {
                    const weight_x = lanczosWeight(x_frac - @as(f64, @floatFromInt(i)), a_f64);
                    const px = std.math.clamp(src_x + i, 0, @as(i32, @intCast(src.width - 1)));

                    const color = src.getPixel(@intCast(px), @intCast(py)) orelse Color.BLACK;
                    const weight = weight_x * weight_y;

                    r += @as(f64, @floatFromInt(color.r)) * weight;
                    g += @as(f64, @floatFromInt(color.g)) * weight;
                    b += @as(f64, @floatFromInt(color.b)) * weight;
                    alpha += @as(f64, @floatFromInt(color.a)) * weight;
                    weight_sum += weight;
                }
            }

            // Normalize
            if (weight_sum > 0) {
                r /= weight_sum;
                g /= weight_sum;
                b /= weight_sum;
                alpha /= weight_sum;
            }

            dst.setPixel(x, y, Color{
                .r = @intFromFloat(std.math.clamp(r, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b, 0, 255)),
                .a = @intFromFloat(std.math.clamp(alpha, 0, 255)),
            });
        }
    }
}

fn lanczosWeight(x: f64, a: f64) f64 {
    if (x == 0) return 1;
    if (@abs(x) >= a) return 0;

    const pi_x = std.math.pi * x;
    return (a * @sin(pi_x) * @sin(pi_x / a)) / (pi_x * pi_x);
}

// ============================================================================
// Tests
// ============================================================================

test "Resize nearest neighbor" {
    var img = try Image.init(std.testing.allocator, 4, 4, .rgba8);
    defer img.deinit();

    img.setPixel(0, 0, Color.RED);
    img.setPixel(1, 0, Color.GREEN);
    img.setPixel(0, 1, Color.BLUE);
    img.setPixel(1, 1, Color.WHITE);

    var resized = try resize(&img, 2, 2, .nearest);
    defer resized.deinit();

    try std.testing.expectEqual(@as(u32, 2), resized.width);
    try std.testing.expectEqual(@as(u32, 2), resized.height);
}

test "Calculate target size - contain" {
    const result = calculateTargetSize(1000, 500, 200, 200, .contain);
    try std.testing.expectEqual(@as(u32, 200), result.width);
    try std.testing.expectEqual(@as(u32, 100), result.height);
}

test "Lanczos weight" {
    // At x=0, weight should be 1
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), lanczosWeight(0, 3), 0.001);

    // At x=a, weight should be 0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), lanczosWeight(3, 3), 0.001);
}
