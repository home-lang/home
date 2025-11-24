// Home Audio Library - Silence Detection/Splitting
// Detect silence regions and split audio at silence boundaries

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Silence region
pub const SilenceRegion = struct {
    start_sample: usize,
    end_sample: usize,
    start_time: f64, // In seconds
    end_time: f64,
    duration: f64, // In seconds

    pub fn durationSamples(self: SilenceRegion) usize {
        return self.end_sample - self.start_sample;
    }
};

/// Audio segment (non-silence region)
pub const AudioSegment = struct {
    start_sample: usize,
    end_sample: usize,
    start_time: f64,
    end_time: f64,
    duration: f64,
    index: usize, // Segment index

    pub fn durationSamples(self: AudioSegment) usize {
        return self.end_sample - self.start_sample;
    }
};

/// Silence detector configuration
pub const SilenceConfig = struct {
    threshold_db: f32 = -40, // Silence threshold in dB
    min_silence_duration: f32 = 0.3, // Minimum silence duration in seconds
    min_sound_duration: f32 = 0.1, // Minimum sound duration in seconds
    hold_time: f32 = 0.05, // Hold time before detecting silence
};

/// Silence detector
pub const SilenceDetector = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,
    config: SilenceConfig,

    // State
    threshold_linear: f32,
    min_silence_samples: usize,
    min_sound_samples: usize,
    hold_samples: usize,

    // Detection results
    silence_regions: std.ArrayList(SilenceRegion),
    audio_segments: std.ArrayList(AudioSegment),

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) Self {
        return initWithConfig(allocator, sample_rate, channels, .{});
    }

    pub fn initWithConfig(allocator: Allocator, sample_rate: u32, channels: u8, config: SilenceConfig) Self {
        var detector = Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .config = config,
            .threshold_linear = 0,
            .min_silence_samples = 0,
            .min_sound_samples = 0,
            .hold_samples = 0,
            .silence_regions = .{},
            .audio_segments = .{},
        };
        detector.updateConfig();
        return detector;
    }

    pub fn deinit(self: *Self) void {
        self.silence_regions.deinit(self.allocator);
        self.audio_segments.deinit(self.allocator);
    }

    fn updateConfig(self: *Self) void {
        self.threshold_linear = math.pow(f32, 10.0, self.config.threshold_db / 20.0);
        self.min_silence_samples = @intFromFloat(self.config.min_silence_duration * @as(f32, @floatFromInt(self.sample_rate)));
        self.min_sound_samples = @intFromFloat(self.config.min_sound_duration * @as(f32, @floatFromInt(self.sample_rate)));
        self.hold_samples = @intFromFloat(self.config.hold_time * @as(f32, @floatFromInt(self.sample_rate)));
    }

    /// Set silence threshold in dB
    pub fn setThreshold(self: *Self, db: f32) void {
        self.config.threshold_db = db;
        self.updateConfig();
    }

    /// Set minimum silence duration in seconds
    pub fn setMinSilenceDuration(self: *Self, seconds: f32) void {
        self.config.min_silence_duration = @max(0.01, seconds);
        self.updateConfig();
    }

    /// Set minimum sound duration in seconds
    pub fn setMinSoundDuration(self: *Self, seconds: f32) void {
        self.config.min_sound_duration = @max(0.01, seconds);
        self.updateConfig();
    }

    /// Analyze audio buffer for silence regions
    pub fn analyze(self: *Self, samples: []const f32) !void {
        self.silence_regions.clearRetainingCapacity();
        self.audio_segments.clearRetainingCapacity();

        const num_frames = samples.len / self.channels;
        const frame_size: usize = 512; // Analysis frame size

        var in_silence = false;
        var silence_start: usize = 0;
        var sound_start: usize = 0;
        var hold_counter: usize = 0;
        var segment_index: usize = 0;

        var pos: usize = 0;
        while (pos < num_frames) : (pos += frame_size) {
            const end_pos = @min(pos + frame_size, num_frames);

            // Calculate RMS for this frame (across all channels)
            var sum_sq: f32 = 0;
            var count: u32 = 0;
            for (pos..end_pos) |frame| {
                for (0..self.channels) |ch| {
                    const idx = frame * self.channels + ch;
                    if (idx < samples.len) {
                        sum_sq += samples[idx] * samples[idx];
                        count += 1;
                    }
                }
            }
            const rms = if (count > 0) @sqrt(sum_sq / @as(f32, @floatFromInt(count))) else 0;

            const is_silent = rms < self.threshold_linear;

            if (is_silent) {
                if (!in_silence) {
                    hold_counter += frame_size;
                    if (hold_counter >= self.hold_samples) {
                        // Transition to silence
                        const actual_silence_start = if (pos > self.hold_samples) pos - self.hold_samples else 0;

                        // Check if previous sound segment is long enough
                        if (actual_silence_start > sound_start) {
                            const sound_duration = actual_silence_start - sound_start;
                            if (sound_duration >= self.min_sound_samples) {
                                try self.audio_segments.append(self.allocator, AudioSegment{
                                    .start_sample = sound_start,
                                    .end_sample = actual_silence_start,
                                    .start_time = @as(f64, @floatFromInt(sound_start)) / @as(f64, @floatFromInt(self.sample_rate)),
                                    .end_time = @as(f64, @floatFromInt(actual_silence_start)) / @as(f64, @floatFromInt(self.sample_rate)),
                                    .duration = @as(f64, @floatFromInt(sound_duration)) / @as(f64, @floatFromInt(self.sample_rate)),
                                    .index = segment_index,
                                });
                                segment_index += 1;
                            }
                        }

                        in_silence = true;
                        silence_start = actual_silence_start;
                        hold_counter = 0;
                    }
                }
            } else {
                hold_counter = 0;
                if (in_silence) {
                    // Transition to sound
                    const silence_duration = pos - silence_start;
                    if (silence_duration >= self.min_silence_samples) {
                        try self.silence_regions.append(self.allocator, SilenceRegion{
                            .start_sample = silence_start,
                            .end_sample = pos,
                            .start_time = @as(f64, @floatFromInt(silence_start)) / @as(f64, @floatFromInt(self.sample_rate)),
                            .end_time = @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(self.sample_rate)),
                            .duration = @as(f64, @floatFromInt(silence_duration)) / @as(f64, @floatFromInt(self.sample_rate)),
                        });
                    }
                    in_silence = false;
                    sound_start = pos;
                }
            }
        }

        // Handle final region
        if (in_silence) {
            const silence_duration = num_frames - silence_start;
            if (silence_duration >= self.min_silence_samples) {
                try self.silence_regions.append(self.allocator, SilenceRegion{
                    .start_sample = silence_start,
                    .end_sample = num_frames,
                    .start_time = @as(f64, @floatFromInt(silence_start)) / @as(f64, @floatFromInt(self.sample_rate)),
                    .end_time = @as(f64, @floatFromInt(num_frames)) / @as(f64, @floatFromInt(self.sample_rate)),
                    .duration = @as(f64, @floatFromInt(silence_duration)) / @as(f64, @floatFromInt(self.sample_rate)),
                });
            }
        } else if (num_frames > sound_start) {
            const sound_duration = num_frames - sound_start;
            if (sound_duration >= self.min_sound_samples) {
                try self.audio_segments.append(self.allocator, AudioSegment{
                    .start_sample = sound_start,
                    .end_sample = num_frames,
                    .start_time = @as(f64, @floatFromInt(sound_start)) / @as(f64, @floatFromInt(self.sample_rate)),
                    .end_time = @as(f64, @floatFromInt(num_frames)) / @as(f64, @floatFromInt(self.sample_rate)),
                    .duration = @as(f64, @floatFromInt(sound_duration)) / @as(f64, @floatFromInt(self.sample_rate)),
                    .index = segment_index,
                });
            }
        }
    }

    /// Get detected silence regions
    pub fn getSilenceRegions(self: *Self) []const SilenceRegion {
        return self.silence_regions.items;
    }

    /// Get detected audio segments
    pub fn getAudioSegments(self: *Self) []const AudioSegment {
        return self.audio_segments.items;
    }

    /// Get total silence duration in seconds
    pub fn getTotalSilenceDuration(self: *Self) f64 {
        var total: f64 = 0;
        for (self.silence_regions.items) |region| {
            total += region.duration;
        }
        return total;
    }

    /// Get total audio (non-silence) duration in seconds
    pub fn getTotalAudioDuration(self: *Self) f64 {
        var total: f64 = 0;
        for (self.audio_segments.items) |segment| {
            total += segment.duration;
        }
        return total;
    }

    /// Check if a specific sample position is in silence
    pub fn isSilentAt(self: *Self, sample_pos: usize) bool {
        for (self.silence_regions.items) |region| {
            if (sample_pos >= region.start_sample and sample_pos < region.end_sample) {
                return true;
            }
        }
        return false;
    }

    /// Clear analysis results
    pub fn clear(self: *Self) void {
        self.silence_regions.clearRetainingCapacity();
        self.audio_segments.clearRetainingCapacity();
    }
};

