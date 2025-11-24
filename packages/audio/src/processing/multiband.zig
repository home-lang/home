// Home Audio Library - Multiband Compressor
// Professional multiband dynamics processing

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Crossover filter type
pub const CrossoverType = enum {
    linkwitz_riley_24, // 24 dB/oct Linkwitz-Riley (most common)
    linkwitz_riley_48, // 48 dB/oct
    butterworth_12, // 12 dB/oct Butterworth
};

/// Multiband band configuration
pub const BandConfig = struct {
    threshold_db: f32 = -20.0,
    ratio: f32 = 4.0,
    attack_ms: f32 = 10.0,
    release_ms: f32 = 100.0,
    knee_db: f32 = 2.0,
    makeup_gain_db: f32 = 0.0,
    bypass: bool = false,
};

/// Single compression band
pub const CompressionBand = struct {
    // Band-pass filter state
    bp_z1: f32 = 0,
    bp_z2: f32 = 0,
    bp_b0: f32 = 0,
    bp_b1: f32 = 0,
    bp_b2: f32 = 0,
    bp_a1: f32 = 0,
    bp_a2: f32 = 0,

    // Compressor state
    envelope: f32 = 0,
    attack_coeff: f32 = 0,
    release_coeff: f32 = 0,
    threshold: f32 = 0,
    ratio: f32 = 1,
    knee: f32 = 0,
    makeup_gain: f32 = 1,
    bypass: bool = false,

    const Self = @This();

    pub fn init(config: BandConfig, sample_rate: u32) Self {
        var band = Self{};
        band.updateConfig(config, sample_rate);
        return band;
    }

    pub fn updateConfig(self: *Self, config: BandConfig, sample_rate: u32) void {
        // Convert dB to linear
        self.threshold = math.pow(f32, 10.0, config.threshold_db / 20.0);
        self.ratio = config.ratio;
        self.knee = math.pow(f32, 10.0, config.knee_db / 20.0);
        self.makeup_gain = math.pow(f32, 10.0, config.makeup_gain_db / 20.0);
        self.bypass = config.bypass;

        // Calculate envelope coefficients
        const sr = @as(f32, @floatFromInt(sample_rate));
        const attack_samples = config.attack_ms * sr / 1000.0;
        const release_samples = config.release_ms * sr / 1000.0;
        self.attack_coeff = @exp(-1.0 / attack_samples);
        self.release_coeff = @exp(-1.0 / release_samples);
    }

    pub fn updateFilter(self: *Self, low_freq: f32, high_freq: f32, sample_rate: u32) void {
        // Design band-pass filter using center frequency
        const center_freq = @sqrt(low_freq * high_freq);
        const bandwidth = high_freq - low_freq;

        const sr = @as(f32, @floatFromInt(sample_rate));
        const omega = 2.0 * math.pi * center_freq / sr;
        const bw = 2.0 * math.pi * bandwidth / sr;
        // sinh(x) = (e^x - e^(-x)) / 2
        const bw_log = bw * @log(2.0) / 2.0;
        const alpha = @sin(omega) * (@exp(bw_log) - @exp(-bw_log)) / 2.0;

        const cos_omega = @cos(omega);
        const a0 = 1.0 + alpha;

        self.bp_b0 = alpha / a0;
        self.bp_b1 = 0;
        self.bp_b2 = -alpha / a0;
        self.bp_a1 = -2.0 * cos_omega / a0;
        self.bp_a2 = (1.0 - alpha) / a0;
    }

    pub fn processSample(self: *Self, sample: f32) f32 {
        if (self.bypass) return sample;

        // Band-pass filter
        const filtered = self.bp_b0 * sample + self.bp_b1 * self.bp_z1 + self.bp_b2 * self.bp_z2 -
            self.bp_a1 * self.bp_z1 - self.bp_a2 * self.bp_z2;

        self.bp_z2 = self.bp_z1;
        self.bp_z1 = filtered;

        // Envelope detection
        const abs_sample = @abs(filtered);
        if (abs_sample > self.envelope) {
            self.envelope = self.attack_coeff * self.envelope + (1.0 - self.attack_coeff) * abs_sample;
        } else {
            self.envelope = self.release_coeff * self.envelope + (1.0 - self.release_coeff) * abs_sample;
        }

        // Compute gain reduction with soft knee
        var gain: f32 = 1.0;
        if (self.envelope > self.threshold) {
            const overshoot = self.envelope / self.threshold;

            // Soft knee implementation
            if (overshoot < self.knee) {
                const knee_factor = (overshoot - 1.0) / (self.knee - 1.0);
                gain = 1.0 - knee_factor * (1.0 - 1.0 / self.ratio);
            } else {
                gain = 1.0 / (1.0 + (overshoot - 1.0) * (self.ratio - 1.0) / self.ratio);
            }
        }

        return filtered * gain * self.makeup_gain;
    }
};

