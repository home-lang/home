// Home Audio Library - Sidechain Compression
// Ducking effect controlled by external signal

const std = @import("std");
const math = std.math;

/// Sidechain compressor for ducking effects
pub const SidechainCompressor = struct {
    sample_rate: u32,

    // Compressor parameters
    threshold_db: f32,
    ratio: f32,
    attack_ms: f32,
    release_ms: f32,
    knee_db: f32,
    makeup_gain_db: f32,

    // State
    envelope: f32,
    attack_coeff: f32,
    release_coeff: f32,
    threshold: f32,
    knee: f32,
    makeup_gain: f32,

    // Detection mode
    mode: DetectionMode,

    const Self = @This();

    pub const DetectionMode = enum {
        peak, // Use peak detection
        rms, // Use RMS detection
    };

    pub fn init(sample_rate: u32) Self {
        var comp = Self{
            .sample_rate = sample_rate,
            .threshold_db = -20.0,
            .ratio = 4.0,
            .attack_ms = 5.0,
            .release_ms = 100.0,
            .knee_db = 2.0,
            .makeup_gain_db = 0.0,
            .envelope = 0,
            .attack_coeff = 0,
            .release_coeff = 0,
            .threshold = 0,
            .knee = 0,
            .makeup_gain = 1,
            .mode = .peak,
        };
        comp.updateCoefficients();
        return comp;
    }

    pub fn setThreshold(self: *Self, threshold_db: f32) void {
        self.threshold_db = threshold_db;
        self.updateCoefficients();
    }

    pub fn setRatio(self: *Self, ratio: f32) void {
        self.ratio = math.clamp(ratio, 1, 20);
    }

    pub fn setAttack(self: *Self, attack_ms: f32) void {
        self.attack_ms = attack_ms;
        self.updateCoefficients();
    }

    pub fn setRelease(self: *Self, release_ms: f32) void {
        self.release_ms = release_ms;
        self.updateCoefficients();
    }

    pub fn setKnee(self: *Self, knee_db: f32) void {
        self.knee_db = knee_db;
        self.updateCoefficients();
    }

    pub fn setMakeupGain(self: *Self, gain_db: f32) void {
        self.makeup_gain_db = gain_db;
        self.updateCoefficients();
    }

    pub fn setMode(self: *Self, mode: DetectionMode) void {
        self.mode = mode;
    }

    fn updateCoefficients(self: *Self) void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));

        // Convert dB to linear
        self.threshold = math.pow(f32, 10.0, self.threshold_db / 20.0);
        self.knee = math.pow(f32, 10.0, self.knee_db / 20.0);
        self.makeup_gain = math.pow(f32, 10.0, self.makeup_gain_db / 20.0);

        // Calculate envelope coefficients
        const attack_samples = self.attack_ms * sr / 1000.0;
        const release_samples = self.release_ms * sr / 1000.0;
        self.attack_coeff = @exp(-1.0 / attack_samples);
        self.release_coeff = @exp(-1.0 / release_samples);
    }

    /// Process a single sample with sidechain input
    /// sidechain_sample: The external signal controlling compression
    /// input_sample: The signal to be compressed
    pub fn processSample(self: *Self, sidechain_sample: f32, input_sample: f32) f32 {
        // Detect level from sidechain
        const abs_sidechain = @abs(sidechain_sample);

        // Envelope detection
        if (abs_sidechain > self.envelope) {
            self.envelope = self.attack_coeff * self.envelope + (1.0 - self.attack_coeff) * abs_sidechain;
        } else {
            self.envelope = self.release_coeff * self.envelope + (1.0 - self.release_coeff) * abs_sidechain;
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

        // Apply gain reduction to input signal
        return input_sample * gain * self.makeup_gain;
    }

    /// Process buffers with separate sidechain and input
    pub fn process(self: *Self, sidechain: []const f32, input: []const f32, output: []f32) void {
        const len = @min(@min(sidechain.len, input.len), output.len);
        for (0..len) |i| {
            output[i] = self.processSample(sidechain[i], input[i]);
        }
    }

    /// Get current gain reduction in dB
    pub fn getGainReduction(self: *Self) f32 {
        if (self.envelope <= self.threshold) return 0;

        const overshoot = self.envelope / self.threshold;
        const gain = 1.0 / (1.0 + (overshoot - 1.0) * (self.ratio - 1.0) / self.ratio);
        return 20.0 * @log10(gain);
    }
};

