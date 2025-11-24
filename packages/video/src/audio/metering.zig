// Home Video Library - Audio Metering
// LUFS/LKFS loudness measurement, true peak detection (ITU-R BS.1770)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Loudness Units
// ============================================================================

/// Loudness measurement result
pub const LoudnessResult = struct {
    integrated_lufs: f64, // Integrated loudness (full program)
    momentary_lufs: f64, // Momentary loudness (400ms window)
    short_term_lufs: f64, // Short-term loudness (3s window)
    loudness_range: f64, // LRA (difference between soft and loud parts)
    true_peak_db: f64, // True peak level in dBTP
    sample_peak_db: f64, // Sample peak level in dBFS

    /// Check if loudness meets broadcast standards
    pub fn meetsStandard(self: *const LoudnessResult, target_lufs: f64, tolerance: f64) bool {
        return @abs(self.integrated_lufs - target_lufs) <= tolerance;
    }
};

/// Common loudness targets
pub const LoudnessTarget = struct {
    pub const EBU_R128: f64 = -23.0; // European broadcast
    pub const ATSC_A85: f64 = -24.0; // US broadcast
    pub const ARIB_TR_B32: f64 = -24.0; // Japan broadcast
    pub const SPOTIFY: f64 = -14.0; // Spotify normalization
    pub const YOUTUBE: f64 = -14.0; // YouTube normalization
    pub const APPLE_MUSIC: f64 = -16.0; // Apple Music
    pub const AMAZON_MUSIC: f64 = -14.0; // Amazon Music
};

// ============================================================================
// K-Weighting Filter (ITU-R BS.1770)
// ============================================================================

/// K-weighting filter state for loudness measurement
pub const KWeightingFilter = struct {
    // High shelf filter state (stage 1)
    hs_x1: f64 = 0,
    hs_x2: f64 = 0,
    hs_y1: f64 = 0,
    hs_y2: f64 = 0,

    // High pass filter state (stage 2)
    hp_x1: f64 = 0,
    hp_x2: f64 = 0,
    hp_y1: f64 = 0,
    hp_y2: f64 = 0,

    // Filter coefficients (48kHz)
    const HS_B0: f64 = 1.53512485958697;
    const HS_B1: f64 = -2.69169618940638;
    const HS_B2: f64 = 1.19839281085285;
    const HS_A1: f64 = -1.69065929318241;
    const HS_A2: f64 = 0.73248077421585;

    const HP_B0: f64 = 1.0;
    const HP_B1: f64 = -2.0;
    const HP_B2: f64 = 1.0;
    const HP_A1: f64 = -1.99004745483398;
    const HP_A2: f64 = 0.99007225036621;

    /// Process a single sample through K-weighting filter
    pub fn process(self: *KWeightingFilter, input: f64) f64 {
        // Stage 1: High shelf filter (+4dB above 1500Hz)
        const hs_out = HS_B0 * input + HS_B1 * self.hs_x1 + HS_B2 * self.hs_x2 -
            HS_A1 * self.hs_y1 - HS_A2 * self.hs_y2;

        self.hs_x2 = self.hs_x1;
        self.hs_x1 = input;
        self.hs_y2 = self.hs_y1;
        self.hs_y1 = hs_out;

        // Stage 2: High pass filter (removes <38Hz)
        const hp_out = HP_B0 * hs_out + HP_B1 * self.hp_x1 + HP_B2 * self.hp_x2 -
            HP_A1 * self.hp_y1 - HP_A2 * self.hp_y2;

        self.hp_x2 = self.hp_x1;
        self.hp_x1 = hs_out;
        self.hp_y2 = self.hp_y1;
        self.hp_y1 = hp_out;

        return hp_out;
    }

    /// Reset filter state
    pub fn reset(self: *KWeightingFilter) void {
        self.hs_x1 = 0;
        self.hs_x2 = 0;
        self.hs_y1 = 0;
        self.hs_y2 = 0;
        self.hp_x1 = 0;
        self.hp_x2 = 0;
        self.hp_y1 = 0;
        self.hp_y2 = 0;
    }
};

// ============================================================================
// Loudness Meter
// ============================================================================

