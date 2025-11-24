// Home Video Library - Advanced Audio Processing
// Ducking, EQ, normalization, compression, pitch shifting

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Audio Ducking / Dynamic Range Compression
// ============================================================================

pub const DuckerOptions = struct {
    threshold_db: f32 = -20.0, // Threshold for ducking
    ratio: f32 = 4.0, // Compression ratio
    attack_ms: f32 = 5.0, // Attack time
    release_ms: f32 = 50.0, // Release time
    knee_db: f32 = 2.0, // Soft knee width
};

pub const Ducker = struct {
    options: DuckerOptions,
    sample_rate: u32,
    envelope: f32 = 0.0,
    attack_coef: f32,
    release_coef: f32,

    pub fn init(sample_rate: u32, options: DuckerOptions) Ducker {
        const attack_samples = (options.attack_ms / 1000.0) * @as(f32, @floatFromInt(sample_rate));
        const release_samples = (options.release_ms / 1000.0) * @as(f32, @floatFromInt(sample_rate));

        return .{
            .options = options,
            .sample_rate = sample_rate,
            .attack_coef = @exp(-1.0 / attack_samples),
            .release_coef = @exp(-1.0 / release_samples),
        };
    }

    pub fn process(self: *Ducker, input: []const f32, output: []f32) void {
        const threshold_linear = dbToLinear(self.options.threshold_db);

        for (input, output) |in_sample, *out_sample| {
            const input_level = @abs(in_sample);

            // Envelope follower
            if (input_level > self.envelope) {
                self.envelope += (input_level - self.envelope) * (1.0 - self.attack_coef);
            } else {
                self.envelope += (input_level - self.envelope) * (1.0 - self.release_coef);
            }

            // Calculate gain reduction
            var gain: f32 = 1.0;
            if (self.envelope > threshold_linear) {
                const over_db = linearToDb(self.envelope) - self.options.threshold_db;
                const reduction_db = over_db * (1.0 - 1.0 / self.options.ratio);
                gain = dbToLinear(-reduction_db);
            }

            out_sample.* = in_sample * gain;
        }
    }
};

// ============================================================================
// Parametric EQ
// ============================================================================

pub const EqBandType = enum {
    low_shelf,
    high_shelf,
    peak,
    low_pass,
    high_pass,
    band_pass,
    notch,
};

