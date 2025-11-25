// Home Video Library - Thumbnail Generator
// Generate thumbnails at specific timestamps, intervals, or using smart detection

const std = @import("std");
const thumbnail = @import("thumbnail.zig");

pub const ThumbnailFormat = thumbnail.ThumbnailFormat;
pub const ThumbnailOptions = thumbnail.ThumbnailOptions;

// ============================================================================
// Thumbnail Generation Strategies
// ============================================================================

pub const GenerationStrategy = enum {
    at_timestamp, // Single frame at specific time
    at_interval, // Frames at regular intervals
    scene_changes, // Frames at detected scene changes
    keyframes_only, // Only keyframes
    smart, // Combination of methods for best coverage
};

pub const GeneratorConfig = struct {
    strategy: GenerationStrategy = .at_interval,
    interval_seconds: f64 = 10.0,
    max_thumbnails: ?u32 = null,
    skip_similar: bool = true, // Skip visually similar frames
    similarity_threshold: f32 = 0.95, // 0-1, higher = more strict
    prefer_interesting: bool = true, // Prefer frames with more visual complexity
    options: ThumbnailOptions = .{},
};

// ============================================================================
// Smart Thumbnail Selection
// ============================================================================

pub const FrameScore = struct {
    timestamp: i64, // microseconds
    score: f32,
    is_keyframe: bool = false,
    is_scene_change: bool = false,
    visual_complexity: f32 = 0,

    pub fn lessThan(_: void, a: FrameScore, b: FrameScore) bool {
        return a.score > b.score; // Higher score first
    }
};

pub const SmartSelector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SmartSelector {
        return .{ .allocator = allocator };
    }

    /// Calculate visual complexity of frame (edge density, color variance)
    pub fn calculateComplexity(pixels: []const u8, width: u32, height: u32) f32 {
        var edge_count: u32 = 0;
        var color_variance: f32 = 0;

        // Simple edge detection (Sobel-like)
        var y: u32 = 1;
        while (y < height - 1) : (y += 1) {
            var x: u32 = 1;
            while (x < width - 1) : (x += 1) {
                const idx = (y * width + x) * 3;
                const above = pixels[((y - 1) * width + x) * 3];
                const below = pixels[((y + 1) * width + x) * 3];
                const left = pixels[(y * width + (x - 1)) * 3];
                const right = pixels[(y * width + (x + 1)) * 3];

                const gx = @as(i32, right) - @as(i32, left);
                const gy = @as(i32, below) - @as(i32, above);
                const magnitude = @abs(gx) + @abs(gy);

                if (magnitude > 30) edge_count += 1;

                _ = idx;
            }
        }

        const total_pixels = width * height;
        const edge_density = @as(f32, @floatFromInt(edge_count)) / @as(f32, @floatFromInt(total_pixels));

        // Calculate color variance
        var r_sum: u64 = 0;
        var g_sum: u64 = 0;
        var b_sum: u64 = 0;

        for (0..total_pixels) |i| {
            r_sum += pixels[i * 3];
            g_sum += pixels[i * 3 + 1];
            b_sum += pixels[i * 3 + 2];
        }

        const r_avg = @as(f32, @floatFromInt(r_sum)) / @as(f32, @floatFromInt(total_pixels));
        const g_avg = @as(f32, @floatFromInt(g_sum)) / @as(f32, @floatFromInt(total_pixels));
        const b_avg = @as(f32, @floatFromInt(b_sum)) / @as(f32, @floatFromInt(total_pixels));

        var variance_sum: f32 = 0;
        for (0..total_pixels) |i| {
            const r_diff = @as(f32, @floatFromInt(pixels[i * 3])) - r_avg;
            const g_diff = @as(f32, @floatFromInt(pixels[i * 3 + 1])) - g_avg;
            const b_diff = @as(f32, @floatFromInt(pixels[i * 3 + 2])) - b_avg;
            variance_sum += r_diff * r_diff + g_diff * g_diff + b_diff * b_diff;
        }

        color_variance = variance_sum / @as(f32, @floatFromInt(total_pixels * 3));

        // Combine metrics (normalized)
        return (edge_density * 100.0 + color_variance / 10000.0) / 2.0;
    }

    /// Check if two frames are visually similar
    pub fn areSimilar(pixels1: []const u8, pixels2: []const u8, width: u32, height: u32, threshold: f32) bool {
        const total = width * height * 3;
        var diff_sum: u64 = 0;

        for (0..total) |i| {
            const diff = @abs(@as(i32, pixels1[i]) - @as(i32, pixels2[i]));
            diff_sum += @as(u64, @intCast(diff));
        }

        const avg_diff = @as(f32, @floatFromInt(diff_sum)) / @as(f32, @floatFromInt(total));
        const similarity = 1.0 - (avg_diff / 255.0);

        return similarity >= threshold;
    }

    /// Select best N frames from candidates
    pub fn selectBest(self: *SmartSelector, candidates: []FrameScore, count: u32) ![]FrameScore {
        // Sort by score (highest first)
        std.mem.sort(FrameScore, candidates, {}, FrameScore.lessThan);

        const n = @min(count, @as(u32, @intCast(candidates.len)));
        var result = try self.allocator.alloc(FrameScore, n);
        @memcpy(result, candidates[0..n]);

        return result;
    }
};

// ============================================================================
// Thumbnail Batch Generator
// ============================================================================

pub const BatchGenerator = struct {
    allocator: std.mem.Allocator,
    config: GeneratorConfig,

    pub fn init(allocator: std.mem.Allocator, config: GeneratorConfig) BatchGenerator {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Generate list of timestamps for thumbnail extraction
    pub fn generateTimestamps(self: *BatchGenerator, duration_us: i64) ![]i64 {
        var timestamps = std.ArrayList(i64).init(self.allocator);
        errdefer timestamps.deinit();

        switch (self.config.strategy) {
            .at_interval => {
                const interval_us = @as(i64, @intFromFloat(self.config.interval_seconds * 1_000_000.0));
                var t: i64 = 0;

                while (t < duration_us) {
                    try timestamps.append(t);
                    t += interval_us;

                    if (self.config.max_thumbnails) |max| {
                        if (timestamps.items.len >= max) break;
                    }
                }
            },
            .at_timestamp => {
                // Single timestamp (would be specified separately)
                try timestamps.append(duration_us / 2); // Default to middle
            },
            else => {
                // For other strategies, use interval as fallback
                const interval_us = @as(i64, @intFromFloat(self.config.interval_seconds * 1_000_000.0));
                var t: i64 = 0;
                while (t < duration_us) {
                    try timestamps.append(t);
                    t += interval_us;
                }
            },
        }

        return timestamps.toOwnedSlice();
    }
};
