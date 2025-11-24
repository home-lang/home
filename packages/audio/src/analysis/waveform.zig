// Home Audio Library - Waveform Peak Generation
// Generate waveform visualization data

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Waveform data point
pub const WaveformPoint = struct {
    min: f32, // Minimum sample value in range
    max: f32, // Maximum sample value in range
    rms: f32, // RMS value in range
};

/// Waveform resolution
pub const WaveformResolution = enum {
    low, // ~100 points per second
    medium, // ~500 points per second
    high, // ~1000 points per second
    ultra, // ~2000 points per second

    pub fn pointsPerSecond(self: WaveformResolution) u32 {
        return switch (self) {
            .low => 100,
            .medium => 500,
            .high => 1000,
            .ultra => 2000,
        };
    }
};

/// Waveform data generator
pub const WaveformGenerator = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    /// Generate waveform peaks from audio buffer
    /// Returns array of WaveformPoint for each channel
    pub fn generate(
        self: *Self,
        samples: []const f32,
        resolution: WaveformResolution,
    ) ![][]WaveformPoint {
        const samples_per_point = self.sample_rate / resolution.pointsPerSecond();
        const total_frames = samples.len / self.channels;
        const num_points = (total_frames + samples_per_point - 1) / samples_per_point;

        // Allocate result arrays
        var result = try self.allocator.alloc([]WaveformPoint, self.channels);
        errdefer self.allocator.free(result);

        for (0..self.channels) |ch| {
            result[ch] = try self.allocator.alloc(WaveformPoint, num_points);
        }

        // Generate waveform data
        for (0..num_points) |point_idx| {
            const start_frame = point_idx * samples_per_point;
            const end_frame = @min(start_frame + samples_per_point, total_frames);

            for (0..self.channels) |ch| {
                var min_val: f32 = 1.0;
                var max_val: f32 = -1.0;
                var sum_sq: f32 = 0;
                var count: u32 = 0;

                for (start_frame..end_frame) |frame| {
                    const idx = frame * self.channels + ch;
                    if (idx < samples.len) {
                        const s = samples[idx];
                        min_val = @min(min_val, s);
                        max_val = @max(max_val, s);
                        sum_sq += s * s;
                        count += 1;
                    }
                }

                result[ch][point_idx] = WaveformPoint{
                    .min = if (count > 0) min_val else 0,
                    .max = if (count > 0) max_val else 0,
                    .rms = if (count > 0) @sqrt(sum_sq / @as(f32, @floatFromInt(count))) else 0,
                };
            }
        }

        return result;
    }

    /// Generate waveform with fixed number of points
    pub fn generateFixed(
        self: *Self,
        samples: []const f32,
        num_points: usize,
    ) ![][]WaveformPoint {
        const total_frames = samples.len / self.channels;
        const samples_per_point = @max(1, total_frames / num_points);

        var result = try self.allocator.alloc([]WaveformPoint, self.channels);
        errdefer self.allocator.free(result);

        for (0..self.channels) |ch| {
            result[ch] = try self.allocator.alloc(WaveformPoint, num_points);
        }

        for (0..num_points) |point_idx| {
            const start_frame = point_idx * samples_per_point;
            const end_frame = @min(start_frame + samples_per_point, total_frames);

            for (0..self.channels) |ch| {
                var min_val: f32 = 1.0;
                var max_val: f32 = -1.0;
                var sum_sq: f32 = 0;
                var count: u32 = 0;

                for (start_frame..end_frame) |frame| {
                    const idx = frame * self.channels + ch;
                    if (idx < samples.len) {
                        const s = samples[idx];
                        min_val = @min(min_val, s);
                        max_val = @max(max_val, s);
                        sum_sq += s * s;
                        count += 1;
                    }
                }

                result[ch][point_idx] = WaveformPoint{
                    .min = if (count > 0) min_val else 0,
                    .max = if (count > 0) max_val else 0,
                    .rms = if (count > 0) @sqrt(sum_sq / @as(f32, @floatFromInt(count))) else 0,
                };
            }
        }

        return result;
    }

    /// Free waveform data
    pub fn freeWaveform(self: *Self, waveform: [][]WaveformPoint) void {
        for (waveform) |channel_data| {
            self.allocator.free(channel_data);
        }
        self.allocator.free(waveform);
    }
};

