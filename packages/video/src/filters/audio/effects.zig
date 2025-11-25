// Home Video Library - Audio Effect Filters
// Volume, fade, crossfade, normalize, compression, EQ, reverb, echo

const std = @import("std");
const core = @import("../../core.zig");
const AudioFrame = core.AudioFrame;
const Duration = core.Duration;

/// Volume filter
pub const VolumeFilter = struct {
    volume: f32, // 0.0 - 2.0+ (0.0 = mute, 1.0 = unchanged, >1.0 = amplify)

    const Self = @This();

    pub fn init(volume: f32) Self {
        return .{ .volume = std.math.clamp(volume, 0.0, 10.0) };
    }

    pub fn apply(self: *Self, frame: *const AudioFrame, allocator: std.mem.Allocator) !*AudioFrame {
        const output = try allocator.create(AudioFrame);
        output.* = try frame.clone(allocator);

        for (0..frame.channels) |ch| {
            for (0..frame.sample_count) |i| {
                output.data[ch][i] = std.math.clamp(frame.data[ch][i] * self.volume, -1.0, 1.0);
            }
        }

        return output;
    }
};

/// Fade filter
pub const FadeFilter = struct {
    fade_in_duration: Duration = Duration.fromMicroseconds(0),
    fade_out_duration: Duration = Duration.fromMicroseconds(0),
    total_duration: Duration,
    curve: FadeCurve = .linear,

    const Self = @This();

    pub const FadeCurve = enum {
        linear,
        exponential,
        logarithmic,
        quarter_sine,
        half_sine,
    };

    pub fn init(fade_in: Duration, fade_out: Duration, total_duration: Duration, curve: FadeCurve) Self {
        return .{
            .fade_in_duration = fade_in,
            .fade_out_duration = fade_out,
            .total_duration = total_duration,
            .curve = curve,
        };
    }

    pub fn apply(self: *Self, frame: *const AudioFrame, timestamp: Duration, allocator: std.mem.Allocator) !*AudioFrame {
        var gain: f32 = 1.0;

        // Calculate fade in
        if (timestamp.toMicroseconds() < self.fade_in_duration.toMicroseconds()) {
            const progress = @as(f32, @floatFromInt(timestamp.toMicroseconds())) / @as(f32, @floatFromInt(self.fade_in_duration.toMicroseconds()));
            gain = self.applyCurve(progress);
        }

        // Calculate fade out
        const fade_out_start_us = self.total_duration.toMicroseconds() - self.fade_out_duration.toMicroseconds();
        if (timestamp.toMicroseconds() > fade_out_start_us) {
            const time_into_fadeout = timestamp.toMicroseconds() - fade_out_start_us;
            const progress = @as(f32, @floatFromInt(time_into_fadeout)) / @as(f32, @floatFromInt(self.fade_out_duration.toMicroseconds()));
            gain = self.applyCurve(1.0 - progress);
        }

        const output = try allocator.create(AudioFrame);
        output.* = try frame.clone(allocator);

        // Apply gain
        for (0..frame.channels) |ch| {
            for (0..frame.sample_count) |i| {
                output.data[ch][i] = frame.data[ch][i] * gain;
            }
        }

        return output;
    }

    fn applyCurve(self: *Self, progress: f32) f32 {
        return switch (self.curve) {
            .linear => progress,
            .exponential => progress * progress,
            .logarithmic => std.math.sqrt(progress),
            .quarter_sine => @sin(progress * std.math.pi / 2.0),
            .half_sine => (1.0 - @cos(progress * std.math.pi)) / 2.0,
        };
    }
};

/// Audio crossfade filter
pub const CrossfadeFilter = struct {
    duration: Duration,
    curve: FadeFilter.FadeCurve = .linear,

    const Self = @This();

    pub fn init(duration: Duration, curve: FadeFilter.FadeCurve) Self {
        return .{
            .duration = duration,
            .curve = curve,
        };
    }

    pub fn apply(self: *Self, frame1: *const AudioFrame, frame2: *const AudioFrame, progress: Duration, allocator: std.mem.Allocator) !*AudioFrame {
        if (frame1.sample_count != frame2.sample_count or frame1.channels != frame2.channels) {
            return error.IncompatibleFrames;
        }

        const ratio = std.math.clamp(
            @as(f32, @floatFromInt(progress.toMicroseconds())) / @as(f32, @floatFromInt(self.duration.toMicroseconds())),
            0.0,
            1.0,
        );

        const fade = FadeFilter{ .fade_in_duration = Duration.fromMicroseconds(0), .fade_out_duration = Duration.fromMicroseconds(0), .total_duration = Duration.fromMicroseconds(0), .curve = self.curve };
        const gain1 = fade.applyCurve(1.0 - ratio);
        const gain2 = fade.applyCurve(ratio);

        const output = try allocator.create(AudioFrame);
        output.* = try AudioFrame.init(allocator, frame1.sample_count, frame1.channels, frame1.sample_rate);

        for (0..frame1.channels) |ch| {
            for (0..frame1.sample_count) |i| {
                output.data[ch][i] = frame1.data[ch][i] * gain1 + frame2.data[ch][i] * gain2;
            }
        }

        output.pts = frame1.pts;
        return output;
    }
};