/// Sidechain gate - gates signal based on sidechain
pub const SidechainGate = struct {
    sample_rate: u32,

    // Gate parameters
    threshold_db: f32,
    attack_ms: f32,
    release_ms: f32,
    hold_ms: f32,
    range_db: f32, // Maximum attenuation

    // State
    envelope: f32,
    attack_coeff: f32,
    release_coeff: f32,
    threshold: f32,
    range: f32,
    hold_samples: u32,
    samples_below_threshold: u32,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        var gate = Self{
            .sample_rate = sample_rate,
            .threshold_db = -40.0,
            .attack_ms = 1.0,
            .release_ms = 100.0,
            .hold_ms = 10.0,
            .range_db = -80.0,
            .envelope = 0,
            .attack_coeff = 0,
            .release_coeff = 0,
            .threshold = 0,
            .range = 0,
            .hold_samples = 0,
            .samples_below_threshold = 0,
        };
        gate.updateCoefficients();
        return gate;
    }

    pub fn setThreshold(self: *Self, threshold_db: f32) void {
        self.threshold_db = threshold_db;
        self.updateCoefficients();
    }

    pub fn setAttack(self: *Self, attack_ms: f32) void {
        self.attack_ms = attack_ms;
        self.updateCoefficients();
    }

    pub fn setRelease(self: *Self, release_ms: f32) void {
        self.release_ms = release_ms;
        self.updateCoefficients();
    }

    pub fn setHold(self: *Self, hold_ms: f32) void {
        self.hold_ms = hold_ms;
        self.updateCoefficients();
    }

    pub fn setRange(self: *Self, range_db: f32) void {
        self.range_db = range_db;
        self.updateCoefficients();
    }

    fn updateCoefficients(self: *Self) void {
        const sr = @as(f32, @floatFromInt(self.sample_rate));

        self.threshold = math.pow(f32, 10.0, self.threshold_db / 20.0);
        self.range = math.pow(f32, 10.0, self.range_db / 20.0);

        const attack_samples = self.attack_ms * sr / 1000.0;
        const release_samples = self.release_ms * sr / 1000.0;
        self.attack_coeff = @exp(-1.0 / attack_samples);
        self.release_coeff = @exp(-1.0 / release_samples);

        self.hold_samples = @intFromFloat(self.hold_ms * sr / 1000.0);
    }

    pub fn processSample(self: *Self, sidechain_sample: f32, input_sample: f32) f32 {
        const abs_sidechain = @abs(sidechain_sample);

        // Envelope detection
        if (abs_sidechain > self.envelope) {
            self.envelope = self.attack_coeff * self.envelope + (1.0 - self.attack_coeff) * abs_sidechain;
        } else {
            self.envelope = self.release_coeff * self.envelope + (1.0 - self.release_coeff) * abs_sidechain;
        }

        // Gate logic with hold
        var gain: f32 = 1.0;
        if (self.envelope < self.threshold) {
            self.samples_below_threshold += 1;
            if (self.samples_below_threshold > self.hold_samples) {
                gain = self.range;
            }
        } else {
            self.samples_below_threshold = 0;
        }

        return input_sample * gain;
    }

    pub fn process(self: *Self, sidechain: []const f32, input: []const f32, output: []f32) void {
        const len = @min(@min(sidechain.len, input.len), output.len);
        for (0..len) |i| {
            output[i] = self.processSample(sidechain[i], input[i]);
        }
    }
};

/// Ducking preset - common sidechain compression settings
pub const DuckingPreset = enum {
    subtle, // Light ducking for voice-over
    moderate, // Moderate ducking for music under dialogue
    aggressive, // Heavy ducking for EDM sidechain pumping

    pub fn getSettings(self: DuckingPreset) struct {
        threshold_db: f32,
        ratio: f32,
        attack_ms: f32,
        release_ms: f32,
    } {
        return switch (self) {
            .subtle => .{
                .threshold_db = -25,
                .ratio = 2.5,
                .attack_ms = 10,
                .release_ms = 150,
            },
            .moderate => .{
                .threshold_db = -20,
                .ratio = 4.0,
                .attack_ms = 5,
                .release_ms = 100,
            },
            .aggressive => .{
                .threshold_db = -15,
                .ratio = 8.0,
                .attack_ms = 1,
                .release_ms = 50,
            },
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SidechainCompressor init" {
    const comp = SidechainCompressor.init(44100);
    try std.testing.expectEqual(@as(u32, 44100), comp.sample_rate);
}

test "SidechainCompressor ducking" {
    var comp = SidechainCompressor.init(44100);
    comp.setThreshold(-20);
    comp.setRatio(4.0);
    comp.setAttack(5);
    comp.setRelease(100);

    // Process with loud sidechain signal
    const sidechain = [_]f32{0.8} ** 100; // Loud sidechain
    const input = [_]f32{0.5} ** 100; // Normal input
    var output: [100]f32 = undefined;

    comp.process(&sidechain, &input, &output);

    // Output should be attenuated due to sidechain
    var sum_output: f32 = 0;
    for (output) |s| {
        sum_output += @abs(s);
    }
    const avg_output = sum_output / 100.0;

    try std.testing.expect(avg_output < 0.5); // Should be ducked
}

test "SidechainGate init" {
    const gate = SidechainGate.init(44100);
    try std.testing.expectEqual(@as(u32, 44100), gate.sample_rate);
}

test "DuckingPreset settings" {
    const settings = DuckingPreset.moderate.getSettings();
    try std.testing.expectEqual(@as(f32, -20), settings.threshold_db);
    try std.testing.expectEqual(@as(f32, 4.0), settings.ratio);
}
