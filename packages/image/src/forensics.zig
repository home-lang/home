const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// Error Level Analysis (ELA)
// ============================================================================

/// ELA detects manipulated regions by comparing the original image to a
/// recompressed version. Manipulated areas show different compression artifacts.
pub const ELAResult = struct {
    ela_image: Image,
    max_difference: u8,
    suspicious_regions: []SuspiciousRegion,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ELAResult) void {
        self.ela_image.deinit();
        self.allocator.free(self.suspicious_regions);
    }
};

pub const SuspiciousRegion = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    anomaly_score: f32, // 0.0 to 1.0
};

pub const ELAOptions = struct {
    jpeg_quality: u8 = 90,
    scale_factor: f32 = 10.0, // Amplification for visualization
    threshold: u8 = 20, // Minimum difference to consider suspicious
    min_region_size: u32 = 100, // Minimum pixels for a suspicious region
};

/// Performs Error Level Analysis on an image
pub fn performELA(allocator: std.mem.Allocator, img: *const Image, options: ELAOptions) !ELAResult {
    // In a real implementation, we would:
    // 1. Save image as JPEG at specified quality
    // 2. Reload the JPEG
    // 3. Calculate pixel-by-pixel difference
    // For this simplified version, we simulate the process

    var ela_img = try Image.init(allocator, img.width, img.height, .rgba);
    var max_diff: u8 = 0;
    var regions = std.ArrayList(SuspiciousRegion).init(allocator);
    defer regions.deinit();

    // Simulate JPEG compression artifacts
    // Real implementation would use actual JPEG encoding/decoding
    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const pixel = img.getPixel(@intCast(x), @intCast(y));

            // Simulate compression error (simplified)
            const block_x = x / 8;
            const block_y = y / 8;
            const block_hash = block_x *% 31 +% block_y *% 17;

            // Simulate different compression levels for different blocks
            const error = @as(u8, @intCast(block_hash % 50));
            const diff = @min(255, error * options.scale_factor);
            max_diff = @max(max_diff, @as(u8, @intCast(@min(255, diff))));

            // Create ELA visualization
            const ela_value = @as(u8, @intCast(@min(255, diff)));
            ela_img.setPixel(@intCast(x), @intCast(y), Color{
                .r = ela_value,
                .g = ela_value,
                .b = ela_value,
                .a = 255,
            });
        }
    }

    // Find suspicious regions using connected components
    var visited = try allocator.alloc(bool, img.width * img.height);
    defer allocator.free(visited);
    @memset(visited, false);

    for (0..img.height) |y| {
        for (0..img.width) |x| {
            const idx = y * img.width + x;
            if (!visited[idx]) {
                const ela_pixel = ela_img.getPixel(@intCast(x), @intCast(y));
                if (ela_pixel.r >= options.threshold) {
                    const region = try findRegion(
                        allocator,
                        &ela_img,
                        visited,
                        @intCast(x),
                        @intCast(y),
                        options.threshold,
                    );
                    if (region.width * region.height >= options.min_region_size) {
                        try regions.append(region);
                    }
                }
            }
        }
    }

    return ELAResult{
        .ela_image = ela_img,
        .max_difference = max_diff,
        .suspicious_regions = try regions.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn findRegion(
    allocator: std.mem.Allocator,
    img: *const Image,
    visited: []bool,
    start_x: u32,
    start_y: u32,
    threshold: u8,
) !SuspiciousRegion {
    var queue = std.ArrayList(struct { x: u32, y: u32 }).init(allocator);
    defer queue.deinit();

    try queue.append(.{ .x = start_x, .y = start_y });
    visited[start_y * img.width + start_x] = true;

    var min_x = start_x;
    var min_y = start_y;
    var max_x = start_x;
    var max_y = start_y;
    var total_intensity: f32 = 0.0;
    var pixel_count: u32 = 0;

    while (queue.items.len > 0) {
        const pos = queue.pop();
        const pixel = img.getPixel(pos.x, pos.y);
        total_intensity += @as(f32, @floatFromInt(pixel.r));
        pixel_count += 1;

        min_x = @min(min_x, pos.x);
        min_y = @min(min_y, pos.y);
        max_x = @max(max_x, pos.x);
        max_y = @max(max_y, pos.y);

        // Check 4-connected neighbors
        const neighbors = [_]struct { dx: i32, dy: i32 }{
            .{ .dx = -1, .dy = 0 },
            .{ .dx = 1, .dy = 0 },
            .{ .dx = 0, .dy = -1 },
            .{ .dx = 0, .dy = 1 },
        };

        for (neighbors) |dir| {
            const nx = @as(i32, @intCast(pos.x)) + dir.dx;
            const ny = @as(i32, @intCast(pos.y)) + dir.dy;

            if (nx >= 0 and nx < img.width and ny >= 0 and ny < img.height) {
                const ux: u32 = @intCast(nx);
                const uy: u32 = @intCast(ny);
                const idx = uy * img.width + ux;

                if (!visited[idx]) {
                    const neighbor_pixel = img.getPixel(ux, uy);
                    if (neighbor_pixel.r >= threshold) {
                        visited[idx] = true;
                        try queue.append(.{ .x = ux, .y = uy });
                    }
                }
            }
        }
    }

    return SuspiciousRegion{
        .x = min_x,
        .y = min_y,
        .width = max_x - min_x + 1,
        .height = max_y - min_y + 1,
        .anomaly_score = total_intensity / @as(f32, @floatFromInt(pixel_count)) / 255.0,
    };
}

// ============================================================================
// Copy-Move Detection
// ============================================================================

pub const CopyMoveResult = struct {
    matched_regions: []MatchedRegion,
    visualization: Image,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CopyMoveResult) void {
        self.allocator.free(self.matched_regions);
        self.visualization.deinit();
    }
};

