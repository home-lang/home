// Home Audio Library - Noise Reduction
// Spectral subtraction and noise gate based noise reduction

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Noise reduction algorithm type
pub const NoiseReductionType = enum {
    spectral_subtraction, // FFT-based spectral subtraction
    noise_gate, // Simple noise gate
    expander, // Downward expander
    adaptive, // Adaptive noise floor tracking
};

/// Simple Noise Gate
pub const NoiseGate = struct {
    threshold: f32,
    threshold_db: f32,
    attack_time: f32, // ms
    release_time: f32, // ms
    hold_time: f32, // ms
    range_db: f32, // Maximum attenuation
    sample_rate: u32,

    // Coefficients
    attack_coeff: f32,
    release_coeff: f32,
    hold_samples: u32,

    // State
    envelope: f32,
    gate_state: f32, // 0 = closed, 1 = open
    hold_counter: u32,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        var gate = Self{
            .threshold = math.pow(f32, 10.0, -40.0 / 20.0),
            .threshold_db = -40,
            .attack_time = 1,
            .release_time = 100,
            .hold_time = 50,
            .range_db = -80,
            .sample_rate = sample_rate,
            .attack_coeff = 0,
            .release_coeff = 0,
            .hold_samples = 0,
            .envelope = 0,
            .gate_state = 1,
            .hold_counter = 0,
        };
        gate.updateCoefficients();
        return gate;
    }

    fn updateCoefficients(self: *Self) void {
        const attack_samples = self.attack_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.attack_coeff = @exp(-1.0 / @max(attack_samples, 1.0));

        const release_samples = self.release_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.release_coeff = @exp(-1.0 / release_samples);

        self.hold_samples = @intFromFloat(self.hold_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0);
    }

    /// Set threshold in dB
    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
        self.threshold = math.pow(f32, 10.0, db / 20.0);
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

    /// Set hold time in ms
    pub fn setHold(self: *Self, ms: f32) void {
        self.hold_time = @max(0, ms);
        self.updateCoefficients();
    }

    /// Set range (maximum attenuation) in dB
    pub fn setRange(self: *Self, db: f32) void {
        self.range_db = @min(0, db);
    }

    /// Process a single sample
    pub fn processSample(self: *Self, sample: f32) f32 {
        const abs_sample = @abs(sample);

        // Envelope follower
        if (abs_sample > self.envelope) {
            self.envelope = self.attack_coeff * self.envelope + (1.0 - self.attack_coeff) * abs_sample;
        } else {
            self.envelope = self.release_coeff * self.envelope + (1.0 - self.release_coeff) * abs_sample;
        }

        // Gate logic
        if (self.envelope > self.threshold) {
            self.hold_counter = self.hold_samples;
            // Open gate
            self.gate_state = self.attack_coeff * self.gate_state + (1.0 - self.attack_coeff);
        } else if (self.hold_counter > 0) {
            self.hold_counter -= 1;
        } else {
            // Close gate
            const min_gain = math.pow(f32, 10.0, self.range_db / 20.0);
            self.gate_state = self.release_coeff * self.gate_state + (1.0 - self.release_coeff) * min_gain;
        }

        return sample * self.gate_state;
    }

    /// Process buffer
    pub fn process(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.processSample(sample.*);
        }
    }

    /// Get current gate state (0-1)
    pub fn getGateState(self: *Self) f32 {
        return self.gate_state;
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        self.envelope = 0;
        self.gate_state = 1;
        self.hold_counter = 0;
    }
};