/// Audio normalizer
pub const NormalizeFilter = struct {
    target_level: f32 = 0.9, // Target peak level (0.0 - 1.0)
    analyze_mode: AnalyzeMode = .peak,

    const Self = @This();

    pub const AnalyzeMode = enum {
        peak, // Normalize to peak amplitude
        rms, // Normalize to RMS level
        loudness, // Normalize to perceived loudness (LUFS)
    };

    pub fn init(target_level: f32, mode: AnalyzeMode) Self {
        return .{
            .target_level = std.math.clamp(target_level, 0.0, 1.0),
            .analyze_mode = mode,
        };
    }

    pub fn apply(self: *Self, frame: *const AudioFrame, allocator: std.mem.Allocator) !*AudioFrame {
        const current_level = switch (self.analyze_mode) {
            .peak => self.calculatePeak(frame),
            .rms => self.calculateRMS(frame),
            .loudness => self.calculateRMS(frame), // Simplified, real LUFS is more complex
        };

        if (current_level < 0.0001) {
            // Silent frame, return clone
            const output = try allocator.create(AudioFrame);
            output.* = try frame.clone(allocator);
            return output;
        }

        const gain = self.target_level / current_level;

        const output = try allocator.create(AudioFrame);
        output.* = try frame.clone(allocator);

        for (0..frame.channels) |ch| {
            for (0..frame.sample_count) |i| {
                output.data[ch][i] = std.math.clamp(frame.data[ch][i] * gain, -1.0, 1.0);
            }
        }

        return output;
    }

    fn calculatePeak(self: *Self, frame: *const AudioFrame) f32 {
        _ = self;

        var peak: f32 = 0.0;

        for (0..frame.channels) |ch| {
            for (0..frame.sample_count) |i| {
                peak = @max(peak, @abs(frame.data[ch][i]));
            }
        }

        return peak;
    }

    fn calculateRMS(self: *Self, frame: *const AudioFrame) f32 {
        _ = self;

        var sum_squares: f32 = 0.0;
        var total_samples: usize = 0;

        for (0..frame.channels) |ch| {
            for (0..frame.sample_count) |i| {
                const sample = frame.data[ch][i];
                sum_squares += sample * sample;
                total_samples += 1;
            }
        }

        if (total_samples == 0) return 0.0;

        return std.math.sqrt(sum_squares / @as(f32, @floatFromInt(total_samples)));
    }
};

/// Dynamic range compressor
pub const CompressorFilter = struct {
    threshold: f32 = 0.5, // Threshold above which compression applies
    ratio: f32 = 4.0, // Compression ratio (e.g., 4:1)
    attack: f32 = 0.005, // Attack time in seconds
    release: f32 = 0.1, // Release time in seconds
    makeup_gain: f32 = 1.0,

    // State
    envelope: f32 = 0.0,
    sample_rate: u32,

    const Self = @This();

    pub fn init(sample_rate: u32, threshold: f32, ratio: f32, attack: f32, release: f32) Self {
        return .{
            .sample_rate = sample_rate,
            .threshold = std.math.clamp(threshold, 0.0, 1.0),
            .ratio = std.math.clamp(ratio, 1.0, 20.0),
            .attack = std.math.clamp(attack, 0.001, 1.0),
            .release = std.math.clamp(release, 0.01, 5.0),
        };
    }

    pub fn apply(self: *Self, frame: *const AudioFrame, allocator: std.mem.Allocator) !*AudioFrame {
        const output = try allocator.create(AudioFrame);
        output.* = try frame.clone(allocator);

        const attack_coef = @exp(-1.0 / (self.attack * @as(f32, @floatFromInt(self.sample_rate))));
        const release_coef = @exp(-1.0 / (self.release * @as(f32, @floatFromInt(self.sample_rate))));

        for (0..frame.sample_count) |i| {
            // Calculate envelope (peak across all channels)
            var peak: f32 = 0.0;
            for (0..frame.channels) |ch| {
                peak = @max(peak, @abs(frame.data[ch][i]));
            }

            // Smooth envelope follower
            if (peak > self.envelope) {
                self.envelope = attack_coef * self.envelope + (1.0 - attack_coef) * peak;
            } else {
                self.envelope = release_coef * self.envelope + (1.0 - release_coef) * peak;
            }

            // Calculate gain reduction
            var gain: f32 = 1.0;
            if (self.envelope > self.threshold) {
                const over = self.envelope / self.threshold;
                const compressed = std.math.pow(f32, over, 1.0 / self.ratio);
                gain = (self.threshold * compressed) / self.envelope;
            }

            // Apply makeup gain
            gain *= self.makeup_gain;

            // Apply to all channels
            for (0..frame.channels) |ch| {
                output.data[ch][i] = std.math.clamp(frame.data[ch][i] * gain, -1.0, 1.0);
            }
        }

        return output;
    }
};

