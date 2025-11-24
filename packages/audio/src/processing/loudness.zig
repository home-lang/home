// Home Audio Library - Loudness Normalization
// EBU R128 loudness measurement and normalization

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// EBU R128 loudness measurement result
pub const LoudnessResult = struct {
    /// Integrated loudness (LUFS)
    integrated: f32,
    /// Loudness range (LU)
    range: f32,
    /// Maximum true peak (dBTP)
    true_peak: f32,
    /// Maximum momentary loudness (LUFS)
    momentary_max: f32,
    /// Maximum short-term loudness (LUFS)
    short_term_max: f32,

    pub fn format(self: LoudnessResult) [128]u8 {
        var buf: [128]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "Integrated: {d:.1} LUFS, Range: {d:.1} LU, Peak: {d:.1} dBTP", .{ self.integrated, self.range, self.true_peak }) catch {};
        return buf;
    }
};

/// EBU R128 K-weighting filter coefficients (48kHz)
/// Two-stage filter: high shelf + high pass
const KWeightingFilter = struct {
    // High shelf filter (pre-filter for head acoustics)
    const HS_B0: f64 = 1.53512485958697;
    const HS_B1: f64 = -2.69169618940638;
    const HS_B2: f64 = 1.19839281085285;
    const HS_A1: f64 = -1.69065929318241;
    const HS_A2: f64 = 0.73248077421585;

    // High pass filter (rumble filter)
    const HP_B0: f64 = 1.0;
    const HP_B1: f64 = -2.0;
    const HP_B2: f64 = 1.0;
    const HP_A1: f64 = -1.99004745483398;
    const HP_A2: f64 = 0.99007225036621;
};

