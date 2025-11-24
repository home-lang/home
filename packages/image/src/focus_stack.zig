const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Focus Stacking
// ============================================================================

pub const FocusStackOptions = struct {
    alignment_method: enum { none, phase_correlation, feature_based } = .phase_correlation,
    merge_method: enum { max_contrast, pyramid, depth_map } = .max_contrast,
    kernel_size: u32 = 5,
    blur_radius: f32 = 2.0,
};

pub const FocusStackResult = struct {
    merged_image: Image,
    depth_map: ?Image, // Optional depth map showing which image was used where
    focus_map: ?[]f32, // Focus quality at each pixel
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FocusStackResult) void {
        self.merged_image.deinit();
        if (self.depth_map) |*dm| dm.deinit();
        if (self.focus_map) |fm| self.allocator.free(fm);
    }
};

/// Stacks multiple images with different focus planes into one sharp image
pub fn stackFocusedImages(
    allocator: std.mem.Allocator,
    images: []const *const Image,
    options: FocusStackOptions,
) !FocusStackResult {
    if (images.len == 0) return error.NoImages;

    const width = images[0].width;
    const height = images[0].height;

    // Verify all images have same dimensions
    for (images) |img| {
        if (img.width != width or img.height != height) {
            return error.DimensionMismatch;
        }
    }

    // Align images if requested
    var aligned_images = try allocator.alloc(Image, images.len);
    defer {
        for (aligned_images) |*img| img.deinit();
        allocator.free(aligned_images);
    }

    if (options.alignment_method != .none) {
        try alignImages(allocator, images, aligned_images, options.alignment_method);
    } else {
        // Just copy images
        for (images, 0..) |img, i| {
            aligned_images[i] = try Image.init(allocator, width, height, img.format);
            for (0..height) |y| {
                for (0..width) |x| {
                    aligned_images[i].setPixel(@intCast(x), @intCast(y), img.getPixel(@intCast(x), @intCast(y)));
                }
            }
        }
    }

    // Create array of aligned image pointers
    var aligned_ptrs = try allocator.alloc(*const Image, images.len);
    defer allocator.free(aligned_ptrs);
    for (aligned_images, 0..) |*img, i| {
        aligned_ptrs[i] = img;
    }

    // Merge based on method
    return switch (options.merge_method) {
        .max_contrast => try mergeMaxContrast(allocator, aligned_ptrs, options),
        .pyramid => try mergePyramid(allocator, aligned_ptrs, options),
        .depth_map => try mergeDepthMap(allocator, aligned_ptrs, options),
    };
}

// ============================================================================
// Image Alignment
// ============================================================================

fn alignImages(
    allocator: std.mem.Allocator,
    source_images: []const *const Image,
    aligned_images: []Image,
    method: enum { phase_correlation, feature_based },
) !void {
    const reference_idx = source_images.len / 2;

    // Copy reference image
    const ref = source_images[reference_idx];
    aligned_images[reference_idx] = try Image.init(allocator, ref.width, ref.height, ref.format);
    for (0..ref.height) |y| {
        for (0..ref.width) |x| {
            aligned_images[reference_idx].setPixel(@intCast(x), @intCast(y), ref.getPixel(@intCast(x), @intCast(y)));
        }
    }

    // Align other images to reference
    for (source_images, 0..) |img, i| {
        if (i == reference_idx) continue;

        const offset = switch (method) {
            .phase_correlation => try computePhaseCorrelation(allocator, ref, img),
            .feature_based => try computeFeatureAlignment(allocator, ref, img),
        };

        aligned_images[i] = try translateImage(allocator, img, offset.x, offset.y);
    }
}

