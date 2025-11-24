const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("image.zig").Color;

// ============================================================================
// Image Statistics
// ============================================================================

/// Per-channel statistics
pub const ChannelStats = struct {
    min: u8,
    max: u8,
    mean: f64,
    std_dev: f64,
    median: u8,
    histogram: [256]u32,
};

/// Complete image statistics
pub const ImageStats = struct {
    red: ChannelStats,
    green: ChannelStats,
    blue: ChannelStats,
    alpha: ChannelStats,
    luminance: ChannelStats,
    entropy: f64, // Shannon entropy
    pixel_count: u64,
};

/// Calculate comprehensive image statistics
pub fn calculateStats(image: *const Image, allocator: std.mem.Allocator) !ImageStats {
    const num_pixels = @as(u64, image.width) * @as(u64, image.height);

    // Initialize histograms
    var r_hist = [_]u32{0} ** 256;
    var g_hist = [_]u32{0} ** 256;
    var b_hist = [_]u32{0} ** 256;
    var a_hist = [_]u32{0} ** 256;
    var l_hist = [_]u32{0} ** 256;

    // Accumulators for mean
    var r_sum: u64 = 0;
    var g_sum: u64 = 0;
    var b_sum: u64 = 0;
    var a_sum: u64 = 0;
    var l_sum: u64 = 0;

    // Build histograms
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const color = image.getPixel(x, y) orelse Color.BLACK;
            const lum = color.toGrayscale();

            r_hist[color.r] += 1;
            g_hist[color.g] += 1;
            b_hist[color.b] += 1;
            a_hist[color.a] += 1;
            l_hist[lum] += 1;

            r_sum += color.r;
            g_sum += color.g;
            b_sum += color.b;
            a_sum += color.a;
            l_sum += lum;
        }
    }

    const pixel_count_f: f64 = @floatFromInt(num_pixels);

    // Calculate means
    const r_mean = @as(f64, @floatFromInt(r_sum)) / pixel_count_f;
    const g_mean = @as(f64, @floatFromInt(g_sum)) / pixel_count_f;
    const b_mean = @as(f64, @floatFromInt(b_sum)) / pixel_count_f;
    const a_mean = @as(f64, @floatFromInt(a_sum)) / pixel_count_f;
    const l_mean = @as(f64, @floatFromInt(l_sum)) / pixel_count_f;

    // Calculate standard deviations
    var r_var: f64 = 0;
    var g_var: f64 = 0;
    var b_var: f64 = 0;
    var a_var: f64 = 0;
    var l_var: f64 = 0;

    for (0..256) |i| {
        const val: f64 = @floatFromInt(i);
        const r_count: f64 = @floatFromInt(r_hist[i]);
        const g_count: f64 = @floatFromInt(g_hist[i]);
        const b_count: f64 = @floatFromInt(b_hist[i]);
        const a_count: f64 = @floatFromInt(a_hist[i]);
        const l_count: f64 = @floatFromInt(l_hist[i]);

        r_var += r_count * (val - r_mean) * (val - r_mean);
        g_var += g_count * (val - g_mean) * (val - g_mean);
        b_var += b_count * (val - b_mean) * (val - b_mean);
        a_var += a_count * (val - a_mean) * (val - a_mean);
        l_var += l_count * (val - l_mean) * (val - l_mean);
    }

    r_var /= pixel_count_f;
    g_var /= pixel_count_f;
    b_var /= pixel_count_f;
    a_var /= pixel_count_f;
    l_var /= pixel_count_f;

    // Calculate entropy
    var entropy: f64 = 0;
    for (l_hist) |count| {
        if (count > 0) {
            const p: f64 = @as(f64, @floatFromInt(count)) / pixel_count_f;
            entropy -= p * @log2(p);
        }
    }

    // Helper to build channel stats
    const buildChannelStats = struct {
        fn call(hist: [256]u32, mean: f64, variance: f64, total: u64, alloc: std.mem.Allocator) !ChannelStats {
            _ = alloc;
            var min_val: u8 = 255;
            var max_val: u8 = 0;

            for (0..256) |i| {
                if (hist[i] > 0) {
                    min_val = @min(min_val, @as(u8, @intCast(i)));
                    max_val = @max(max_val, @as(u8, @intCast(i)));
                }
            }

            // Find median
            var cumulative: u64 = 0;
            var median: u8 = 0;
            const half = total / 2;
            for (0..256) |i| {
                cumulative += hist[i];
                if (cumulative >= half) {
                    median = @intCast(i);
                    break;
                }
            }

            return ChannelStats{
                .min = min_val,
                .max = max_val,
                .mean = mean,
                .std_dev = @sqrt(variance),
                .median = median,
                .histogram = hist,
            };
        }
    }.call;

    return ImageStats{
        .red = try buildChannelStats(r_hist, r_mean, r_var, num_pixels, allocator),
        .green = try buildChannelStats(g_hist, g_mean, g_var, num_pixels, allocator),
        .blue = try buildChannelStats(b_hist, b_mean, b_var, num_pixels, allocator),
        .alpha = try buildChannelStats(a_hist, a_mean, a_var, num_pixels, allocator),
        .luminance = try buildChannelStats(l_hist, l_mean, l_var, num_pixels, allocator),
        .entropy = entropy,
        .pixel_count = num_pixels,
    };
}

