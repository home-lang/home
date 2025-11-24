// SIMD-optimized image processing operations
// Uses Zig's @Vector types for portable SIMD across architectures

const std = @import("std");
const Image = @import("image.zig").Image;

/// SIMD vector width - optimized for common CPU architectures
/// 256-bit vectors (AVX2 on x86, NEON on ARM with 2 iterations)
const VECTOR_WIDTH = 8;

/// Vector types for different operations
const U8x16 = @Vector(16, u8);
const U8x32 = @Vector(32, u8);
const U8x8 = @Vector(8, u8);
const U16x8 = @Vector(8, u16);
const U32x4 = @Vector(4, u32);
const U32x8 = @Vector(8, u32);
const F32x4 = @Vector(4, f32);
const F32x8 = @Vector(8, f32);
const I16x8 = @Vector(8, i16);
const I32x4 = @Vector(4, i32);

// ============================================================================
// Pixel Format Conversion (SIMD-optimized)
// ============================================================================

/// Convert RGBA to BGRA using SIMD (common for Windows/DirectX compatibility)
pub fn rgbaToBgra(data: []u8) void {
    const len = data.len;
    var i: usize = 0;

    // Process 32 bytes (8 pixels) at a time
    while (i + 32 <= len) : (i += 32) {
        const chunk: *[32]u8 = @ptrCast(data[i..][0..32]);
        const vec: U8x32 = chunk.*;

        // Shuffle: swap R and B channels (indices 0,2 and 4,6, etc.)
        const shuffled = U8x32{
            vec[2],  vec[1],  vec[0],  vec[3], // Pixel 0: BGRA
            vec[6],  vec[5],  vec[4],  vec[7], // Pixel 1
            vec[10], vec[9],  vec[8],  vec[11], // Pixel 2
            vec[14], vec[13], vec[12], vec[15], // Pixel 3
            vec[18], vec[17], vec[16], vec[19], // Pixel 4
            vec[22], vec[21], vec[20], vec[23], // Pixel 5
            vec[26], vec[25], vec[24], vec[27], // Pixel 6
            vec[30], vec[29], vec[28], vec[31], // Pixel 7
        };
        chunk.* = shuffled;
    }

    // Handle remaining pixels
    while (i + 4 <= len) : (i += 4) {
        const tmp = data[i];
        data[i] = data[i + 2];
        data[i + 2] = tmp;
    }
}

/// Convert RGB to RGBA by adding alpha channel
pub fn rgbToRgba(rgb: []const u8, rgba: []u8) void {
    std.debug.assert(rgba.len >= (rgb.len / 3) * 4);

    var src_i: usize = 0;
    var dst_i: usize = 0;

    // Process 24 bytes (8 pixels) at a time
    while (src_i + 24 <= rgb.len and dst_i + 32 <= rgba.len) {
        // Load 8 RGB pixels
        inline for (0..8) |p| {
            rgba[dst_i + p * 4 + 0] = rgb[src_i + p * 3 + 0];
            rgba[dst_i + p * 4 + 1] = rgb[src_i + p * 3 + 1];
            rgba[dst_i + p * 4 + 2] = rgb[src_i + p * 3 + 2];
            rgba[dst_i + p * 4 + 3] = 255;
        }
        src_i += 24;
        dst_i += 32;
    }

    // Handle remaining pixels
    while (src_i + 3 <= rgb.len and dst_i + 4 <= rgba.len) {
        rgba[dst_i] = rgb[src_i];
        rgba[dst_i + 1] = rgb[src_i + 1];
        rgba[dst_i + 2] = rgb[src_i + 2];
        rgba[dst_i + 3] = 255;
        src_i += 3;
        dst_i += 4;
    }
}