fn computePhaseCorrelation(allocator: std.mem.Allocator, img1: *const Image, img2: *const Image) !struct { x: i32, y: i32 } {
    // Simplified phase correlation - real version would use FFT
    // For now, use simple template matching

    const search_radius = 20;
    var best_x: i32 = 0;
    var best_y: i32 = 0;
    var best_similarity: f32 = 0.0;

    var dy: i32 = -search_radius;
    while (dy <= search_radius) : (dy += 1) {
        var dx: i32 = -search_radius;
        while (dx <= search_radius) : (dx += 1) {
            const similarity = computeSimilarity(img1, img2, dx, dy);
            if (similarity > best_similarity) {
                best_similarity = similarity;
                best_x = dx;
                best_y = dy;
            }
        }
    }

    _ = allocator;
    return .{ .x = best_x, .y = best_y };
}

fn computeFeatureAlignment(allocator: std.mem.Allocator, img1: *const Image, img2: *const Image) !struct { x: i32, y: i32 } {
    // Simplified - just use phase correlation for now
    return computePhaseCorrelation(allocator, img1, img2);
}

fn computeSimilarity(img1: *const Image, img2: *const Image, offset_x: i32, offset_y: i32) f32 {
    var sum: f32 = 0.0;
    var count: f32 = 0.0;

    const start_x = @max(0, offset_x);
    const start_y = @max(0, offset_y);
    const end_x = @min(@as(i32, @intCast(img1.width)), @as(i32, @intCast(img2.width)) + offset_x);
    const end_y = @min(@as(i32, @intCast(img1.height)), @as(i32, @intCast(img2.height)) + offset_y);

    var y = start_y;
    while (y < end_y) : (y += 1) {
        var x = start_x;
        while (x < end_x) : (x += 1) {
            const x2 = x - offset_x;
            const y2 = y - offset_y;

            if (x >= 0 and x < img1.width and y >= 0 and y < img1.height and
                x2 >= 0 and x2 < img2.width and y2 >= 0 and y2 < img2.height)
            {
                const p1 = img1.getPixel(@intCast(x), @intCast(y));
                const p2 = img2.getPixel(@intCast(x2), @intCast(y2));

                const diff_r = @as(f32, @floatFromInt(p1.r)) - @as(f32, @floatFromInt(p2.r));
                const diff_g = @as(f32, @floatFromInt(p1.g)) - @as(f32, @floatFromInt(p2.g));
                const diff_b = @as(f32, @floatFromInt(p1.b)) - @as(f32, @floatFromInt(p2.b));

                sum += diff_r * diff_r + diff_g * diff_g + diff_b * diff_b;
                count += 1.0;
            }
        }
    }

    if (count == 0.0) return 0.0;
    return 1.0 / (1.0 + sum / count / (255.0 * 255.0 * 3.0));
}

fn translateImage(allocator: std.mem.Allocator, img: *const Image, offset_x: i32, offset_y: i32) !Image {
    var result = try Image.init(allocator, img.width, img.height, img.format);

    // Fill with black
    for (0..result.height) |y| {
        for (0..result.width) |x| {
            result.setPixel(@intCast(x), @intCast(y), Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
        }
    }

    // Copy with offset
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const new_x = @as(i32, @intCast(x)) + offset_x;
            const new_y = @as(i32, @intCast(y)) + offset_y;

            if (new_x >= 0 and new_x < result.width and new_y >= 0 and new_y < result.height) {
                result.setPixel(@intCast(new_x), @intCast(new_y), img.getPixel(@intCast(x), @intCast(y)));
            }
        }
    }

    return result;
}

// ============================================================================
// Focus Measurement
// ============================================================================

fn computeFocusMap(allocator: std.mem.Allocator, img: *const Image, kernel_size: u32) ![]f32 {
    var focus_map = try allocator.alloc(f32, img.width * img.height);

    // Convert to grayscale
    var gray = try allocator.alloc(f32, img.width * img.height);
    defer allocator.free(gray);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(@intCast(x), @intCast(y));
            gray[y * img.width + x] = (@as(f32, @floatFromInt(pixel.r)) * 0.299 +
                @as(f32, @floatFromInt(pixel.g)) * 0.587 +
                @as(f32, @floatFromInt(pixel.b)) * 0.114) / 255.0;
        }
    }

    // Compute Laplacian (measure of local contrast/sharpness)
    const half_kernel = kernel_size / 2;

    for (half_kernel..img.height - half_kernel) |y| {
        for (half_kernel..img.width - half_kernel) |x| {
            const idx = y * img.width + x;

            // 3x3 Laplacian kernel
            const laplacian = -4.0 * gray[idx] +
                gray[idx - 1] +
                gray[idx + 1] +
                gray[idx - img.width] +
                gray[idx + img.width];

            focus_map[idx] = @abs(laplacian);
        }
    }

    return focus_map;
}