/// Audio splitter - splits audio at silence boundaries
pub const AudioSplitter = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    // Split options
    fade_duration: f32, // Fade in/out duration in seconds
    min_segment_duration: f32, // Minimum segment duration
    max_segments: ?usize, // Maximum number of segments (null = unlimited)

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .fade_duration = 0.01,
            .min_segment_duration = 0.5,
            .max_segments = null,
        };
    }

    /// Set fade duration in seconds
    pub fn setFadeDuration(self: *Self, seconds: f32) void {
        self.fade_duration = @max(0, seconds);
    }

    /// Set minimum segment duration
    pub fn setMinSegmentDuration(self: *Self, seconds: f32) void {
        self.min_segment_duration = @max(0.1, seconds);
    }

    /// Set maximum number of segments
    pub fn setMaxSegments(self: *Self, max: ?usize) void {
        self.max_segments = max;
    }

    /// Split audio at detected segments
    pub fn split(self: *Self, samples: []const f32, segments: []const AudioSegment) ![][]f32 {
        var actual_segments = segments;
        if (self.max_segments) |max| {
            actual_segments = segments[0..@min(segments.len, max)];
        }

        var result = try self.allocator.alloc([]f32, actual_segments.len);
        errdefer {
            for (result) |seg| {
                self.allocator.free(seg);
            }
            self.allocator.free(result);
        }

        const fade_samples = @as(usize, @intFromFloat(self.fade_duration * @as(f32, @floatFromInt(self.sample_rate))));

        for (actual_segments, 0..) |segment, i| {
            const start = segment.start_sample * self.channels;
            const end = @min(segment.end_sample * self.channels, samples.len);
            const len = end - start;

            result[i] = try self.allocator.alloc(f32, len);
            @memcpy(result[i], samples[start..end]);

            // Apply fade in
            const fade_in_samples = @min(fade_samples * self.channels, len);
            for (0..fade_in_samples) |j| {
                const fade = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(fade_in_samples));
                result[i][j] *= fade;
            }

            // Apply fade out
            const fade_out_samples = @min(fade_samples * self.channels, len);
            for (0..fade_out_samples) |j| {
                const idx = len - 1 - j;
                const fade = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(fade_out_samples));
                result[i][idx] *= fade;
            }
        }

        return result;
    }

    /// Free split result
    pub fn freeSplit(self: *Self, segments: [][]f32) void {
        for (segments) |seg| {
            self.allocator.free(seg);
        }
        self.allocator.free(segments);
    }
};