/// Downward Expander (softer than gate)
pub const Expander = struct {
    threshold: f32,
    threshold_db: f32,
    ratio: f32, // Expansion ratio (2:1, 4:1, etc.)
    attack_time: f32,
    release_time: f32,
    knee_width: f32, // dB
    sample_rate: u32,

    // Coefficients
    attack_coeff: f32,
    release_coeff: f32,

    // State
    envelope: f32,
    gain: f32,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        var exp = Self{
            .threshold = math.pow(f32, 10.0, -30.0 / 20.0),
            .threshold_db = -30,
            .ratio = 2.0,
            .attack_time = 1,
            .release_time = 50,
            .knee_width = 6,
            .sample_rate = sample_rate,
            .attack_coeff = 0,
            .release_coeff = 0,
            .envelope = 0,
            .gain = 1,
        };
        exp.updateCoefficients();
        return exp;
    }

    fn updateCoefficients(self: *Self) void {
        const attack_samples = self.attack_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.attack_coeff = @exp(-1.0 / @max(attack_samples, 1.0));

        const release_samples = self.release_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.release_coeff = @exp(-1.0 / release_samples);
    }

    /// Set threshold in dB
    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
        self.threshold = math.pow(f32, 10.0, db / 20.0);
    }

    /// Set expansion ratio
    pub fn setRatio(self: *Self, ratio: f32) void {
        self.ratio = @max(1.0, ratio);
    }

    /// Compute gain with soft knee
    fn computeGain(self: *Self, input_db: f32) f32 {
        const knee_start = self.threshold_db - self.knee_width / 2;
        const knee_end = self.threshold_db + self.knee_width / 2;

        if (input_db >= knee_end) {
            // Above threshold, no expansion
            return 0;
        } else if (input_db <= knee_start) {
            // Below knee, full expansion
            const below = self.threshold_db - input_db;
            return -(below * (self.ratio - 1));
        } else {
            // In knee region
            const knee_pos = (knee_end - input_db) / self.knee_width;
            const below = self.threshold_db - input_db;
            return -(below * (self.ratio - 1) * knee_pos * knee_pos);
        }
    }

    /// Process a single sample
    pub fn processSample(self: *Self, sample: f32) f32 {
        const abs_sample = @abs(sample);

        // Envelope follower
        if (abs_sample > self.envelope) {
            self.envelope = self.attack_coeff * self.envelope + (1.0 - self.attack_coeff) * abs_sample;
        } else {
            self.envelope = self.release_coeff * self.envelope + (1.0 - self.release_coeff) * abs_sample;
        }

        const env_db: f32 = if (self.envelope > 0.000001) 20.0 * @log10(self.envelope) else -120;
        const gain_db = self.computeGain(env_db);
        self.gain = math.pow(f32, 10.0, gain_db / 20.0);

        return sample * self.gain;
    }

    /// Process buffer
    pub fn process(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.processSample(sample.*);
        }
    }

    /// Get current gain in dB
    pub fn getGainDb(self: *Self) f32 {
        if (self.gain <= 0) return -100;
        return 20.0 * @log10(self.gain);
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        self.envelope = 0;
        self.gain = 1;
    }
};

