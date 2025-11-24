// Home Audio Library - De-esser
// Sibilance reduction for vocal processing

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// De-esser detection mode
pub const DetectionMode = enum {
    wideband, // Detect on full signal
    split_band, // Detect only in sibilant range
};

/// De-esser type
pub const DeesserType = enum {
    cut, // Reduce sibilant frequencies
    duck, // Duck entire signal during sibilance
};

/// De-esser processor
pub const Deesser = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    // Parameters
    threshold_db: f32,
    threshold: f32,
    ratio: f32,
    frequency: f32, // Center frequency for sibilance detection
    range_db: f32, // Maximum gain reduction
    attack_time: f32, // ms
    release_time: f32, // ms
    detection_mode: DetectionMode,
    deesser_type: DeesserType,

    // Coefficients
    attack_coeff: f32,
    release_coeff: f32,

    // High-pass filter for sibilance detection (per channel)
    hp_x1: [8]f64,
    hp_x2: [8]f64,
    hp_y1: [8]f64,
    hp_y2: [8]f64,
    hp_coeffs: BiquadCoeffs,

    // Band-pass filter for sibilance reduction (per channel)
    bp_x1: [8]f64,
    bp_x2: [8]f64,
    bp_y1: [8]f64,
    bp_y2: [8]f64,
    bp_coeffs: BiquadCoeffs,

    // State
    envelope: [8]f32,
    gain_reduction: [8]f32,

    const Self = @This();

    const BiquadCoeffs = struct {
        b0: f64,
        b1: f64,
        b2: f64,
        a1: f64,
        a2: f64,
    };

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) Self {
        var deesser = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .threshold_db = -20,
            .threshold = math.pow(f32, 10.0, -20.0 / 20.0),
            .ratio = 4.0,
            .frequency = 6000,
            .range_db = -12,
            .attack_time = 0.5,
            .release_time = 50,
            .detection_mode = .split_band,
            .deesser_type = .cut,
            .attack_coeff = 0,
            .release_coeff = 0,
            .hp_x1 = [_]f64{0} ** 8,
            .hp_x2 = [_]f64{0} ** 8,
            .hp_y1 = [_]f64{0} ** 8,
            .hp_y2 = [_]f64{0} ** 8,
            .hp_coeffs = .{ .b0 = 1, .b1 = 0, .b2 = 0, .a1 = 0, .a2 = 0 },
            .bp_x1 = [_]f64{0} ** 8,
            .bp_x2 = [_]f64{0} ** 8,
            .bp_y1 = [_]f64{0} ** 8,
            .bp_y2 = [_]f64{0} ** 8,
            .bp_coeffs = .{ .b0 = 1, .b1 = 0, .b2 = 0, .a1 = 0, .a2 = 0 },
            .envelope = [_]f32{0} ** 8,
            .gain_reduction = [_]f32{1} ** 8,
        };
        deesser.updateCoefficients();
        return deesser;
    }

    fn updateCoefficients(self: *Self) void {
        // Time constants
        const attack_samples = self.attack_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.attack_coeff = @exp(-1.0 / @max(attack_samples, 1.0));

        const release_samples = self.release_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.release_coeff = @exp(-1.0 / release_samples);

        // High-pass filter for detection (2nd order Butterworth)
        const w0 = 2.0 * math.pi * @as(f64, self.frequency) / @as(f64, @floatFromInt(self.sample_rate));
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * @sqrt(2.0)); // Q = sqrt(2)/2 for Butterworth

        // High-pass coefficients
        const hp_b0 = (1 + cos_w0) / 2;
        const hp_b1 = -(1 + cos_w0);
        const hp_b2 = (1 + cos_w0) / 2;
        const hp_a0 = 1 + alpha;
        const hp_a1 = -2 * cos_w0;
        const hp_a2 = 1 - alpha;

        self.hp_coeffs = .{
            .b0 = hp_b0 / hp_a0,
            .b1 = hp_b1 / hp_a0,
            .b2 = hp_b2 / hp_a0,
            .a1 = hp_a1 / hp_a0,
            .a2 = hp_a2 / hp_a0,
        };

        // Band-pass filter for reduction (narrower Q)
        const bp_alpha = sin_w0 / (2.0 * 2.0); // Q = 2
        const bp_b0 = bp_alpha;
        const bp_b1: f64 = 0;
        const bp_b2 = -bp_alpha;
        const bp_a0 = 1 + bp_alpha;
        const bp_a1 = -2 * cos_w0;
        const bp_a2 = 1 - bp_alpha;

        self.bp_coeffs = .{
            .b0 = bp_b0 / bp_a0,
            .b1 = bp_b1 / bp_a0,
            .b2 = bp_b2 / bp_a0,
            .a1 = bp_a1 / bp_a0,
            .a2 = bp_a2 / bp_a0,
        };
    }

    /// Set threshold in dB
    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
        self.threshold = math.pow(f32, 10.0, db / 20.0);
    }

    /// Set ratio
    pub fn setRatio(self: *Self, ratio: f32) void {
        self.ratio = @max(1.0, ratio);
    }

    /// Set center frequency in Hz
    pub fn setFrequency(self: *Self, freq: f32) void {
        self.frequency = std.math.clamp(freq, 2000, 12000);
        self.updateCoefficients();
    }

    /// Set maximum gain reduction range in dB
    pub fn setRange(self: *Self, db: f32) void {
        self.range_db = @min(0, db);
    }

    /// Set attack time in ms
    pub fn setAttack(self: *Self, ms: f32) void {
        self.attack_time = @max(0.01, ms);
        self.updateCoefficients();
    }

    /// Set release time in ms
    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_time = @max(1.0, ms);
        self.updateCoefficients();
    }

    /// Apply high-pass filter for detection
    fn applyHighPass(self: *Self, sample: f32, ch: u8) f32 {
        const x: f64 = sample;
        const y = self.hp_coeffs.b0 * x +
            self.hp_coeffs.b1 * self.hp_x1[ch] +
            self.hp_coeffs.b2 * self.hp_x2[ch] -
            self.hp_coeffs.a1 * self.hp_y1[ch] -
            self.hp_coeffs.a2 * self.hp_y2[ch];

        self.hp_x2[ch] = self.hp_x1[ch];
        self.hp_x1[ch] = x;
        self.hp_y2[ch] = self.hp_y1[ch];
        self.hp_y1[ch] = y;

        return @floatCast(y);
    }

    /// Apply band-pass filter for reduction
    fn applyBandPass(self: *Self, sample: f32, ch: u8) f32 {
        const x: f64 = sample;
        const y = self.bp_coeffs.b0 * x +
            self.bp_coeffs.b1 * self.bp_x1[ch] +
            self.bp_coeffs.b2 * self.bp_x2[ch] -
            self.bp_coeffs.a1 * self.bp_y1[ch] -
            self.bp_coeffs.a2 * self.bp_y2[ch];

        self.bp_x2[ch] = self.bp_x1[ch];
        self.bp_x1[ch] = x;
        self.bp_y2[ch] = self.bp_y1[ch];
        self.bp_y1[ch] = y;

        return @floatCast(y);
    }

    /// Process a single sample
    pub fn processSample(self: *Self, sample: f32, channel: u8) f32 {
        const ch = @min(channel, 7);

        // Detection signal
        const detect_signal: f32 = switch (self.detection_mode) {
            .wideband => sample,
            .split_band => self.applyHighPass(sample, ch),
        };

        const abs_detect = @abs(detect_signal);

        // Envelope follower
        if (abs_detect > self.envelope[ch]) {
            self.envelope[ch] = self.attack_coeff * self.envelope[ch] + (1.0 - self.attack_coeff) * abs_detect;
        } else {
            self.envelope[ch] = self.release_coeff * self.envelope[ch] + (1.0 - self.release_coeff) * abs_detect;
        }

        // Calculate gain reduction
        var gr: f32 = 1.0;
        if (self.envelope[ch] > self.threshold) {
            const over_db = 20.0 * @log10(self.envelope[ch] / self.threshold);
            const reduction_db = over_db * (1.0 - 1.0 / self.ratio);
            const clamped_db = @max(self.range_db, -reduction_db);
            gr = math.pow(f32, 10.0, clamped_db / 20.0);
        }

        // Smooth gain reduction
        if (gr < self.gain_reduction[ch]) {
            self.gain_reduction[ch] = self.attack_coeff * self.gain_reduction[ch] + (1.0 - self.attack_coeff) * gr;
        } else {
            self.gain_reduction[ch] = self.release_coeff * self.gain_reduction[ch] + (1.0 - self.release_coeff) * gr;
        }

        // Apply reduction
        return switch (self.deesser_type) {
            .cut => {
                // Only reduce sibilant frequencies
                const sibilant = self.applyBandPass(sample, ch);
                return sample - sibilant * (1.0 - self.gain_reduction[ch]);
            },
            .duck => {
                // Duck entire signal
                return sample * self.gain_reduction[ch];
            },
        };
    }

    /// Process buffer
    pub fn process(self: *Self, buffer: []f32) void {
        const frame_count = buffer.len / self.channels;

        for (0..frame_count) |frame| {
            for (0..self.channels) |ch| {
                const idx = frame * self.channels + ch;
                buffer[idx] = self.processSample(buffer[idx], @intCast(ch));
            }
        }
    }

    /// Get current gain reduction in dB for a channel
    pub fn getGainReductionDb(self: *Self, channel: u8) f32 {
        const ch = @min(channel, 7);
        if (self.gain_reduction[ch] <= 0) return -100;
        return 20.0 * @log10(self.gain_reduction[ch]);
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        self.hp_x1 = [_]f64{0} ** 8;
        self.hp_x2 = [_]f64{0} ** 8;
        self.hp_y1 = [_]f64{0} ** 8;
        self.hp_y2 = [_]f64{0} ** 8;
        self.bp_x1 = [_]f64{0} ** 8;
        self.bp_x2 = [_]f64{0} ** 8;
        self.bp_y1 = [_]f64{0} ** 8;
        self.bp_y2 = [_]f64{0} ** 8;
        self.envelope = [_]f32{0} ** 8;
        self.gain_reduction = [_]f32{1} ** 8;
    }
};