/// Silence removal - removes silence while keeping audio
pub const SilenceRemover = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,

    // Options
    keep_gap: f32, // Gap to keep between segments (seconds)
    crossfade: f32, // Crossfade duration (seconds)

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .keep_gap = 0.1,
            .crossfade = 0.02,
        };
    }

    /// Set gap to keep between segments
    pub fn setKeepGap(self: *Self, seconds: f32) void {
        self.keep_gap = @max(0, seconds);
    }

    /// Set crossfade duration
    pub fn setCrossfade(self: *Self, seconds: f32) void {
        self.crossfade = @max(0, seconds);
    }

    /// Remove silence from audio
    pub fn removeSilence(self: *Self, samples: []const f32, segments: []const AudioSegment) ![]f32 {
        if (segments.len == 0) {
            return try self.allocator.alloc(f32, 0);
        }

        const gap_samples = @as(usize, @intFromFloat(self.keep_gap * @as(f32, @floatFromInt(self.sample_rate)))) * self.channels;
        const crossfade_samples = @as(usize, @intFromFloat(self.crossfade * @as(f32, @floatFromInt(self.sample_rate)))) * self.channels;

        // Calculate total output size
        var total_size: usize = 0;
        for (segments, 0..) |segment, i| {
            total_size += (segment.end_sample - segment.start_sample) * self.channels;
            if (i < segments.len - 1) {
                total_size += gap_samples;
            }
        }

        var result = try self.allocator.alloc(f32, total_size);
        @memset(result, 0);

        var write_pos: usize = 0;
        for (segments, 0..) |segment, i| {
            const start = segment.start_sample * self.channels;
            const end = @min(segment.end_sample * self.channels, samples.len);
            const len = end - start;

            // Copy segment
            @memcpy(result[write_pos .. write_pos + len], samples[start..end]);

            // Apply crossfade at boundaries
            if (i > 0 and crossfade_samples > 0) {
                const fade_len = @min(crossfade_samples, len);
                for (0..fade_len) |j| {
                    const fade = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(fade_len));
                    result[write_pos + j] *= fade;
                }
            }

            if (i < segments.len - 1 and crossfade_samples > 0) {
                const fade_len = @min(crossfade_samples, len);
                for (0..fade_len) |j| {
                    const idx = write_pos + len - 1 - j;
                    const fade = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(fade_len));
                    result[idx] *= fade;
                }
            }

            write_pos += len;
            if (i < segments.len - 1) {
                write_pos += gap_samples;
            }
        }

        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SilenceDetector basic" {
    const allocator = std.testing.allocator;

    var detector = SilenceDetector.init(allocator, 44100, 1);
    defer detector.deinit();

    detector.setThreshold(-30);
    detector.setMinSilenceDuration(0.1);

    // Create audio with silence in the middle
    var samples: [44100]f32 = undefined;
    for (0..10000) |i| {
        samples[i] = 0.5; // Loud
    }
    for (10000..30000) |i| {
        samples[i] = 0.001; // Silent
    }
    for (30000..44100) |i| {
        samples[i] = 0.5; // Loud again
    }

    try detector.analyze(&samples);

    // Should detect silence region
    const silences = detector.getSilenceRegions();
    try std.testing.expect(silences.len > 0);
}

