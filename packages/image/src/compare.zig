// Image Comparison and Similarity Metrics
// PSNR, SSIM, MSE, and perceptual hashing

const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;
const Color = image.Color;

// ============================================================================
// Basic Metrics
// ============================================================================

/// Mean Squared Error between two images
pub fn mse(img1: *const Image, img2: *const Image) f64 {
    if (img1.width != img2.width or img1.height != img2.height) {
        return std.math.inf(f64);
    }

    var sum: f64 = 0;
    const num_pixels = @as(u64, img1.width) * @as(u64, img1.height);

    for (0..img1.height) |y| {
        for (0..img1.width) |x| {
            const c1 = img1.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK;
            const c2 = img2.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK;

            const dr = @as(f64, @floatFromInt(c1.r)) - @as(f64, @floatFromInt(c2.r));
            const dg = @as(f64, @floatFromInt(c1.g)) - @as(f64, @floatFromInt(c2.g));
            const db = @as(f64, @floatFromInt(c1.b)) - @as(f64, @floatFromInt(c2.b));

            sum += (dr * dr + dg * dg + db * db) / 3.0;
        }
    }

    return sum / @as(f64, @floatFromInt(num_pixels));
}

/// Root Mean Squared Error
pub fn rmse(img1: *const Image, img2: *const Image) f64 {
    return @sqrt(mse(img1, img2));
}

/// Peak Signal-to-Noise Ratio (in dB)
/// Higher is better. Typically 30-50 dB for good quality.
pub fn psnr(img1: *const Image, img2: *const Image) f64 {
    const mse_val = mse(img1, img2);
    if (mse_val == 0) return std.math.inf(f64); // Identical images

    const max_val: f64 = 255.0;
    return 10.0 * @log10((max_val * max_val) / mse_val);
}

/// Mean Absolute Error
pub fn mae(img1: *const Image, img2: *const Image) f64 {
    if (img1.width != img2.width or img1.height != img2.height) {
        return std.math.inf(f64);
    }

    var sum: f64 = 0;
    const num_pixels = @as(u64, img1.width) * @as(u64, img1.height);

    for (0..img1.height) |y| {
        for (0..img1.width) |x| {
            const c1 = img1.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK;
            const c2 = img2.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK;

            const dr = @abs(@as(f64, @floatFromInt(c1.r)) - @as(f64, @floatFromInt(c2.r)));
            const dg = @abs(@as(f64, @floatFromInt(c1.g)) - @as(f64, @floatFromInt(c2.g)));
            const db = @abs(@as(f64, @floatFromInt(c1.b)) - @as(f64, @floatFromInt(c2.b)));

            sum += (dr + dg + db) / 3.0;
        }
    }

    return sum / @as(f64, @floatFromInt(num_pixels));
}

// ============================================================================
// Structural Similarity Index (SSIM)
// ============================================================================

/// SSIM constants
const K1: f64 = 0.01;
const K2: f64 = 0.03;
const L: f64 = 255.0; // Dynamic range
const C1: f64 = (K1 * L) * (K1 * L);
const C2: f64 = (K2 * L) * (K2 * L);

/// Compute SSIM between two images
/// Returns value between -1 and 1, where 1 means identical
pub fn ssim(img1: *const Image, img2: *const Image) f64 {
    if (img1.width != img2.width or img1.height != img2.height) {
        return 0;
    }

    // Use 8x8 windows
    const window_size: u32 = 8;
    if (img1.width < window_size or img1.height < window_size) {
        return ssimSimple(img1, img2);
    }

    var total_ssim: f64 = 0;
    var window_count: u64 = 0;

    var y: u32 = 0;
    while (y + window_size <= img1.height) : (y += window_size) {
        var x: u32 = 0;
        while (x + window_size <= img1.width) : (x += window_size) {
            const window_ssim = ssimWindow(img1, img2, x, y, window_size);
            total_ssim += window_ssim;
            window_count += 1;
        }
    }

    if (window_count == 0) return ssimSimple(img1, img2);
    return total_ssim / @as(f64, @floatFromInt(window_count));
}

