// Home Audio Library - Pitch Detection
// Algorithms for detecting fundamental frequency

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// Musical note representation
pub const Note = struct {
    /// MIDI note number (0-127)
    midi: u8,
    /// Cents deviation from perfect pitch (-50 to +50)
    cents: i8,
    /// Frequency in Hz
    frequency: f32,
    /// Confidence (0.0 to 1.0)
    confidence: f32,

    /// Note names
    const NOTE_NAMES = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

    /// Get note name
    pub fn getName(self: Note) []const u8 {
        return NOTE_NAMES[self.midi % 12];
    }

    /// Get octave number
    pub fn getOctave(self: Note) i8 {
        return @as(i8, @intCast(self.midi / 12)) - 1;
    }

    /// Create from frequency
    pub fn fromFrequency(freq: f32, confidence: f32) Note {
        if (freq <= 0) return .{ .midi = 0, .cents = 0, .frequency = 0, .confidence = 0 };

        // A4 = 440Hz = MIDI 69
        const midi_float = 69.0 + 12.0 * @log2(freq / 440.0);
        const midi_rounded = @round(midi_float);
        const cents: i8 = @intFromFloat((midi_float - midi_rounded) * 100.0);

        return .{
            .midi = @intFromFloat(@max(0, @min(127, midi_rounded))),
            .cents = cents,
            .frequency = freq,
            .confidence = confidence,
        };
    }

    /// Get frequency from MIDI note
    pub fn midiToFrequency(midi: u8) f32 {
        return 440.0 * math.pow(f32, 2.0, (@as(f32, @floatFromInt(midi)) - 69.0) / 12.0);
    }
};

/// Pitch detection algorithm
pub const PitchAlgorithm = enum {
    /// Autocorrelation (good for monophonic)
    autocorrelation,
    /// YIN algorithm (more accurate)
    yin,
    /// McLeod Pitch Method (better for music)
    mpm,
};

/// Pitch detector
pub const PitchDetector = struct {
    allocator: Allocator,
    sample_rate: u32,
    algorithm: PitchAlgorithm,
    min_freq: f32,
    max_freq: f32,

    // Working buffers
    buffer: []f32,
    autocorr: []f32,
    diff: []f32,

    // YIN threshold
    yin_threshold: f32,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        sample_rate: u32,
        buffer_size: usize,
        algorithm: PitchAlgorithm,
    ) !Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .algorithm = algorithm,
            .min_freq = 50, // ~G1
            .max_freq = 2000, // ~B6
            .buffer = try allocator.alloc(f32, buffer_size),
            .autocorr = try allocator.alloc(f32, buffer_size),
            .diff = try allocator.alloc(f32, buffer_size / 2),
            .yin_threshold = 0.1,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
        self.allocator.free(self.autocorr);
        self.allocator.free(self.diff);
    }

    /// Set frequency range
    pub fn setFrequencyRange(self: *Self, min_freq: f32, max_freq: f32) void {
        self.min_freq = min_freq;
        self.max_freq = max_freq;
    }

    /// Detect pitch from audio samples
    pub fn detect(self: *Self, samples: []const f32) Note {
        if (samples.len < self.buffer.len) {
            return Note.fromFrequency(0, 0);
        }

        // Copy to buffer
        @memcpy(self.buffer, samples[0..self.buffer.len]);

        // Apply selected algorithm
        const result = switch (self.algorithm) {
            .autocorrelation => self.detectAutocorrelation(),
            .yin => self.detectYin(),
            .mpm => self.detectMpm(),
        };

        return Note.fromFrequency(result.frequency, result.confidence);
    }

    const PitchResult = struct {
        frequency: f32,
        confidence: f32,
    };

    fn detectAutocorrelation(self: *Self) PitchResult {
        const n = self.buffer.len;
        const min_lag = self.sample_rate / @as(u32, @intFromFloat(self.max_freq));
        const max_lag = self.sample_rate / @as(u32, @intFromFloat(self.min_freq));

        // Compute autocorrelation
        for (0..n) |lag| {
            var sum: f32 = 0;
            for (0..n - lag) |i| {
                sum += self.buffer[i] * self.buffer[i + lag];
            }
            self.autocorr[lag] = sum;
        }

        // Find first peak after zero crossing
        var best_lag: usize = min_lag;
        var best_val: f32 = 0;

        var i: usize = min_lag;
        while (i < @min(max_lag, n / 2)) : (i += 1) {
            if (self.autocorr[i] > best_val and
                self.autocorr[i] > self.autocorr[i - 1] and
                self.autocorr[i] >= self.autocorr[i + 1])
            {
                best_val = self.autocorr[i];
                best_lag = i;
            }
        }

        // Parabolic interpolation
        const refined_lag = self.parabolicInterpolation(self.autocorr, best_lag);
        const frequency = @as(f32, @floatFromInt(self.sample_rate)) / refined_lag;
        const confidence = @min(1.0, best_val / self.autocorr[0]);

        return .{ .frequency = frequency, .confidence = confidence };
    }

    fn detectYin(self: *Self) PitchResult {
        const n = self.buffer.len / 2;
        const min_lag = self.sample_rate / @as(u32, @intFromFloat(self.max_freq));
        const max_lag = @min(self.sample_rate / @as(u32, @intFromFloat(self.min_freq)), @as(u32, @intCast(n)));

        // Step 1: Difference function
        for (0..n) |tau| {
            var sum: f32 = 0;
            for (0..n) |j| {
                const delta = self.buffer[j] - self.buffer[j + tau];
                sum += delta * delta;
            }
            self.diff[tau] = sum;
        }

        // Step 2: Cumulative mean normalized difference
        self.diff[0] = 1;
        var running_sum: f32 = 0;
        for (1..n) |tau| {
            running_sum += self.diff[tau];
            self.diff[tau] = self.diff[tau] * @as(f32, @floatFromInt(tau)) / running_sum;
        }

        // Step 3: Absolute threshold
        var best_tau: usize = min_lag;
        for (min_lag..max_lag) |tau| {
            if (self.diff[tau] < self.yin_threshold) {
                while (best_tau + 1 < max_lag and self.diff[best_tau + 1] < self.diff[best_tau]) {
                    best_tau += 1;
                }
                break;
            }
        }

        // Parabolic interpolation
        const refined_tau = self.parabolicInterpolation(self.diff, best_tau);
        const frequency = @as(f32, @floatFromInt(self.sample_rate)) / refined_tau;
        const confidence = 1.0 - self.diff[best_tau];

        return .{ .frequency = frequency, .confidence = @max(0, confidence) };
    }

    fn detectMpm(self: *Self) PitchResult {
        const n = self.buffer.len;

        // Normalized squared difference function
        for (0..n / 2) |tau| {
            var acf: f32 = 0;
            var energy_a: f32 = 0;
            var energy_b: f32 = 0;

            for (0..n / 2) |i| {
                acf += self.buffer[i] * self.buffer[i + tau];
                energy_a += self.buffer[i] * self.buffer[i];
                energy_b += self.buffer[i + tau] * self.buffer[i + tau];
            }

            if (energy_a * energy_b > 0) {
                self.autocorr[tau] = 2.0 * acf / (energy_a + energy_b);
            } else {
                self.autocorr[tau] = 0;
            }
        }

        // Find peaks
        const min_lag = self.sample_rate / @as(u32, @intFromFloat(self.max_freq));
        const max_lag = self.sample_rate / @as(u32, @intFromFloat(self.min_freq));

        var best_lag: usize = min_lag;
        var best_val: f32 = 0;

        var i: usize = min_lag + 1;
        while (i < @min(max_lag, n / 2 - 1)) : (i += 1) {
            // Peak detection
            if (self.autocorr[i] > self.autocorr[i - 1] and
                self.autocorr[i] >= self.autocorr[i + 1] and
                self.autocorr[i] > best_val and
                self.autocorr[i] > 0.5)
            {
                best_val = self.autocorr[i];
                best_lag = i;
            }
        }

        const refined_lag = self.parabolicInterpolation(self.autocorr, best_lag);
        const frequency = @as(f32, @floatFromInt(self.sample_rate)) / refined_lag;

        return .{ .frequency = frequency, .confidence = best_val };
    }

    fn parabolicInterpolation(self: *Self, data: []const f32, peak: usize) f32 {
        _ = self;
        if (peak == 0 or peak >= data.len - 1) {
            return @floatFromInt(peak);
        }

        const y0 = data[peak - 1];
        const y1 = data[peak];
        const y2 = data[peak + 1];

        const d = (y0 - y2) / (2.0 * (y0 - 2.0 * y1 + y2));
        return @as(f32, @floatFromInt(peak)) + d;
    }
};