test "SilenceDetector audio segments" {
    const allocator = std.testing.allocator;

    var detector = SilenceDetector.init(allocator, 44100, 1);
    defer detector.deinit();

    detector.setMinSilenceDuration(0.1);
    detector.setMinSoundDuration(0.05);

    // Create audio with multiple segments
    var samples: [44100]f32 = undefined;
    for (0..10000) |i| {
        samples[i] = 0.5; // Sound
    }
    for (10000..20000) |i| {
        samples[i] = 0.0001; // Silence
    }
    for (20000..30000) |i| {
        samples[i] = 0.5; // Sound
    }
    for (30000..44100) |i| {
        samples[i] = 0.0001; // Silence
    }

    try detector.analyze(&samples);

    const segments = detector.getAudioSegments();
    try std.testing.expect(segments.len >= 2);
}

test "AudioSplitter init" {
    const allocator = std.testing.allocator;

    var splitter = AudioSplitter.init(allocator, 44100, 2);
    splitter.setFadeDuration(0.01);
    splitter.setMinSegmentDuration(0.5);
}

test "SilenceRemover init" {
    const allocator = std.testing.allocator;

    var remover = SilenceRemover.init(allocator, 44100, 2);
    remover.setKeepGap(0.05);
    remover.setCrossfade(0.01);
}
