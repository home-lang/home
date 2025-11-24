// Home Video Library - Content Detection
// Black frame, freeze frame, silence, loudness range detection

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Black Frame Detection
// ============================================================================

pub const BlackFrameOptions = struct {
    threshold: f32 = 32.0, // Pixel brightness threshold (0-255)
    picture_black_ratio_th: f32 = 0.98, // Minimum ratio of dark pixels
};

pub const BlackFrameResult = struct {
    is_black: bool,
    average_brightness: f32,
    black_pixel_ratio: f32,
    min_brightness: u8,
    max_brightness: u8,
};

pub fn detectBlackFrame(
    frame_data: []const u8,
    width: u32,
    height: u32,
    options: BlackFrameOptions,
) BlackFrameResult {
    const pixels = width * height;
    if (frame_data.len < pixels) {
        return .{
            .is_black = false,
            .average_brightness = 0,
            .black_pixel_ratio = 0,
            .min_brightness = 0,
            .max_brightness = 0,
        };
    }

    // Only analyze luma (Y) plane
    const luma = frame_data[0..pixels];

    var sum: u64 = 0;
    var black_count: u32 = 0;
    var min: u8 = 255;
    var max: u8 = 0;

    for (luma) |pixel| {
        sum += pixel;
        if (pixel < min) min = pixel;
        if (pixel > max) max = pixel;

        if (@as(f32, @floatFromInt(pixel)) < options.threshold) {
            black_count += 1;
        }
    }

    const avg = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(pixels));
    const black_ratio = @as(f32, @floatFromInt(black_count)) / @as(f32, @floatFromInt(pixels));

    return .{
        .is_black = black_ratio >= options.picture_black_ratio_th,
        .average_brightness = avg,
        .black_pixel_ratio = black_ratio,
        .min_brightness = min,
        .max_brightness = max,
    };
}

// ============================================================================
// Freeze Frame Detection
// ============================================================================

pub const FreezeFrameOptions = struct {
    threshold: f32 = 0.001, // Similarity threshold (0-1, lower = more strict)
    min_duration_frames: u32 = 5, // Minimum consecutive frames
};

pub const FreezeFrameDetector = struct {
    options: FreezeFrameOptions,
    previous_frame: ?[]u8 = null,
    freeze_count: u32 = 0,
    total_frames: u32 = 0,
    freeze_start_frame: ?u32 = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, options: FreezeFrameOptions) FreezeFrameDetector {
        return .{
            .options = options,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FreezeFrameDetector) void {
        if (self.previous_frame) |frame| {
            self.allocator.free(frame);
        }
    }

    pub fn processFrame(
        self: *FreezeFrameDetector,
        frame_data: []const u8,
        width: u32,
        height: u32,
    ) !?FreezeFrameEvent {
        self.total_frames += 1;

        const pixels = width * height;
        if (frame_data.len < pixels) return null;

        const luma = frame_data[0..pixels];

        if (self.previous_frame) |prev| {
            const diff = calculateFrameDifference(prev, luma);

            if (diff < self.options.threshold) {
                // Frames are similar (frozen)
                if (self.freeze_count == 0) {
                    self.freeze_start_frame = self.total_frames - 1;
                }
                self.freeze_count += 1;
            } else {
                // Frames differ (motion detected)
                if (self.freeze_count >= self.options.min_duration_frames) {
                    // Freeze sequence ended
                    const event = FreezeFrameEvent{
                        .start_frame = self.freeze_start_frame orelse 0,
                        .end_frame = self.total_frames - 1,
                        .duration_frames = self.freeze_count,
                    };
                    self.freeze_count = 0;
                    self.freeze_start_frame = null;

                    // Update previous frame
                    @memcpy(self.previous_frame.?, luma);

                    return event;
                }
                self.freeze_count = 0;
                self.freeze_start_frame = null;
            }

            // Update previous frame
            @memcpy(self.previous_frame.?, luma);
        } else {
            // First frame
            self.previous_frame = try self.allocator.dupe(u8, luma);
        }

        return null;
    }

    pub fn finalize(self: *FreezeFrameDetector) ?FreezeFrameEvent {
        if (self.freeze_count >= self.options.min_duration_frames) {
            return .{
                .start_frame = self.freeze_start_frame orelse 0,
                .end_frame = self.total_frames,
                .duration_frames = self.freeze_count,
            };
        }
        return null;
    }

    pub fn reset(self: *FreezeFrameDetector) void {
        if (self.previous_frame) |frame| {
            self.allocator.free(frame);
            self.previous_frame = null;
        }
        self.freeze_count = 0;
        self.total_frames = 0;
        self.freeze_start_frame = null;
    }
};

pub const FreezeFrameEvent = struct {
    start_frame: u32,
    end_frame: u32,
    duration_frames: u32,
};