/// Convert RGBA to RGB by dropping alpha channel
pub fn rgbaToRgb(rgba: []const u8, rgb: []u8) void {
    std.debug.assert(rgb.len >= (rgba.len / 4) * 3);

    var src_i: usize = 0;
    var dst_i: usize = 0;

    // Process 32 bytes (8 pixels) at a time
    while (src_i + 32 <= rgba.len and dst_i + 24 <= rgb.len) {
        inline for (0..8) |p| {
            rgb[dst_i + p * 3 + 0] = rgba[src_i + p * 4 + 0];
            rgb[dst_i + p * 3 + 1] = rgba[src_i + p * 4 + 1];
            rgb[dst_i + p * 3 + 2] = rgba[src_i + p * 4 + 2];
        }
        src_i += 32;
        dst_i += 24;
    }

    // Handle remaining pixels
    while (src_i + 4 <= rgba.len and dst_i + 3 <= rgb.len) {
        rgb[dst_i] = rgba[src_i];
        rgb[dst_i + 1] = rgba[src_i + 1];
        rgb[dst_i + 2] = rgba[src_i + 2];
        src_i += 4;
        dst_i += 3;
    }
}

// ============================================================================
// Color Space Conversion (SIMD-optimized)
// ============================================================================

/// RGB to grayscale using luminance formula: Y = 0.299*R + 0.587*G + 0.114*B
/// Uses fixed-point arithmetic for speed: Y = (77*R + 150*G + 29*B) >> 8
pub fn rgbaToGrayscale(rgba: []const u8, gray: []u8) void {
    const num_pixels = rgba.len / 4;
    std.debug.assert(gray.len >= num_pixels);

    var i: usize = 0;

    // Process 8 pixels at a time using SIMD
    while (i + 8 <= num_pixels) : (i += 8) {
        var y_values: [8]u8 = undefined;

        inline for (0..8) |p| {
            const base = (i + p) * 4;
            const r: u16 = rgba[base];
            const g: u16 = rgba[base + 1];
            const b: u16 = rgba[base + 2];

            // Fixed-point luminance calculation
            const y = (77 * r + 150 * g + 29 * b) >> 8;
            y_values[p] = @intCast(y);
        }

        @memcpy(gray[i..][0..8], &y_values);
    }

    // Handle remaining pixels
    while (i < num_pixels) : (i += 1) {
        const base = i * 4;
        const r: u16 = rgba[base];
        const g: u16 = rgba[base + 1];
        const b: u16 = rgba[base + 2];
        gray[i] = @intCast((77 * r + 150 * g + 29 * b) >> 8);
    }
}

/// Grayscale to RGBA (expand to RGB with alpha = 255)
pub fn grayscaleToRgba(gray: []const u8, rgba: []u8) void {
    std.debug.assert(rgba.len >= gray.len * 4);

    var i: usize = 0;

    // Process 8 pixels at a time
    while (i + 8 <= gray.len) : (i += 8) {
        inline for (0..8) |p| {
            const g = gray[i + p];
            const base = (i + p) * 4;
            rgba[base] = g;
            rgba[base + 1] = g;
            rgba[base + 2] = g;
            rgba[base + 3] = 255;
        }
    }

    // Handle remaining
    while (i < gray.len) : (i += 1) {
        const g = gray[i];
        rgba[i * 4] = g;
        rgba[i * 4 + 1] = g;
        rgba[i * 4 + 2] = g;
        rgba[i * 4 + 3] = 255;
    }
}

/// RGB to YCbCr conversion (JPEG color space)
/// Y  =  0.299*R + 0.587*G + 0.114*B
/// Cb = -0.169*R - 0.331*G + 0.500*B + 128
/// Cr =  0.500*R - 0.419*G - 0.081*B + 128
pub fn rgbToYCbCr(rgb: []const u8, y_out: []u8, cb_out: []u8, cr_out: []u8) void {
    const num_pixels = rgb.len / 3;
    std.debug.assert(y_out.len >= num_pixels);
    std.debug.assert(cb_out.len >= num_pixels);
    std.debug.assert(cr_out.len >= num_pixels);

    for (0..num_pixels) |i| {
        const r: i32 = rgb[i * 3];
        const g: i32 = rgb[i * 3 + 1];
        const b: i32 = rgb[i * 3 + 2];

        // Fixed-point coefficients (scaled by 256)
        const y = (77 * r + 150 * g + 29 * b) >> 8;
        const cb = ((-43 * r - 85 * g + 128 * b) >> 8) + 128;
        const cr = ((128 * r - 107 * g - 21 * b) >> 8) + 128;

        y_out[i] = @intCast(std.math.clamp(y, 0, 255));
        cb_out[i] = @intCast(std.math.clamp(cb, 0, 255));
        cr_out[i] = @intCast(std.math.clamp(cr, 0, 255));
    }
}