/// EBU R128 loudness meter
pub const LoudnessMeter = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    // Filter states per channel
    hs_z1: []f64,
    hs_z2: []f64,
    hp_z1: []f64,
    hp_z2: []f64,

    // Gated blocks (for integrated loudness)
    block_loudness: std.ArrayList(f32),

    // Momentary loudness (400ms window)
    momentary_buffer: []f64,
    momentary_pos: usize,
    momentary_samples: usize,

    // Short-term loudness (3s window)
    short_term_buffer: []f64,
    short_term_pos: usize,
    short_term_samples: usize,

    // Statistics
    momentary_max: f32,
    short_term_max: f32,
    true_peak: f32,

    const Self = @This();

    /// Channel weights for surround (ITU-R BS.1770)
    const CHANNEL_WEIGHTS = [_]f32{
        1.0, // L
        1.0, // R
        1.0, // C
        0.0, // LFE (excluded)
        1.41, // Ls
        1.41, // Rs
    };

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        const momentary_samples = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sample_rate)) * 0.4));
        const short_term_samples = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sample_rate)) * 3.0));

        var self = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .hs_z1 = try allocator.alloc(f64, channels),
            .hs_z2 = try allocator.alloc(f64, channels),
            .hp_z1 = try allocator.alloc(f64, channels),
            .hp_z2 = try allocator.alloc(f64, channels),
            .block_loudness = .{},
            .momentary_buffer = try allocator.alloc(f64, momentary_samples),
            .momentary_pos = 0,
            .momentary_samples = momentary_samples,
            .short_term_buffer = try allocator.alloc(f64, short_term_samples),
            .short_term_pos = 0,
            .short_term_samples = short_term_samples,
            .momentary_max = -100,
            .short_term_max = -100,
            .true_peak = -100,
        };

        @memset(self.hs_z1, 0);
        @memset(self.hs_z2, 0);
        @memset(self.hp_z1, 0);
        @memset(self.hp_z2, 0);
        @memset(self.momentary_buffer, 0);
        @memset(self.short_term_buffer, 0);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.hs_z1);
        self.allocator.free(self.hs_z2);
        self.allocator.free(self.hp_z1);
        self.allocator.free(self.hp_z2);
        self.allocator.free(self.momentary_buffer);
        self.allocator.free(self.short_term_buffer);
        self.block_loudness.deinit(self.allocator);
    }

    /// Process samples (interleaved)
    pub fn process(self: *Self, samples: []const f32) void {
        const num_frames = samples.len / self.channels;

        for (0..num_frames) |i| {
            var sum_squared: f64 = 0;

            for (0..self.channels) |ch| {
                const sample = samples[i * self.channels + ch];

                // Update true peak
                const abs_sample = @abs(sample);
                if (abs_sample > self.true_peak) {
                    self.true_peak = abs_sample;
                }

                // Apply K-weighting filter
                const filtered = self.applyKWeighting(sample, ch);

                // Weight by channel
                const weight: f64 = if (ch < CHANNEL_WEIGHTS.len) CHANNEL_WEIGHTS[ch] else 1.0;
                sum_squared += filtered * filtered * weight;
            }

            // Store in momentary buffer
            self.momentary_buffer[self.momentary_pos] = sum_squared;
            self.momentary_pos = (self.momentary_pos + 1) % self.momentary_samples;

            // Store in short-term buffer
            self.short_term_buffer[self.short_term_pos] = sum_squared;
            self.short_term_pos = (self.short_term_pos + 1) % self.short_term_samples;
        }

        // Update momentary/short-term max
        self.updateMomentary();
        self.updateShortTerm();
    }

    fn applyKWeighting(self: *Self, sample: f32, ch: usize) f64 {
        const x: f64 = sample;

        // High shelf filter
        const hs_y = KWeightingFilter.HS_B0 * x +
            KWeightingFilter.HS_B1 * self.hs_z1[ch] +
            KWeightingFilter.HS_B2 * self.hs_z2[ch] -
            KWeightingFilter.HS_A1 * self.hp_z1[ch] -
            KWeightingFilter.HS_A2 * self.hp_z2[ch];

        self.hs_z2[ch] = self.hs_z1[ch];
        self.hs_z1[ch] = x;

        // High pass filter
        const hp_y = KWeightingFilter.HP_B0 * hs_y +
            KWeightingFilter.HP_B1 * self.hp_z1[ch] +
            KWeightingFilter.HP_B2 * self.hp_z2[ch] -
            KWeightingFilter.HP_A1 * self.hp_z1[ch] -
            KWeightingFilter.HP_A2 * self.hp_z2[ch];

        self.hp_z2[ch] = self.hp_z1[ch];
        self.hp_z1[ch] = hs_y;

        return hp_y;
    }

    fn updateMomentary(self: *Self) void {
        var sum: f64 = 0;
        for (self.momentary_buffer) |s| {
            sum += s;
        }
        const mean = sum / @as(f64, @floatFromInt(self.momentary_samples));
        const lufs: f32 = @floatCast(-0.691 + 10.0 * @log10(mean + 1e-10));

        if (lufs > self.momentary_max) {
            self.momentary_max = lufs;
        }

        // Store for gated calculation
        if (lufs > -70) { // Absolute gate
            self.block_loudness.append(self.allocator, lufs) catch {};
        }
    }

    fn updateShortTerm(self: *Self) void {
        var sum: f64 = 0;
        for (self.short_term_buffer) |s| {
            sum += s;
        }
        const mean = sum / @as(f64, @floatFromInt(self.short_term_samples));
        const lufs: f32 = @floatCast(-0.691 + 10.0 * @log10(mean + 1e-10));

        if (lufs > self.short_term_max) {
            self.short_term_max = lufs;
        }
    }

    /// Get final loudness measurement
    pub fn getResult(self: *Self) LoudnessResult {
        const integrated = self.calculateIntegrated();
        const range = self.calculateRange();

        return LoudnessResult{
            .integrated = integrated,
            .range = range,
            .true_peak = if (self.true_peak > 0) 20.0 * @log10(self.true_peak) else -100,
            .momentary_max = self.momentary_max,
            .short_term_max = self.short_term_max,
        };
    }

    fn calculateIntegrated(self: *Self) f32 {
        if (self.block_loudness.items.len == 0) return -70;

        // Calculate ungated average
        var sum: f64 = 0;
        for (self.block_loudness.items) |l| {
            sum += math.pow(f64, 10, @as(f64, l) / 10.0);
        }
        const ungated_avg: f32 = @floatCast(10.0 * @log10(sum / @as(f64, @floatFromInt(self.block_loudness.items.len))));

        // Relative gate (-10 LU below ungated average)
        const gate = ungated_avg - 10;

        // Calculate gated average
        var gated_sum: f64 = 0;
        var gated_count: usize = 0;
        for (self.block_loudness.items) |l| {
            if (l >= gate) {
                gated_sum += math.pow(f64, 10, @as(f64, l) / 10.0);
                gated_count += 1;
            }
        }

        if (gated_count == 0) return -70;
        return @floatCast(10.0 * @log10(gated_sum / @as(f64, @floatFromInt(gated_count))));
    }

    fn calculateRange(self: *Self) f32 {
        if (self.block_loudness.items.len < 2) return 0;

        // Sort loudness values
        const items = self.block_loudness.items;
        var sorted = self.allocator.dupe(f32, items) catch return 0;
        defer self.allocator.free(sorted);

        std.mem.sort(f32, sorted, {}, std.sort.asc(f32));

        // 10th and 95th percentiles
        const low_idx = sorted.len / 10;
        const high_idx = sorted.len * 95 / 100;

        return sorted[high_idx] - sorted[low_idx];
    }

    /// Reset the meter
    pub fn reset(self: *Self) void {
        @memset(self.hs_z1, 0);
        @memset(self.hs_z2, 0);
        @memset(self.hp_z1, 0);
        @memset(self.hp_z2, 0);
        @memset(self.momentary_buffer, 0);
        @memset(self.short_term_buffer, 0);
        self.momentary_pos = 0;
        self.short_term_pos = 0;
        self.momentary_max = -100;
        self.short_term_max = -100;
        self.true_peak = -100;
        self.block_loudness.clearRetainingCapacity();
    }
};