fn calculateFrameDifference(frame1: []const u8, frame2: []const u8) f32 {
    if (frame1.len != frame2.len) return 1.0;

    var sum_diff: u64 = 0;
    for (frame1, frame2) |p1, p2| {
        const diff = if (p1 > p2) p1 - p2 else p2 - p1;
        sum_diff += diff;
    }

    // Normalize to 0-1 range
    const max_diff = @as(u64, 255) * frame1.len;
    return @as(f32, @floatFromInt(sum_diff)) / @as(f32, @floatFromInt(max_diff));
}

// ============================================================================
// Audio Silence Detection
// ============================================================================

pub const SilenceOptions = struct {
    noise_threshold_db: f32 = -60.0, // dBFS threshold
    min_duration_ms: u32 = 2000, // Minimum silence duration
};

pub const SilenceDetector = struct {
    options: SilenceOptions,
    sample_rate: u32,
    silence_samples: u32 = 0,
    total_samples: u32 = 0,
    silence_start_sample: ?u32 = null,

    pub fn init(sample_rate: u32, options: SilenceOptions) SilenceDetector {
        return .{
            .options = options,
            .sample_rate = sample_rate,
        };
    }

    pub fn processSamples(
        self: *SilenceDetector,
        samples: []const f32,
    ) ?SilenceEvent {
        const threshold_linear = dbToLinear(self.options.noise_threshold_db);

        for (samples) |sample| {
            self.total_samples += 1;
            const amplitude = @abs(sample);

            if (amplitude < threshold_linear) {
                // Silent sample
                if (self.silence_samples == 0) {
                    self.silence_start_sample = self.total_samples;
                }
                self.silence_samples += 1;
            } else {
                // Non-silent sample
                const min_samples = (self.options.min_duration_ms * self.sample_rate) / 1000;

                if (self.silence_samples >= min_samples) {
                    // Silence period ended
                    const event = SilenceEvent{
                        .start_sample = self.silence_start_sample orelse 0,
                        .end_sample = self.total_samples - 1,
                        .duration_ms = (self.silence_samples * 1000) / self.sample_rate,
                    };
                    self.silence_samples = 0;
                    self.silence_start_sample = null;
                    return event;
                }

                self.silence_samples = 0;
                self.silence_start_sample = null;
            }
        }

        return null;
    }

    pub fn finalize(self: *SilenceDetector) ?SilenceEvent {
        const min_samples = (self.options.min_duration_ms * self.sample_rate) / 1000;

        if (self.silence_samples >= min_samples) {
            return .{
                .start_sample = self.silence_start_sample orelse 0,
                .end_sample = self.total_samples,
                .duration_ms = (self.silence_samples * 1000) / self.sample_rate,
            };
        }
        return null;
    }

    pub fn reset(self: *SilenceDetector) void {
        self.silence_samples = 0;
        self.total_samples = 0;
        self.silence_start_sample = null;
    }
};

pub const SilenceEvent = struct {
    start_sample: u32,
    end_sample: u32,
    duration_ms: u32,

    pub fn getStartTimeSeconds(self: *const SilenceEvent, sample_rate: u32) f64 {
        return @as(f64, @floatFromInt(self.start_sample)) / @as(f64, @floatFromInt(sample_rate));
    }

    pub fn getDurationSeconds(self: *const SilenceEvent) f64 {
        return @as(f64, @floatFromInt(self.duration_ms)) / 1000.0;
    }
};

fn dbToLinear(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

// ============================================================================
// Loudness Range Analysis
// ============================================================================

pub const LoudnessRangeResult = struct {
    range_db: f32, // LRA (Loudness Range) in dB
    min_loudness: f32, // Minimum integrated loudness
    max_loudness: f32, // Maximum integrated loudness
    low_percentile: f32, // 10th percentile
    high_percentile: f32, // 95th percentile

    pub fn toString(self: *const LoudnessRangeResult) [128]u8 {
        var buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "LRA: {d:.1} dB (Range: {d:.1} to {d:.1} dB)", .{
            self.range_db,
            self.low_percentile,
            self.high_percentile,
        }) catch unreachable;
        _ = result;
        return buf;
    }
};

pub fn analyzeLoudnessRange(
    loudness_values: []const f32,
    allocator: Allocator,
) !LoudnessRangeResult {
    if (loudness_values.len == 0) {
        return .{
            .range_db = 0,
            .min_loudness = 0,
            .max_loudness = 0,
            .low_percentile = 0,
            .high_percentile = 0,
        };
    }

    // Sort values for percentile calculation
    var sorted = try allocator.dupe(f32, loudness_values);
    defer allocator.free(sorted);
    std.mem.sort(f32, sorted, {}, std.sort.asc(f32));

    const min_val = sorted[0];
    const max_val = sorted[sorted.len - 1];

    // Calculate 10th and 95th percentiles
    const p10_idx = (sorted.len * 10) / 100;
    const p95_idx = (sorted.len * 95) / 100;

    const p10 = sorted[p10_idx];
    const p95 = sorted[@min(p95_idx, sorted.len - 1)];

    // LRA is the difference between 95th and 10th percentile
    const lra = p95 - p10;

    return .{
        .range_db = lra,
        .min_loudness = min_val,
        .max_loudness = max_val,
        .low_percentile = p10,
        .high_percentile = p95,
    };
}