pub const EqBand = struct {
    type: EqBandType,
    frequency: f32, // Hz
    gain_db: f32, // For peak/shelf types
    q: f32 = 1.0, // Q factor (bandwidth)

    // Biquad coefficients
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    // State
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    pub fn init(band_type: EqBandType, frequency: f32, gain_db: f32, q: f32) EqBand {
        var band = EqBand{
            .type = band_type,
            .frequency = frequency,
            .gain_db = gain_db,
            .q = q,
        };
        return band;
    }

    pub fn calculateCoefficients(self: *EqBand, sample_rate: u32) void {
        const w0 = 2.0 * std.math.pi * self.frequency / @as(f32, @floatFromInt(sample_rate));
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * self.q);
        const A = std.math.pow(f32, 10.0, self.gain_db / 40.0);

        switch (self.type) {
            .peak => {
                self.b0 = 1.0 + alpha * A;
                self.b1 = -2.0 * cos_w0;
                self.b2 = 1.0 - alpha * A;
                const a0 = 1.0 + alpha / A;
                self.a1 = -2.0 * cos_w0 / a0;
                self.a2 = (1.0 - alpha / A) / a0;

                self.b0 /= a0;
                self.b1 /= a0;
                self.b2 /= a0;
            },
            .low_shelf => {
                const a_plus_1 = A + 1.0;
                const a_minus_1 = A - 1.0;

                self.b0 = A * (a_plus_1 - a_minus_1 * cos_w0 + 2.0 * @sqrt(A) * alpha);
                self.b1 = 2.0 * A * (a_minus_1 - a_plus_1 * cos_w0);
                self.b2 = A * (a_plus_1 - a_minus_1 * cos_w0 - 2.0 * @sqrt(A) * alpha);
                const a0 = a_plus_1 + a_minus_1 * cos_w0 + 2.0 * @sqrt(A) * alpha;
                self.a1 = -2.0 * (a_minus_1 + a_plus_1 * cos_w0) / a0;
                self.a2 = (a_plus_1 + a_minus_1 * cos_w0 - 2.0 * @sqrt(A) * alpha) / a0;

                self.b0 /= a0;
                self.b1 /= a0;
                self.b2 /= a0;
            },
            .high_shelf => {
                const a_plus_1 = A + 1.0;
                const a_minus_1 = A - 1.0;

                self.b0 = A * (a_plus_1 + a_minus_1 * cos_w0 + 2.0 * @sqrt(A) * alpha);
                self.b1 = -2.0 * A * (a_minus_1 + a_plus_1 * cos_w0);
                self.b2 = A * (a_plus_1 + a_minus_1 * cos_w0 - 2.0 * @sqrt(A) * alpha);
                const a0 = a_plus_1 - a_minus_1 * cos_w0 + 2.0 * @sqrt(A) * alpha;
                self.a1 = 2.0 * (a_minus_1 - a_plus_1 * cos_w0) / a0;
                self.a2 = (a_plus_1 - a_minus_1 * cos_w0 - 2.0 * @sqrt(A) * alpha) / a0;

                self.b0 /= a0;
                self.b1 /= a0;
                self.b2 /= a0;
            },
            .low_pass => {
                self.b0 = (1.0 - cos_w0) / 2.0;
                self.b1 = 1.0 - cos_w0;
                self.b2 = (1.0 - cos_w0) / 2.0;
                const a0 = 1.0 + alpha;
                self.a1 = -2.0 * cos_w0 / a0;
                self.a2 = (1.0 - alpha) / a0;

                self.b0 /= a0;
                self.b1 /= a0;
                self.b2 /= a0;
            },
            .high_pass => {
                self.b0 = (1.0 + cos_w0) / 2.0;
                self.b1 = -(1.0 + cos_w0);
                self.b2 = (1.0 + cos_w0) / 2.0;
                const a0 = 1.0 + alpha;
                self.a1 = -2.0 * cos_w0 / a0;
                self.a2 = (1.0 - alpha) / a0;

                self.b0 /= a0;
                self.b1 /= a0;
                self.b2 /= a0;
            },
            .band_pass => {
                self.b0 = alpha;
                self.b1 = 0.0;
                self.b2 = -alpha;
                const a0 = 1.0 + alpha;
                self.a1 = -2.0 * cos_w0 / a0;
                self.a2 = (1.0 - alpha) / a0;

                self.b0 /= a0;
                self.b2 /= a0;
            },
            .notch => {
                self.b0 = 1.0;
                self.b1 = -2.0 * cos_w0;
                self.b2 = 1.0;
                const a0 = 1.0 + alpha;
                self.a1 = -2.0 * cos_w0 / a0;
                self.a2 = (1.0 - alpha) / a0;

                self.b0 /= a0;
                self.b1 /= a0;
                self.b2 /= a0;
            },
        }
    }

    pub fn processSample(self: *EqBand, input: f32) f32 {
        const output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2 -
            self.a1 * self.y1 - self.a2 * self.y2;

        self.x2 = self.x1;
        self.x1 = input;
        self.y2 = self.y1;
        self.y1 = output;

        return output;
    }

    pub fn reset(self: *EqBand) void {
        self.x1 = 0;
        self.x2 = 0;
        self.y1 = 0;
        self.y2 = 0;
    }
};

pub const ParametricEq = struct {
    bands: []EqBand,
    sample_rate: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, sample_rate: u32, num_bands: usize) !ParametricEq {
        var bands = try allocator.alloc(EqBand, num_bands);
        for (bands) |*band| {
            band.* = EqBand.init(.peak, 1000, 0, 1.0);
        }

        return .{
            .bands = bands,
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParametricEq) void {
        self.allocator.free(self.bands);
    }

    pub fn setBand(self: *ParametricEq, index: usize, band: EqBand) void {
        if (index >= self.bands.len) return;
        self.bands[index] = band;
        self.bands[index].calculateCoefficients(self.sample_rate);
    }

    pub fn process(self: *ParametricEq, input: []const f32, output: []f32) void {
        // Process each sample through all bands
        for (input, output) |in_sample, *out_sample| {
            var sample = in_sample;
            for (self.bands) |*band| {
                sample = band.processSample(sample);
            }
            out_sample.* = sample;
        }
    }

    pub fn reset(self: *ParametricEq) void {
        for (self.bands) |*band| {
            band.reset();
        }
    }
};

