// Home Audio Library - Vocoder
// Classic vocoder effect for voice synthesis

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Vocoder band
const VocoderBand = struct {
    // Carrier filter state
    carrier_x1: f32 = 0,
    carrier_x2: f32 = 0,
    carrier_y1: f32 = 0,
    carrier_y2: f32 = 0,

    // Modulator filter state
    mod_x1: f32 = 0,
    mod_x2: f32 = 0,
    mod_y1: f32 = 0,
    mod_y2: f32 = 0,

    // Envelope follower state
    envelope: f32 = 0,

    // Filter coefficients
    b0: f64 = 0,
    b1: f64 = 0,
    b2: f64 = 0,
    a1: f64 = 0,
    a2: f64 = 0,

    // Band parameters
    frequency: f32 = 0,
    bandwidth: f32 = 0,
};

/// Vocoder processor
pub const Vocoder = struct {
    allocator: Allocator,
    sample_rate: u32,

    // Bands
    bands: []VocoderBand,
    num_bands: usize,

    // Parameters
    attack_time: f32, // ms
    release_time: f32, // ms
    carrier_level: f32,
    modulator_level: f32,
    output_level: f32,

    // Envelope coefficients
    attack_coeff: f32,
    release_coeff: f32,

    // Internal carrier (for built-in sawtooth)
    internal_carrier_phase: f32,
    internal_carrier_freq: f32,
    use_internal_carrier: bool,

    const Self = @This();

    pub const DEFAULT_NUM_BANDS = 16;
    pub const MIN_FREQ = 100.0;
    pub const MAX_FREQ = 8000.0;

    pub fn init(allocator: Allocator, sample_rate: u32) !Self {
        return initWithBands(allocator, sample_rate, DEFAULT_NUM_BANDS);
    }

    pub fn initWithBands(allocator: Allocator, sample_rate: u32, num_bands: usize) !Self {
        var vocoder = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .bands = try allocator.alloc(VocoderBand, num_bands),
            .num_bands = num_bands,
            .attack_time = 5,
            .release_time = 20,
            .carrier_level = 1.0,
            .modulator_level = 1.0,
            .output_level = 1.0,
            .attack_coeff = 0,
            .release_coeff = 0,
            .internal_carrier_phase = 0,
            .internal_carrier_freq = 100,
            .use_internal_carrier = false,
        };

        vocoder.updateCoefficients();
        vocoder.initializeBands();

        return vocoder;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bands);
    }

    fn updateCoefficients(self: *Self) void {
        const attack_samples = self.attack_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.attack_coeff = @exp(-1.0 / @max(attack_samples, 1.0));

        const release_samples = self.release_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.release_coeff = @exp(-1.0 / release_samples);
    }

    fn initializeBands(self: *Self) void {
        // Logarithmic frequency spacing
        const log_min = @log10(MIN_FREQ);
        const log_max = @log10(MAX_FREQ);
        const log_step = (log_max - log_min) / @as(f32, @floatFromInt(self.num_bands));

        for (0..self.num_bands) |i| {
            const log_freq = log_min + log_step * (@as(f32, @floatFromInt(i)) + 0.5);
            const freq = math.pow(f32, 10.0, log_freq);
            const bandwidth = freq * 0.5; // Half-octave bandwidth

            self.bands[i] = VocoderBand{
                .frequency = freq,
                .bandwidth = bandwidth,
            };

            self.calculateBandCoeffs(i);
        }
    }

    fn calculateBandCoeffs(self: *Self, band_idx: usize) void {
        const freq = self.bands[band_idx].frequency;
        const bw = self.bands[band_idx].bandwidth;

        const w0 = 2.0 * math.pi * @as(f64, freq) / @as(f64, @floatFromInt(self.sample_rate));
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const q = freq / bw;
        const alpha = sin_w0 / (2.0 * @as(f64, q));

        // Band-pass filter coefficients
        const b0 = alpha;
        const b1: f64 = 0;
        const b2 = -alpha;
        const a0 = 1 + alpha;
        const a1 = -2 * cos_w0;
        const a2 = 1 - alpha;

        self.bands[band_idx].b0 = b0 / a0;
        self.bands[band_idx].b1 = b1 / a0;
        self.bands[band_idx].b2 = b2 / a0;
        self.bands[band_idx].a1 = a1 / a0;
        self.bands[band_idx].a2 = a2 / a0;
    }

    /// Set attack time in ms
    pub fn setAttack(self: *Self, ms: f32) void {
        self.attack_time = @max(0.1, ms);
        self.updateCoefficients();
    }

    /// Set release time in ms
    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_time = @max(1.0, ms);
        self.updateCoefficients();
    }

    /// Set carrier level
    pub fn setCarrierLevel(self: *Self, level: f32) void {
        self.carrier_level = std.math.clamp(level, 0.0, 2.0);
    }

    /// Set modulator level
    pub fn setModulatorLevel(self: *Self, level: f32) void {
        self.modulator_level = std.math.clamp(level, 0.0, 2.0);
    }

    /// Set output level
    pub fn setOutputLevel(self: *Self, level: f32) void {
        self.output_level = std.math.clamp(level, 0.0, 2.0);
    }

    /// Enable internal carrier with given frequency
    pub fn setInternalCarrier(self: *Self, enabled: bool, frequency: f32) void {
        self.use_internal_carrier = enabled;
        self.internal_carrier_freq = std.math.clamp(frequency, 20, 500);
    }

    /// Generate internal carrier sample (sawtooth)
    fn generateCarrier(self: *Self) f32 {
        self.internal_carrier_phase += self.internal_carrier_freq / @as(f32, @floatFromInt(self.sample_rate));
        if (self.internal_carrier_phase >= 1.0) {
            self.internal_carrier_phase -= 1.0;
        }

        // Sawtooth wave with harmonics
        return self.internal_carrier_phase * 2.0 - 1.0;
    }

    /// Apply band-pass filter
    fn applyFilter(band: *VocoderBand, input: f32, is_carrier: bool) f32 {
        const x = @as(f64, input);
        var y: f64 = undefined;

        if (is_carrier) {
            y = band.b0 * x + band.b1 * band.carrier_x1 + band.b2 * band.carrier_x2 -
                band.a1 * band.carrier_y1 - band.a2 * band.carrier_y2;

            band.carrier_x2 = band.carrier_x1;
            band.carrier_x1 = @floatCast(x);
            band.carrier_y2 = band.carrier_y1;
            band.carrier_y1 = @floatCast(y);
        } else {
            y = band.b0 * x + band.b1 * band.mod_x1 + band.b2 * band.mod_x2 -
                band.a1 * band.mod_y1 - band.a2 * band.mod_y2;

            band.mod_x2 = band.mod_x1;
            band.mod_x1 = @floatCast(x);
            band.mod_y2 = band.mod_y1;
            band.mod_y1 = @floatCast(y);
        }

        return @floatCast(y);
    }

    /// Process audio with separate carrier and modulator
    pub fn process(self: *Self, carrier: []const f32, modulator: []const f32, output: []f32) void {
        const num_samples = @min(carrier.len, @min(modulator.len, output.len));

        for (0..num_samples) |i| {
            var carrier_sample = carrier[i] * self.carrier_level;
            const mod_sample = modulator[i] * self.modulator_level;

            // Use internal carrier if enabled
            if (self.use_internal_carrier) {
                carrier_sample = self.generateCarrier() * self.carrier_level;
            }

            var out: f32 = 0;

            // Process each band
            for (self.bands) |*band| {
                // Filter carrier
                const carrier_filtered = applyFilter(band, carrier_sample, true);

                // Filter modulator
                const mod_filtered = applyFilter(band, mod_sample, false);

                // Envelope follower
                const mod_abs = @abs(mod_filtered);
                if (mod_abs > band.envelope) {
                    band.envelope = self.attack_coeff * band.envelope + (1.0 - self.attack_coeff) * mod_abs;
                } else {
                    band.envelope = self.release_coeff * band.envelope + (1.0 - self.release_coeff) * mod_abs;
                }

                // Modulate carrier with envelope
                out += carrier_filtered * band.envelope;
            }

            output[i] = out * self.output_level / @as(f32, @floatFromInt(self.num_bands)) * 4.0;
        }
    }

    /// Process stereo in-place (left = carrier, right = modulator -> both = output)
    pub fn processStereo(self: *Self, buffer: []f32) void {
        const num_frames = buffer.len / 2;

        for (0..num_frames) |frame| {
            const carrier_sample = buffer[frame * 2] * self.carrier_level;
            const mod_sample = buffer[frame * 2 + 1] * self.modulator_level;

            var carrier_input = carrier_sample;
            if (self.use_internal_carrier) {
                carrier_input = self.generateCarrier() * self.carrier_level;
            }

            var out: f32 = 0;

            for (self.bands) |*band| {
                const carrier_filtered = applyFilter(band, carrier_input, true);
                const mod_filtered = applyFilter(band, mod_sample, false);

                const mod_abs = @abs(mod_filtered);
                if (mod_abs > band.envelope) {
                    band.envelope = self.attack_coeff * band.envelope + (1.0 - self.attack_coeff) * mod_abs;
                } else {
                    band.envelope = self.release_coeff * band.envelope + (1.0 - self.release_coeff) * mod_abs;
                }

                out += carrier_filtered * band.envelope;
            }

            const result = out * self.output_level / @as(f32, @floatFromInt(self.num_bands)) * 4.0;
            buffer[frame * 2] = result;
            buffer[frame * 2 + 1] = result;
        }
    }

    /// Reset all filter states
    pub fn reset(self: *Self) void {
        for (self.bands) |*band| {
            band.carrier_x1 = 0;
            band.carrier_x2 = 0;
            band.carrier_y1 = 0;
            band.carrier_y2 = 0;
            band.mod_x1 = 0;
            band.mod_x2 = 0;
            band.mod_y1 = 0;
            band.mod_y2 = 0;
            band.envelope = 0;
        }
        self.internal_carrier_phase = 0;
    }
};