/// Multi-band de-esser with adjustable bands
pub const MultibandDeesser = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    // Multiple bands for different sibilant frequencies
    bands: [3]Deesser,
    band_enabled: [3]bool,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) Self {
        var deesser = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .bands = undefined,
            .band_enabled = .{ true, true, true },
        };

        // Low sibilance (4-6 kHz)
        deesser.bands[0] = Deesser.init(allocator, sample_rate, channels);
        deesser.bands[0].setFrequency(5000);
        deesser.bands[0].setThreshold(-25);

        // Mid sibilance (6-8 kHz)
        deesser.bands[1] = Deesser.init(allocator, sample_rate, channels);
        deesser.bands[1].setFrequency(7000);
        deesser.bands[1].setThreshold(-22);

        // High sibilance (8-10 kHz)
        deesser.bands[2] = Deesser.init(allocator, sample_rate, channels);
        deesser.bands[2].setFrequency(9000);
        deesser.bands[2].setThreshold(-20);

        return deesser;
    }

    /// Enable/disable a specific band
    pub fn setBandEnabled(self: *Self, band: usize, enabled: bool) void {
        if (band < 3) {
            self.band_enabled[band] = enabled;
        }
    }

    /// Set threshold for a specific band
    pub fn setBandThreshold(self: *Self, band: usize, db: f32) void {
        if (band < 3) {
            self.bands[band].setThreshold(db);
        }
    }

    /// Process buffer
    pub fn process(self: *Self, buffer: []f32) void {
        for (0..3) |i| {
            if (self.band_enabled[i]) {
                self.bands[i].process(buffer);
            }
        }
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        for (&self.bands) |*band| {
            band.reset();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Deesser init" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var deesser = Deesser.init(std.testing.allocator, 44100, 2);
    _ = &deesser;

    deesser.setThreshold(-20);
    deesser.setFrequency(6000);
    deesser.setRatio(4);
}

test "Deesser process" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var deesser = Deesser.init(std.testing.allocator, 44100, 1);
    deesser.setThreshold(-30);

    var buffer = [_]f32{ 0.5, -0.5, 0.3, -0.3, 0.8, -0.8, 0.2, -0.2 };
    deesser.process(&buffer);

    // Output should be processed
    try std.testing.expect(buffer[0] != 0);
}

test "MultibandDeesser init" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var deesser = MultibandDeesser.init(std.testing.allocator, 44100, 2);
    _ = &deesser;

    deesser.setBandEnabled(0, true);
    deesser.setBandThreshold(0, -25);
}