/// Simple parametric EQ (single band)
pub const EQBand = struct {
    frequency: f32, // Center frequency in Hz
    gain: f32, // Gain in dB
    q: f32 = 1.0, // Q factor (bandwidth)
    filter_type: FilterType = .peak,

    // Filter coefficients
    a0: f32 = 1.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,

    // State per channel (for stereo, need 2)
    x1: [8]f32 = [_]f32{0.0} ** 8,
    x2: [8]f32 = [_]f32{0.0} ** 8,
    y1: [8]f32 = [_]f32{0.0} ** 8,
    y2: [8]f32 = [_]f32{0.0} ** 8,

    const Self = @This();

    pub const FilterType = enum {
        peak, // Peaking/bell
        low_shelf, // Low shelf
        high_shelf, // High shelf
        low_pass, // Low pass
        high_pass, // High pass
    };

    pub fn init(filter_type: FilterType, frequency: f32, gain: f32, q: f32, sample_rate: u32) Self {
        var band = Self{
            .filter_type = filter_type,
            .frequency = frequency,
            .gain = gain,
            .q = q,
        };

        band.calculateCoefficients(sample_rate);
        return band;
    }

    fn calculateCoefficients(self: *Self, sample_rate: u32) void {
        const w0 = 2.0 * std.math.pi * self.frequency / @as(f32, @floatFromInt(sample_rate));
        const cos_w0 = @cos(w0);
        const sin_w0 = @sin(w0);
        const alpha = sin_w0 / (2.0 * self.q);
        const A = std.math.pow(f32, 10.0, self.gain / 40.0);

        switch (self.filter_type) {
            .peak => {
                self.b0 = 1.0 + alpha * A;
                self.b1 = -2.0 * cos_w0;
                self.b2 = 1.0 - alpha * A;
                self.a0 = 1.0 + alpha / A;
                self.a1 = -2.0 * cos_w0;
                self.a2 = 1.0 - alpha / A;
            },
            .low_shelf => {
                const sqrt_A = std.math.sqrt(A);
                self.b0 = A * ((A + 1.0) - (A - 1.0) * cos_w0 + 2.0 * sqrt_A * alpha);
                self.b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cos_w0);
                self.b2 = A * ((A + 1.0) - (A - 1.0) * cos_w0 - 2.0 * sqrt_A * alpha);
                self.a0 = (A + 1.0) + (A - 1.0) * cos_w0 + 2.0 * sqrt_A * alpha;
                self.a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cos_w0);
                self.a2 = (A + 1.0) + (A - 1.0) * cos_w0 - 2.0 * sqrt_A * alpha;
            },
            .high_shelf => {
                const sqrt_A = std.math.sqrt(A);
                self.b0 = A * ((A + 1.0) + (A - 1.0) * cos_w0 + 2.0 * sqrt_A * alpha);
                self.b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cos_w0);
                self.b2 = A * ((A + 1.0) + (A - 1.0) * cos_w0 - 2.0 * sqrt_A * alpha);
                self.a0 = (A + 1.0) - (A - 1.0) * cos_w0 + 2.0 * sqrt_A * alpha;
                self.a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cos_w0);
                self.a2 = (A + 1.0) - (A - 1.0) * cos_w0 - 2.0 * sqrt_A * alpha;
            },
            .low_pass => {
                self.b0 = (1.0 - cos_w0) / 2.0;
                self.b1 = 1.0 - cos_w0;
                self.b2 = (1.0 - cos_w0) / 2.0;
                self.a0 = 1.0 + alpha;
                self.a1 = -2.0 * cos_w0;
                self.a2 = 1.0 - alpha;
            },
            .high_pass => {
                self.b0 = (1.0 + cos_w0) / 2.0;
                self.b1 = -(1.0 + cos_w0);
                self.b2 = (1.0 + cos_w0) / 2.0;
                self.a0 = 1.0 + alpha;
                self.a1 = -2.0 * cos_w0;
                self.a2 = 1.0 - alpha;
            },
        }

        // Normalize
        self.b0 /= self.a0;
        self.b1 /= self.a0;
        self.b2 /= self.a0;
        self.a1 /= self.a0;
        self.a2 /= self.a0;
        self.a0 = 1.0;
    }

    pub fn processSample(self: *Self, input: f32, channel: usize) f32 {
        const output = self.b0 * input + self.b1 * self.x1[channel] + self.b2 * self.x2[channel] - self.a1 * self.y1[channel] - self.a2 * self.y2[channel];

        self.x2[channel] = self.x1[channel];
        self.x1[channel] = input;
        self.y2[channel] = self.y1[channel];
        self.y1[channel] = output;

        return output;
    }
};