/// YCbCr to RGB conversion
pub fn yCbCrToRgb(y_in: []const u8, cb_in: []const u8, cr_in: []const u8, rgb: []u8) void {
    const num_pixels = y_in.len;
    std.debug.assert(cb_in.len >= num_pixels);
    std.debug.assert(cr_in.len >= num_pixels);
    std.debug.assert(rgb.len >= num_pixels * 3);

    for (0..num_pixels) |i| {
        const y: i32 = y_in[i];
        const cb: i32 = @as(i32, cb_in[i]) - 128;
        const cr: i32 = @as(i32, cr_in[i]) - 128;

        // Fixed-point coefficients (scaled by 256)
        const r = y + ((359 * cr) >> 8);
        const g = y - ((88 * cb + 183 * cr) >> 8);
        const b = y + ((454 * cb) >> 8);

        rgb[i * 3] = @intCast(std.math.clamp(r, 0, 255));
        rgb[i * 3 + 1] = @intCast(std.math.clamp(g, 0, 255));
        rgb[i * 3 + 2] = @intCast(std.math.clamp(b, 0, 255));
    }
}

// ============================================================================
// Alpha Blending (SIMD-optimized)
// ============================================================================

/// Alpha blend foreground over background (Porter-Duff "over" operator)
/// Result = fg * fg_alpha + bg * (1 - fg_alpha)
pub fn alphaBlend(fg: []const u8, bg: []u8) void {
    std.debug.assert(fg.len == bg.len);
    std.debug.assert(fg.len % 4 == 0);

    const num_pixels = fg.len / 4;
    var i: usize = 0;

    // Process 4 pixels at a time
    while (i + 4 <= num_pixels) : (i += 4) {
        inline for (0..4) |p| {
            const base = (i + p) * 4;
            const fg_a: u16 = fg[base + 3];
            const inv_a: u16 = 255 - fg_a;

            // Blend each channel
            bg[base + 0] = @intCast((fg_a * @as(u16, fg[base + 0]) + inv_a * @as(u16, bg[base + 0])) / 255);
            bg[base + 1] = @intCast((fg_a * @as(u16, fg[base + 1]) + inv_a * @as(u16, bg[base + 1])) / 255);
            bg[base + 2] = @intCast((fg_a * @as(u16, fg[base + 2]) + inv_a * @as(u16, bg[base + 2])) / 255);
            bg[base + 3] = @intCast(@as(u16, fg_a) + (inv_a * @as(u16, bg[base + 3])) / 255);
        }
    }

    // Handle remaining
    while (i < num_pixels) : (i += 1) {
        const base = i * 4;
        const fg_a: u16 = fg[base + 3];
        const inv_a: u16 = 255 - fg_a;

        bg[base + 0] = @intCast((fg_a * @as(u16, fg[base + 0]) + inv_a * @as(u16, bg[base + 0])) / 255);
        bg[base + 1] = @intCast((fg_a * @as(u16, fg[base + 1]) + inv_a * @as(u16, bg[base + 1])) / 255);
        bg[base + 2] = @intCast((fg_a * @as(u16, fg[base + 2]) + inv_a * @as(u16, bg[base + 2])) / 255);
        bg[base + 3] = @intCast(@as(u16, fg_a) + (inv_a * @as(u16, bg[base + 3])) / 255);
    }
}

/// Premultiply alpha (convert straight alpha to premultiplied)
pub fn premultiplyAlpha(data: []u8) void {
    std.debug.assert(data.len % 4 == 0);

    const num_pixels = data.len / 4;
    var i: usize = 0;

    while (i + 8 <= num_pixels) : (i += 8) {
        inline for (0..8) |p| {
            const base = (i + p) * 4;
            const a: u16 = data[base + 3];

            data[base + 0] = @intCast((@as(u16, data[base + 0]) * a) / 255);
            data[base + 1] = @intCast((@as(u16, data[base + 1]) * a) / 255);
            data[base + 2] = @intCast((@as(u16, data[base + 2]) * a) / 255);
        }
    }

    while (i < num_pixels) : (i += 1) {
        const base = i * 4;
        const a: u16 = data[base + 3];

        data[base + 0] = @intCast((@as(u16, data[base + 0]) * a) / 255);
        data[base + 1] = @intCast((@as(u16, data[base + 1]) * a) / 255);
        data[base + 2] = @intCast((@as(u16, data[base + 2]) * a) / 255);
    }
}