/// Multiband compressor (3-band or 4-band)
pub const MultibandCompressor = struct {
    allocator: Allocator,
    sample_rate: u32,
    crossover_type: CrossoverType,

    // Bands
    bands: []CompressionBand,
    crossover_freqs: []f32, // N-1 crossover points for N bands

    // Output mixing
    band_gains: []f32,

    const Self = @This();

    /// Create a 3-band compressor (low, mid, high)
    pub fn init3Band(
        allocator: Allocator,
        sample_rate: u32,
        low_config: BandConfig,
        mid_config: BandConfig,
        high_config: BandConfig,
        low_mid_crossover: f32, // e.g., 250 Hz
        mid_high_crossover: f32, // e.g., 2500 Hz
    ) !Self {
        var bands = try allocator.alloc(CompressionBand, 3);
        bands[0] = CompressionBand.init(low_config, sample_rate);
        bands[1] = CompressionBand.init(mid_config, sample_rate);
        bands[2] = CompressionBand.init(high_config, sample_rate);

        // Update filter coefficients
        bands[0].updateFilter(20.0, low_mid_crossover, sample_rate); // Low band
        bands[1].updateFilter(low_mid_crossover, mid_high_crossover, sample_rate); // Mid band
        bands[2].updateFilter(mid_high_crossover, 20000.0, sample_rate); // High band

        var crossover_freqs = try allocator.alloc(f32, 2);
        crossover_freqs[0] = low_mid_crossover;
        crossover_freqs[1] = mid_high_crossover;

        var band_gains = try allocator.alloc(f32, 3);
        band_gains[0] = 1.0;
        band_gains[1] = 1.0;
        band_gains[2] = 1.0;

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .crossover_type = .linkwitz_riley_24,
            .bands = bands,
            .crossover_freqs = crossover_freqs,
            .band_gains = band_gains,
        };
    }

    /// Create a 4-band compressor (low, low-mid, high-mid, high)
    pub fn init4Band(
        allocator: Allocator,
        sample_rate: u32,
        configs: [4]BandConfig,
        crossovers: [3]f32, // e.g., [120, 1000, 8000]
    ) !Self {
        var bands = try allocator.alloc(CompressionBand, 4);
        for (configs, 0..) |config, i| {
            bands[i] = CompressionBand.init(config, sample_rate);
        }

        // Update filter coefficients
        bands[0].updateFilter(20.0, crossovers[0], sample_rate);
        bands[1].updateFilter(crossovers[0], crossovers[1], sample_rate);
        bands[2].updateFilter(crossovers[1], crossovers[2], sample_rate);
        bands[3].updateFilter(crossovers[2], 20000.0, sample_rate);

        const crossover_freqs = try allocator.alloc(f32, 3);
        @memcpy(crossover_freqs, &crossovers);

        var band_gains = try allocator.alloc(f32, 4);
        for (0..4) |i| {
            band_gains[i] = 1.0;
        }

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .crossover_type = .linkwitz_riley_24,
            .bands = bands,
            .crossover_freqs = crossover_freqs,
            .band_gains = band_gains,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bands);
        self.allocator.free(self.crossover_freqs);
        self.allocator.free(self.band_gains);
    }

    /// Process a single sample
    pub fn processSample(self: *Self, sample: f32) f32 {
        var output: f32 = 0;

        for (self.bands, 0..) |*band, i| {
            const band_output = band.processSample(sample);
            output += band_output * self.band_gains[i];
        }

        return output;
    }

    /// Process a buffer of samples
    pub fn process(self: *Self, input: []const f32, output: []f32) void {
        const len = @min(input.len, output.len);
        for (0..len) |i| {
            output[i] = self.processSample(input[i]);
        }
    }

    /// Set per-band output gain
    pub fn setBandGain(self: *Self, band_index: usize, gain_db: f32) void {
        if (band_index < self.bands.len) {
            self.band_gains[band_index] = math.pow(f32, 10.0, gain_db / 20.0);
        }
    }

    /// Update band configuration
    pub fn updateBand(self: *Self, band_index: usize, config: BandConfig) void {
        if (band_index < self.bands.len) {
            self.bands[band_index].updateConfig(config, self.sample_rate);
        }
    }

    /// Get reduction amount for a band (in dB)
    pub fn getBandReduction(self: *Self, band_index: usize) f32 {
        if (band_index >= self.bands.len) return 0;
        const band = &self.bands[band_index];

        if (band.envelope <= band.threshold) return 0;

        const overshoot = band.envelope / band.threshold;
        const reduction_linear = 1.0 / (1.0 + (overshoot - 1.0) * (band.ratio - 1.0) / band.ratio);
        return 20.0 * @log10(reduction_linear);
    }
};