fn ssimWindow(img1: *const Image, img2: *const Image, start_x: u32, start_y: u32, size: u32) f64 {
    var sum1: f64 = 0;
    var sum2: f64 = 0;
    var sum1_sq: f64 = 0;
    var sum2_sq: f64 = 0;
    var sum12: f64 = 0;

    const n: f64 = @floatFromInt(@as(u64, size) * @as(u64, size));

    for (0..size) |dy| {
        for (0..size) |dx| {
            const c1 = img1.getPixel(start_x + @as(u32, @intCast(dx)), start_y + @as(u32, @intCast(dy))) orelse Color.BLACK;
            const c2 = img2.getPixel(start_x + @as(u32, @intCast(dx)), start_y + @as(u32, @intCast(dy))) orelse Color.BLACK;

            // Convert to grayscale luminance
            const l1 = 0.299 * @as(f64, @floatFromInt(c1.r)) + 0.587 * @as(f64, @floatFromInt(c1.g)) + 0.114 * @as(f64, @floatFromInt(c1.b));
            const l2 = 0.299 * @as(f64, @floatFromInt(c2.r)) + 0.587 * @as(f64, @floatFromInt(c2.g)) + 0.114 * @as(f64, @floatFromInt(c2.b));

            sum1 += l1;
            sum2 += l2;
            sum1_sq += l1 * l1;
            sum2_sq += l2 * l2;
            sum12 += l1 * l2;
        }
    }

    const mu1 = sum1 / n;
    const mu2 = sum2 / n;
    const sigma1_sq = (sum1_sq / n) - (mu1 * mu1);
    const sigma2_sq = (sum2_sq / n) - (mu2 * mu2);
    const sigma12 = (sum12 / n) - (mu1 * mu2);

    const numerator = (2.0 * mu1 * mu2 + C1) * (2.0 * sigma12 + C2);
    const denominator = (mu1 * mu1 + mu2 * mu2 + C1) * (sigma1_sq + sigma2_sq + C2);

    return numerator / denominator;
}

fn ssimSimple(img1: *const Image, img2: *const Image) f64 {
    return ssimWindow(img1, img2, 0, 0, @min(img1.width, img1.height));
}

/// Multi-Scale SSIM (MS-SSIM)
pub fn msssim(img1: *const Image, img2: *const Image, allocator: std.mem.Allocator) !f64 {
    const weights = [_]f64{ 0.0448, 0.2856, 0.3001, 0.2363, 0.1333 };
    var result: f64 = 1.0;

    var scale1 = img1;
    var scale2 = img2;
    var owned1: ?Image = null;
    var owned2: ?Image = null;
    defer if (owned1) |*o| o.deinit();
    defer if (owned2) |*o| o.deinit();

    for (weights, 0..) |weight, i| {
        const ssim_val = ssim(scale1, scale2);
        result *= std.math.pow(f64, ssim_val, weight);

        if (i < weights.len - 1) {
            // Downsample for next scale
            if (owned1) |*o| o.deinit();
            if (owned2) |*o| o.deinit();

            const new_w = @max(1, scale1.width / 2);
            const new_h = @max(1, scale1.height / 2);

            owned1 = try downsample(scale1, new_w, new_h, allocator);
            owned2 = try downsample(scale2, new_w, new_h, allocator);

            scale1 = &owned1.?;
            scale2 = &owned2.?;
        }
    }

    return result;
}

fn downsample(img: *const Image, new_w: u32, new_h: u32, allocator: std.mem.Allocator) !Image {
    var result = try Image.init(allocator, new_w, new_h, img.format);

    const scale_x = @as(f64, @floatFromInt(img.width)) / @as(f64, @floatFromInt(new_w));
    const scale_y = @as(f64, @floatFromInt(img.height)) / @as(f64, @floatFromInt(new_h));

    for (0..new_h) |y| {
        for (0..new_w) |x| {
            const src_x: u32 = @intFromFloat(@as(f64, @floatFromInt(x)) * scale_x);
            const src_y: u32 = @intFromFloat(@as(f64, @floatFromInt(y)) * scale_y);

            if (img.getPixel(@min(src_x, img.width - 1), @min(src_y, img.height - 1))) |c| {
                result.setPixel(@intCast(x), @intCast(y), c);
            }
        }
    }

    return result;
}

// ============================================================================
// Perceptual Hashing
// ============================================================================

/// Average Hash (aHash) - 64-bit perceptual hash
/// Similar images produce similar hashes
pub fn averageHash(img: *const Image) u64 {
    // Resize to 8x8 conceptually
    const size: u32 = 8;
    var gray_values: [64]u8 = undefined;
    var sum: u32 = 0;

    const scale_x = @as(f64, @floatFromInt(img.width)) / @as(f64, size);
    const scale_y = @as(f64, @floatFromInt(img.height)) / @as(f64, size);

    for (0..size) |y| {
        for (0..size) |x| {
            const src_x: u32 = @intFromFloat(@as(f64, @floatFromInt(x)) * scale_x);
            const src_y: u32 = @intFromFloat(@as(f64, @floatFromInt(y)) * scale_y);

            const c = img.getPixel(@min(src_x, img.width - 1), @min(src_y, img.height - 1)) orelse Color.BLACK;
            const gray = c.toGrayscale();

            gray_values[y * size + x] = gray;
            sum += gray;
        }
    }

    const mean = sum / 64;

    // Generate hash based on whether each pixel is above average
    var hash: u64 = 0;
    for (0..64) |i| {
        if (gray_values[i] >= mean) {
            hash |= @as(u64, 1) << @intCast(i);
        }
    }

    return hash;
}