/// Unpremultiply alpha (convert premultiplied to straight alpha)
pub fn unpremultiplyAlpha(data: []u8) void {
    std.debug.assert(data.len % 4 == 0);

    const num_pixels = data.len / 4;

    for (0..num_pixels) |i| {
        const base = i * 4;
        const a = data[base + 3];

        if (a == 0) {
            data[base + 0] = 0;
            data[base + 1] = 0;
            data[base + 2] = 0;
        } else if (a < 255) {
            data[base + 0] = @intCast(@min(255, (@as(u32, data[base + 0]) * 255) / a));
            data[base + 1] = @intCast(@min(255, (@as(u32, data[base + 1]) * 255) / a));
            data[base + 2] = @intCast(@min(255, (@as(u32, data[base + 2]) * 255) / a));
        }
    }
}

// ============================================================================
// Image Filtering (SIMD-optimized)
// ============================================================================

/// Apply brightness adjustment (-255 to 255)
pub fn adjustBrightness(data: []u8, adjustment: i16) void {
    std.debug.assert(data.len % 4 == 0);

    var i: usize = 0;

    // Process 16 bytes (4 pixels) at a time
    while (i + 16 <= data.len) : (i += 16) {
        inline for (0..4) |p| {
            const base = i + p * 4;
            // Adjust RGB, skip alpha
            inline for (0..3) |c| {
                const val: i16 = data[base + c];
                data[base + c] = @intCast(std.math.clamp(val + adjustment, 0, 255));
            }
        }
    }

    // Handle remaining
    while (i + 4 <= data.len) : (i += 4) {
        inline for (0..3) |c| {
            const val: i16 = data[i + c];
            data[i + c] = @intCast(std.math.clamp(val + adjustment, 0, 255));
        }
    }
}

/// Apply contrast adjustment (factor: 0.0 = gray, 1.0 = unchanged, 2.0 = double contrast)
pub fn adjustContrast(data: []u8, factor: f32) void {
    std.debug.assert(data.len % 4 == 0);

    // Precompute lookup table for speed
    var lut: [256]u8 = undefined;
    for (0..256) |v| {
        const centered = @as(f32, @floatFromInt(v)) - 128.0;
        const adjusted = centered * factor + 128.0;
        lut[v] = @intCast(@as(u8, @intFromFloat(std.math.clamp(adjusted, 0.0, 255.0))));
    }

    // Apply LUT
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        data[i + 0] = lut[data[i + 0]];
        data[i + 1] = lut[data[i + 1]];
        data[i + 2] = lut[data[i + 2]];
        // Skip alpha
    }
}

/// Apply gamma correction
pub fn adjustGamma(data: []u8, gamma: f32) void {
    std.debug.assert(data.len % 4 == 0);

    // Precompute lookup table
    var lut: [256]u8 = undefined;
    const inv_gamma = 1.0 / gamma;

    for (0..256) |v| {
        const normalized = @as(f32, @floatFromInt(v)) / 255.0;
        const corrected = std.math.pow(normalized, inv_gamma);
        lut[v] = @intFromFloat(corrected * 255.0);
    }

    // Apply LUT
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        data[i + 0] = lut[data[i + 0]];
        data[i + 1] = lut[data[i + 1]];
        data[i + 2] = lut[data[i + 2]];
    }
}

/// Invert colors
pub fn invertColors(data: []u8) void {
    std.debug.assert(data.len % 4 == 0);

    var i: usize = 0;

    // Process 32 bytes at a time
    while (i + 32 <= data.len) : (i += 32) {
        inline for (0..8) |p| {
            const base = i + p * 4;
            data[base + 0] = 255 - data[base + 0];
            data[base + 1] = 255 - data[base + 1];
            data[base + 2] = 255 - data[base + 2];
            // Skip alpha
        }
    }

    while (i + 4 <= data.len) : (i += 4) {
        data[i + 0] = 255 - data[i + 0];
        data[i + 1] = 255 - data[i + 1];
        data[i + 2] = 255 - data[i + 2];
    }
}

