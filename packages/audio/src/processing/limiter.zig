// Home Audio Library - Limiter
// Brick-wall and Look-ahead Limiter implementations

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Limiter type
pub const LimiterType = enum {
    brickwall, // Hard clipping at threshold
    soft_knee, // Soft knee compression above threshold
    look_ahead, // Look-ahead limiting for true peak control
};

/// Simple Brick-wall Limiter
pub const BrickwallLimiter = struct {
    threshold: f32, // Threshold in linear scale
    threshold_db: f32,
    ceiling: f32, // Output ceiling
    release_time: f32, // Release time in ms
    sample_rate: u32,

    // State
    gain_reduction: f32,
    release_coeff: f32,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        var limiter = Self{
            .threshold = 1.0,
            .threshold_db = 0,
            .ceiling = 1.0,
            .release_time = 100,
            .sample_rate = sample_rate,
            .gain_reduction = 1.0,
            .release_coeff = 0,
        };
        limiter.updateCoefficients();
        return limiter;
    }

    fn updateCoefficients(self: *Self) void {
        // Release coefficient (exponential decay)
        const release_samples = self.release_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.release_coeff = @exp(-1.0 / release_samples);
    }

    /// Set threshold in dB
    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
        self.threshold = math.pow(f32, 10.0, db / 20.0);
    }

    /// Set ceiling in dB
    pub fn setCeiling(self: *Self, db: f32) void {
        self.ceiling = math.pow(f32, 10.0, db / 20.0);
    }

    /// Set release time in ms
    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_time = ms;
        self.updateCoefficients();
    }

    /// Process a single sample
    pub fn processSample(self: *Self, sample: f32) f32 {
        const abs_sample = @abs(sample);

        // Calculate required gain reduction
        if (abs_sample > self.threshold) {
            const required_gr = self.threshold / abs_sample;
            if (required_gr < self.gain_reduction) {
                self.gain_reduction = required_gr; // Instant attack
            }
        } else {
            // Release
            self.gain_reduction = self.release_coeff * self.gain_reduction + (1.0 - self.release_coeff);
        }

        return sample * self.gain_reduction * (self.ceiling / self.threshold);
    }

    /// Process buffer
    pub fn process(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.processSample(sample.*);
        }
    }

    /// Get current gain reduction in dB
    pub fn getGainReductionDb(self: *Self) f32 {
        if (self.gain_reduction <= 0) return -100;
        return 20.0 * @log10(self.gain_reduction);
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        self.gain_reduction = 1.0;
    }
};