/// Difference Hash (dHash) - 64-bit perceptual hash
/// Based on gradient direction
pub fn differenceHash(img: *const Image) u64 {
    const w: u32 = 9;
    const h: u32 = 8;
    var gray_values: [72]u8 = undefined;

    const scale_x = @as(f64, @floatFromInt(img.width)) / @as(f64, w);
    const scale_y = @as(f64, @floatFromInt(img.height)) / @as(f64, h);

    for (0..h) |y| {
        for (0..w) |x| {
            const src_x: u32 = @intFromFloat(@as(f64, @floatFromInt(x)) * scale_x);
            const src_y: u32 = @intFromFloat(@as(f64, @floatFromInt(y)) * scale_y);

            const c = img.getPixel(@min(src_x, img.width - 1), @min(src_y, img.height - 1)) orelse Color.BLACK;
            gray_values[y * w + x] = c.toGrayscale();
        }
    }

    // Compare adjacent pixels
    var hash: u64 = 0;
    var bit: u6 = 0;
    for (0..h) |y| {
        for (0..w - 1) |x| {
            if (gray_values[y * w + x] < gray_values[y * w + x + 1]) {
                hash |= @as(u64, 1) << bit;
            }
            bit += 1;
        }
    }

    return hash;
}

/// Perceptual Hash (pHash) using DCT
/// More robust than aHash and dHash
pub fn perceptualHash(img: *const Image) u64 {
    const size: u32 = 32;
    var gray: [1024]f64 = undefined;

    const scale_x = @as(f64, @floatFromInt(img.width)) / @as(f64, size);
    const scale_y = @as(f64, @floatFromInt(img.height)) / @as(f64, size);

    // Convert to grayscale and resize
    for (0..size) |y| {
        for (0..size) |x| {
            const src_x: u32 = @intFromFloat(@as(f64, @floatFromInt(x)) * scale_x);
            const src_y: u32 = @intFromFloat(@as(f64, @floatFromInt(y)) * scale_y);

            const c = img.getPixel(@min(src_x, img.width - 1), @min(src_y, img.height - 1)) orelse Color.BLACK;
            gray[y * size + x] = @floatFromInt(c.toGrayscale());
        }
    }

    // Compute 2D DCT (simplified - just top-left 8x8)
    var dct: [64]f64 = undefined;
    for (0..8) |v| {
        for (0..8) |u| {
            var sum: f64 = 0;
            for (0..size) |y| {
                for (0..size) |x| {
                    sum += gray[y * size + x] *
                        @cos(std.math.pi * @as(f64, @floatFromInt(2 * x + 1)) * @as(f64, @floatFromInt(u)) / (2.0 * size)) *
                        @cos(std.math.pi * @as(f64, @floatFromInt(2 * y + 1)) * @as(f64, @floatFromInt(v)) / (2.0 * size));
                }
            }
            dct[v * 8 + u] = sum;
        }
    }

    // Compute median of DCT coefficients (excluding DC)
    var sorted: [63]f64 = undefined;
    for (1..64) |i| {
        sorted[i - 1] = dct[i];
    }
    std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
    const median = sorted[31];

    // Generate hash
    var hash: u64 = 0;
    for (1..64) |i| {
        if (dct[i] > median) {
            hash |= @as(u64, 1) << @intCast(i - 1);
        }
    }

    return hash;
}

/// Hamming distance between two hashes
pub fn hammingDistance(hash1: u64, hash2: u64) u8 {
    return @popCount(hash1 ^ hash2);
}

/// Similarity score based on hash distance (0 to 1)
pub fn hashSimilarity(hash1: u64, hash2: u64) f64 {
    const distance = hammingDistance(hash1, hash2);
    return 1.0 - @as(f64, @floatFromInt(distance)) / 64.0;
}

// ============================================================================
// Difference Image
// ============================================================================