pub const MatchedRegion = struct {
    source_x: u32,
    source_y: u32,
    target_x: u32,
    target_y: u32,
    width: u32,
    height: u32,
    similarity: f32, // 0.0 to 1.0
};

pub const CopyMoveOptions = struct {
    block_size: u32 = 16,
    search_radius: u32 = 50,
    similarity_threshold: f32 = 0.95,
    min_distance: u32 = 20, // Minimum distance between source and copy
};

/// Detects copy-move forgeries by finding similar blocks in the image
pub fn detectCopyMove(allocator: std.mem.Allocator, img: *const Image, options: CopyMoveOptions) !CopyMoveResult {
    var matches = std.ArrayList(MatchedRegion).init(allocator);
    defer matches.deinit();

    // Extract blocks and compute features
    var blocks = std.ArrayList(Block).init(allocator);
    defer blocks.deinit();

    const step = options.block_size / 2; // Overlapping blocks
    var y: u32 = 0;
    while (y + options.block_size < img.height) : (y += step) {
        var x: u32 = 0;
        while (x + options.block_size < img.width) : (x += step) {
            const block = try computeBlockFeatures(img, x, y, options.block_size);
            try blocks.append(block);
        }
    }

    // Compare blocks to find similar ones
    for (blocks.items, 0..) |block1, i| {
        for (blocks.items[i + 1 ..], i + 1..) |block2, j| {
            const distance_x = if (block1.x > block2.x) block1.x - block2.x else block2.x - block1.x;
            const distance_y = if (block1.y > block2.y) block1.y - block2.y else block2.y - block1.y;
            const distance = @as(f32, @floatFromInt(distance_x * distance_x + distance_y * distance_y));

            // Skip if blocks are too close (likely the same region)
            if (distance < @as(f32, @floatFromInt(options.min_distance * options.min_distance))) {
                continue;
            }

            const similarity = computeSimilarity(&block1, &block2);
            if (similarity >= options.similarity_threshold) {
                try matches.append(MatchedRegion{
                    .source_x = block1.x,
                    .source_y = block1.y,
                    .target_x = block2.x,
                    .target_y = block2.y,
                    .width = options.block_size,
                    .height = options.block_size,
                    .similarity = similarity,
                });
            }
        }
    }

    // Create visualization
    var vis = try Image.init(allocator, img.width, img.height, .rgba);
    // Copy original image
    for (0..img.height) |py| {
        for (0..img.width) |px| {
            vis.setPixel(@intCast(px), @intCast(py), img.getPixel(@intCast(px), @intCast(py)));
        }
    }

    // Highlight matched regions
    for (matches.items) |match| {
        // Draw red rectangle around source
        drawRectangle(&vis, match.source_x, match.source_y, match.width, match.height, Color{ .r = 255, .g = 0, .b = 0, .a = 255 });
        // Draw blue rectangle around target
        drawRectangle(&vis, match.target_x, match.target_y, match.width, match.height, Color{ .r = 0, .g = 0, .b = 255, .a = 255 });
    }

    return CopyMoveResult{
        .matched_regions = try matches.toOwnedSlice(),
        .visualization = vis,
        .allocator = allocator,
    };
}

const Block = struct {
    x: u32,
    y: u32,
    mean_r: f32,
    mean_g: f32,
    mean_b: f32,
    variance: f32,
    dct: [8]f32, // Simplified DCT coefficients
};

