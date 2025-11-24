// Home Audio Library - Beat/Tempo Detection
// Onset detection and BPM estimation

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Beat detection result
pub const BeatInfo = struct {
    bpm: f32,
    confidence: f32, // 0.0 - 1.0
    beat_positions: []f64, // In seconds
    first_beat: f64, // First beat position in seconds
    beat_interval: f64, // Seconds between beats
};

/// Onset type
pub const OnsetType = enum {
    energy, // Simple energy-based
    spectral_flux, // Spectral flux
    complex_domain, // Complex domain deviation
};

/// Onset detector
pub const OnsetDetector = struct {
    allocator: Allocator,
    sample_rate: u32,
    hop_size: usize,
    onset_type: OnsetType,

    // Parameters
    threshold: f32,
    min_interval_ms: f32, // Minimum time between onsets

    // State
    prev_energy: f32,
    prev_flux: f32,
    samples_since_onset: usize,
    min_interval_samples: usize,

    // Onset buffer
    onsets: std.ArrayList(f64),

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32) !Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .hop_size = 512,
            .onset_type = .energy,
            .threshold = 1.5,
            .min_interval_ms = 50,
            .prev_energy = 0,
            .prev_flux = 0,
            .samples_since_onset = 0,
            .min_interval_samples = @intFromFloat(50.0 * @as(f32, @floatFromInt(sample_rate)) / 1000.0),
            .onsets = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.onsets.deinit(self.allocator);
    }

    /// Set detection threshold (multiplier above average)
    pub fn setThreshold(self: *Self, threshold: f32) void {
        self.threshold = @max(1.0, threshold);
    }

    /// Set minimum interval between onsets in ms
    pub fn setMinInterval(self: *Self, ms: f32) void {
        self.min_interval_ms = ms;
        self.min_interval_samples = @intFromFloat(ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0);
    }

    /// Process a frame of audio
    pub fn processFrame(self: *Self, frame: []const f32, position_samples: usize) !bool {
        // Calculate detection function
        const df = switch (self.onset_type) {
            .energy => self.energyDF(frame),
            .spectral_flux => self.spectralFluxDF(frame),
            .complex_domain => self.energyDF(frame), // Fallback to energy
        };

        var is_onset = false;

        // Check for onset
        if (self.samples_since_onset >= self.min_interval_samples) {
            if (df > self.prev_energy * self.threshold and df > 0.01) {
                is_onset = true;
                self.samples_since_onset = 0;

                // Record onset time
                const time = @as(f64, @floatFromInt(position_samples)) / @as(f64, @floatFromInt(self.sample_rate));
                try self.onsets.append(self.allocator, time);
            }
        }

        self.prev_energy = self.prev_energy * 0.9 + df * 0.1; // Smoothed average
        self.prev_flux = df;
        self.samples_since_onset += frame.len;

        return is_onset;
    }

    /// Energy-based detection function
    fn energyDF(self: *Self, frame: []const f32) f32 {
        _ = self;
        var energy: f32 = 0;
        for (frame) |s| {
            energy += s * s;
        }
        return energy / @as(f32, @floatFromInt(frame.len));
    }

    /// Spectral flux detection function (simplified)
    fn spectralFluxDF(self: *Self, frame: []const f32) f32 {
        // Simplified: use energy difference as proxy for spectral flux
        const energy = self.energyDF(frame);
        const flux = @max(0, energy - self.prev_flux);
        return flux;
    }

    /// Get detected onset times
    pub fn getOnsets(self: *Self) []const f64 {
        return self.onsets.items;
    }

    /// Clear detected onsets
    pub fn clear(self: *Self) void {
        self.onsets.clearRetainingCapacity();
        self.prev_energy = 0;
        self.prev_flux = 0;
        self.samples_since_onset = self.min_interval_samples;
    }
};

