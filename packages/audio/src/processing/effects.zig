// Home Audio Library - Audio Effects
// Common audio processing effects

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// ============================================================================
// Filters
// ============================================================================

/// Biquad filter types
pub const FilterType = enum {
    lowpass,
    highpass,
    bandpass,
    notch,
    peak,
    lowshelf,
    highshelf,
};

/// Biquad filter (second-order IIR filter)
pub const BiquadFilter = struct {
    // Coefficients
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,

    // State
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,

    const Self = @This();

    /// Create a lowpass filter
    pub fn lowpass(sample_rate: f32, cutoff: f32, q: f32) Self {
        const w0 = 2.0 * math.pi * cutoff / sample_rate;
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * q);

        const a0 = 1.0 + alpha;
        return Self{
            .b0 = ((1.0 - cos_w0) / 2.0) / a0,
            .b1 = (1.0 - cos_w0) / a0,
            .b2 = ((1.0 - cos_w0) / 2.0) / a0,
            .a1 = (-2.0 * cos_w0) / a0,
            .a2 = (1.0 - alpha) / a0,
            .x1 = 0,
            .x2 = 0,
            .y1 = 0,
            .y2 = 0,
        };
    }

    /// Create a highpass filter
    pub fn highpass(sample_rate: f32, cutoff: f32, q: f32) Self {
        const w0 = 2.0 * math.pi * cutoff / sample_rate;
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * q);

        const a0 = 1.0 + alpha;
        return Self{
            .b0 = ((1.0 + cos_w0) / 2.0) / a0,
            .b1 = (-(1.0 + cos_w0)) / a0,
            .b2 = ((1.0 + cos_w0) / 2.0) / a0,
            .a1 = (-2.0 * cos_w0) / a0,
            .a2 = (1.0 - alpha) / a0,
            .x1 = 0,
            .x2 = 0,
            .y1 = 0,
            .y2 = 0,
        };
    }

    /// Create a bandpass filter
    pub fn bandpass(sample_rate: f32, center: f32, q: f32) Self {
        const w0 = 2.0 * math.pi * center / sample_rate;
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * q);

        const a0 = 1.0 + alpha;
        return Self{
            .b0 = (sin_w0 / 2.0) / a0,
            .b1 = 0,
            .b2 = (-sin_w0 / 2.0) / a0,
            .a1 = (-2.0 * cos_w0) / a0,
            .a2 = (1.0 - alpha) / a0,
            .x1 = 0,
            .x2 = 0,
            .y1 = 0,
            .y2 = 0,
        };
    }

    /// Create a peak/parametric EQ filter
    pub fn peak(sample_rate: f32, center: f32, q: f32, gain_db: f32) Self {
        const A = math.pow(f32, 10.0, gain_db / 40.0);
        const w0 = 2.0 * math.pi * center / sample_rate;
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * q);

        const a0 = 1.0 + alpha / A;
        return Self{
            .b0 = (1.0 + alpha * A) / a0,
            .b1 = (-2.0 * cos_w0) / a0,
            .b2 = (1.0 - alpha * A) / a0,
            .a1 = (-2.0 * cos_w0) / a0,
            .a2 = (1.0 - alpha / A) / a0,
            .x1 = 0,
            .x2 = 0,
            .y1 = 0,
            .y2 = 0,
        };
    }

    /// Process a single sample
    pub fn process(self: *Self, x: f32) f32 {
        const y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 -
            self.a1 * self.y1 - self.a2 * self.y2;

        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;

        return y;
    }

    /// Process a buffer of samples in-place
    pub fn processBuffer(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }

    /// Reset filter state
    pub fn reset(self: *Self) void {
        self.x1 = 0;
        self.x2 = 0;
        self.y1 = 0;
        self.y2 = 0;
    }
};

// ============================================================================
// Dynamics
// ============================================================================