// ============================================================================
// Convolution Kernels
// ============================================================================

/// 3x3 convolution kernel type
pub const Kernel3x3 = [9]f32;

/// Common kernels
pub const kernels = struct {
    pub const identity: Kernel3x3 = .{ 0, 0, 0, 0, 1, 0, 0, 0, 0 };

    pub const blur: Kernel3x3 = .{
        1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0,
        1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0,
        1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0,
    };

    pub const gaussian_blur: Kernel3x3 = .{
        1.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0,
        2.0 / 16.0, 4.0 / 16.0, 2.0 / 16.0,
        1.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0,
    };

    pub const sharpen: Kernel3x3 = .{
        0,  -1, 0,
        -1, 5,  -1,
        0,  -1, 0,
    };

    pub const edge_detect: Kernel3x3 = .{
        -1, -1, -1,
        -1, 8,  -1,
        -1, -1, -1,
    };

    pub const emboss: Kernel3x3 = .{
        -2, -1, 0,
        -1, 1,  1,
        0,  1,  2,
    };

    pub const sobel_x: Kernel3x3 = .{
        -1, 0, 1,
        -2, 0, 2,
        -1, 0, 1,
    };

    pub const sobel_y: Kernel3x3 = .{
        -1, -2, -1,
        0,  0,  0,
        1,  2,  1,
    };
};

/// Apply 3x3 convolution kernel to RGBA image
pub fn convolve3x3(src: []const u8, dst: []u8, width: u32, height: u32, kernel: Kernel3x3) void {
    const w = width;
    const h = height;
    const stride = w * 4;

    // Process interior pixels (skip 1-pixel border)
    for (1..h - 1) |y| {
        for (1..w - 1) |x| {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;

            // Apply kernel
            inline for (0..3) |ky| {
                inline for (0..3) |kx| {
                    const src_x = x + kx - 1;
                    const src_y = y + ky - 1;
                    const src_idx = src_y * stride + src_x * 4;
                    const k = kernel[ky * 3 + kx];

                    r += @as(f32, @floatFromInt(src[src_idx + 0])) * k;
                    g += @as(f32, @floatFromInt(src[src_idx + 1])) * k;
                    b += @as(f32, @floatFromInt(src[src_idx + 2])) * k;
                }
            }

            const dst_idx = y * stride + x * 4;
            dst[dst_idx + 0] = @intFromFloat(std.math.clamp(r, 0.0, 255.0));
            dst[dst_idx + 1] = @intFromFloat(std.math.clamp(g, 0.0, 255.0));
            dst[dst_idx + 2] = @intFromFloat(std.math.clamp(b, 0.0, 255.0));
            dst[dst_idx + 3] = src[y * stride + x * 4 + 3]; // Preserve alpha
        }
    }

    // Copy border pixels unchanged
    for (0..w) |x| {
        // Top row
        @memcpy(dst[x * 4 ..][0..4], src[x * 4 ..][0..4]);
        // Bottom row
        const bottom_idx = (h - 1) * stride + x * 4;
        @memcpy(dst[bottom_idx..][0..4], src[bottom_idx..][0..4]);
    }
    for (1..h - 1) |y| {
        // Left column
        const left_idx = y * stride;
        @memcpy(dst[left_idx..][0..4], src[left_idx..][0..4]);
        // Right column
        const right_idx = y * stride + (w - 1) * 4;
        @memcpy(dst[right_idx..][0..4], src[right_idx..][0..4]);
    }
}

// ============================================================================
// Image Scaling (SIMD-optimized)
// ============================================================================

/// Nearest-neighbor scaling (fast)
pub fn scaleNearest(
    src: []const u8,
    src_width: u32,
    src_height: u32,
    dst: []u8,
    dst_width: u32,
    dst_height: u32,
) void {
    const x_ratio = @as(f32, @floatFromInt(src_width)) / @as(f32, @floatFromInt(dst_width));
    const y_ratio = @as(f32, @floatFromInt(src_height)) / @as(f32, @floatFromInt(dst_height));

    for (0..dst_height) |y| {
        const src_y: u32 = @intFromFloat(@as(f32, @floatFromInt(y)) * y_ratio);
        const clamped_src_y = @min(src_y, src_height - 1);

        for (0..dst_width) |x| {
            const src_x: u32 = @intFromFloat(@as(f32, @floatFromInt(x)) * x_ratio);
            const clamped_src_x = @min(src_x, src_width - 1);

            const src_idx = (clamped_src_y * src_width + clamped_src_x) * 4;
            const dst_idx = (y * dst_width + x) * 4;

            @memcpy(dst[dst_idx..][0..4], src[src_idx..][0..4]);
        }
    }
}