/// Create a difference image showing where two images differ
pub fn differenceImage(img1: *const Image, img2: *const Image, allocator: std.mem.Allocator) !Image {
    const w = @max(img1.width, img2.width);
    const h = @max(img1.height, img2.height);

    var result = try Image.init(allocator, w, h, .rgba8);

    for (0..h) |y| {
        for (0..w) |x| {
            const c1 = if (x < img1.width and y < img1.height)
                img1.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK
            else
                Color.BLACK;

            const c2 = if (x < img2.width and y < img2.height)
                img2.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK
            else
                Color.BLACK;

            const dr = @abs(@as(i16, c1.r) - @as(i16, c2.r));
            const dg = @abs(@as(i16, c1.g) - @as(i16, c2.g));
            const db = @abs(@as(i16, c1.b) - @as(i16, c2.b));

            result.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intCast(dr),
                .g = @intCast(dg),
                .b = @intCast(db),
                .a = 255,
            });
        }
    }

    return result;
}

/// Create a heatmap showing difference intensity
pub fn differenceHeatmap(img1: *const Image, img2: *const Image, allocator: std.mem.Allocator) !Image {
    const w = @max(img1.width, img2.width);
    const h = @max(img1.height, img2.height);

    var result = try Image.init(allocator, w, h, .rgba8);

    for (0..h) |y| {
        for (0..w) |x| {
            const c1 = if (x < img1.width and y < img1.height)
                img1.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK
            else
                Color.BLACK;

            const c2 = if (x < img2.width and y < img2.height)
                img2.getPixel(@intCast(x), @intCast(y)) orelse Color.BLACK
            else
                Color.BLACK;

            const dr = @abs(@as(i16, c1.r) - @as(i16, c2.r));
            const dg = @abs(@as(i16, c1.g) - @as(i16, c2.g));
            const db = @abs(@as(i16, c1.b) - @as(i16, c2.b));

            const intensity: u8 = @intCast((dr + dg + db) / 3);

            // Map to heatmap colors (blue -> green -> yellow -> red)
            const heat_color = intensityToHeat(intensity);
            result.setPixel(@intCast(x), @intCast(y), heat_color);
        }
    }

    return result;
}

fn intensityToHeat(intensity: u8) Color {
    // Blue (0) -> Cyan (64) -> Green (128) -> Yellow (192) -> Red (255)
    if (intensity < 64) {
        const t = intensity * 4;
        return Color{ .r = 0, .g = t, .b = 255, .a = 255 };
    } else if (intensity < 128) {
        const t = (intensity - 64) * 4;
        return Color{ .r = 0, .g = 255, .b = @intCast(255 - t), .a = 255 };
    } else if (intensity < 192) {
        const t = (intensity - 128) * 4;
        return Color{ .r = t, .g = 255, .b = 0, .a = 255 };
    } else {
        const t = (intensity - 192) * 4;
        return Color{ .r = 255, .g = @intCast(255 - t), .b = 0, .a = 255 };
    }
}

// ============================================================================
// Tests
// ============================================================================

test "MSE of identical images" {
    var img = try Image.init(std.testing.allocator, 10, 10, .rgba8);
    defer img.deinit();

    @memset(img.pixels, 128);

    const result = mse(&img, &img);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result, 0.001);
}

test "PSNR of identical images" {
    var img = try Image.init(std.testing.allocator, 10, 10, .rgba8);
    defer img.deinit();

    @memset(img.pixels, 128);

    const result = psnr(&img, &img);
    try std.testing.expect(std.math.isInf(result));
}

test "SSIM of identical images" {
    var img = try Image.init(std.testing.allocator, 16, 16, .rgba8);
    defer img.deinit();

    @memset(img.pixels, 128);

    const result = ssim(&img, &img);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result, 0.01);
}

test "Hamming distance" {
    try std.testing.expectEqual(@as(u8, 0), hammingDistance(0, 0));
    try std.testing.expectEqual(@as(u8, 1), hammingDistance(0, 1));
    try std.testing.expectEqual(@as(u8, 64), hammingDistance(0, 0xFFFFFFFFFFFFFFFF));
}

test "Average hash of same image" {
    var img = try Image.init(std.testing.allocator, 64, 64, .rgba8);
    defer img.deinit();

    for (0..img.pixels.len / 4) |i| {
        img.pixels[i * 4] = @intCast(i % 256);
        img.pixels[i * 4 + 1] = @intCast((i * 2) % 256);
        img.pixels[i * 4 + 2] = @intCast((i * 3) % 256);
        img.pixels[i * 4 + 3] = 255;
    }

    const hash1 = averageHash(&img);
    const hash2 = averageHash(&img);

    try std.testing.expectEqual(hash1, hash2);
}