/// Preset multiband compressor configurations
pub const MultibandPreset = enum {
    mastering_gentle,
    mastering_aggressive,
    broadcast,
    podcast,

    pub fn getLowConfig(self: MultibandPreset) BandConfig {
        return switch (self) {
            .mastering_gentle => .{
                .threshold_db = -24,
                .ratio = 2.5,
                .attack_ms = 30,
                .release_ms = 150,
                .knee_db = 3,
            },
            .mastering_aggressive => .{
                .threshold_db = -18,
                .ratio = 4.0,
                .attack_ms = 15,
                .release_ms = 100,
                .knee_db = 2,
            },
            .broadcast => .{
                .threshold_db = -20,
                .ratio = 3.0,
                .attack_ms = 20,
                .release_ms = 120,
                .knee_db = 2.5,
            },
            .podcast => .{
                .threshold_db = -22,
                .ratio = 3.5,
                .attack_ms = 25,
                .release_ms = 130,
                .knee_db = 3,
            },
        };
    }

    pub fn getMidConfig(self: MultibandPreset) BandConfig {
        return switch (self) {
            .mastering_gentle => .{
                .threshold_db = -20,
                .ratio = 2.0,
                .attack_ms = 20,
                .release_ms = 120,
                .knee_db = 3,
            },
            .mastering_aggressive => .{
                .threshold_db = -15,
                .ratio = 3.5,
                .attack_ms = 10,
                .release_ms = 80,
                .knee_db = 2,
            },
            .broadcast => .{
                .threshold_db = -16,
                .ratio = 4.0,
                .attack_ms = 10,
                .release_ms = 100,
                .knee_db = 2,
            },
            .podcast => .{
                .threshold_db = -18,
                .ratio = 3.0,
                .attack_ms = 15,
                .release_ms = 110,
                .knee_db = 2.5,
            },
        };
    }

    pub fn getHighConfig(self: MultibandPreset) BandConfig {
        return switch (self) {
            .mastering_gentle => .{
                .threshold_db = -22,
                .ratio = 2.5,
                .attack_ms = 10,
                .release_ms = 100,
                .knee_db = 2.5,
            },
            .mastering_aggressive => .{
                .threshold_db = -16,
                .ratio = 3.0,
                .attack_ms = 5,
                .release_ms = 60,
                .knee_db = 1.5,
            },
            .broadcast => .{
                .threshold_db = -18,
                .ratio = 3.5,
                .attack_ms = 5,
                .release_ms = 80,
                .knee_db = 2,
            },
            .podcast => .{
                .threshold_db = -20,
                .ratio = 3.0,
                .attack_ms = 8,
                .release_ms = 90,
                .knee_db = 2.5,
            },
        };
    }

    pub fn getCrossovers(self: MultibandPreset) [2]f32 {
        return switch (self) {
            .mastering_gentle => [2]f32{ 250, 2500 },
            .mastering_aggressive => [2]f32{ 200, 3000 },
            .broadcast => [2]f32{ 150, 3500 },
            .podcast => [2]f32{ 180, 3000 },
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MultibandCompressor 3-band init" {
    const allocator = std.testing.allocator;

    const preset = MultibandPreset.mastering_gentle;
    const crossovers = preset.getCrossovers();

    var comp = try MultibandCompressor.init3Band(
        allocator,
        44100,
        preset.getLowConfig(),
        preset.getMidConfig(),
        preset.getHighConfig(),
        crossovers[0],
        crossovers[1],
    );
    defer comp.deinit();

    try std.testing.expectEqual(@as(usize, 3), comp.bands.len);
    try std.testing.expectEqual(@as(usize, 2), comp.crossover_freqs.len);
}

test "MultibandCompressor process" {
    const allocator = std.testing.allocator;

    const preset = MultibandPreset.mastering_gentle;
    const crossovers = preset.getCrossovers();

    var comp = try MultibandCompressor.init3Band(
        allocator,
        44100,
        preset.getLowConfig(),
        preset.getMidConfig(),
        preset.getHighConfig(),
        crossovers[0],
        crossovers[1],
    );
    defer comp.deinit();

    const input = [_]f32{0.5} ** 100;
    var output: [100]f32 = undefined;

    comp.process(&input, &output);

    // Output should be modified
    var different = false;
    for (input, output) |i, o| {
        if (@abs(i - o) > 0.001) {
            different = true;
            break;
        }
    }
    try std.testing.expect(different);
}

test "MultibandCompressor band gain" {
    const allocator = std.testing.allocator;

    const preset = MultibandPreset.broadcast;
    const crossovers = preset.getCrossovers();

    var comp = try MultibandCompressor.init3Band(
        allocator,
        44100,
        preset.getLowConfig(),
        preset.getMidConfig(),
        preset.getHighConfig(),
        crossovers[0],
        crossovers[1],
    );
    defer comp.deinit();

    comp.setBandGain(0, -3.0); // -3 dB on low band
    try std.testing.expectApproxEqAbs(@as(f32, 0.707), comp.band_gains[0], 0.01);
}