/// Multi-band parametric EQ
pub const EqualizerFilter = struct {
    bands: []EQBand,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .bands = &[_]EQBand{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bands);
    }

    pub fn addBand(self: *Self, band: EQBand) !void {
        const new_bands = try self.allocator.realloc(self.bands, self.bands.len + 1);
        new_bands[new_bands.len - 1] = band;
        self.bands = new_bands;
    }

    pub fn apply(self: *Self, frame: *const AudioFrame, allocator: std.mem.Allocator) !*AudioFrame {
        const output = try allocator.create(AudioFrame);
        output.* = try frame.clone(allocator);

        // Apply each band sequentially
        for (self.bands) |*band| {
            for (0..frame.channels) |ch| {
                for (0..frame.sample_count) |i| {
                    output.data[ch][i] = band.processSample(output.data[ch][i], ch);
                }
            }
        }

        return output;
    }
};

/// Simple delay/echo effect
pub const EchoFilter = struct {
    delay_time: Duration,
    feedback: f32 = 0.5, // 0.0 - 1.0
    mix: f32 = 0.5, // 0.0 = dry, 1.0 = wet
    delay_buffer: [][]f32,
    buffer_pos: usize = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, delay_time: Duration, feedback: f32, mix: f32, sample_rate: u32, channels: u16) !Self {
        const delay_samples = @as(usize, @intFromFloat(@as(f64, @floatFromInt(delay_time.toMicroseconds())) / 1_000_000.0 * @as(f64, @floatFromInt(sample_rate))));

        var delay_buffer = try allocator.alloc([]f32, channels);
        for (0..channels) |ch| {
            delay_buffer[ch] = try allocator.alloc(f32, delay_samples);
            @memset(delay_buffer[ch], 0.0);
        }

        return .{
            .allocator = allocator,
            .delay_time = delay_time,
            .feedback = std.math.clamp(feedback, 0.0, 0.99),
            .mix = std.math.clamp(mix, 0.0, 1.0),
            .delay_buffer = delay_buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.delay_buffer) |buf| {
            self.allocator.free(buf);
        }
        self.allocator.free(self.delay_buffer);
    }

    pub fn apply(self: *Self, frame: *const AudioFrame, allocator: std.mem.Allocator) !*AudioFrame {
        const output = try allocator.create(AudioFrame);
        output.* = try AudioFrame.init(allocator, frame.sample_count, frame.channels, frame.sample_rate);

        for (0..frame.channels) |ch| {
            for (0..frame.sample_count) |i| {
                const delayed = self.delay_buffer[ch][self.buffer_pos];
                const input = frame.data[ch][i];

                // Mix dry and wet
                output.data[ch][i] = input * (1.0 - self.mix) + delayed * self.mix;

                // Update delay buffer with feedback
                self.delay_buffer[ch][self.buffer_pos] = input + delayed * self.feedback;

                self.buffer_pos = (self.buffer_pos + 1) % self.delay_buffer[ch].len;
            }
        }

        output.pts = frame.pts;
        return output;
    }
};

/// Pan filter (stereo positioning)
pub const PanFilter = struct {
    pan: f32, // -1.0 = left, 0.0 = center, 1.0 = right

    const Self = @This();

    pub fn init(pan: f32) Self {
        return .{ .pan = std.math.clamp(pan, -1.0, 1.0) };
    }

    pub fn apply(self: *Self, frame: *const AudioFrame, allocator: std.mem.Allocator) !*AudioFrame {
        if (frame.channels != 2) {
            return error.RequiresStereo;
        }

        const output = try allocator.create(AudioFrame);
        output.* = try frame.clone(allocator);

        // Constant power panning
        const angle = (self.pan + 1.0) * std.math.pi / 4.0;
        const left_gain = @cos(angle);
        const right_gain = @sin(angle);

        for (0..frame.sample_count) |i| {
            const left = frame.data[0][i];
            const right = frame.data[1][i];

            output.data[0][i] = left * left_gain + right * (1.0 - right_gain);
            output.data[1][i] = right * right_gain + left * (1.0 - left_gain);
        }

        return output;
    }
};