/// Look-ahead Limiter with true peak detection
pub const LookAheadLimiter = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    // Parameters
    threshold: f32,
    threshold_db: f32,
    ceiling: f32,
    attack_time: f32, // ms
    release_time: f32, // ms
    look_ahead_ms: f32,

    // Coefficients
    attack_coeff: f32,
    release_coeff: f32,

    // State
    delay_buffer: []f32,
    delay_write_pos: usize,
    look_ahead_samples: usize,
    envelope: f32,
    gain_reduction: f32,

    // Peak detection buffer
    peak_buffer: []f32,
    peak_write_pos: usize,

    const Self = @This();

    pub const DEFAULT_LOOK_AHEAD_MS = 5.0;
    pub const MAX_LOOK_AHEAD_MS = 20.0;

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) !Self {
        const max_delay = @as(usize, @intFromFloat(MAX_LOOK_AHEAD_MS * @as(f32, @floatFromInt(sample_rate)) / 1000.0));
        const buffer_size = max_delay * channels;

        var limiter = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .threshold = 1.0,
            .threshold_db = 0,
            .ceiling = 1.0,
            .attack_time = DEFAULT_LOOK_AHEAD_MS,
            .release_time = 100,
            .look_ahead_ms = DEFAULT_LOOK_AHEAD_MS,
            .attack_coeff = 0,
            .release_coeff = 0,
            .delay_buffer = try allocator.alloc(f32, buffer_size),
            .delay_write_pos = 0,
            .look_ahead_samples = 0,
            .envelope = 0,
            .gain_reduction = 1.0,
            .peak_buffer = try allocator.alloc(f32, max_delay),
            .peak_write_pos = 0,
        };

        @memset(limiter.delay_buffer, 0);
        @memset(limiter.peak_buffer, 0);
        limiter.updateCoefficients();

        return limiter;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.delay_buffer);
        self.allocator.free(self.peak_buffer);
    }

    fn updateCoefficients(self: *Self) void {
        self.look_ahead_samples = @intFromFloat(self.look_ahead_ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0);

        // Attack matches look-ahead
        const attack_samples = self.attack_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.attack_coeff = @exp(-1.0 / attack_samples);

        const release_samples = self.release_time * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;
        self.release_coeff = @exp(-1.0 / release_samples);
    }

    /// Set threshold in dB
    pub fn setThreshold(self: *Self, db: f32) void {
        self.threshold_db = db;
        self.threshold = math.pow(f32, 10.0, db / 20.0);
    }

    /// Set ceiling in dB
    pub fn setCeiling(self: *Self, db: f32) void {
        self.ceiling = math.pow(f32, 10.0, db / 20.0);
    }

    /// Set attack time in ms
    pub fn setAttack(self: *Self, ms: f32) void {
        self.attack_time = ms;
        self.updateCoefficients();
    }

    /// Set release time in ms
    pub fn setRelease(self: *Self, ms: f32) void {
        self.release_time = ms;
        self.updateCoefficients();
    }

    /// Set look-ahead time in ms
    pub fn setLookAhead(self: *Self, ms: f32) void {
        self.look_ahead_ms = @min(ms, MAX_LOOK_AHEAD_MS);
        self.attack_time = self.look_ahead_ms;
        self.updateCoefficients();
    }

    /// Process stereo buffer
    pub fn process(self: *Self, buffer: []f32) void {
        const frame_count = buffer.len / self.channels;

        for (0..frame_count) |frame| {
            // Find peak across all channels for this frame
            var peak: f32 = 0;
            for (0..self.channels) |ch| {
                const idx = frame * self.channels + ch;
                peak = @max(peak, @abs(buffer[idx]));
            }

            // Store peak for look-ahead
            self.peak_buffer[self.peak_write_pos] = peak;
            self.peak_write_pos = (self.peak_write_pos + 1) % self.look_ahead_samples;

            // Find maximum in look-ahead window
            var max_peak: f32 = 0;
            for (0..self.look_ahead_samples) |i| {
                max_peak = @max(max_peak, self.peak_buffer[i]);
            }

            // Calculate target gain
            var target_gain: f32 = 1.0;
            if (max_peak > self.threshold) {
                target_gain = self.threshold / max_peak;
            }

            // Smooth gain reduction
            if (target_gain < self.gain_reduction) {
                self.gain_reduction = self.attack_coeff * self.gain_reduction + (1.0 - self.attack_coeff) * target_gain;
            } else {
                self.gain_reduction = self.release_coeff * self.gain_reduction + (1.0 - self.release_coeff) * target_gain;
            }

            // Apply gain to delayed signal
            const delay_read_pos = (self.delay_write_pos + self.delay_buffer.len - self.look_ahead_samples * self.channels) % self.delay_buffer.len;

            for (0..self.channels) |ch| {
                const in_idx = frame * self.channels + ch;
                const delay_read = (delay_read_pos + ch) % self.delay_buffer.len;
                const delay_write = (self.delay_write_pos + ch) % self.delay_buffer.len;

                // Store input in delay buffer
                self.delay_buffer[delay_write] = buffer[in_idx];

                // Read delayed and apply gain
                const delayed_sample = self.delay_buffer[delay_read];
                buffer[in_idx] = delayed_sample * self.gain_reduction * (self.ceiling / self.threshold);
            }

            self.delay_write_pos = (self.delay_write_pos + self.channels) % self.delay_buffer.len;
        }
    }

    /// Get current gain reduction in dB
    pub fn getGainReductionDb(self: *Self) f32 {
        if (self.gain_reduction <= 0) return -100;
        return 20.0 * @log10(self.gain_reduction);
    }

    /// Get latency in samples
    pub fn getLatency(self: *Self) usize {
        return self.look_ahead_samples;
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        @memset(self.delay_buffer, 0);
        @memset(self.peak_buffer, 0);
        self.delay_write_pos = 0;
        self.peak_write_pos = 0;
        self.envelope = 0;
        self.gain_reduction = 1.0;
    }
};