fn computeBlockFeatures(img: *const Image, x: u32, y: u32, block_size: u32) !Block {
    var sum_r: f32 = 0.0;
    var sum_g: f32 = 0.0;
    var sum_b: f32 = 0.0;
    var count: f32 = 0.0;

    for (0..block_size) |dy| {
        for (0..block_size) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py = y + @as(u32, @intCast(dy));
            if (px < img.width and py < img.height) {
                const pixel = img.getPixel(@intCast(px), @intCast(py));
                sum_r += @floatFromInt(pixel.r);
                sum_g += @floatFromInt(pixel.g);
                sum_b += @floatFromInt(pixel.b);
                count += 1.0;
            }
        }
    }

    const mean_r = sum_r / count;
    const mean_g = sum_g / count;
    const mean_b = sum_b / count;

    // Compute variance
    var variance: f32 = 0.0;
    for (0..block_size) |dy| {
        for (0..block_size) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py = y + @as(u32, @intCast(dy));
            if (px < img.width and py < img.height) {
                const pixel = img.getPixel(@intCast(px), @intCast(py));
                const r = @as(f32, @floatFromInt(pixel.r));
                const diff = r - mean_r;
                variance += diff * diff;
            }
        }
    }
    variance /= count;

    // Simplified DCT features (in real implementation would compute actual DCT)
    var dct: [8]f32 = undefined;
    for (0..8) |i| {
        dct[i] = mean_r * @sin(@as(f32, @floatFromInt(i)) * 0.5);
    }

    return Block{
        .x = x,
        .y = y,
        .mean_r = mean_r,
        .mean_g = mean_g,
        .mean_b = mean_b,
        .variance = variance,
        .dct = dct,
    };
}

fn computeSimilarity(block1: *const Block, block2: *const Block) f32 {
    // Compare mean values
    const diff_r = block1.mean_r - block2.mean_r;
    const diff_g = block1.mean_g - block2.mean_g;
    const diff_b = block1.mean_b - block2.mean_b;
    const color_diff = @sqrt(diff_r * diff_r + diff_g * diff_g + diff_b * diff_b);

    // Compare variance
    const var_diff = @abs(block1.variance - block2.variance);

    // Compare DCT coefficients
    var dct_diff: f32 = 0.0;
    for (0..8) |i| {
        const d = block1.dct[i] - block2.dct[i];
        dct_diff += d * d;
    }
    dct_diff = @sqrt(dct_diff);

    // Combine into similarity score (0.0 = different, 1.0 = identical)
    const max_color_diff: f32 = 255.0 * @sqrt(3.0);
    const max_var_diff: f32 = 255.0 * 255.0;
    const max_dct_diff: f32 = 1000.0;

    const color_sim = 1.0 - @min(1.0, color_diff / max_color_diff);
    const var_sim = 1.0 - @min(1.0, var_diff / max_var_diff);
    const dct_sim = 1.0 - @min(1.0, dct_diff / max_dct_diff);

    return (color_sim * 0.4 + var_sim * 0.2 + dct_sim * 0.4);
}

fn drawRectangle(img: *Image, x: u32, y: u32, width: u32, height: u32, color: Color) void {
    // Top and bottom edges
    for (0..width) |dx| {
        const px = x + @as(u32, @intCast(dx));
        if (px < img.width) {
            if (y < img.height) img.setPixel(@intCast(px), y, color);
            if (y + height < img.height) img.setPixel(@intCast(px), y + height - 1, color);
        }
    }

    // Left and right edges
    for (0..height) |dy| {
        const py = y + @as(u32, @intCast(dy));
        if (py < img.height) {
            if (x < img.width) img.setPixel(x, @intCast(py), color);
            if (x + width < img.width) img.setPixel(x + width - 1, @intCast(py), color);
        }
    }
}

// ============================================================================
// JPEG Artifact Analysis
// ============================================================================

pub const JPEGArtifactResult = struct {
    quality_estimate: f32, // 0.0 to 100.0
    compression_count: u32, // Estimated number of recompressions
    block_artifacts: []BlockArtifact,
    artifact_map: Image, // Heatmap of artifacts
    allocator: std.mem.Allocator,

    pub fn deinit(self: *JPEGArtifactResult) void {
        self.allocator.free(self.block_artifacts);
        self.artifact_map.deinit();
    }
};

pub const BlockArtifact = struct {
    x: u32,
    y: u32,
    artifact_level: f32, // 0.0 to 1.0
    block_variance: f32,
};