// ============================================================================
// Graphic EQ (10-band)
// ============================================================================

pub const GraphicEq = struct {
    bands: [10]EqBand,
    sample_rate: u32,

    // Standard 10-band frequencies
    pub const FREQUENCIES = [10]f32{ 31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };

    pub fn init(sample_rate: u32) GraphicEq {
        var eq = GraphicEq{
            .bands = undefined,
            .sample_rate = sample_rate,
        };

        for (FREQUENCIES, 0..) |freq, i| {
            eq.bands[i] = EqBand.init(.peak, freq, 0, 1.0);
            eq.bands[i].calculateCoefficients(sample_rate);
        }

        return eq;
    }

    pub fn setGain(self: *GraphicEq, band_index: usize, gain_db: f32) void {
        if (band_index >= 10) return;
        self.bands[band_index].gain_db = gain_db;
        self.bands[band_index].calculateCoefficients(self.sample_rate);
    }

    pub fn process(self: *GraphicEq, input: []const f32, output: []f32) void {
        for (input, output) |in_sample, *out_sample| {
            var sample = in_sample;
            for (&self.bands) |*band| {
                sample = band.processSample(sample);
            }
            out_sample.* = sample;
        }
    }
};

// ============================================================================
// Audio Normalization
// ============================================================================

pub const NormalizationType = enum {
    peak, // Normalize to peak level
    rms, // Normalize to RMS level
    lufs, // Normalize to LUFS (ITU-R BS.1770)
};

pub const NormalizationOptions = struct {
    type: NormalizationType = .peak,
    target_db: f32 = -3.0, // Target level in dB
    true_peak_limit: bool = true, // Prevent true peaks > 0 dBFS
};

pub fn normalizeAudio(
    input: []const f32,
    output: []f32,
    options: NormalizationOptions,
) void {
    if (input.len != output.len) return;

    const current_level = switch (options.type) {
        .peak => calculatePeakLevel(input),
        .rms => calculateRmsLevel(input),
        .lufs => calculateSimplifiedLufs(input),
    };

    const target_linear = dbToLinear(options.target_db);
    const gain = target_linear / current_level;

    // Apply gain with optional true peak limiting
    for (input, output) |in_sample, *out_sample| {
        var processed = in_sample * gain;

        if (options.true_peak_limit) {
            processed = std.math.clamp(processed, -1.0, 1.0);
        }

        out_sample.* = processed;
    }
}

fn calculatePeakLevel(samples: []const f32) f32 {
    var peak: f32 = 0;
    for (samples) |sample| {
        const abs_sample = @abs(sample);
        if (abs_sample > peak) peak = abs_sample;
    }
    return peak;
}

fn calculateRmsLevel(samples: []const f32) f32 {
    var sum: f64 = 0;
    for (samples) |sample| {
        sum += @as(f64, sample) * @as(f64, sample);
    }
    return @sqrt(@as(f32, @floatCast(sum / @as(f64, @floatFromInt(samples.len)))));
}

fn calculateSimplifiedLufs(samples: []const f32) f32 {
    // Simplified LUFS calculation (real implementation needs K-weighting)
    return calculateRmsLevel(samples);
}

// ============================================================================
// Pitch Shifting (Simple Time-Domain)
// ============================================================================