/// Soft Knee Limiter with adjustable knee width
pub const SoftKneeLimiter = struct {
    threshold: f32,
    threshold_db: f32,
    ceiling: f32,
    knee_width: f32, // dB
    ratio: f32,
    attack_time: f32,
    release_time: f32,
    sample_rate: u32,

    // Coefficients
    attack_coeff: f32,
    release_coeff: f32,

    // State
    envelope: f32,

    const Self = @This();

    pub fn init(sample_rate: u32) Self {
        var limiter = Self{
            .threshold = 1.0,
            .threshold_db = 0,
            .ceiling = 1.0,
            .knee_width = 6.0,
            .ratio = 100, // Very high ratio for limiting
            .attack_time = 0.1,
            .release_time = 100,
            .sample_rate = sample_rate,
            .attack_coeff = 0,
            .release_coeff = 0,
            .envelope = 0,
        };
        limiter.updateCoefficients();
        return limiter;
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

    /// Set ceiling in dB
    pub fn setCeiling(self: *Self, db: f32) void {
        self.ceiling = math.pow(f32, 10.0, db / 20.0);
    }

    /// Set knee width in dB
    pub fn setKneeWidth(self: *Self, db: f32) void {
        self.knee_width = @max(0, db);
    }

    /// Calculate soft knee gain reduction
    fn computeGain(self: *Self, input_db: f32) f32 {
        const knee_start = self.threshold_db - self.knee_width / 2;
        const knee_end = self.threshold_db + self.knee_width / 2;

        var output_db: f32 = undefined;

        if (input_db <= knee_start) {
            // Below knee
            output_db = input_db;
        } else if (input_db >= knee_end) {
            // Above knee (full compression)
            output_db = self.threshold_db + (input_db - self.threshold_db) / self.ratio;
        } else {
            // In knee region (interpolate)
            const knee_pos = (input_db - knee_start) / self.knee_width;
            const knee_curve = knee_pos * knee_pos;
            const compressed = self.threshold_db + (input_db - self.threshold_db) / self.ratio;
            output_db = input_db + (compressed - input_db) * knee_curve;
        }

        return output_db - input_db;
    }

    /// Process a single sample
    pub fn processSample(self: *Self, sample: f32) f32 {
        const abs_sample = @abs(sample);
        _ = if (abs_sample > 0.000001) 20.0 * @log10(abs_sample) else -120; // input_db for debugging

        // Envelope follower
        if (abs_sample > self.envelope) {
            self.envelope = self.attack_coeff * self.envelope + (1.0 - self.attack_coeff) * abs_sample;
        } else {
            self.envelope = self.release_coeff * self.envelope + (1.0 - self.release_coeff) * abs_sample;
        }

        const envelope_db: f32 = if (self.envelope > 0.000001) 20.0 * @log10(self.envelope) else -120;
        const gain_db = self.computeGain(envelope_db);
        const gain = math.pow(f32, 10.0, gain_db / 20.0);

        return sample * gain * (self.ceiling / self.threshold);
    }

    /// Process buffer
    pub fn process(self: *Self, buffer: []f32) void {
        for (buffer) |*sample| {
            sample.* = self.processSample(sample.*);
        }
    }

    /// Reset state
    pub fn reset(self: *Self) void {
        self.envelope = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BrickwallLimiter basic" {
    var limiter = BrickwallLimiter.init(44100);
    limiter.setThreshold(-3);

    const input: f32 = 1.5; // Above threshold
    const output = limiter.processSample(input);
    try std.testing.expect(@abs(output) <= 1.0);
}

test "LookAheadLimiter init" {
    const allocator = std.testing.allocator;

    var limiter = try LookAheadLimiter.init(allocator, 44100, 2);
    defer limiter.deinit();

    limiter.setThreshold(-1);
    try std.testing.expect(limiter.getLatency() > 0);
}

test "LookAheadLimiter process" {
    const allocator = std.testing.allocator;

    var limiter = try LookAheadLimiter.init(allocator, 44100, 1);
    defer limiter.deinit();

    limiter.setThreshold(-6);

    // Process some samples to fill delay buffer
    var buffer: [256]f32 = undefined;
    for (&buffer) |*s| {
        s.* = 1.0; // Hot signal
    }

    limiter.process(&buffer);
    // After look-ahead is filled, output should be limited
}

test "SoftKneeLimiter basic" {
    var limiter = SoftKneeLimiter.init(44100);
    limiter.setThreshold(-6);
    limiter.setKneeWidth(6);

    const output = limiter.processSample(1.0);
    try std.testing.expect(output != 0);
}