// ============================================================================
// Histogram Analysis
// ============================================================================

pub const Histogram = struct {
    bins: [256]u32 = [_]u32{0} ** 256,
    total_pixels: u32 = 0,

    pub fn fromFrame(frame_data: []const u8, width: u32, height: u32) Histogram {
        const pixels = width * height;
        if (frame_data.len < pixels) {
            return .{};
        }

        var hist = Histogram{};
        const luma = frame_data[0..pixels];

        for (luma) |pixel| {
            hist.bins[pixel] += 1;
            hist.total_pixels += 1;
        }

        return hist;
    }

    pub fn getMean(self: *const Histogram) f32 {
        if (self.total_pixels == 0) return 0;

        var sum: u64 = 0;
        for (self.bins, 0..) |count, value| {
            sum += count * value;
        }

        return @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(self.total_pixels));
    }

    pub fn getStdDev(self: *const Histogram) f32 {
        if (self.total_pixels == 0) return 0;

        const mean = self.getMean();
        var variance: f64 = 0;

        for (self.bins, 0..) |count, value| {
            const diff = @as(f32, @floatFromInt(value)) - mean;
            variance += @as(f64, @floatFromInt(count)) * diff * diff;
        }

        variance /= @as(f64, @floatFromInt(self.total_pixels));
        return @sqrt(@as(f32, @floatCast(variance)));
    }

    pub fn getPercentile(self: *const Histogram, percentile: f32) u8 {
        if (self.total_pixels == 0) return 0;

        const target = @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.total_pixels)) * percentile));
        var cumulative: u32 = 0;

        for (self.bins, 0..) |count, value| {
            cumulative += count;
            if (cumulative >= target) {
                return @intCast(value);
            }
        }

        return 255;
    }

    /// Compare two histograms (returns similarity 0-1)
    pub fn compare(self: *const Histogram, other: *const Histogram) f32 {
        var sum: f64 = 0;

        for (self.bins, other.bins) |a, b| {
            const a_norm = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(self.total_pixels, 1)));
            const b_norm = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(@max(other.total_pixels, 1)));
            const diff = a_norm - b_norm;
            sum += diff * diff;
        }

        // Bhattacharyya distance converted to similarity
        return @floatCast(1.0 - @sqrt(sum) / @sqrt(2.0));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Black frame detection - black frame" {
    const testing = std.testing;

    var frame = [_]u8{10} ** 256;

    const result = detectBlackFrame(&frame, 16, 16, .{});
    try testing.expect(result.is_black);
    try testing.expect(result.average_brightness < 32.0);
}

test "Black frame detection - normal frame" {
    const testing = std.testing;

    var frame = [_]u8{128} ** 256;

    const result = detectBlackFrame(&frame, 16, 16, .{});
    try testing.expect(!result.is_black);
}

test "Freeze frame detection" {
    const testing = std.testing;

    var detector = FreezeFrameDetector.init(testing.allocator, .{ .min_duration_frames = 3 });
    defer detector.deinit();

    var frame = [_]u8{100} ** 256;

    // Process same frame 5 times
    for (0..5) |_| {
        _ = try detector.processFrame(&frame, 16, 16);
    }

    // Change frame
    frame[0] = 200;
    const event = try detector.processFrame(&frame, 16, 16);

    try testing.expect(event != null);
    try testing.expect(event.?.duration_frames >= 3);
}

test "Silence detection" {
    const testing = std.testing;

    var detector = SilenceDetector.init(48000, .{ .min_duration_ms = 100 });

    // Generate silent samples
    var samples = [_]f32{0.0001} ** 5000;

    _ = detector.processSamples(&samples);

    // Generate loud sample
    samples[0] = 0.5;
    const event = detector.processSamples(samples[0..1]);

    try testing.expect(event != null);
}

test "Histogram calculation" {
    const testing = std.testing;

    var frame = [_]u8{0} ** 256;
    for (&frame, 0..) |*pixel, i| {
        pixel.* = @intCast(i);
    }

    const hist = Histogram.fromFrame(&frame, 16, 16);

    try testing.expectEqual(@as(u32, 256), hist.total_pixels);
    try testing.expectApproxEqAbs(@as(f32, 127.5), hist.getMean(), 1.0);
}
