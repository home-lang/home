// Home Video Library - Scene Cut Detection
// Shot boundary detection using histogram and motion analysis

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Scene Cut Detection
// ============================================================================

pub const ScenecutOptions = struct {
    threshold: f32 = 0.3, // Histogram difference threshold (0-1)
    min_scene_length_frames: u32 = 25, // Minimum scene length
    adaptive_threshold: bool = true, // Use adaptive thresholding
    check_motion: bool = true, // Check motion vectors
};

pub const ScenecutMethod = enum {
    histogram, // Histogram-based
    pixel_difference, // Frame difference
    edge_change, // Edge change ratio
    combined, // Combined metrics
};

pub const ScenecutResult = struct {
    frame_number: u32,
    confidence: f32, // 0-1
    method: ScenecutMethod,
    histogram_diff: f32,
    pixel_diff: f32,
    edge_diff: f32,
};

pub const ScenecutDetector = struct {
    options: ScenecutOptions,
    previous_histogram: ?Histogram = null,
    previous_frame: ?[]u8 = null,
    previous_edges: ?[]f32 = null,
    frame_count: u32 = 0,
    last_scene_frame: u32 = 0,
    history: std.ArrayList(f32), // Difference history for adaptive threshold
    allocator: Allocator,

    pub fn init(allocator: Allocator, options: ScenecutOptions) ScenecutDetector {
        return .{
            .options = options,
            .history = std.ArrayList(f32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScenecutDetector) void {
        if (self.previous_frame) |frame| {
            self.allocator.free(frame);
        }
        if (self.previous_edges) |edges| {
            self.allocator.free(edges);
        }
        self.history.deinit();
    }

    pub fn processFrame(
        self: *ScenecutDetector,
        frame_data: []const u8,
        width: u32,
        height: u32,
    ) !?ScenecutResult {
        self.frame_count += 1;

        const pixels = width * height;
        if (frame_data.len < pixels) return null;

        const luma = frame_data[0..pixels];

        // Calculate current histogram
        const current_hist = Histogram.fromFrame(luma);

        var histogram_diff: f32 = 0;
        var pixel_diff: f32 = 0;
        var edge_diff: f32 = 0;

        if (self.previous_histogram) |prev_hist| {
            // Check minimum scene length
            if (self.frame_count - self.last_scene_frame < self.options.min_scene_length_frames) {
                self.previous_histogram = current_hist;
                return null;
            }

            // Calculate histogram difference
            histogram_diff = 1.0 - prev_hist.compare(&current_hist);

            // Calculate pixel difference if enabled
            if (self.previous_frame) |prev_frame| {
                pixel_diff = calculatePixelDifference(prev_frame, luma);
            }

            // Calculate edge difference
            const current_edges = try calculateEdgeMap(luma, width, height, self.allocator);
            defer self.allocator.free(current_edges);

            if (self.previous_edges) |prev_edges| {
                edge_diff = calculateEdgeDifference(prev_edges, current_edges);
            }

            // Store current edges for next frame
            if (self.previous_edges) |old_edges| {
                self.allocator.free(old_edges);
            }
            self.previous_edges = try self.allocator.dupe(f32, current_edges);

            // Determine threshold
            var threshold = self.options.threshold;
            if (self.options.adaptive_threshold) {
                threshold = try self.calculateAdaptiveThreshold();
            }

            // Add to history
            try self.history.append(histogram_diff);
            if (self.history.items.len > 100) {
                _ = self.history.orderedRemove(0);
            }

            // Determine if this is a scene cut
            const combined_diff = (histogram_diff * 0.5) + (pixel_diff * 0.3) + (edge_diff * 0.2);

            if (combined_diff > threshold) {
                // Scene cut detected
                self.last_scene_frame = self.frame_count;

                // Update previous frame
                if (self.previous_frame) |old_frame| {
                    self.allocator.free(old_frame);
                }
                self.previous_frame = try self.allocator.dupe(u8, luma);
                self.previous_histogram = current_hist;

                return ScenecutResult{
                    .frame_number = self.frame_count,
                    .confidence = @min(combined_diff / threshold, 1.0),
                    .method = .combined,
                    .histogram_diff = histogram_diff,
                    .pixel_diff = pixel_diff,
                    .edge_diff = edge_diff,
                };
            }
        } else {
            // First frame
            self.previous_frame = try self.allocator.dupe(u8, luma);
            self.previous_edges = try calculateEdgeMap(luma, width, height, self.allocator);
        }

        self.previous_histogram = current_hist;

        // Update previous frame
        if (self.previous_frame) |old_frame| {
            @memcpy(old_frame, luma);
        }

        return null;
    }

    fn calculateAdaptiveThreshold(self: *const ScenecutDetector) !f32 {
        if (self.history.items.len < 10) {
            return self.options.threshold;
        }

        // Calculate mean and std dev of recent differences
        var sum: f32 = 0;
        for (self.history.items) |val| {
            sum += val;
        }
        const mean = sum / @as(f32, @floatFromInt(self.history.items.len));

        var variance: f32 = 0;
        for (self.history.items) |val| {
            const diff = val - mean;
            variance += diff * diff;
        }
        variance /= @as(f32, @floatFromInt(self.history.items.len));
        const std_dev = @sqrt(variance);

        // Adaptive threshold = mean + 2 * std_dev
        return @min(mean + 2.0 * std_dev, 1.0);
    }

    pub fn reset(self: *ScenecutDetector) void {
        if (self.previous_frame) |frame| {
            self.allocator.free(frame);
            self.previous_frame = null;
        }
        if (self.previous_edges) |edges| {
            self.allocator.free(edges);
            self.previous_edges = null;
        }
        self.previous_histogram = null;
        self.frame_count = 0;
        self.last_scene_frame = 0;
        self.history.clearRetainingCapacity();
    }
};

// ============================================================================
// Histogram
// ============================================================================

pub const Histogram = struct {
    bins: [256]u32 = [_]u32{0} ** 256,
    total_pixels: u32 = 0,

    pub fn fromFrame(luma: []const u8) Histogram {
        var hist = Histogram{};

        for (luma) |pixel| {
            hist.bins[pixel] += 1;
            hist.total_pixels += 1;
        }

        return hist;
    }

    /// Compare two histograms (returns similarity 0-1)
    pub fn compare(self: *const Histogram, other: *const Histogram) f32 {
        if (self.total_pixels == 0 or other.total_pixels == 0) return 0.0;

        // Bhattacharyya coefficient
        var sum: f64 = 0;

        for (self.bins, other.bins) |a, b| {
            const a_norm = @sqrt(@as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(self.total_pixels)));
            const b_norm = @sqrt(@as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(other.total_pixels)));
            sum += a_norm * b_norm;
        }

        return @floatCast(@min(sum, 1.0));
    }

    pub fn chiSquared(self: *const Histogram, other: *const Histogram) f32 {
        if (self.total_pixels == 0 or other.total_pixels == 0) return 1.0;

        var chi_sq: f64 = 0;

        for (self.bins, other.bins) |a, b| {
            const a_norm = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(self.total_pixels));
            const b_norm = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(other.total_pixels));

            if (a_norm + b_norm > 0) {
                const diff = a_norm - b_norm;
                chi_sq += (diff * diff) / (a_norm + b_norm);
            }
        }

        return @floatCast(@min(chi_sq, 1.0));
    }
};