pub const PitchShifter = struct {
    shift_semitones: f32,
    sample_rate: u32,
    buffer: []f32,
    read_pos: f32 = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator, sample_rate: u32, shift_semitones: f32) !PitchShifter {
        return .{
            .shift_semitones = shift_semitones,
            .sample_rate = sample_rate,
            .buffer = try allocator.alloc(f32, 8192),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PitchShifter) void {
        self.allocator.free(self.buffer);
    }

    pub fn process(self: *PitchShifter, input: []const f32, output: []f32) void {
        // Pitch shift ratio from semitones
        const ratio = std.math.pow(f32, 2.0, self.shift_semitones / 12.0);

        for (input, output) |in_sample, *out_sample| {
            // Simple resampling (real implementation would use PSOLA or phase vocoder)
            const int_pos: usize = @intFromFloat(self.read_pos);
            const frac = self.read_pos - @as(f32, @floatFromInt(int_pos));

            if (int_pos + 1 < input.len) {
                // Linear interpolation
                out_sample.* = input[int_pos] * (1.0 - frac) + input[int_pos + 1] * frac;
            } else {
                out_sample.* = in_sample;
            }

            self.read_pos += ratio;
            if (self.read_pos >= @as(f32, @floatFromInt(input.len))) {
                self.read_pos -= @as(f32, @floatFromInt(input.len));
            }
        }
    }
};

// ============================================================================
// Tempo Adjustment (Time-Stretching)
// ============================================================================

pub const TempoAdjuster = struct {
    tempo_ratio: f32, // 1.0 = original, 2.0 = double speed, 0.5 = half speed
    window_size: usize = 2048,
    hop_size: usize = 512,
    buffer: []f32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, tempo_ratio: f32) !TempoAdjuster {
        return .{
            .tempo_ratio = tempo_ratio,
            .buffer = try allocator.alloc(f32, 8192),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TempoAdjuster) void {
        self.allocator.free(self.buffer);
    }

    pub fn process(self: *TempoAdjuster, input: []const f32, output: []f32) ![]const f32 {
        // Simplified time-stretching using overlap-add
        // Real implementation would use PSOLA or phase vocoder

        const output_length = @as(usize, @intFromFloat(@as(f32, @floatFromInt(input.len)) / self.tempo_ratio));
        if (output.len < output_length) return error.BufferTooSmall;

        const analysis_hop = self.hop_size;
        const synthesis_hop = @as(usize, @intFromFloat(@as(f32, @floatFromInt(self.hop_size)) / self.tempo_ratio));

        var write_pos: usize = 0;
        var read_pos: usize = 0;

        while (write_pos + self.window_size < output_length and read_pos + self.window_size < input.len) {
            // Copy window with crossfade
            for (0..self.window_size) |i| {
                if (write_pos + i < output.len) {
                    output[write_pos + i] = input[read_pos + i];
                }
            }

            read_pos += analysis_hop;
            write_pos += synthesis_hop;
        }

        return output[0..output_length];
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

pub fn dbToLinear(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

pub fn linearToDb(linear: f32) f32 {
    return 20.0 * std.math.log10(std.math.max(linear, 1e-10));
}

// ============================================================================
// Tests
// ============================================================================

test "Ducker basic operation" {
    const testing = std.testing;

    var ducker = Ducker.init(48000, .{});

    var input = [_]f32{0.5} ** 100;
    var output = [_]f32{0.0} ** 100;

    ducker.process(&input, &output);

    // Output should be attenuated
    try testing.expect(output[50] < input[50]);
}

test "EQ band coefficient calculation" {
    const testing = std.testing;

    var band = EqBand.init(.peak, 1000, 6.0, 1.0);
    band.calculateCoefficients(48000);

    // Coefficients should be calculated
    try testing.expect(band.b0 != 0);
}

test "Pitch shift ratio calculation" {
    const testing = std.testing;

    const ratio = std.math.pow(f32, 2.0, 12.0 / 12.0); // +12 semitones = octave up
    try testing.expectApproxEqAbs(@as(f32, 2.0), ratio, 0.01);
}

test "Audio normalization peak" {
    const testing = std.testing;

    var input = [_]f32{ 0.5, 0.3, 0.7, 0.2 };
    var output = [_]f32{0.0} ** 4;

    normalizeAudio(&input, &output, .{ .type = .peak, .target_db = 0.0 });

    // Peak should be at 1.0
    const peak = calculatePeakLevel(&output);
    try testing.expectApproxEqAbs(@as(f32, 1.0), peak, 0.01);
}

test "Graphic EQ initialization" {
    const testing = std.testing;

    var eq = GraphicEq.init(48000);

    // Check that all bands are initialized
    for (eq.bands) |band| {
        try testing.expect(band.frequency > 0);
    }
}