/// Compressor/limiter
pub const Compressor = struct {
    sample_rate: f32,
    threshold: f32, // dB
    ratio: f32, // compression ratio (e.g., 4.0 for 4:1)
    attack: f32, // attack time in seconds
    release: f32, // release time in seconds
    makeup_gain: f32, // dB

    // State
    envelope: f32,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        return Self{
            .sample_rate = sample_rate,
            .threshold = -20.0,
            .ratio = 4.0,
            .attack = 0.01,
            .release = 0.1,
            .makeup_gain = 0.0,
            .envelope = 0,
        };
    }

    pub fn setThreshold(self: *Self, threshold_db: f32) void {
        self.threshold = threshold_db;
    }

    pub fn setRatio(self: *Self, ratio: f32) void {
        self.ratio = @max(1.0, ratio);
    }

    pub fn setAttack(self: *Self, attack_ms: f32) void {
        self.attack = attack_ms / 1000.0;
    }

    pub fn setRelease(self: *Self, release_ms: f32) void {
        self.release = release_ms / 1000.0;
    }

    pub fn setMakeupGain(self: *Self, gain_db: f32) void {
        self.makeup_gain = gain_db;
    }

    /// Process a single sample
    pub fn process(self: *Self, input: f32) f32 {
        // Get input level in dB
        const input_level = @max(0.00001, @abs(input));
        const input_db = 20.0 * @log10(input_level);

        // Calculate gain reduction
        var gain_db: f32 = 0;
        if (input_db > self.threshold) {
            const over_db = input_db - self.threshold;
            gain_db = over_db * (1.0 - 1.0 / self.ratio);
        }

        // Apply envelope
        const attack_coef = @exp(-1.0 / (self.attack * self.sample_rate));
        const release_coef = @exp(-1.0 / (self.release * self.sample_rate));

        if (gain_db > self.envelope) {
            self.envelope = attack_coef * self.envelope + (1.0 - attack_coef) * gain_db;
        } else {
            self.envelope = release_coef * self.envelope + (1.0 - release_coef) * gain_db;
        }

        // Apply gain reduction and makeup
        const total_gain = -self.envelope + self.makeup_gain;
        const linear_gain = math.pow(f32, 10.0, total_gain / 20.0);

        return input * linear_gain;
    }

    /// Process buffer in-place
    pub fn processBuffer(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }

    /// Create a limiter (compressor with high ratio)
    pub fn limiter(sample_rate: f32, threshold_db: f32) Self {
        var comp = Self.init(sample_rate);
        comp.threshold = threshold_db;
        comp.ratio = 100.0; // Very high ratio for limiting
        comp.attack = 0.001; // Fast attack
        comp.release = 0.05; // Quick release
        return comp;
    }
};