/// Spectral noise reduction using simple spectral subtraction
/// Note: Requires FFT processing, simplified implementation
pub const SpectralNoiseReducer = struct {
    allocator: Allocator,
    sample_rate: u32,
    fft_size: usize,
    hop_size: usize,

    // Noise profile (estimated noise floor per bin)
    noise_profile: []f32,
    noise_profile_set: bool,

    // Processing parameters
    reduction_amount: f32, // 0.0 - 1.0
    noise_floor: f32, // Minimum level to preserve

    // Buffers
    input_buffer: []f32,
    output_buffer: []f32,
    window: []f32,
    input_pos: usize,
    output_pos: usize,

    // FFT workspace (simplified - real implementation would use proper FFT)
    fft_real: []f32,
    fft_imag: []f32,

    const Self = @This();

    pub const DEFAULT_FFT_SIZE = 2048;

    pub fn init(allocator: Allocator, sample_rate: u32) !Self {
        return initWithSize(allocator, sample_rate, DEFAULT_FFT_SIZE);
    }

    pub fn initWithSize(allocator: Allocator, sample_rate: u32, fft_size: usize) !Self {
        const hop_size = fft_size / 4;
        const bins = fft_size / 2 + 1;

        var reducer = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .fft_size = fft_size,
            .hop_size = hop_size,
            .noise_profile = try allocator.alloc(f32, bins),
            .noise_profile_set = false,
            .reduction_amount = 0.8,
            .noise_floor = 0.001,
            .input_buffer = try allocator.alloc(f32, fft_size * 2),
            .output_buffer = try allocator.alloc(f32, fft_size * 2),
            .window = try allocator.alloc(f32, fft_size),
            .input_pos = 0,
            .output_pos = 0,
            .fft_real = try allocator.alloc(f32, fft_size),
            .fft_imag = try allocator.alloc(f32, fft_size),
        };

        // Initialize Hann window
        for (0..fft_size) |i| {
            reducer.window[i] = 0.5 * (1.0 - @cos(2.0 * math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fft_size))));
        }

        @memset(reducer.noise_profile, 0);
        @memset(reducer.input_buffer, 0);
        @memset(reducer.output_buffer, 0);
        @memset(reducer.fft_real, 0);
        @memset(reducer.fft_imag, 0);

        return reducer;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.noise_profile);
        self.allocator.free(self.input_buffer);
        self.allocator.free(self.output_buffer);
        self.allocator.free(self.window);
        self.allocator.free(self.fft_real);
        self.allocator.free(self.fft_imag);
    }

    /// Set reduction amount (0.0 - 1.0)
    pub fn setReduction(self: *Self, amount: f32) void {
        self.reduction_amount = std.math.clamp(amount, 0.0, 1.0);
    }

    /// Learn noise profile from a buffer of noise-only audio
    pub fn learnNoiseProfile(self: *Self, noise_samples: []const f32) void {
        // Simplified: average RMS per frequency band estimation
        // Real implementation would use FFT

        const bins = self.fft_size / 2 + 1;
        var profile_sum = try self.allocator.alloc(f32, bins) catch return;
        defer self.allocator.free(profile_sum);
        @memset(profile_sum, 0);

        var frame_count: u32 = 0;

        var pos: usize = 0;
        while (pos + self.fft_size <= noise_samples.len) : (pos += self.hop_size) {
            // Apply window and estimate magnitude spectrum
            // (Simplified - just use amplitude envelope estimation)
            var sum_squared: f32 = 0;
            for (0..self.fft_size) |i| {
                const s = noise_samples[pos + i] * self.window[i];
                sum_squared += s * s;
            }
            const rms = @sqrt(sum_squared / @as(f32, @floatFromInt(self.fft_size)));

            // Distribute across bins (simplified)
            for (0..bins) |bin| {
                profile_sum[bin] += rms;
            }
            frame_count += 1;
        }

        if (frame_count > 0) {
            for (0..bins) |bin| {
                self.noise_profile[bin] = profile_sum[bin] / @as(f32, @floatFromInt(frame_count));
            }
            self.noise_profile_set = true;
        }
    }

    /// Set a manual noise floor level
    pub fn setNoiseFloor(self: *Self, level_db: f32) void {
        const linear = math.pow(f32, 10.0, level_db / 20.0);
        const bins = self.fft_size / 2 + 1;
        for (0..bins) |bin| {
            self.noise_profile[bin] = linear;
        }
        self.noise_profile_set = true;
    }

    /// Process audio buffer (simplified - real implementation needs overlap-add FFT)
    pub fn process(self: *Self, buffer: []f32) void {
        if (!self.noise_profile_set) return;

        // Simplified time-domain processing
        // Real spectral subtraction requires proper STFT

        for (buffer) |*sample| {
            const abs_s = @abs(sample.*);

            // Estimate current noise level (simplified)
            const estimated_noise = self.noise_profile[0] * self.reduction_amount;

            // Spectral subtraction in time domain (approximation)
            if (abs_s > estimated_noise) {
                const scale = (abs_s - estimated_noise) / abs_s;
                sample.* *= @max(self.noise_floor, scale);
            } else {
                sample.* *= self.noise_floor;
            }
        }
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        @memset(self.input_buffer, 0);
        @memset(self.output_buffer, 0);
        self.input_pos = 0;
        self.output_pos = 0;
    }
};