// ============================================================================
// Dominant Color Extraction
// ============================================================================

/// Extracted dominant color with weight
pub const DominantColor = struct {
    color: Color,
    percentage: f32,
    pixel_count: u32,
};

/// Extract dominant colors using histogram-based approach
pub fn extractDominantColors(
    image: *const Image,
    num_colors: u32,
    allocator: std.mem.Allocator,
) ![]DominantColor {
    // Quantize colors to 4-bit per channel (4096 colors)
    var color_counts = std.AutoHashMap(u16, u32).init(allocator);
    defer color_counts.deinit();

    const total_pixels = image.width * image.height;

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const color = image.getPixel(x, y) orelse continue;
            // Skip transparent pixels
            if (color.a < 128) continue;

            // Quantize to 4-bit
            const qr: u16 = color.r >> 4;
            const qg: u16 = color.g >> 4;
            const qb: u16 = color.b >> 4;
            const key: u16 = (qr << 8) | (qg << 4) | qb;

            const entry = try color_counts.getOrPut(key);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
        }
    }

    // Convert to array and sort
    var colors = std.ArrayList(struct { key: u16, count: u32 }).init(allocator);
    defer colors.deinit();

    var it = color_counts.iterator();
    while (it.next()) |entry| {
        try colors.append(.{ .key = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    std.mem.sort(@TypeOf(colors.items[0]), colors.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(colors.items[0]), b: @TypeOf(colors.items[0])) bool {
            return a.count > b.count;
        }
    }.lessThan);

    // Build result
    const result_count = @min(num_colors, @as(u32, @intCast(colors.items.len)));
    const result = try allocator.alloc(DominantColor, result_count);

    for (0..result_count) |i| {
        const key = colors.items[i].key;
        const count = colors.items[i].count;

        result[i] = DominantColor{
            .color = Color{
                .r = @as(u8, @intCast((key >> 8) & 0xF)) * 17,
                .g = @as(u8, @intCast((key >> 4) & 0xF)) * 17,
                .b = @as(u8, @intCast(key & 0xF)) * 17,
                .a = 255,
            },
            .percentage = @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(total_pixels)) * 100.0,
            .pixel_count = count,
        };
    }

    return result;
}

// ============================================================================
// K-Means Color Clustering
// ============================================================================

/// Color cluster from k-means
pub const ColorCluster = struct {
    centroid: Color,
    pixel_count: u32,
    percentage: f32,
};