/// Streaming waveform generator for real-time use
pub const StreamingWaveformGenerator = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,
    samples_per_point: usize,

    // Current point accumulator (per channel)
    current_min: []f32,
    current_max: []f32,
    current_sum_sq: []f32,
    sample_count: usize,

    // Output buffer
    points: std.ArrayList([]WaveformPoint),

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8, resolution: WaveformResolution) !Self {
        const samples_per_point = sample_rate / resolution.pointsPerSecond();

        var gen = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .samples_per_point = samples_per_point,
            .current_min = try allocator.alloc(f32, channels),
            .current_max = try allocator.alloc(f32, channels),
            .current_sum_sq = try allocator.alloc(f32, channels),
            .sample_count = 0,
            .points = .{},
        };

        gen.resetAccumulators();
        return gen;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.current_min);
        self.allocator.free(self.current_max);
        self.allocator.free(self.current_sum_sq);

        for (self.points.items) |point_array| {
            self.allocator.free(point_array);
        }
        self.points.deinit(self.allocator);
    }

    fn resetAccumulators(self: *Self) void {
        for (0..self.channels) |ch| {
            self.current_min[ch] = 1.0;
            self.current_max[ch] = -1.0;
            self.current_sum_sq[ch] = 0;
        }
        self.sample_count = 0;
    }

    /// Process audio samples
    pub fn process(self: *Self, samples: []const f32) !void {
        const num_frames = samples.len / self.channels;

        for (0..num_frames) |frame| {
            for (0..self.channels) |ch| {
                const idx = frame * self.channels + ch;
                const s = samples[idx];

                self.current_min[ch] = @min(self.current_min[ch], s);
                self.current_max[ch] = @max(self.current_max[ch], s);
                self.current_sum_sq[ch] += s * s;
            }

            self.sample_count += 1;

            if (self.sample_count >= self.samples_per_point) {
                try self.emitPoint();
            }
        }
    }

    fn emitPoint(self: *Self) !void {
        var point = try self.allocator.alloc(WaveformPoint, self.channels);

        for (0..self.channels) |ch| {
            const count_f = @as(f32, @floatFromInt(self.sample_count));
            point[ch] = WaveformPoint{
                .min = self.current_min[ch],
                .max = self.current_max[ch],
                .rms = @sqrt(self.current_sum_sq[ch] / count_f),
            };
        }

        try self.points.append(self.allocator, point);
        self.resetAccumulators();
    }

    /// Finish and emit any remaining samples as a point
    pub fn finish(self: *Self) !void {
        if (self.sample_count > 0) {
            try self.emitPoint();
        }
    }

    /// Get number of generated points
    pub fn getPointCount(self: *Self) usize {
        return self.points.items.len;
    }

    /// Get point data for a channel
    pub fn getChannelData(self: *Self, channel: u8) []WaveformPoint {
        if (channel >= self.channels) return &[_]WaveformPoint{};

        var result = self.allocator.alloc(WaveformPoint, self.points.items.len) catch return &[_]WaveformPoint{};

        for (self.points.items, 0..) |point_array, i| {
            result[i] = point_array[channel];
        }

        return result;
    }

    /// Clear all generated points
    pub fn clear(self: *Self) void {
        for (self.points.items) |point_array| {
            self.allocator.free(point_array);
        }
        self.points.clearRetainingCapacity();
        self.resetAccumulators();
    }
};