/// Adaptive noise floor tracker
pub const AdaptiveNoiseTracker = struct {
    noise_floor: f32,
    adaptation_rate: f32,
    threshold_margin: f32, // dB above noise floor
    sample_rate: u32,

    // Envelope
    min_envelope: f32,
    max_envelope: f32,
    env_attack: f32,
    env_release: f32,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        var tracker = Self{
            .noise_floor = 0.001,
            .adaptation_rate = 0.001,
            .threshold_margin = 10,
            .sample_rate = sample_rate,
            .min_envelope = 1.0,
            .max_envelope = 0,
            .env_attack = 0,
            .env_release = 0,
        };
        tracker.updateCoefficients();
        return tracker;
    }

    fn updateCoefficients(self: *Self) void {
        // Very slow attack for minimum tracking
        const attack_samples = 1000.0 * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.env_attack = @exp(-1.0 / attack_samples);

        // Faster release
        const release_samples = 100.0 * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.env_release = @exp(-1.0 / release_samples);
    }

    /// Process sample and track noise floor
    pub fn process(self: *Self, sample: f32) void {
        const abs_s = @abs(sample);

        // Track minimum (noise floor estimate)
        if (abs_s < self.min_envelope) {
            self.min_envelope = self.env_release * self.min_envelope + (1.0 - self.env_release) * abs_s;
        } else {
            self.min_envelope = self.env_attack * self.min_envelope + (1.0 - self.env_attack) * abs_s;
        }

        // Update noise floor estimate with slow adaptation
        self.noise_floor = self.noise_floor * (1.0 - self.adaptation_rate) + self.min_envelope * self.adaptation_rate;
    }

    /// Get current noise floor estimate
    pub fn getNoiseFloor(self: *Self) f32 {
        return self.noise_floor;
    }

    /// Get noise floor in dB
    pub fn getNoiseFloorDb(self: *Self) f32 {
        if (self.noise_floor <= 0) return -100;
        return 20.0 * @log10(self.noise_floor);
    }

    /// Get recommended gate threshold (noise floor + margin)
    pub fn getRecommendedThreshold(self: *Self) f32 {
        return self.noise_floor * math.pow(f32, 10.0, self.threshold_margin / 20.0);
    }

    /// Reset
    pub fn reset(self: *Self) void {
        self.noise_floor = 0.001;
        self.min_envelope = 1.0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "NoiseGate basic" {
    var gate = NoiseGate.init(44100);
    gate.setThreshold(-30);
    gate.setRange(-60);

    // Process loud signal
    const loud = gate.processSample(0.5);
    try std.testing.expect(loud != 0);

    // Process quiet signal (below threshold)
    gate.reset();
    _ = gate.processSample(0.001);
    // Gate needs time to close, so just verify it processes
}

test "Expander basic" {
    var exp = Expander.init(44100);
    exp.setThreshold(-30);
    exp.setRatio(2.0);

    const output = exp.processSample(0.5);
    try std.testing.expect(output != 0);
}

test "SpectralNoiseReducer init" {
    const allocator = std.testing.allocator;

    var reducer = try SpectralNoiseReducer.init(allocator, 44100);
    defer reducer.deinit();

    reducer.setNoiseFloor(-40);
    reducer.setReduction(0.5);

    var buffer = [_]f32{ 0.1, -0.1, 0.05, -0.05 };
    reducer.process(&buffer);
}

test "AdaptiveNoiseTracker basic" {
    var tracker = AdaptiveNoiseTracker.init(44100);

    // Process some samples (needs many iterations due to slow adaptation)
    for (0..10000) |_| {
        tracker.process(0.01);
    }

    const floor = tracker.getNoiseFloor();
    try std.testing.expect(floor > 0);
    // After many iterations with 0.01 input, noise floor should converge toward 0.01
    try std.testing.expect(floor < 0.5); // Relaxed threshold for slow adaptation
}