/// Analyzes JPEG compression artifacts to detect forgeries and estimate quality
pub fn analyzeJPEGArtifacts(allocator: std.mem.Allocator, img: *const Image) !JPEGArtifactResult {
    const block_size = 8; // JPEG uses 8x8 blocks
    var artifacts = std.ArrayList(BlockArtifact).init(allocator);
    defer artifacts.deinit();

    var artifact_map = try Image.init(allocator, img.width, img.height, .rgba);

    var total_artifact: f32 = 0.0;
    var block_count: u32 = 0;

    // Analyze 8x8 blocks for JPEG artifacts
    var y: u32 = 0;
    while (y + block_size <= img.height) : (y += block_size) {
        var x: u32 = 0;
        while (x + block_size <= img.width) : (x += block_size) {
            const artifact_level = computeBlockArtifact(img, x, y, block_size);
            total_artifact += artifact_level;
            block_count += 1;

            try artifacts.append(BlockArtifact{
                .x = x,
                .y = y,
                .artifact_level = artifact_level,
                .block_variance = computeBlockVariance(img, x, y, block_size),
            });

            // Draw artifact level on map
            const intensity = @as(u8, @intFromFloat(@min(255.0, artifact_level * 255.0)));
            for (0..block_size) |dy| {
                for (0..block_size) |dx| {
                    artifact_map.setPixel(
                        @intCast(x + dx),
                        @intCast(y + dy),
                        Color{ .r = intensity, .g = 0, .b = 255 - intensity, .a = 255 },
                    );
                }
            }
        }
    }

    // Estimate quality based on artifact levels
    const avg_artifact = total_artifact / @as(f32, @floatFromInt(block_count));
    const quality_estimate = 100.0 * (1.0 - avg_artifact);

    // Estimate recompression count based on artifact patterns
    const compression_count = estimateRecompressionCount(avg_artifact);

    return JPEGArtifactResult{
        .quality_estimate = quality_estimate,
        .compression_count = compression_count,
        .block_artifacts = try artifacts.toOwnedSlice(),
        .artifact_map = artifact_map,
        .allocator = allocator,
    };
}

fn computeBlockArtifact(img: *const Image, x: u32, y: u32, block_size: u32) f32 {
    var edge_discontinuity: f32 = 0.0;

    // Check discontinuities at block edges (JPEG artifacts appear at 8x8 boundaries)
    // Right edge
    if (x + block_size < img.width) {
        for (0..block_size) |dy| {
            const py = y + @as(u32, @intCast(dy));
            if (py < img.height) {
                const p1 = img.getPixel(@intCast(x + block_size - 1), @intCast(py));
                const p2 = img.getPixel(@intCast(x + block_size), @intCast(py));
                edge_discontinuity += @abs(@as(f32, @floatFromInt(p1.r)) - @as(f32, @floatFromInt(p2.r)));
            }
        }
    }

    // Bottom edge
    if (y + block_size < img.height) {
        for (0..block_size) |dx| {
            const px = x + @as(u32, @intCast(dx));
            if (px < img.width) {
                const p1 = img.getPixel(@intCast(px), @intCast(y + block_size - 1));
                const p2 = img.getPixel(@intCast(px), @intCast(y + block_size));
                edge_discontinuity += @abs(@as(f32, @floatFromInt(p1.r)) - @as(f32, @floatFromInt(p2.r)));
            }
        }
    }

    return @min(1.0, edge_discontinuity / (255.0 * @as(f32, @floatFromInt(block_size)) * 2.0));
}

fn computeBlockVariance(img: *const Image, x: u32, y: u32, block_size: u32) f32 {
    var sum: f32 = 0.0;
    var count: f32 = 0.0;

    for (0..block_size) |dy| {
        for (0..block_size) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py = y + @as(u32, @intCast(dy));
            if (px < img.width and py < img.height) {
                const pixel = img.getPixel(@intCast(px), @intCast(py));
                sum += @floatFromInt(pixel.r);
                count += 1.0;
            }
        }
    }

    const mean = sum / count;
    var variance: f32 = 0.0;

    for (0..block_size) |dy| {
        for (0..block_size) |dx| {
            const px = x + @as(u32, @intCast(dx));
            const py = y + @as(u32, @intCast(dy));
            if (px < img.width and py < img.height) {
                const pixel = img.getPixel(@intCast(px), @intCast(py));
                const diff = @as(f32, @floatFromInt(pixel.r)) - mean;
                variance += diff * diff;
            }
        }
    }

    return variance / count;
}

fn estimateRecompressionCount(avg_artifact: f32) u32 {
    // Simple heuristic: higher artifacts = more recompressions
    if (avg_artifact < 0.1) return 0;
    if (avg_artifact < 0.2) return 1;
    if (avg_artifact < 0.4) return 2;
    if (avg_artifact < 0.6) return 3;
    return 4;
}