fn calculatePixelDifference(frame1: []const u8, frame2: []const u8) f32 {
    if (frame1.len != frame2.len) return 1.0;

    var sum_diff: u64 = 0;
    for (frame1, frame2) |p1, p2| {
        const diff = if (p1 > p2) p1 - p2 else p2 - p1;
        sum_diff += diff;
    }

    const max_diff = @as(u64, 255) * frame1.len;
    return @as(f32, @floatFromInt(sum_diff)) / @as(f32, @floatFromInt(max_diff));
}

// ============================================================================
// Edge Detection
// ============================================================================

fn calculateEdgeMap(
    luma: []const u8,
    width: u32,
    height: u32,
    allocator: Allocator,
) ![]f32 {
    var edges = try allocator.alloc(f32, luma.len);

    for (0..height) |y| {
        for (0..width) |x| {
            const idx = y * width + x;

            if (x == 0 or y == 0 or x == width - 1 or y == height - 1) {
                edges[idx] = 0;
                continue;
            }

            // Sobel operator
            const nw = @as(f32, @floatFromInt(luma[idx - width - 1]));
            const n = @as(f32, @floatFromInt(luma[idx - width]));
            const ne = @as(f32, @floatFromInt(luma[idx - width + 1]));
            const w = @as(f32, @floatFromInt(luma[idx - 1]));
            const e = @as(f32, @floatFromInt(luma[idx + 1]));
            const sw = @as(f32, @floatFromInt(luma[idx + width - 1]));
            const s = @as(f32, @floatFromInt(luma[idx + width]));
            const se = @as(f32, @floatFromInt(luma[idx + width + 1]));

            const gx = (ne + 2.0 * e + se) - (nw + 2.0 * w + sw);
            const gy = (sw + 2.0 * s + se) - (nw + 2.0 * n + ne);

            edges[idx] = @sqrt(gx * gx + gy * gy);
        }
    }

    return edges;
}