/// K-means color palette generation
pub fn generatePalette(
    image: *const Image,
    num_colors: u32,
    max_iterations: u32,
    allocator: std.mem.Allocator,
) ![]ColorCluster {
    // Sample pixels (for large images)
    const max_samples: u32 = 10000;
    const total_pixels = image.width * image.height;
    const sample_step = if (total_pixels > max_samples) total_pixels / max_samples else 1;

    var samples = std.ArrayList([3]f32).init(allocator);
    defer samples.deinit();

    var idx: u32 = 0;
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            if (idx % sample_step == 0) {
                const color = image.getPixel(x, y) orelse continue;
                if (color.a >= 128) {
                    try samples.append(.{
                        @floatFromInt(color.r),
                        @floatFromInt(color.g),
                        @floatFromInt(color.b),
                    });
                }
            }
            idx += 1;
        }
    }

    if (samples.items.len == 0) {
        return try allocator.alloc(ColorCluster, 0);
    }

    // Initialize centroids using k-means++
    var centroids = try allocator.alloc([3]f32, num_colors);
    defer allocator.free(centroids);

    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();

    // First centroid: random sample
    centroids[0] = samples.items[random.intRangeAtMost(usize, 0, samples.items.len - 1)];

    // Remaining centroids: weighted by distance
    for (1..num_colors) |k| {
        var distances = try allocator.alloc(f32, samples.items.len);
        defer allocator.free(distances);

        var total_dist: f32 = 0;
        for (samples.items, 0..) |sample, i| {
            var min_dist: f32 = std.math.floatMax(f32);
            for (0..k) |j| {
                const dist = colorDistance(sample, centroids[j]);
                min_dist = @min(min_dist, dist);
            }
            distances[i] = min_dist * min_dist;
            total_dist += distances[i];
        }

        // Weighted random selection
        var target = random.float(f32) * total_dist;
        for (samples.items, 0..) |sample, i| {
            target -= distances[i];
            if (target <= 0) {
                centroids[k] = sample;
                break;
            }
        }
    }

    // Assignments
    var assignments = try allocator.alloc(u32, samples.items.len);
    defer allocator.free(assignments);

    // K-means iterations
    for (0..max_iterations) |_| {
        // Assign samples to nearest centroid
        for (samples.items, 0..) |sample, i| {
            var best_cluster: u32 = 0;
            var best_dist: f32 = std.math.floatMax(f32);

            for (centroids, 0..) |centroid, k| {
                const dist = colorDistance(sample, centroid);
                if (dist < best_dist) {
                    best_dist = dist;
                    best_cluster = @intCast(k);
                }
            }
            assignments[i] = best_cluster;
        }

        // Update centroids
        var new_centroids = try allocator.alloc([3]f32, num_colors);
        defer allocator.free(new_centroids);
        var counts = try allocator.alloc(u32, num_colors);
        defer allocator.free(counts);

        @memset(new_centroids, .{ 0, 0, 0 });
        @memset(counts, 0);

        for (samples.items, 0..) |sample, i| {
            const cluster = assignments[i];
            new_centroids[cluster][0] += sample[0];
            new_centroids[cluster][1] += sample[1];
            new_centroids[cluster][2] += sample[2];
            counts[cluster] += 1;
        }

        var converged = true;
        for (0..num_colors) |k| {
            if (counts[k] > 0) {
                const count_f: f32 = @floatFromInt(counts[k]);
                new_centroids[k][0] /= count_f;
                new_centroids[k][1] /= count_f;
                new_centroids[k][2] /= count_f;

                if (colorDistance(centroids[k], new_centroids[k]) > 1.0) {
                    converged = false;
                }
                centroids[k] = new_centroids[k];
            }
        }

        if (converged) break;
    }

    // Count final assignments
    var final_counts = try allocator.alloc(u32, num_colors);
    defer allocator.free(final_counts);
    @memset(final_counts, 0);

    for (assignments) |cluster| {
        final_counts[cluster] += 1;
    }

    // Build result
    const result = try allocator.alloc(ColorCluster, num_colors);
    const samples_count: f32 = @floatFromInt(samples.items.len);

    for (0..num_colors) |k| {
        result[k] = ColorCluster{
            .centroid = Color{
                .r = @intFromFloat(std.math.clamp(centroids[k][0], 0, 255)),
                .g = @intFromFloat(std.math.clamp(centroids[k][1], 0, 255)),
                .b = @intFromFloat(std.math.clamp(centroids[k][2], 0, 255)),
                .a = 255,
            },
            .pixel_count = final_counts[k],
            .percentage = @as(f32, @floatFromInt(final_counts[k])) / samples_count * 100.0,
        };
    }

    // Sort by percentage
    std.mem.sort(ColorCluster, result, {}, struct {
        fn lessThan(_: void, a: ColorCluster, b: ColorCluster) bool {
            return a.percentage > b.percentage;
        }
    }.lessThan);

    return result;
}