/// Vocoder preset
pub const VocoderPreset = enum {
    classic, // Classic analog vocoder sound
    robot, // Robot voice effect
    whisper, // Whisper effect
    formant, // Formant preservation

    pub fn apply(self: VocoderPreset, vocoder: *Vocoder) void {
        switch (self) {
            .classic => {
                vocoder.setAttack(5);
                vocoder.setRelease(20);
            },
            .robot => {
                vocoder.setAttack(1);
                vocoder.setRelease(5);
                vocoder.setInternalCarrier(true, 100);
            },
            .whisper => {
                vocoder.setAttack(2);
                vocoder.setRelease(50);
            },
            .formant => {
                vocoder.setAttack(10);
                vocoder.setRelease(30);
            },
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Vocoder init" {
    const allocator = std.testing.allocator;

    var vocoder = try Vocoder.init(allocator, 44100);
    defer vocoder.deinit();

    try std.testing.expectEqual(@as(usize, Vocoder.DEFAULT_NUM_BANDS), vocoder.num_bands);
}

test "Vocoder process" {
    const allocator = std.testing.allocator;

    var vocoder = try Vocoder.init(allocator, 44100);
    defer vocoder.deinit();

    var carrier = [_]f32{ 0.5, -0.5, 0.3, -0.3 };
    var modulator = [_]f32{ 0.8, 0.7, 0.6, 0.5 };
    var output: [4]f32 = undefined;

    vocoder.process(&carrier, &modulator, &output);

    try std.testing.expect(output[0] != 0 or output[1] != 0);
}

test "Vocoder preset" {
    const allocator = std.testing.allocator;

    var vocoder = try Vocoder.init(allocator, 44100);
    defer vocoder.deinit();

    VocoderPreset.robot.apply(&vocoder);
    try std.testing.expect(vocoder.use_internal_carrier);
}