fn calculateEdgeDifference(edges1: []const f32, edges2: []const f32) f32 {
    if (edges1.len != edges2.len) return 1.0;

    var sum_diff: f64 = 0;
    var sum_magnitude: f64 = 0;

    for (edges1, edges2) |e1, e2| {
        const diff = @abs(e1 - e2);
        sum_diff += diff;
        sum_magnitude += @max(e1, e2);
    }

    if (sum_magnitude == 0) return 0;
    return @floatCast(sum_diff / sum_magnitude);
}

// ============================================================================
// Motion Analysis
// ============================================================================

pub const MotionVector = struct {
    dx: i16,
    dy: i16,
    magnitude: f32,
};

pub const MotionAnalyzer = struct {
    block_size: u32 = 16,
    search_range: u32 = 16,

    pub fn analyzeMotion(
        self: *const MotionAnalyzer,
        prev_frame: []const u8,
        curr_frame: []const u8,
        width: u32,
        height: u32,
        allocator: Allocator,
    ) ![]MotionVector {
        const blocks_x = width / self.block_size;
        const blocks_y = height / self.block_size;
        const num_blocks = blocks_x * blocks_y;

        var vectors = try allocator.alloc(MotionVector, num_blocks);

        for (0..blocks_y) |by| {
            for (0..blocks_x) |bx| {
                const block_idx = by * blocks_x + bx;
                vectors[block_idx] = try self.findMotionVector(
                    prev_frame,
                    curr_frame,
                    @intCast(bx * self.block_size),
                    @intCast(by * self.block_size),
                    width,
                    height,
                );
            }
        }

        return vectors;
    }

    fn findMotionVector(
        self: *const MotionAnalyzer,
        prev_frame: []const u8,
        curr_frame: []const u8,
        block_x: u32,
        block_y: u32,
        width: u32,
        height: u32,
    ) !MotionVector {
        var best_dx: i16 = 0;
        var best_dy: i16 = 0;
        var best_sad: u32 = std.math.maxInt(u32);

        const search_start_x: i32 = @as(i32, @intCast(block_x)) - @as(i32, @intCast(self.search_range));
        const search_end_x: i32 = @as(i32, @intCast(block_x)) + @as(i32, @intCast(self.search_range));
        const search_start_y: i32 = @as(i32, @intCast(block_y)) - @as(i32, @intCast(self.search_range));
        const search_end_y: i32 = @as(i32, @intCast(block_y)) + @as(i32, @intCast(self.search_range));

        var search_y = search_start_y;
        while (search_y <= search_end_y) : (search_y += 1) {
            if (search_y < 0 or search_y + @as(i32, @intCast(self.block_size)) > height) continue;

            var search_x = search_start_x;
            while (search_x <= search_end_x) : (search_x += 1) {
                if (search_x < 0 or search_x + @as(i32, @intCast(self.block_size)) > width) continue;

                const sad = self.calculateSAD(
                    prev_frame,
                    curr_frame,
                    block_x,
                    block_y,
                    @intCast(search_x),
                    @intCast(search_y),
                    width,
                );

                if (sad < best_sad) {
                    best_sad = sad;
                    best_dx = @intCast(search_x - @as(i32, @intCast(block_x)));
                    best_dy = @intCast(search_y - @as(i32, @intCast(block_y)));
                }
            }
        }

        const magnitude = @sqrt(@as(f32, @floatFromInt(best_dx * best_dx + best_dy * best_dy)));

        return MotionVector{
            .dx = best_dx,
            .dy = best_dy,
            .magnitude = magnitude,
        };
    }

    fn calculateSAD(
        self: *const MotionAnalyzer,
        frame1: []const u8,
        frame2: []const u8,
        x1: u32,
        y1: u32,
        x2: u32,
        y2: u32,
        width: u32,
    ) u32 {
        var sad: u32 = 0;

        for (0..self.block_size) |dy| {
            for (0..self.block_size) |dx| {
                const idx1 = (y1 + @as(u32, @intCast(dy))) * width + (x1 + @as(u32, @intCast(dx)));
                const idx2 = (y2 + @as(u32, @intCast(dy))) * width + (x2 + @as(u32, @intCast(dx)));

                if (idx1 >= frame1.len or idx2 >= frame2.len) continue;

                const p1 = frame1[idx1];
                const p2 = frame2[idx2];
                sad += if (p1 > p2) p1 - p2 else p2 - p1;
            }
        }

        return sad;
    }

    pub fn getAverageMotion(vectors: []const MotionVector) f32 {
        if (vectors.len == 0) return 0;

        var sum: f32 = 0;
        for (vectors) |vec| {
            sum += vec.magnitude;
        }

        return sum / @as(f32, @floatFromInt(vectors.len));
    }
};