fn colorDistance(a: [3]f32, b: [3]f32) f32 {
    const dr = a[0] - b[0];
    const dg = a[1] - b[1];
    const db = a[2] - b[2];
    return @sqrt(dr * dr + dg * dg + db * db);
}

// ============================================================================
// Edge Detection
// ============================================================================

/// Edge detection result
pub const EdgeResult = struct {
    edge_image: *Image,
    edge_density: f32, // Percentage of edge pixels
    average_gradient: f32,
    max_gradient: f32,
};

/// Sobel edge detection
pub fn sobelEdgeDetect(image: *const Image, allocator: std.mem.Allocator) !EdgeResult {
    var result = try Image.init(allocator, image.width, image.height, .grayscale8);
    errdefer result.deinit();

    const sobel_x = [3][3]i32{
        .{ -1, 0, 1 },
        .{ -2, 0, 2 },
        .{ -1, 0, 1 },
    };

    const sobel_y = [3][3]i32{
        .{ -1, -2, -1 },
        .{ 0, 0, 0 },
        .{ 1, 2, 1 },
    };

    var edge_count: u32 = 0;
    var total_gradient: f64 = 0;
    var max_gradient: f32 = 0;
    const edge_threshold: f32 = 50;

    var y: u32 = 1;
    while (y < image.height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < image.width - 1) : (x += 1) {
            var gx: i32 = 0;
            var gy: i32 = 0;

            for (0..3) |ky| {
                for (0..3) |kx| {
                    const px = x + @as(u32, @intCast(kx)) - 1;
                    const py = y + @as(u32, @intCast(ky)) - 1;
                    const color = image.getPixel(px, py) orelse Color.BLACK;
                    const lum: i32 = color.toGrayscale();

                    gx += lum * sobel_x[ky][kx];
                    gy += lum * sobel_y[ky][kx];
                }
            }

            const gradient: f32 = @sqrt(@as(f32, @floatFromInt(gx * gx + gy * gy)));
            const clamped: u8 = @intFromFloat(@min(gradient, 255.0));

            result.setPixel(x, y, Color{ .r = clamped, .g = clamped, .b = clamped, .a = 255 });

            if (gradient > edge_threshold) edge_count += 1;
            total_gradient += gradient;
            max_gradient = @max(max_gradient, gradient);
        }
    }

    const total_pixels = (image.width - 2) * (image.height - 2);

    return EdgeResult{
        .edge_image = &result,
        .edge_density = @as(f32, @floatFromInt(edge_count)) / @as(f32, @floatFromInt(total_pixels)) * 100.0,
        .average_gradient = @floatCast(total_gradient / @as(f64, @floatFromInt(total_pixels))),
        .max_gradient = max_gradient,
    };
}