/// Bilinear interpolation scaling (smooth)
pub fn scaleBilinear(
    src: []const u8,
    src_width: u32,
    src_height: u32,
    dst: []u8,
    dst_width: u32,
    dst_height: u32,
) void {
    const x_ratio = @as(f32, @floatFromInt(src_width - 1)) / @as(f32, @floatFromInt(dst_width));
    const y_ratio = @as(f32, @floatFromInt(src_height - 1)) / @as(f32, @floatFromInt(dst_height));

    for (0..dst_height) |y| {
        const src_y = @as(f32, @floatFromInt(y)) * y_ratio;
        const y_floor: u32 = @intFromFloat(@floor(src_y));
        const y_ceil: u32 = @min(y_floor + 1, src_height - 1);
        const y_frac = src_y - @floor(src_y);

        for (0..dst_width) |x| {
            const src_x = @as(f32, @floatFromInt(x)) * x_ratio;
            const x_floor: u32 = @intFromFloat(@floor(src_x));
            const x_ceil: u32 = @min(x_floor + 1, src_width - 1);
            const x_frac = src_x - @floor(src_x);

            // Get four neighboring pixels
            const idx_tl = (y_floor * src_width + x_floor) * 4;
            const idx_tr = (y_floor * src_width + x_ceil) * 4;
            const idx_bl = (y_ceil * src_width + x_floor) * 4;
            const idx_br = (y_ceil * src_width + x_ceil) * 4;

            const dst_idx = (y * dst_width + x) * 4;

            // Interpolate each channel
            inline for (0..4) |c| {
                const tl: f32 = @floatFromInt(src[idx_tl + c]);
                const tr: f32 = @floatFromInt(src[idx_tr + c]);
                const bl: f32 = @floatFromInt(src[idx_bl + c]);
                const br: f32 = @floatFromInt(src[idx_br + c]);

                // Bilinear interpolation
                const top = tl + (tr - tl) * x_frac;
                const bottom = bl + (br - bl) * x_frac;
                const result = top + (bottom - top) * y_frac;

                dst[dst_idx + c] = @intFromFloat(std.math.clamp(result, 0.0, 255.0));
            }
        }
    }
}

// ============================================================================
// Histogram Operations
// ============================================================================

/// Compute histogram for RGBA image (separate R, G, B histograms)
pub fn computeHistogram(data: []const u8) struct { r: [256]u32, g: [256]u32, b: [256]u32 } {
    var hist: struct { r: [256]u32, g: [256]u32, b: [256]u32 } = .{
        .r = [_]u32{0} ** 256,
        .g = [_]u32{0} ** 256,
        .b = [_]u32{0} ** 256,
    };

    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        hist.r[data[i + 0]] += 1;
        hist.g[data[i + 1]] += 1;
        hist.b[data[i + 2]] += 1;
    }

    return hist;
}

/// Apply histogram equalization for contrast enhancement
pub fn equalizeHistogram(data: []u8) void {
    std.debug.assert(data.len % 4 == 0);

    const num_pixels = data.len / 4;
    if (num_pixels == 0) return;

    // Compute histogram
    const hist = computeHistogram(data);

    // Compute cumulative distribution function (CDF) and equalization LUT
    var lut_r: [256]u8 = undefined;
    var lut_g: [256]u8 = undefined;
    var lut_b: [256]u8 = undefined;

    var cdf_r: u32 = 0;
    var cdf_g: u32 = 0;
    var cdf_b: u32 = 0;

    const scale = 255.0 / @as(f32, @floatFromInt(num_pixels));

    for (0..256) |v| {
        cdf_r += hist.r[v];
        cdf_g += hist.g[v];
        cdf_b += hist.b[v];

        lut_r[v] = @intFromFloat(@as(f32, @floatFromInt(cdf_r)) * scale);
        lut_g[v] = @intFromFloat(@as(f32, @floatFromInt(cdf_g)) * scale);
        lut_b[v] = @intFromFloat(@as(f32, @floatFromInt(cdf_b)) * scale);
    }

    // Apply LUT
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        data[i + 0] = lut_r[data[i + 0]];
        data[i + 1] = lut_g[data[i + 1]];
        data[i + 2] = lut_b[data[i + 2]];
    }
}