// ============================================================================
// Shot Boundary Classification
// ============================================================================

pub const ShotBoundaryType = enum {
    cut, // Hard cut
    fade_in, // Fade from black
    fade_out, // Fade to black
    dissolve, // Cross-dissolve
    wipe, // Wipe transition
    unknown,
};

pub fn classifyTransition(
    prev_frame: []const u8,
    curr_frame: []const u8,
    width: u32,
    height: u32,
) ShotBoundaryType {
    const pixels = width * height;
    if (prev_frame.len < pixels or curr_frame.len < pixels) return .unknown;

    // Calculate average brightness
    var prev_brightness: u32 = 0;
    var curr_brightness: u32 = 0;

    for (0..pixels) |i| {
        prev_brightness += prev_frame[i];
        curr_brightness += curr_frame[i];
    }

    const prev_avg = @as(f32, @floatFromInt(prev_brightness)) / @as(f32, @floatFromInt(pixels));
    const curr_avg = @as(f32, @floatFromInt(curr_brightness)) / @as(f32, @floatFromInt(pixels));

    // Check for fades
    if (curr_avg < 20 and prev_avg > 50) return .fade_out;
    if (prev_avg < 20 and curr_avg > 50) return .fade_in;

    // Check for dissolve (moderate brightness change with high pixel correlation)
    const brightness_change = @abs(curr_avg - prev_avg);
    if (brightness_change > 10 and brightness_change < 50) {
        // Could be dissolve - would need more analysis
        return .dissolve;
    }

    // Default to cut
    return .cut;
}

// ============================================================================
// Scene Analysis
// ============================================================================

pub const Scene = struct {
    start_frame: u32,
    end_frame: u32,
    duration_frames: u32,
    average_brightness: f32,
    average_motion: f32,
    shot_count: u32,

    pub fn getDurationSeconds(self: *const Scene, fps: f32) f32 {
        return @as(f32, @floatFromInt(self.duration_frames)) / fps;
    }
};