/// Canny edge detection
pub fn cannyEdgeDetect(
    image: *const Image,
    low_threshold: f32,
    high_threshold: f32,
    allocator: std.mem.Allocator,
) !*Image {
    // Step 1: Gaussian blur (3x3)
    var blurred = try Image.init(allocator, image.width, image.height, image.format);
    defer blurred.deinit();

    const gaussian = [3][3]f32{
        .{ 1.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0 },
        .{ 2.0 / 16.0, 4.0 / 16.0, 2.0 / 16.0 },
        .{ 1.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0 },
    };

    var y: u32 = 1;
    while (y < image.height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < image.width - 1) : (x += 1) {
            var sum: f32 = 0;
            for (0..3) |ky| {
                for (0..3) |kx| {
                    const color = image.getPixel(x + @as(u32, @intCast(kx)) - 1, y + @as(u32, @intCast(ky)) - 1) orelse Color.BLACK;
                    sum += @as(f32, @floatFromInt(color.toGrayscale())) * gaussian[ky][kx];
                }
            }
            const val: u8 = @intFromFloat(@min(@max(sum, 0), 255));
            blurred.setPixel(x, y, Color{ .r = val, .g = val, .b = val, .a = 255 });
        }
    }

    // Step 2: Sobel gradients
    var gradients = try allocator.alloc(f32, image.width * image.height);
    defer allocator.free(gradients);
    var directions = try allocator.alloc(u8, image.width * image.height);
    defer allocator.free(directions);

    y = 1;
    while (y < image.height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < image.width - 1) : (x += 1) {
            var gx: i32 = 0;
            var gy: i32 = 0;

            // Simplified Sobel
            const tl = blurred.getPixel(x - 1, y - 1).?.toGrayscale();
            const t = blurred.getPixel(x, y - 1).?.toGrayscale();
            const tr = blurred.getPixel(x + 1, y - 1).?.toGrayscale();
            const l = blurred.getPixel(x - 1, y).?.toGrayscale();
            const r = blurred.getPixel(x + 1, y).?.toGrayscale();
            const bl = blurred.getPixel(x - 1, y + 1).?.toGrayscale();
            const b = blurred.getPixel(x, y + 1).?.toGrayscale();
            const br = blurred.getPixel(x + 1, y + 1).?.toGrayscale();

            gx = -@as(i32, tl) + @as(i32, tr) - 2 * @as(i32, l) + 2 * @as(i32, r) - @as(i32, bl) + @as(i32, br);
            gy = -@as(i32, tl) - 2 * @as(i32, t) - @as(i32, tr) + @as(i32, bl) + 2 * @as(i32, b) + @as(i32, br);

            const idx = y * image.width + x;
            gradients[idx] = @sqrt(@as(f32, @floatFromInt(gx * gx + gy * gy)));

            // Quantize direction to 4 angles
            const angle = std.math.atan2(@as(f32, @floatFromInt(gy)), @as(f32, @floatFromInt(gx)));
            const deg = angle * 180.0 / std.math.pi;
            if (deg < -67.5 or deg >= 67.5) {
                directions[idx] = 0; // Horizontal
            } else if (deg >= -67.5 and deg < -22.5) {
                directions[idx] = 1; // Diagonal /
            } else if (deg >= -22.5 and deg < 22.5) {
                directions[idx] = 2; // Vertical
            } else {
                directions[idx] = 3; // Diagonal \
            }
        }
    }

    // Step 3: Non-maximum suppression
    var suppressed = try allocator.alloc(f32, image.width * image.height);
    defer allocator.free(suppressed);
    @memset(suppressed, 0);

    y = 1;
    while (y < image.height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < image.width - 1) : (x += 1) {
            const idx = y * image.width + x;
            const g = gradients[idx];
            const dir = directions[idx];

            var n1: f32 = 0;
            var n2: f32 = 0;

            switch (dir) {
                0 => { // Horizontal
                    n1 = gradients[idx - 1];
                    n2 = gradients[idx + 1];
                },
                1 => { // Diagonal /
                    n1 = gradients[(y - 1) * image.width + x + 1];
                    n2 = gradients[(y + 1) * image.width + x - 1];
                },
                2 => { // Vertical
                    n1 = gradients[(y - 1) * image.width + x];
                    n2 = gradients[(y + 1) * image.width + x];
                },
                3 => { // Diagonal \
                    n1 = gradients[(y - 1) * image.width + x - 1];
                    n2 = gradients[(y + 1) * image.width + x + 1];
                },
                else => {},
            }

            if (g >= n1 and g >= n2) {
                suppressed[idx] = g;
            }
        }
    }

    // Step 4: Hysteresis thresholding
    var result = try allocator.create(Image);
    result.* = try Image.init(allocator, image.width, image.height, .grayscale8);

    y = 1;
    while (y < image.height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < image.width - 1) : (x += 1) {
            const idx = y * image.width + x;
            var val: u8 = 0;

            if (suppressed[idx] >= high_threshold) {
                val = 255;
            } else if (suppressed[idx] >= low_threshold) {
                // Check if connected to strong edge
                for (0..3) |ky| {
                    for (0..3) |kx| {
                        const ny = y + @as(u32, @intCast(ky)) - 1;
                        const nx = x + @as(u32, @intCast(kx)) - 1;
                        if (suppressed[ny * image.width + nx] >= high_threshold) {
                            val = 255;
                            break;
                        }
                    }
                }
            }

            result.setPixel(x, y, Color{ .r = val, .g = val, .b = val, .a = 255 });
        }
    }

    return result;
}