/// Tempo/BPM estimator
pub const TempoEstimator = struct {
    allocator: Allocator,
    sample_rate: u32,

    // BPM range
    min_bpm: f32,
    max_bpm: f32,

    // Analysis results
    estimated_bpm: f32,
    confidence: f32,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32) Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .min_bpm = 60,
            .max_bpm = 200,
            .estimated_bpm = 0,
            .confidence = 0,
        };
    }

    /// Set BPM search range
    pub fn setBPMRange(self: *Self, min: f32, max: f32) void {
        self.min_bpm = @max(30, min);
        self.max_bpm = @min(300, max);
    }

    /// Estimate tempo from onset times
    pub fn estimateFromOnsets(self: *Self, onsets: []const f64) void {
        if (onsets.len < 4) {
            self.estimated_bpm = 0;
            self.confidence = 0;
            return;
        }

        // Calculate inter-onset intervals
        var intervals = self.allocator.alloc(f64, onsets.len - 1) catch return;
        defer self.allocator.free(intervals);

        for (0..onsets.len - 1) |i| {
            intervals[i] = onsets[i + 1] - onsets[i];
        }

        // Convert BPM range to interval range (in seconds)
        const min_interval = 60.0 / @as(f64, self.max_bpm);
        const max_interval = 60.0 / @as(f64, self.min_bpm);

        // Histogram-based tempo estimation
        const num_bins = 100;
        var histogram = [_]u32{0} ** num_bins;

        for (intervals) |interval| {
            // Try different multiples (half-time, normal, double-time)
            const multiples = [_]f64{ 0.5, 1.0, 2.0 };
            for (multiples) |mult| {
                const adj_interval = interval * mult;
                if (adj_interval >= min_interval and adj_interval <= max_interval) {
                    const bin_f = (adj_interval - min_interval) / (max_interval - min_interval) * @as(f64, num_bins - 1);
                    const bin = @as(usize, @intFromFloat(@min(@max(bin_f, 0), num_bins - 1)));
                    histogram[bin] += 1;
                }
            }
        }

        // Find peak in histogram
        var max_count: u32 = 0;
        var peak_bin: usize = 0;
        for (histogram, 0..) |count, i| {
            if (count > max_count) {
                max_count = count;
                peak_bin = i;
            }
        }

        // Convert peak bin back to BPM
        const peak_interval = min_interval + @as(f64, @floatFromInt(peak_bin)) / @as(f64, num_bins - 1) * (max_interval - min_interval);
        self.estimated_bpm = @floatCast(60.0 / peak_interval);

        // Calculate confidence based on histogram peak strength
        var total: u32 = 0;
        for (histogram) |count| {
            total += count;
        }
        self.confidence = if (total > 0) @as(f32, @floatFromInt(max_count)) / @as(f32, @floatFromInt(total)) * 3.0 else 0;
        self.confidence = @min(1.0, self.confidence);
    }

    /// Estimate tempo from audio directly
    pub fn estimateFromAudio(self: *Self, samples: []const f32, channels: u8) !void {
        // Create onset detector
        var detector = try OnsetDetector.init(self.allocator, self.sample_rate);
        defer detector.deinit();

        // Mix to mono if stereo
        var mono: []f32 = undefined;
        var allocated_mono = false;

        if (channels == 1) {
            mono = @constCast(samples);
        } else {
            mono = try self.allocator.alloc(f32, samples.len / channels);
            allocated_mono = true;

            for (0..mono.len) |i| {
                var sum: f32 = 0;
                for (0..channels) |ch| {
                    sum += samples[i * channels + ch];
                }
                mono[i] = sum / @as(f32, @floatFromInt(channels));
            }
        }
        defer if (allocated_mono) self.allocator.free(mono);

        // Process in frames
        const frame_size: usize = 1024;
        var pos: usize = 0;
        while (pos + frame_size <= mono.len) : (pos += frame_size) {
            _ = try detector.processFrame(mono[pos .. pos + frame_size], pos);
        }

        // Estimate tempo from detected onsets
        self.estimateFromOnsets(detector.getOnsets());
    }

    /// Get estimated BPM
    pub fn getBPM(self: *Self) f32 {
        return self.estimated_bpm;
    }

    /// Get confidence (0-1)
    pub fn getConfidence(self: *Self) f32 {
        return self.confidence;
    }
};