// ============================================================================
// Merge Methods
// ============================================================================

fn mergeMaxContrast(allocator: std.mem.Allocator, images: []*const Image, options: FocusStackOptions) !FocusStackResult {
    const width = images[0].width;
    const height = images[0].height;

    // Compute focus maps for all images
    var focus_maps = try allocator.alloc([]f32, images.len);
    defer {
        for (focus_maps) |map| allocator.free(map);
        allocator.free(focus_maps);
    }

    for (images, 0..) |img, i| {
        focus_maps[i] = try computeFocusMap(allocator, img, options.kernel_size);
    }

    // Create result images
    var merged = try Image.init(allocator, width, height, images[0].format);
    var depth_map = try Image.init(allocator, width, height, .rgba);
    var final_focus_map = try allocator.alloc(f32, width * height);

    // For each pixel, select the sharpest source
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * width + x;

            var best_focus: f32 = 0.0;
            var best_image_idx: usize = 0;

            for (focus_maps, 0..) |focus_map, i| {
                if (focus_map[idx] > best_focus) {
                    best_focus = focus_map[idx];
                    best_image_idx = i;
                }
            }

            // Copy pixel from sharpest image
            const pixel = images[best_image_idx].getPixel(@intCast(x), @intCast(y));
            merged.setPixel(@intCast(x), @intCast(y), pixel);

            // Store depth/source information
            const depth_value = @as(u8, @intFromFloat(255.0 * @as(f32, @floatFromInt(best_image_idx)) / @as(f32, @floatFromInt(images.len - 1))));
            depth_map.setPixel(@intCast(x), @intCast(y), Color{
                .r = depth_value,
                .g = depth_value,
                .b = depth_value,
                .a = 255,
            });

            final_focus_map[idx] = best_focus;
        }
    }

    return FocusStackResult{
        .merged_image = merged,
        .depth_map = depth_map,
        .focus_map = final_focus_map,
        .allocator = allocator,
    };
}

fn mergePyramid(allocator: std.mem.Allocator, images: []*const Image, options: FocusStackOptions) !FocusStackResult {
    // Simplified pyramid blending - real version would use Laplacian pyramids
    // For now, fall back to max contrast with blurring
    return mergeMaxContrast(allocator, images, options);
}

fn mergeDepthMap(allocator: std.mem.Allocator, images: []*const Image, options: FocusStackOptions) !FocusStackResult {
    // Build explicit depth map first, then blend
    var result = try mergeMaxContrast(allocator, images, options);

    // Apply smoothing to reduce artifacts
    var smoothed = try smoothImage(allocator, &result.merged_image, options.blur_radius);
    result.merged_image.deinit();
    result.merged_image = smoothed;

    return result;
}