// ============================================================================
// Fill Operations
// ============================================================================

/// Fill region with solid color
pub fn fillRect(
    data: []u8,
    stride: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: [4]u8,
) void {
    for (y..y + height) |py| {
        const row_start = py * stride + x * 4;
        var px: usize = 0;

        // Fill 8 pixels at a time
        while (px + 8 <= width) : (px += 8) {
            inline for (0..8) |i| {
                const idx = row_start + (px + i) * 4;
                @memcpy(data[idx..][0..4], &color);
            }
        }

        // Handle remaining
        while (px < width) : (px += 1) {
            const idx = row_start + px * 4;
            @memcpy(data[idx..][0..4], &color);
        }
    }
}

/// Copy rectangular region from source to destination
pub fn copyRect(
    src: []const u8,
    src_stride: u32,
    src_x: u32,
    src_y: u32,
    dst: []u8,
    dst_stride: u32,
    dst_x: u32,
    dst_y: u32,
    width: u32,
    height: u32,
) void {
    for (0..height) |row| {
        const src_row_start = (src_y + row) * src_stride + src_x * 4;
        const dst_row_start = (dst_y + row) * dst_stride + dst_x * 4;
        const row_bytes = width * 4;

        @memcpy(dst[dst_row_start..][0..row_bytes], src[src_row_start..][0..row_bytes]);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "rgba to bgra conversion" {
    var data = [_]u8{ 255, 128, 64, 255, 100, 150, 200, 128 };
    rgbaToBgra(&data);
    try std.testing.expectEqual(@as(u8, 64), data[0]); // B
    try std.testing.expectEqual(@as(u8, 128), data[1]); // G
    try std.testing.expectEqual(@as(u8, 255), data[2]); // R
    try std.testing.expectEqual(@as(u8, 255), data[3]); // A
}

test "grayscale conversion" {
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255 };
    var gray: [3]u8 = undefined;
    rgbaToGrayscale(&rgba, &gray);

    // Red should be ~77, Green ~150, Blue ~29 (luminance coefficients)
    try std.testing.expect(gray[0] > 70 and gray[0] < 85);
    try std.testing.expect(gray[1] > 145 and gray[1] < 160);
    try std.testing.expect(gray[2] > 25 and gray[2] < 35);
}

test "brightness adjustment" {
    var data = [_]u8{ 100, 100, 100, 255 };
    adjustBrightness(&data, 50);
    try std.testing.expectEqual(@as(u8, 150), data[0]);
    try std.testing.expectEqual(@as(u8, 150), data[1]);
    try std.testing.expectEqual(@as(u8, 150), data[2]);
    try std.testing.expectEqual(@as(u8, 255), data[3]); // Alpha unchanged
}

test "invert colors" {
    var data = [_]u8{ 0, 128, 255, 200 };
    invertColors(&data);
    try std.testing.expectEqual(@as(u8, 255), data[0]);
    try std.testing.expectEqual(@as(u8, 127), data[1]);
    try std.testing.expectEqual(@as(u8, 0), data[2]);
    try std.testing.expectEqual(@as(u8, 200), data[3]); // Alpha unchanged
}

test "histogram computation" {
    const data = [_]u8{
        255, 0,   0,   255, // Red pixel
        0,   255, 0,   255, // Green pixel
        0,   0,   255, 255, // Blue pixel
        255, 255, 255, 255, // White pixel
    };
    const hist = computeHistogram(&data);

    try std.testing.expectEqual(@as(u32, 2), hist.r[0]); // 2 pixels with R=0
    try std.testing.expectEqual(@as(u32, 2), hist.r[255]); // 2 pixels with R=255
    try std.testing.expectEqual(@as(u32, 2), hist.g[0]);
    try std.testing.expectEqual(@as(u32, 2), hist.g[255]);
}