/// Beat tracker for real-time beat tracking
pub const BeatTracker = struct {
    allocator: Allocator,
    sample_rate: u32,

    // Tempo
    current_bpm: f32,
    beat_interval_samples: f64,

    // Phase
    phase: f64, // 0.0 - 1.0, where 1.0 = beat
    last_beat_sample: i64,

    // Adaptation
    adaptation_rate: f32,

    // Onset detector for adaptation
    onset_detector: OnsetDetector,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, initial_bpm: f32) !Self {
        const beat_interval = @as(f64, @floatFromInt(sample_rate)) * 60.0 / @as(f64, initial_bpm);

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .current_bpm = initial_bpm,
            .beat_interval_samples = beat_interval,
            .phase = 0,
            .last_beat_sample = 0,
            .adaptation_rate = 0.1,
            .onset_detector = try OnsetDetector.init(allocator, sample_rate),
        };
    }

    pub fn deinit(self: *Self) void {
        self.onset_detector.deinit();
    }

    /// Set BPM manually
    pub fn setBPM(self: *Self, bpm: f32) void {
        self.current_bpm = std.math.clamp(bpm, 30, 300);
        self.beat_interval_samples = @as(f64, @floatFromInt(self.sample_rate)) * 60.0 / @as(f64, self.current_bpm);
    }

    /// Process audio frame and return true if beat occurred
    pub fn process(self: *Self, frame: []const f32, position_samples: i64) !bool {
        // Advance phase
        self.phase += @as(f64, @floatFromInt(frame.len)) / self.beat_interval_samples;

        var beat_occurred = false;
        if (self.phase >= 1.0) {
            self.phase -= 1.0;
            beat_occurred = true;
            self.last_beat_sample = position_samples;
        }

        // Detect onsets for adaptation
        const is_onset = try self.onset_detector.processFrame(frame, @intCast(position_samples));

        // If onset near predicted beat, reinforce; if not, adjust
        if (is_onset) {
            const phase_error = if (self.phase < 0.5) self.phase else self.phase - 1.0;

            // Adjust phase toward onset
            self.phase -= phase_error * self.adaptation_rate;
            if (self.phase < 0) self.phase += 1.0;
        }

        return beat_occurred;
    }

    /// Get current beat phase (0.0 - 1.0)
    pub fn getPhase(self: *Self) f64 {
        return self.phase;
    }

    /// Get time until next beat in seconds
    pub fn getTimeToNextBeat(self: *Self) f64 {
        return (1.0 - self.phase) * self.beat_interval_samples / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Get current BPM
    pub fn getBPM(self: *Self) f32 {
        return self.current_bpm;
    }

    /// Reset phase to beginning
    pub fn resetPhase(self: *Self) void {
        self.phase = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OnsetDetector init" {
    const allocator = std.testing.allocator;

    var detector = try OnsetDetector.init(allocator, 44100);
    defer detector.deinit();

    detector.setThreshold(1.5);
    detector.setMinInterval(50);
}

test "OnsetDetector process" {
    const allocator = std.testing.allocator;

    var detector = try OnsetDetector.init(allocator, 44100);
    defer detector.deinit();

    // Process a loud frame
    var loud = [_]f32{0.8} ** 512;
    _ = try detector.processFrame(&loud, 0);

    // Process a quiet frame
    var quiet = [_]f32{0.01} ** 512;
    _ = try detector.processFrame(&quiet, 512);
}

test "TempoEstimator from onsets" {
    const allocator = std.testing.allocator;

    var estimator = TempoEstimator.init(allocator, 44100);

    // Create artificial onset times at 120 BPM (0.5 second intervals)
    const onsets = [_]f64{ 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0 };
    estimator.estimateFromOnsets(&onsets);

    // Should estimate close to 120 BPM
    const bpm = estimator.getBPM();
    try std.testing.expect(bpm > 100 and bpm < 140);
}

test "BeatTracker init" {
    const allocator = std.testing.allocator;

    var tracker = try BeatTracker.init(allocator, 44100, 120);
    defer tracker.deinit();

    tracker.setBPM(120);
    try std.testing.expectApproxEqAbs(@as(f32, 120), tracker.getBPM(), 0.001);
}