fn smoothImage(allocator: std.mem.Allocator, img: *const Image, radius: f32) !Image {
    var result = try Image.init(allocator, img.width, img.height, img.format);

    const kernel_size = @as(u32, @intFromFloat(@ceil(radius * 2.0))) | 1; // Make odd
    const half_kernel = kernel_size / 2;

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            var sum_r: f32 = 0.0;
            var sum_g: f32 = 0.0;
            var sum_b: f32 = 0.0;
            var sum_a: f32 = 0.0;
            var weight_sum: f32 = 0.0;

            for (0..kernel_size) |ky| {
                for (0..kernel_size) |kx| {
                    const sx = @as(i32, @intCast(x)) - @as(i32, @intCast(half_kernel)) + @as(i32, @intCast(kx));
                    const sy = @as(i32, @intCast(y)) - @as(i32, @intCast(half_kernel)) + @as(i32, @intCast(ky));

                    if (sx >= 0 and sx < img.width and sy >= 0 and sy < img.height) {
                        const pixel = img.getPixel(@intCast(sx), @intCast(sy));
                        const weight = 1.0;
                        sum_r += @as(f32, @floatFromInt(pixel.r)) * weight;
                        sum_g += @as(f32, @floatFromInt(pixel.g)) * weight;
                        sum_b += @as(f32, @floatFromInt(pixel.b)) * weight;
                        sum_a += @as(f32, @floatFromInt(pixel.a)) * weight;
                        weight_sum += weight;
                    }
                }
            }

            result.setPixel(@intCast(x), @intCast(y), Color{
                .r = @intFromFloat(sum_r / weight_sum),
                .g = @intFromFloat(sum_g / weight_sum),
                .b = @intFromFloat(sum_b / weight_sum),
                .a = @intFromFloat(sum_a / weight_sum),
            });
        }
    }

    return result;
}

// ============================================================================
// Advanced Focus Detection
// ============================================================================

pub const FocusQuality = struct {
    variance: f32,
    edge_strength: f32,
    frequency_content: f32,
    overall_score: f32,
};

/// Analyzes focus quality of an image
pub fn analyzeFocusQuality(allocator: std.mem.Allocator, img: *const Image) !FocusQuality {
    // Convert to grayscale
    var gray = try allocator.alloc(f32, img.width * img.height);
    defer allocator.free(gray);

    var sum: f32 = 0.0;
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(@intCast(x), @intCast(y));
            const intensity = (@as(f32, @floatFromInt(pixel.r)) * 0.299 +
                @as(f32, @floatFromInt(pixel.g)) * 0.587 +
                @as(f32, @floatFromInt(pixel.b)) * 0.114) / 255.0;
            gray[y * img.width + x] = intensity;
            sum += intensity;
        }
    }

    const mean = sum / @as(f32, @floatFromInt(img.width * img.height));

    // Compute variance
    var variance: f32 = 0.0;
    for (gray) |val| {
        const diff = val - mean;
        variance += diff * diff;
    }
    variance /= @as(f32, @floatFromInt(gray.len));

    // Compute edge strength using Sobel
    var edge_strength: f32 = 0.0;
    for (1..img.height - 1) |y| {
        for (1..img.width - 1) |x| {
            const idx = y * img.width + x;

            const gx = -gray[idx - img.width - 1] + gray[idx - img.width + 1] -
                2.0 * gray[idx - 1] + 2.0 * gray[idx + 1] -
                gray[idx + img.width - 1] + gray[idx + img.width + 1];

            const gy = -gray[idx - img.width - 1] - 2.0 * gray[idx - img.width] - gray[idx - img.width + 1] +
                gray[idx + img.width - 1] + 2.0 * gray[idx + img.width] + gray[idx + img.width + 1];

            edge_strength += @sqrt(gx * gx + gy * gy);
        }
    }
    edge_strength /= @as(f32, @floatFromInt((img.width - 2) * (img.height - 2)));

    // Compute frequency content (simplified)
    var frequency_content: f32 = 0.0;
    for (1..img.height) |y| {
        for (1..img.width) |x| {
            const idx = y * img.width + x;
            const diff = @abs(gray[idx] - gray[idx - 1]) + @abs(gray[idx] - gray[idx - img.width]);
            frequency_content += diff;
        }
    }
    frequency_content /= @as(f32, @floatFromInt(img.width * img.height));

    // Combine metrics
    const overall_score = variance * 0.3 + edge_strength * 0.5 + frequency_content * 0.2;

    return FocusQuality{
        .variance = variance,
        .edge_strength = edge_strength,
        .frequency_content = frequency_content,
        .overall_score = overall_score,
    };
}