pub const LoudnessMeter = struct {
    sample_rate: u32,
    channels: u8,
    allocator: Allocator,

    // Per-channel K-weighting filters
    filters: []KWeightingFilter,

    // Channel weights for summing (ITU-R BS.1770)
    channel_weights: []f64,

    // Gating blocks (100ms intervals)
    block_size: usize,
    block_samples: usize,
    block_sum: f64,
    blocks: std.ArrayList(f64),

    // Momentary loudness (400ms window)
    momentary_window: std.ArrayList(f64),
    momentary_sum: f64,

    // Short-term loudness (3s window)
    short_term_window: std.ArrayList(f64),
    short_term_sum: f64,

    // Peak detection
    sample_peak: f64,
    true_peak: f64,

    // True peak oversampling filter
    tp_history: [4]f64,

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !LoudnessMeter {
        const filters = try allocator.alloc(KWeightingFilter, channels);
        @memset(filters, KWeightingFilter{});

        // Channel weights per ITU-R BS.1770
        const weights = try allocator.alloc(f64, channels);
        for (weights, 0..) |*w, i| {
            if (channels <= 2) {
                w.* = 1.0; // Mono/Stereo: equal weight
            } else {
                // 5.1: L, R, C, LFE, Ls, Rs
                w.* = switch (i) {
                    0, 1, 2 => 1.0, // L, R, C
                    3 => 0.0, // LFE excluded
                    4, 5 => 1.41, // Surround channels (+1.5dB)
                    else => 1.0,
                };
            }
        }

        const block_size = sample_rate / 10; // 100ms blocks

        return LoudnessMeter{
            .sample_rate = sample_rate,
            .channels = channels,
            .allocator = allocator,
            .filters = filters,
            .channel_weights = weights,
            .block_size = block_size,
            .block_samples = 0,
            .block_sum = 0,
            .blocks = std.ArrayList(f64).init(allocator),
            .momentary_window = std.ArrayList(f64).init(allocator),
            .momentary_sum = 0,
            .short_term_window = std.ArrayList(f64).init(allocator),
            .short_term_sum = 0,
            .sample_peak = 0,
            .true_peak = 0,
            .tp_history = .{ 0, 0, 0, 0 },
        };
    }

    pub fn deinit(self: *LoudnessMeter) void {
        self.allocator.free(self.filters);
        self.allocator.free(self.channel_weights);
        self.blocks.deinit();
        self.momentary_window.deinit();
        self.short_term_window.deinit();
    }

    /// Process interleaved audio samples (normalized -1.0 to 1.0)
    pub fn process(self: *LoudnessMeter, samples: []const f64) !void {
        const frame_count = samples.len / self.channels;

        var frame: usize = 0;
        while (frame < frame_count) : (frame += 1) {
            var channel_sum: f64 = 0;

            // Process each channel
            var ch: usize = 0;
            while (ch < self.channels) : (ch += 1) {
                const sample = samples[frame * self.channels + ch];

                // Sample peak
                const abs_sample = @abs(sample);
                if (abs_sample > self.sample_peak) {
                    self.sample_peak = abs_sample;
                }

                // True peak (4x oversampling)
                const tp = self.calculateTruePeak(sample);
                if (tp > self.true_peak) {
                    self.true_peak = tp;
                }

                // K-weighting
                const weighted = self.filters[ch].process(sample);

                // Weighted sum
                channel_sum += weighted * weighted * self.channel_weights[ch];
            }

            self.block_sum += channel_sum;
            self.block_samples += 1;

            // Complete block
            if (self.block_samples >= self.block_size) {
                const block_loudness = self.block_sum / @as(f64, @floatFromInt(self.block_samples));
                try self.blocks.append(block_loudness);

                // Update momentary window (4 blocks = 400ms)
                try self.momentary_window.append(block_loudness);
                self.momentary_sum += block_loudness;
                if (self.momentary_window.items.len > 4) {
                    self.momentary_sum -= self.momentary_window.orderedRemove(0);
                }

                // Update short-term window (30 blocks = 3s)
                try self.short_term_window.append(block_loudness);
                self.short_term_sum += block_loudness;
                if (self.short_term_window.items.len > 30) {
                    self.short_term_sum -= self.short_term_window.orderedRemove(0);
                }

                self.block_sum = 0;
                self.block_samples = 0;
            }
        }
    }

    fn calculateTruePeak(self: *LoudnessMeter, sample: f64) f64 {
        // Simple 4x oversampling with linear interpolation
        // For production, use proper sinc interpolation
        const prev = self.tp_history[3];
        self.tp_history[3] = self.tp_history[2];
        self.tp_history[2] = self.tp_history[1];
        self.tp_history[1] = self.tp_history[0];
        self.tp_history[0] = sample;

        var max_peak = @abs(sample);

        // Interpolated samples
        const interp1 = (prev + sample) * 0.5;
        const interp2 = (self.tp_history[1] + sample) * 0.5;
        const interp3 = (self.tp_history[2] + sample) * 0.5;

        if (@abs(interp1) > max_peak) max_peak = @abs(interp1);
        if (@abs(interp2) > max_peak) max_peak = @abs(interp2);
        if (@abs(interp3) > max_peak) max_peak = @abs(interp3);

        return max_peak;
    }

    /// Get current measurement results
    pub fn getResults(self: *const LoudnessMeter) LoudnessResult {
        // Integrated loudness with gating
        const integrated = self.calculateIntegratedLoudness();

        // Momentary loudness
        const momentary = if (self.momentary_window.items.len > 0)
            -0.691 + 10.0 * std.math.log10(self.momentary_sum / @as(f64, @floatFromInt(self.momentary_window.items.len)))
        else
            -70.0;

        // Short-term loudness
        const short_term = if (self.short_term_window.items.len > 0)
            -0.691 + 10.0 * std.math.log10(self.short_term_sum / @as(f64, @floatFromInt(self.short_term_window.items.len)))
        else
            -70.0;

        // Loudness range
        const lra = self.calculateLoudnessRange();

        // Peak levels in dB
        const sample_peak_db = if (self.sample_peak > 0)
            20.0 * std.math.log10(self.sample_peak)
        else
            -96.0;

        const true_peak_db = if (self.true_peak > 0)
            20.0 * std.math.log10(self.true_peak)
        else
            -96.0;

        return LoudnessResult{
            .integrated_lufs = integrated,
            .momentary_lufs = momentary,
            .short_term_lufs = short_term,
            .loudness_range = lra,
            .true_peak_db = true_peak_db,
            .sample_peak_db = sample_peak_db,
        };
    }

    fn calculateIntegratedLoudness(self: *const LoudnessMeter) f64 {
        if (self.blocks.items.len == 0) return -70.0;

        // First pass: absolute gating at -70 LUFS
        var sum: f64 = 0;
        var count: usize = 0;

        for (self.blocks.items) |block| {
            const block_lufs = -0.691 + 10.0 * std.math.log10(block);
            if (block_lufs > -70.0) {
                sum += block;
                count += 1;
            }
        }

        if (count == 0) return -70.0;

        // Relative threshold = mean - 10 LUFS
        const mean = sum / @as(f64, @floatFromInt(count));
        const threshold_lufs = -0.691 + 10.0 * std.math.log10(mean) - 10.0;

        // Second pass: relative gating
        sum = 0;
        count = 0;

        for (self.blocks.items) |block| {
            const block_lufs = -0.691 + 10.0 * std.math.log10(block);
            if (block_lufs > threshold_lufs) {
                sum += block;
                count += 1;
            }
        }

        if (count == 0) return -70.0;

        return -0.691 + 10.0 * std.math.log10(sum / @as(f64, @floatFromInt(count)));
    }

    fn calculateLoudnessRange(self: *const LoudnessMeter) f64 {
        if (self.blocks.items.len < 2) return 0.0;

        // Convert blocks to LUFS and sort
        var lufs_values = std.ArrayList(f64).init(self.allocator);
        defer lufs_values.deinit();

        for (self.blocks.items) |block| {
            const block_lufs = -0.691 + 10.0 * std.math.log10(block);
            if (block_lufs > -70.0) {
                lufs_values.append(block_lufs) catch continue;
            }
        }

        if (lufs_values.items.len < 2) return 0.0;

        std.mem.sort(f64, lufs_values.items, {}, std.sort.asc(f64));

        // LRA = 95th percentile - 10th percentile
        const low_idx = lufs_values.items.len / 10;
        const high_idx = lufs_values.items.len * 95 / 100;

        return lufs_values.items[high_idx] - lufs_values.items[low_idx];
    }

    /// Reset meter state
    pub fn reset(self: *LoudnessMeter) void {
        for (self.filters) |*f| {
            f.reset();
        }
        self.blocks.clearRetainingCapacity();
        self.momentary_window.clearRetainingCapacity();
        self.short_term_window.clearRetainingCapacity();
        self.block_sum = 0;
        self.block_samples = 0;
        self.momentary_sum = 0;
        self.short_term_sum = 0;
        self.sample_peak = 0;
        self.true_peak = 0;
        self.tp_history = .{ 0, 0, 0, 0 };
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Convert LUFS to linear gain
pub fn lufsToGain(lufs: f64) f64 {
    return std.math.pow(f64, 10.0, lufs / 20.0);
}

/// Convert linear gain to LUFS
pub fn gainToLufs(gain: f64) f64 {
    return 20.0 * std.math.log10(gain);
}

/// Calculate gain adjustment to reach target loudness
pub fn calculateGainAdjustment(current_lufs: f64, target_lufs: f64) f64 {
    return target_lufs - current_lufs;
}

// ============================================================================
// Tests
// ============================================================================

test "K-weighting filter" {
    const testing = std.testing;

    var filter = KWeightingFilter{};

    // Process some samples
    _ = filter.process(0.5);
    _ = filter.process(-0.5);
    _ = filter.process(0.25);

    // Should produce non-zero output
    const out = filter.process(0.0);
    try testing.expect(out != 0);
}

test "Loudness targets" {
    const testing = std.testing;

    try testing.expectEqual(@as(f64, -23.0), LoudnessTarget.EBU_R128);
    try testing.expectEqual(@as(f64, -24.0), LoudnessTarget.ATSC_A85);
}

test "LUFS conversion" {
    const testing = std.testing;

    // -6 dB should be ~0.5 gain
    const gain = lufsToGain(-6.0);
    try testing.expectApproxEqAbs(@as(f64, 0.5012), gain, 0.001);

    // Roundtrip
    const back = gainToLufs(gain);
    try testing.expectApproxEqAbs(@as(f64, -6.0), back, 0.001);
}

test "Gain adjustment calculation" {
    const testing = std.testing;

    // Need +3 dB to go from -17 to -14 LUFS
    const adj = calculateGainAdjustment(-17.0, -14.0);
    try testing.expectApproxEqAbs(@as(f64, 3.0), adj, 0.001);
}