/// Normalize audio to target loudness
pub fn normalize(
    allocator: Allocator,
    samples: []const f32,
    channels: u8,
    sample_rate: u32,
    target_lufs: f32,
) ![]f32 {
    // Measure current loudness
    var meter = try LoudnessMeter.init(allocator, sample_rate, channels);
    defer meter.deinit();

    meter.process(samples);
    const result = meter.getResult();

    // Calculate gain
    const gain_db = target_lufs - result.integrated;
    const gain = math.pow(f32, 10, gain_db / 20.0);

    // Apply gain
    const output = try allocator.alloc(f32, samples.len);
    for (0..samples.len) |i| {
        output[i] = samples[i] * gain;
    }

    return output;
}

/// Normalize to EBU R128 broadcast standard (-23 LUFS)
pub fn normalizeBroadcast(
    allocator: Allocator,
    samples: []const f32,
    channels: u8,
    sample_rate: u32,
) ![]f32 {
    return normalize(allocator, samples, channels, sample_rate, -23.0);
}

/// Normalize to streaming standard (-14 LUFS)
pub fn normalizeStreaming(
    allocator: Allocator,
    samples: []const f32,
    channels: u8,
    sample_rate: u32,
) ![]f32 {
    return normalize(allocator, samples, channels, sample_rate, -14.0);
}

// ============================================================================
// Tests
// ============================================================================

test "LoudnessMeter init" {
    const allocator = std.testing.allocator;

    var meter = try LoudnessMeter.init(allocator, 48000, 2);
    defer meter.deinit();

    // Check buffer sizes
    try std.testing.expectEqual(@as(usize, 19200), meter.momentary_samples); // 400ms
    try std.testing.expectEqual(@as(usize, 144000), meter.short_term_samples); // 3s
}

test "LoudnessResult format" {
    const result = LoudnessResult{
        .integrated = -23.0,
        .range = 8.0,
        .true_peak = -1.0,
        .momentary_max = -18.0,
        .short_term_max = -20.0,
    };

    const formatted = result.format();
    try std.testing.expect(formatted[0] != 0);
}