/// Detect pitch from audio buffer (convenience function)
pub fn detectPitch(
    allocator: Allocator,
    samples: []const f32,
    sample_rate: u32,
    algorithm: PitchAlgorithm,
) !Note {
    const buffer_size = @min(samples.len, 4096);
    var detector = try PitchDetector.init(allocator, sample_rate, buffer_size, algorithm);
    defer detector.deinit();

    return detector.detect(samples);
}

/// Generate test tone at frequency
pub fn generateTestTone(allocator: Allocator, frequency: f32, sample_rate: u32, duration_samples: usize) ![]f32 {
    const samples = try allocator.alloc(f32, duration_samples);

    for (0..duration_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        samples[i] = @sin(2.0 * math.pi * frequency * t);
    }

    return samples;
}

// ============================================================================
// Tests
// ============================================================================

test "Note from frequency" {
    // A4 = 440Hz
    const a4 = Note.fromFrequency(440.0, 1.0);
    try std.testing.expectEqual(@as(u8, 69), a4.midi);
    try std.testing.expectEqualStrings("A", a4.getName());
    try std.testing.expectEqual(@as(i8, 4), a4.getOctave());

    // C4 = 261.63Hz
    const c4 = Note.fromFrequency(261.63, 1.0);
    try std.testing.expectEqual(@as(u8, 60), c4.midi);
    try std.testing.expectEqualStrings("C", c4.getName());
}

test "MIDI to frequency" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), Note.midiToFrequency(69), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), Note.midiToFrequency(60), 0.1);
}

test "Pitch detector init" {
    const allocator = std.testing.allocator;

    var detector = try PitchDetector.init(allocator, 44100, 2048, .yin);
    defer detector.deinit();

    try std.testing.expectEqual(@as(u32, 44100), detector.sample_rate);
}

test "Generate test tone" {
    const allocator = std.testing.allocator;

    const tone = try generateTestTone(allocator, 440.0, 44100, 4410);
    defer allocator.free(tone);

    try std.testing.expectEqual(@as(usize, 4410), tone.len);
}