/// Noise gate
pub const NoiseGate = struct {
    sample_rate: f32,
    threshold: f32, // dB
    attack: f32, // seconds
    hold: f32, // seconds
    release: f32, // seconds
    range: f32, // dB reduction when gate is closed

    // State
    envelope: f32,
    hold_counter: f32,
    gate_open: bool,

    const Self = @This();

    pub fn init(sample_rate: f32) Self {
        return Self{
            .sample_rate = sample_rate,
            .threshold = -40.0,
            .attack = 0.001,
            .hold = 0.01,
            .release = 0.1,
            .range = -80.0,
            .envelope = 0,
            .hold_counter = 0,
            .gate_open = false,
        };
    }

    pub fn process(self: *Self, input: f32) f32 {
        const input_level = @abs(input);
        const input_db = 20.0 * @log10(@max(0.00001, input_level));

        // Gate logic
        if (input_db > self.threshold) {
            self.gate_open = true;
            self.hold_counter = self.hold * self.sample_rate;
        } else if (self.hold_counter > 0) {
            self.hold_counter -= 1;
        } else {
            self.gate_open = false;
        }

        // Envelope follower
        const target = if (self.gate_open) @as(f32, 0.0) else self.range;
        const coef = if (self.gate_open)
            @exp(-1.0 / (self.attack * self.sample_rate))
        else
            @exp(-1.0 / (self.release * self.sample_rate));

        self.envelope = coef * self.envelope + (1.0 - coef) * target;

        // Apply gain
        const linear_gain = math.pow(f32, 10.0, self.envelope / 20.0);
        return input * linear_gain;
    }

    pub fn processBuffer(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// ============================================================================
// Delay Effects
// ============================================================================

/// Simple delay effect
pub const Delay = struct {
    allocator: Allocator,
    buffer: []f32,
    write_pos: usize,
    delay_samples: usize,
    feedback: f32,
    mix: f32,

    const Self = @This();

    pub fn init(allocator: Allocator, max_delay_samples: usize) !Self {
        const buffer = try allocator.alloc(f32, max_delay_samples);
        @memset(buffer, 0);

        return Self{
            .allocator = allocator,
            .buffer = buffer,
            .write_pos = 0,
            .delay_samples = max_delay_samples / 2,
            .feedback = 0.5,
            .mix = 0.5,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    pub fn setDelay(self: *Self, samples: usize) void {
        self.delay_samples = @min(samples, self.buffer.len - 1);
    }

    pub fn setDelayMs(self: *Self, ms: f32, sample_rate: f32) void {
        const samples = @as(usize, @intFromFloat(ms * sample_rate / 1000.0));
        self.setDelay(samples);
    }

    pub fn setFeedback(self: *Self, feedback: f32) void {
        self.feedback = math.clamp(feedback, 0.0, 0.99);
    }

    pub fn setMix(self: *Self, mix: f32) void {
        self.mix = math.clamp(mix, 0.0, 1.0);
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Read from delay buffer
        var read_pos = self.write_pos + self.buffer.len - self.delay_samples;
        if (read_pos >= self.buffer.len) read_pos -= self.buffer.len;

        const delayed = self.buffer[read_pos];

        // Write to delay buffer (input + feedback)
        self.buffer[self.write_pos] = input + delayed * self.feedback;

        // Advance write position
        self.write_pos += 1;
        if (self.write_pos >= self.buffer.len) self.write_pos = 0;

        // Mix dry/wet
        return input * (1.0 - self.mix) + delayed * self.mix;
    }

    pub fn processBuffer(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }

    pub fn clear(self: *Self) void {
        @memset(self.buffer, 0);
    }
};

// ============================================================================
// Modulation Effects
// ============================================================================

/// LFO (Low Frequency Oscillator) for modulation
pub const LFO = struct {
    phase: f32,
    frequency: f32,
    sample_rate: f32,
    waveform: Waveform,

    pub const Waveform = enum {
        sine,
        triangle,
        square,
        sawtooth,
    };

    const Self = @This();

    pub fn init(sample_rate: f32, frequency: f32) Self {
        return Self{
            .phase = 0,
            .frequency = frequency,
            .sample_rate = sample_rate,
            .waveform = .sine,
        };
    }

    pub fn tick(self: *Self) f32 {
        const output = self.getValue();

        self.phase += self.frequency / self.sample_rate;
        if (self.phase >= 1.0) self.phase -= 1.0;

        return output;
    }

    pub fn getValue(self: *const Self) f32 {
        return switch (self.waveform) {
            .sine => @sin(self.phase * 2.0 * math.pi),
            .triangle => 1.0 - 4.0 * @abs(self.phase - 0.5),
            .square => if (self.phase < 0.5) @as(f32, 1.0) else @as(f32, -1.0),
            .sawtooth => 2.0 * self.phase - 1.0,
        };
    }
};

/// Chorus effect
pub const Chorus = struct {
    allocator: Allocator,
    buffer: []f32,
    write_pos: usize,
    lfo: LFO,
    base_delay: f32,
    depth: f32,
    mix: f32,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: f32) !Self {
        // Buffer for up to 50ms delay
        const buffer_size = @as(usize, @intFromFloat(sample_rate * 0.05));
        const buffer = try allocator.alloc(f32, buffer_size);
        @memset(buffer, 0);

        return Self{
            .allocator = allocator,
            .buffer = buffer,
            .write_pos = 0,
            .lfo = LFO.init(sample_rate, 1.0),
            .base_delay = 0.02 * sample_rate, // 20ms
            .depth = 0.002 * sample_rate, // 2ms modulation depth
            .mix = 0.5,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    pub fn setRate(self: *Self, rate_hz: f32) void {
        self.lfo.frequency = rate_hz;
    }

    pub fn setDepth(self: *Self, depth_ms: f32, sample_rate: f32) void {
        self.depth = depth_ms * sample_rate / 1000.0;
    }

    pub fn process(self: *Self, input: f32) f32 {
        // Calculate modulated delay
        const mod = self.lfo.tick();
        const delay = self.base_delay + mod * self.depth;
        const delay_int = @as(usize, @intFromFloat(delay));
        const delay_frac = delay - @as(f32, @floatFromInt(delay_int));

        // Read from buffer with linear interpolation
        var read_pos = self.write_pos + self.buffer.len - delay_int;
        if (read_pos >= self.buffer.len) read_pos -= self.buffer.len;

        var read_pos_next = read_pos + self.buffer.len - 1;
        if (read_pos_next >= self.buffer.len) read_pos_next -= self.buffer.len;

        const delayed = self.buffer[read_pos] * (1.0 - delay_frac) +
            self.buffer[read_pos_next] * delay_frac;

        // Write to buffer
        self.buffer[self.write_pos] = input;
        self.write_pos += 1;
        if (self.write_pos >= self.buffer.len) self.write_pos = 0;

        return input * (1.0 - self.mix) + delayed * self.mix;
    }

    pub fn processBuffer(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.process(sample.*);
        }
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Convert dB to linear gain
pub fn dbToLinear(db: f32) f32 {
    return math.pow(f32, 10.0, db / 20.0);
}

/// Convert linear gain to dB
pub fn linearToDb(linear: f32) f32 {
    return 20.0 * @log10(@max(0.00001, linear));
}

/// Fade in audio
pub fn fadeIn(buffer: []f32, curve: FadeCurve) void {
    for (buffer, 0..) |*sample, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(buffer.len));
        sample.* *= curve.getValue(t);
    }
}

/// Fade out audio
pub fn fadeOut(buffer: []f32, curve: FadeCurve) void {
    for (buffer, 0..) |*sample, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(buffer.len));
        sample.* *= curve.getValue(1.0 - t);
    }
}

/// Fade curve types
pub const FadeCurve = enum {
    linear,
    exponential,
    logarithmic,
    s_curve,

    pub fn getValue(self: FadeCurve, t: f32) f32 {
        return switch (self) {
            .linear => t,
            .exponential => t * t,
            .logarithmic => @sqrt(t),
            .s_curve => t * t * (3.0 - 2.0 * t),
        };
    }
};

/// DC offset removal filter
pub fn removeDcOffset(buffer: []f32, alpha: f32) void {
    var prev_x: f32 = 0;
    var prev_y: f32 = 0;

    for (buffer) |*sample| {
        const x = sample.*;
        const y = x - prev_x + alpha * prev_y;
        prev_x = x;
        prev_y = y;
        sample.* = y;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "BiquadFilter lowpass" {
    var filter = BiquadFilter.lowpass(44100, 1000, 0.707);

    // Process some samples
    const output = filter.process(1.0);
    try std.testing.expect(output != 0);

    // Reset and verify
    filter.reset();
    try std.testing.expectEqual(@as(f32, 0), filter.x1);
    try std.testing.expectEqual(@as(f32, 0), filter.y1);
}

test "Compressor init" {
    var comp = Compressor.init(44100);

    comp.setThreshold(-10.0);
    try std.testing.expectEqual(@as(f32, -10.0), comp.threshold);

    comp.setRatio(8.0);
    try std.testing.expectEqual(@as(f32, 8.0), comp.ratio);
}

test "Delay" {
    const allocator = std.testing.allocator;

    var delay = try Delay.init(allocator, 1000);
    defer delay.deinit();

    delay.setDelay(100);
    delay.setFeedback(0.5);

    // Process input
    _ = delay.process(1.0);

    // Clear buffer
    delay.clear();
}

test "LFO" {
    var lfo = LFO.init(44100, 1.0);

    // Tick through a full cycle
    for (0..44100) |_| {
        const val = lfo.tick();
        try std.testing.expect(val >= -1.0 and val <= 1.0);
    }
}

test "dbToLinear and linearToDb" {
    // 0 dB = 1.0 linear
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dbToLinear(0), 0.001);

    // -20 dB = 0.1 linear
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), dbToLinear(-20), 0.001);

    // Round trip
    const db: f32 = -12.0;
    try std.testing.expectApproxEqAbs(db, linearToDb(dbToLinear(db)), 0.001);
}

test "FadeCurve" {
    try std.testing.expectEqual(@as(f32, 0.0), FadeCurve.linear.getValue(0.0));
    try std.testing.expectEqual(@as(f32, 0.5), FadeCurve.linear.getValue(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), FadeCurve.linear.getValue(1.0));
}