pub const SceneAnalyzer = struct {
    scenes: std.ArrayList(Scene),
    current_scene_start: u32 = 0,
    frame_count: u32 = 0,
    brightness_sum: f64 = 0,
    motion_sum: f64 = 0,
    shot_count: u32 = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) SceneAnalyzer {
        return .{
            .scenes = std.ArrayList(Scene).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SceneAnalyzer) void {
        self.scenes.deinit();
    }

    pub fn onSceneCut(self: *SceneAnalyzer, frame_number: u32, brightness: f32, motion: f32) !void {
        // Finalize previous scene
        if (frame_number > self.current_scene_start) {
            const duration = frame_number - self.current_scene_start;
            const avg_brightness = @as(f32, @floatCast(self.brightness_sum / @as(f64, @floatFromInt(duration))));
            const avg_motion = @as(f32, @floatCast(self.motion_sum / @as(f64, @floatFromInt(duration))));

            try self.scenes.append(.{
                .start_frame = self.current_scene_start,
                .end_frame = frame_number - 1,
                .duration_frames = duration,
                .average_brightness = avg_brightness,
                .average_motion = avg_motion,
                .shot_count = self.shot_count,
            });
        }

        // Start new scene
        self.current_scene_start = frame_number;
        self.brightness_sum = 0;
        self.motion_sum = 0;
        self.shot_count = 1;
    }

    pub fn updateMetrics(self: *SceneAnalyzer, brightness: f32, motion: f32) void {
        self.frame_count += 1;
        self.brightness_sum += brightness;
        self.motion_sum += motion;
    }

    pub fn finalize(self: *SceneAnalyzer, final_frame: u32) !void {
        if (final_frame > self.current_scene_start) {
            const duration = final_frame - self.current_scene_start;
            const avg_brightness = if (duration > 0)
                @as(f32, @floatCast(self.brightness_sum / @as(f64, @floatFromInt(duration))))
            else
                0;
            const avg_motion = if (duration > 0)
                @as(f32, @floatCast(self.motion_sum / @as(f64, @floatFromInt(duration))))
            else
                0;

            try self.scenes.append(.{
                .start_frame = self.current_scene_start,
                .end_frame = final_frame,
                .duration_frames = duration,
                .average_brightness = avg_brightness,
                .average_motion = avg_motion,
                .shot_count = self.shot_count,
            });
        }
    }

    pub fn getScenes(self: *const SceneAnalyzer) []const Scene {
        return self.scenes.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Histogram comparison" {
    const testing = std.testing;

    var frame1 = [_]u8{100} ** 256;
    var frame2 = [_]u8{100} ** 256;

    const hist1 = Histogram.fromFrame(&frame1);
    const hist2 = Histogram.fromFrame(&frame2);

    const similarity = hist1.compare(&hist2);
    try testing.expectApproxEqAbs(@as(f32, 1.0), similarity, 0.01);
}

test "Scene cut detection" {
    const testing = std.testing;

    var detector = ScenecutDetector.init(testing.allocator, .{ .min_scene_length_frames = 2 });
    defer detector.deinit();

    var frame1 = [_]u8{100} ** 256;
    var frame2 = [_]u8{200} ** 256;

    // First frame
    _ = try detector.processFrame(&frame1, 16, 16);
    _ = try detector.processFrame(&frame1, 16, 16);

    // Scene cut
    const result = try detector.processFrame(&frame2, 16, 16);

    try testing.expect(result != null);
}

test "Motion vector calculation" {
    const testing = std.testing;

    const analyzer = MotionAnalyzer{};

    var frame1 = [_]u8{100} ** (64 * 64);
    var frame2 = [_]u8{100} ** (64 * 64);

    const vectors = try analyzer.analyzeMotion(&frame1, &frame2, 64, 64, testing.allocator);
    defer testing.allocator.free(vectors);

    try testing.expect(vectors.len > 0);

    const avg_motion = MotionAnalyzer.getAverageMotion(vectors);
    try testing.expect(avg_motion >= 0);
}