// ============================================================================
// Blur Detection
// ============================================================================

/// Blur detection result
pub const BlurResult = struct {
    laplacian_variance: f64,
    is_blurry: bool,
    blur_score: f32, // 0 = very blurry, 100 = very sharp
};

/// Detect blur using Laplacian variance method
pub fn detectBlur(image: *const Image, threshold: f64) BlurResult {
    // Laplacian kernel
    const laplacian = [3][3]i32{
        .{ 0, 1, 0 },
        .{ 1, -4, 1 },
        .{ 0, 1, 0 },
    };

    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var count: u64 = 0;

    var y: u32 = 1;
    while (y < image.height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < image.width - 1) : (x += 1) {
            var lap: i32 = 0;

            for (0..3) |ky| {
                for (0..3) |kx| {
                    const color = image.getPixel(x + @as(u32, @intCast(kx)) - 1, y + @as(u32, @intCast(ky)) - 1) orelse Color.BLACK;
                    lap += @as(i32, color.toGrayscale()) * laplacian[ky][kx];
                }
            }

            const lap_f: f64 = @floatFromInt(lap);
            sum += lap_f;
            sum_sq += lap_f * lap_f;
            count += 1;
        }
    }

    const count_f: f64 = @floatFromInt(count);
    const mean = sum / count_f;
    const variance = (sum_sq / count_f) - (mean * mean);

    // Normalize to 0-100 score (higher = sharper)
    const blur_score: f32 = @floatCast(@min(variance / 10.0, 100.0));

    return BlurResult{
        .laplacian_variance = variance,
        .is_blurry = variance < threshold,
        .blur_score = blur_score,
    };
}

// ============================================================================
// Feature Detection (Simple Corner Detection)
// ============================================================================

/// Detected feature/corner
pub const Feature = struct {
    x: u32,
    y: u32,
    strength: f32,
};

/// Bounding box for detected region
pub const BoundingBox = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    confidence: f32,
};

/// Harris corner detection
pub fn detectCorners(
    image: *const Image,
    threshold: f32,
    max_corners: u32,
    allocator: std.mem.Allocator,
) ![]Feature {
    var corners = std.ArrayList(Feature).init(allocator);
    defer corners.deinit();

    // Sobel derivatives
    const Ix = try allocator.alloc(f32, image.width * image.height);
    defer allocator.free(Ix);
    const Iy = try allocator.alloc(f32, image.width * image.height);
    defer allocator.free(Iy);

    // Compute gradients
    var y: u32 = 1;
    while (y < image.height - 1) : (y += 1) {
        var x: u32 = 1;
        while (x < image.width - 1) : (x += 1) {
            const idx = y * image.width + x;

            const l = image.getPixel(x - 1, y).?.toGrayscale();
            const r = image.getPixel(x + 1, y).?.toGrayscale();
            const t = image.getPixel(x, y - 1).?.toGrayscale();
            const b = image.getPixel(x, y + 1).?.toGrayscale();

            Ix[idx] = @as(f32, @floatFromInt(r)) - @as(f32, @floatFromInt(l));
            Iy[idx] = @as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(t));
        }
    }

    // Harris response
    const k: f32 = 0.04;
    const window_size: u32 = 3;
    const half_window: u32 = window_size / 2;

    y = half_window;
    while (y < image.height - half_window) : (y += 1) {
        var x: u32 = half_window;
        while (x < image.width - half_window) : (x += 1) {
            var Ixx: f32 = 0;
            var Iyy: f32 = 0;
            var Ixy: f32 = 0;

            for (0..window_size) |wy| {
                for (0..window_size) |wx| {
                    const idx = (y + @as(u32, @intCast(wy)) - half_window) * image.width + (x + @as(u32, @intCast(wx)) - half_window);
                    Ixx += Ix[idx] * Ix[idx];
                    Iyy += Iy[idx] * Iy[idx];
                    Ixy += Ix[idx] * Iy[idx];
                }
            }

            const det = Ixx * Iyy - Ixy * Ixy;
            const trace = Ixx + Iyy;
            const response = det - k * trace * trace;

            if (response > threshold) {
                try corners.append(Feature{
                    .x = x,
                    .y = y,
                    .strength = response,
                });
            }
        }
    }

    // Sort by strength and limit
    std.mem.sort(Feature, corners.items, {}, struct {
        fn lessThan(_: void, a: Feature, b: Feature) bool {
            return a.strength > b.strength;
        }
    }.lessThan);

    const result_count = @min(max_corners, @as(u32, @intCast(corners.items.len)));
    const result = try allocator.alloc(Feature, result_count);
    @memcpy(result, corners.items[0..result_count]);

    return result;
}