/// Overview waveform (highly compressed for entire file overview)
pub const OverviewWaveform = struct {
    allocator: Allocator,
    width: usize, // Number of points (typically screen width)

    const Self = @This();

    pub fn init(allocator: Allocator, width: usize) Self {
        return Self{
            .allocator = allocator,
            .width = width,
        };
    }

    /// Generate overview waveform for entire audio file
    pub fn generate(self: *Self, samples: []const f32, channels: u8) ![]WaveformPoint {
        const total_frames = samples.len / channels;
        const samples_per_point = @max(1, total_frames / self.width);

        var result = try self.allocator.alloc(WaveformPoint, self.width);

        for (0..self.width) |point_idx| {
            const start_frame = point_idx * samples_per_point;
            const end_frame = @min(start_frame + samples_per_point, total_frames);

            var min_val: f32 = 1.0;
            var max_val: f32 = -1.0;
            var sum_sq: f32 = 0;
            var count: u32 = 0;

            // Mix all channels for overview
            for (start_frame..end_frame) |frame| {
                var mixed: f32 = 0;
                for (0..channels) |ch| {
                    const idx = frame * channels + ch;
                    if (idx < samples.len) {
                        mixed += samples[idx];
                    }
                }
                mixed /= @as(f32, @floatFromInt(channels));

                min_val = @min(min_val, mixed);
                max_val = @max(max_val, mixed);
                sum_sq += mixed * mixed;
                count += 1;
            }

            result[point_idx] = WaveformPoint{
                .min = if (count > 0) min_val else 0,
                .max = if (count > 0) max_val else 0,
                .rms = if (count > 0) @sqrt(sum_sq / @as(f32, @floatFromInt(count))) else 0,
            };
        }

        return result;
    }

    /// Free overview waveform
    pub fn free(self: *Self, waveform: []WaveformPoint) void {
        self.allocator.free(waveform);
    }
};

/// Loudness statistics from waveform
pub const WaveformStats = struct {
    peak: f32,
    peak_db: f32,
    rms: f32,
    rms_db: f32,
    crest_factor: f32,
    crest_factor_db: f32,
    dc_offset: f32,

    pub fn fromSamples(samples: []const f32) WaveformStats {
        var peak: f32 = 0;
        var sum_sq: f32 = 0;
        var sum: f32 = 0;

        for (samples) |s| {
            peak = @max(peak, @abs(s));
            sum_sq += s * s;
            sum += s;
        }

        const count_f = @as(f32, @floatFromInt(samples.len));
        const rms = @sqrt(sum_sq / @max(1, count_f));
        const dc_offset = sum / @max(1, count_f);
        const crest = if (rms > 0) peak / rms else 0;

        return WaveformStats{
            .peak = peak,
            .peak_db = if (peak > 0) 20.0 * @log10(peak) else -100,
            .rms = rms,
            .rms_db = if (rms > 0) 20.0 * @log10(rms) else -100,
            .crest_factor = crest,
            .crest_factor_db = if (crest > 0) 20.0 * @log10(crest) else 0,
            .dc_offset = dc_offset,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WaveformGenerator basic" {
    const allocator = std.testing.allocator;

    var gen = WaveformGenerator.init(allocator, 44100, 2);

    // Create simple test audio
    var samples: [4410 * 2]f32 = undefined; // 0.1 second stereo
    for (0..4410) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        samples[i * 2] = @sin(t * 440 * 2 * math.pi);
        samples[i * 2 + 1] = @sin(t * 880 * 2 * math.pi);
    }

    const waveform = try gen.generate(&samples, .low);
    defer gen.freeWaveform(waveform);

    try std.testing.expectEqual(@as(usize, 2), waveform.len); // 2 channels
    try std.testing.expect(waveform[0].len > 0);
}

test "WaveformGenerator fixed points" {
    const allocator = std.testing.allocator;

    var gen = WaveformGenerator.init(allocator, 44100, 1);

    var samples = [_]f32{0.5} ** 1000;
    const waveform = try gen.generateFixed(&samples, 10);
    defer gen.freeWaveform(waveform);

    try std.testing.expectEqual(@as(usize, 10), waveform[0].len);
}

test "OverviewWaveform generate" {
    const allocator = std.testing.allocator;

    var overview = OverviewWaveform.init(allocator, 100);

    var samples = [_]f32{0.3} ** 1000;
    const waveform = try overview.generate(&samples, 1);
    defer overview.free(waveform);

    try std.testing.expectEqual(@as(usize, 100), waveform.len);
}

test "WaveformStats basic" {
    const samples = [_]f32{ 0.5, -0.5, 0.3, -0.3, 0.8, -0.8 };
    const stats = WaveformStats.fromSamples(&samples);

    try std.testing.expectApproxEqAbs(@as(f32, 0.8), stats.peak, 0.001);
    try std.testing.expect(stats.rms > 0);
    try std.testing.expect(stats.crest_factor > 1);
}