/// Simple region detection using connected components
pub fn detectRegions(
    image: *const Image,
    threshold: u8,
    min_size: u32,
    allocator: std.mem.Allocator,
) ![]BoundingBox {
    // Binary threshold
    var binary = try allocator.alloc(bool, image.width * image.height);
    defer allocator.free(binary);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const color = image.getPixel(x, y) orelse Color.BLACK;
            binary[y * image.width + x] = color.toGrayscale() > threshold;
        }
    }

    // Connected component labeling
    var labels = try allocator.alloc(u32, image.width * image.height);
    defer allocator.free(labels);
    @memset(labels, 0);

    var next_label: u32 = 1;
    var boxes = std.ArrayList(BoundingBox).init(allocator);
    defer boxes.deinit();

    y = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = y * image.width + x;
            if (binary[idx] and labels[idx] == 0) {
                // Flood fill to find connected component
                var min_x: u32 = x;
                var max_x: u32 = x;
                var min_y: u32 = y;
                var max_y: u32 = y;
                var pixel_count: u32 = 0;

                var stack = std.ArrayList(struct { x: u32, y: u32 }).init(allocator);
                defer stack.deinit();

                try stack.append(.{ .x = x, .y = y });
                labels[idx] = next_label;

                while (stack.items.len > 0) {
                    const pt = stack.pop();
                    pixel_count += 1;

                    min_x = @min(min_x, pt.x);
                    max_x = @max(max_x, pt.x);
                    min_y = @min(min_y, pt.y);
                    max_y = @max(max_y, pt.y);

                    // Check 4-neighbors
                    const neighbors = [_]struct { dx: i32, dy: i32 }{
                        .{ .dx = -1, .dy = 0 },
                        .{ .dx = 1, .dy = 0 },
                        .{ .dx = 0, .dy = -1 },
                        .{ .dx = 0, .dy = 1 },
                    };

                    for (neighbors) |n| {
                        const nx = @as(i32, @intCast(pt.x)) + n.dx;
                        const ny = @as(i32, @intCast(pt.y)) + n.dy;

                        if (nx >= 0 and nx < @as(i32, @intCast(image.width)) and
                            ny >= 0 and ny < @as(i32, @intCast(image.height)))
                        {
                            const nidx = @as(u32, @intCast(ny)) * image.width + @as(u32, @intCast(nx));
                            if (binary[nidx] and labels[nidx] == 0) {
                                labels[nidx] = next_label;
                                try stack.append(.{ .x = @intCast(nx), .y = @intCast(ny) });
                            }
                        }
                    }
                }

                if (pixel_count >= min_size) {
                    try boxes.append(BoundingBox{
                        .x = min_x,
                        .y = min_y,
                        .width = max_x - min_x + 1,
                        .height = max_y - min_y + 1,
                        .confidence = @as(f32, @floatFromInt(pixel_count)) / @as(f32, @floatFromInt((max_x - min_x + 1) * (max_y - min_y + 1))),
                    });
                }

                next_label += 1;
            }
        }
    }

    const result = try allocator.alloc(BoundingBox, boxes.items.len);
    @memcpy(result, boxes.items);
    return result;
}

/// Skin tone detection for face region hints
pub fn detectSkinRegions(
    image: *const Image,
    min_size: u32,
    allocator: std.mem.Allocator,
) ![]BoundingBox {
    // Create skin mask
    var skin_mask = try allocator.alloc(bool, image.width * image.height);
    defer allocator.free(skin_mask);

    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const color = image.getPixel(x, y) orelse Color.BLACK;
            skin_mask[y * image.width + x] = isSkinTone(color);
        }
    }

    // Find connected skin regions
    var labels = try allocator.alloc(u32, image.width * image.height);
    defer allocator.free(labels);
    @memset(labels, 0);

    var next_label: u32 = 1;
    var boxes = std.ArrayList(BoundingBox).init(allocator);
    defer boxes.deinit();

    y = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const idx = y * image.width + x;
            if (skin_mask[idx] and labels[idx] == 0) {
                var min_x: u32 = x;
                var max_x: u32 = x;
                var min_y: u32 = y;
                var max_y: u32 = y;
                var pixel_count: u32 = 0;

                var stack = std.ArrayList(struct { x: u32, y: u32 }).init(allocator);
                defer stack.deinit();

                try stack.append(.{ .x = x, .y = y });
                labels[idx] = next_label;

                while (stack.items.len > 0) {
                    const pt = stack.pop();
                    pixel_count += 1;

                    min_x = @min(min_x, pt.x);
                    max_x = @max(max_x, pt.x);
                    min_y = @min(min_y, pt.y);
                    max_y = @max(max_y, pt.y);

                    const neighbors = [_]struct { dx: i32, dy: i32 }{
                        .{ .dx = -1, .dy = 0 },
                        .{ .dx = 1, .dy = 0 },
                        .{ .dx = 0, .dy = -1 },
                        .{ .dx = 0, .dy = 1 },
                    };

                    for (neighbors) |n| {
                        const nx = @as(i32, @intCast(pt.x)) + n.dx;
                        const ny = @as(i32, @intCast(pt.y)) + n.dy;

                        if (nx >= 0 and nx < @as(i32, @intCast(image.width)) and
                            ny >= 0 and ny < @as(i32, @intCast(image.height)))
                        {
                            const nidx = @as(u32, @intCast(ny)) * image.width + @as(u32, @intCast(nx));
                            if (skin_mask[nidx] and labels[nidx] == 0) {
                                labels[nidx] = next_label;
                                try stack.append(.{ .x = @intCast(nx), .y = @intCast(ny) });
                            }
                        }
                    }
                }

                // Filter by aspect ratio (faces are roughly square-ish)
                const width = max_x - min_x + 1;
                const height = max_y - min_y + 1;
                const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));

                if (pixel_count >= min_size and aspect > 0.5 and aspect < 2.0) {
                    try boxes.append(BoundingBox{
                        .x = min_x,
                        .y = min_y,
                        .width = width,
                        .height = height,
                        .confidence = @as(f32, @floatFromInt(pixel_count)) / @as(f32, @floatFromInt(width * height)),
                    });
                }

                next_label += 1;
            }
        }
    }

    // Sort by size (larger regions first)
    std.mem.sort(BoundingBox, boxes.items, {}, struct {
        fn lessThan(_: void, a: BoundingBox, b: BoundingBox) bool {
            return a.width * a.height > b.width * b.height;
        }
    }.lessThan);

    const result = try allocator.alloc(BoundingBox, boxes.items.len);
    @memcpy(result, boxes.items);
    return result;
}

/// Check if color is likely skin tone (works for various skin colors)
fn isSkinTone(color: Color) bool {
    const r = color.r;
    const g = color.g;
    const b = color.b;

    // RGB-based skin detection
    // Rule 1: R > 95, G > 40, B > 20
    if (r <= 95 or g <= 40 or b <= 20) return false;

    // Rule 2: max(R,G,B) - min(R,G,B) > 15
    const max_val = @max(r, @max(g, b));
    const min_val = @min(r, @min(g, b));
    if (max_val - min_val <= 15) return false;

    // Rule 3: |R-G| > 15
    const r_i: i16 = r;
    const g_i: i16 = g;
    if (@abs(r_i - g_i) <= 15) return false;

    // Rule 4: R > G and R > B
    if (r <= g or r <= b) return false;

    return true;
}
