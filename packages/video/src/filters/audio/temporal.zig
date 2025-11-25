// Home Video Library - Audio Temporal Filters
// Trim, speed adjustment with pitch preservation, time stretching

const std = @import("std");
const core = @import("../../core.zig");
const AudioFrame = core.AudioFrame;
const Timestamp = core.Timestamp;
const Duration = core.Duration;

/// Audio trim filter
pub const AudioTrimFilter = struct {
    start_time: Timestamp,
    end_time: ?Timestamp = null,
    duration: ?Duration = null,

    const Self = @This();

    pub fn init(start_time: Timestamp, end_time: ?Timestamp, duration: ?Duration) Self {
        return .{
            .start_time = start_time,
            .end_time = end_time,
            .duration = duration,
        };
    }

    pub fn shouldIncludeFrame(self: *const Self, pts: Timestamp) bool {
        if (pts.compare(self.start_time) == .lt) return false;

        if (self.end_time) |end| {
            if (pts.compare(end) == .gt) return false;
        }

        if (self.duration) |dur| {
            const end = self.start_time.add(dur.toMicroseconds());
            if (pts.compare(end) == .gt) return false;
        }

        return true;
    }

    pub fn adjustTimestamp(self: *const Self, pts: Timestamp) Timestamp {
        return pts.sub(self.start_time.toMicroseconds());
    }
};

/// Audio speed adjustment mode
pub const SpeedMode = enum {
    simple, // Simple resampling (changes pitch)
    preserve_pitch, // Time-domain pitch-synchronous overlap-add
    phase_vocoder, // Frequency-domain phase vocoder
};

/// Audio speed filter
pub const AudioSpeedFilter = struct {
    speed_factor: f32, // 0.5x - 2.0x
    mode: SpeedMode = .simple,
    sample_rate: u32,
    channels: u16,
    allocator: std.mem.Allocator,

    // State for pitch preservation
    overlap_buffer: ?[]f32 = null,
    analysis_hop: u32,
    synthesis_hop: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, speed_factor: f32, mode: SpeedMode, sample_rate: u32, channels: u16) !Self {
        if (speed_factor < 0.5 or speed_factor > 2.0) {
            return error.InvalidSpeedFactor;
        }

        return .{
            .allocator = allocator,
            .speed_factor = speed_factor,
            .mode = mode,
            .sample_rate = sample_rate,
            .channels = channels,
            .analysis_hop = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * 0.01), // 10ms
            .synthesis_hop = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * 0.01 / speed_factor),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.overlap_buffer) |buf| {
            self.allocator.free(buf);
        }
    }

    pub fn apply(self: *Self, frame: *const AudioFrame) !*AudioFrame {
        switch (self.mode) {
            .simple => return try self.applySimple(frame),
            .preserve_pitch => return try self.applyPSOLA(frame),
            .phase_vocoder => return error.NotImplemented,
        }
    }

    fn applySimple(self: *Self, frame: *const AudioFrame) !*AudioFrame {
        const new_sample_count: u32 = @intFromFloat(@as(f32, @floatFromInt(frame.sample_count)) / self.speed_factor);

        const output = try self.allocator.create(AudioFrame);
        output.* = try AudioFrame.init(self.allocator, new_sample_count, frame.channels, frame.sample_rate);

        // Simple linear interpolation resampling
        for (0..new_sample_count) |i| {
            const src_pos = @as(f32, @floatFromInt(i)) * self.speed_factor;
            const src_idx: u32 = @intFromFloat(src_pos);
            const frac = src_pos - @as(f32, @floatFromInt(src_idx));

            if (src_idx + 1 < frame.sample_count) {
                for (0..frame.channels) |ch| {
                    const sample1 = frame.data[ch][src_idx];
                    const sample2 = frame.data[ch][src_idx + 1];

                    // Linear interpolation
                    const interpolated = sample1 * (1.0 - frac) + sample2 * frac;
                    output.data[ch][i] = interpolated;
                }
            } else if (src_idx < frame.sample_count) {
                for (0..frame.channels) |ch| {
                    output.data[ch][i] = frame.data[ch][src_idx];
                }
            }
        }

        output.pts = frame.pts;
        return output;
    }

    fn applyPSOLA(self: *Self, frame: *const AudioFrame) !*AudioFrame {
        // PSOLA (Pitch-Synchronous Overlap-Add) for pitch-preserving time stretching
        const window_size = self.analysis_hop * 4;
        const new_sample_count: u32 = @intFromFloat(@as(f32, @floatFromInt(frame.sample_count)) / self.speed_factor);

        const output = try self.allocator.create(AudioFrame);
        output.* = try AudioFrame.init(self.allocator, new_sample_count, frame.channels, frame.sample_rate);

        // Initialize output to zero
        for (0..frame.channels) |ch| {
            @memset(output.data[ch], 0.0);
        }

        // Create Hann window
        var window = try self.allocator.alloc(f32, window_size);
        defer self.allocator.free(window);

        for (0..window_size) |i| {
            const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(window_size - 1));
            window[i] = 0.5 * (1.0 - @cos(2.0 * std.math.pi * phase));
        }

        // Overlap-add synthesis
        var read_pos: u32 = 0;
        var write_pos: u32 = 0;

        while (read_pos + window_size < frame.sample_count and write_pos + window_size < new_sample_count) {
            // Copy and window the segment
            for (0..frame.channels) |ch| {
                for (0..window_size) |i| {
                    const sample = frame.data[ch][read_pos + i] * window[i];
                    if (write_pos + i < new_sample_count) {
                        output.data[ch][write_pos + i] += sample;
                    }
                }
            }

            read_pos += self.analysis_hop;
            write_pos += self.synthesis_hop;
        }

        output.pts = frame.pts;
        return output;
    }
};

/// Audio reverse filter
pub const AudioReverseFilter = struct {
    allocator: std.mem.Allocator,
    frame_buffer: std.ArrayList(*AudioFrame),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .frame_buffer = std.ArrayList(*AudioFrame).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.frame_buffer.items) |frame| {
            frame.deinit();
            self.allocator.destroy(frame);
        }
        self.frame_buffer.deinit();
    }

    pub fn addFrame(self: *Self, frame: *AudioFrame) !void {
        const cloned = try self.allocator.create(AudioFrame);
        cloned.* = try frame.clone(self.allocator);
        try self.frame_buffer.append(cloned);
    }

    pub fn getReversedFrames(self: *Self) ![]const *AudioFrame {
        // Reverse the entire buffer
        std.mem.reverse(*AudioFrame, self.frame_buffer.items);

        // Reverse samples within each frame
        for (self.frame_buffer.items) |frame| {
            for (0..frame.channels) |ch| {
                std.mem.reverse(f32, frame.data[ch][0..frame.sample_count]);
            }
        }

        // Update timestamps
        var current_time: i64 = 0;
        for (self.frame_buffer.items) |frame| {
            frame.pts = Timestamp.fromMicroseconds(current_time);
            const frame_duration: i64 = @intCast(@as(u64, frame.sample_count) * 1_000_000 / @as(u64, frame.sample_rate));
            current_time += frame_duration;
        }

        return self.frame_buffer.items;
    }
};

/// Audio loop filter
pub const AudioLoopFilter = struct {
    loop_count: u32, // 0 = infinite
    current_loop: u32 = 0,
    allocator: std.mem.Allocator,
    loop_buffer: std.ArrayList(*AudioFrame),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, loop_count: u32) Self {
        return .{
            .allocator = allocator,
            .loop_count = loop_count,
            .loop_buffer = std.ArrayList(*AudioFrame).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.loop_buffer.items) |frame| {
            frame.deinit();
            self.allocator.destroy(frame);
        }
        self.loop_buffer.deinit();
    }

    pub fn addFrame(self: *Self, frame: *AudioFrame) !void {
        const cloned = try self.allocator.create(AudioFrame);
        cloned.* = try frame.clone(self.allocator);
        try self.loop_buffer.append(cloned);
    }

    pub fn shouldLoop(self: *const Self) bool {
        if (self.loop_count == 0) return true; // Infinite
        return self.current_loop < self.loop_count;
    }

    pub fn getNextLoop(self: *Self) ![]const *AudioFrame {
        if (!self.shouldLoop()) {
            return &[_]*AudioFrame{};
        }

        self.current_loop += 1;

        // Clone all frames for this loop iteration
        var looped_frames = std.ArrayList(*AudioFrame).init(self.allocator);

        for (self.loop_buffer.items) |frame| {
            const cloned = try self.allocator.create(AudioFrame);
            cloned.* = try frame.clone(self.allocator);
            try looped_frames.append(cloned);
        }

        return looped_frames.items;
    }
};

/// Silence detector
pub const SilenceDetector = struct {
    threshold: f32 = 0.01, // Amplitude threshold
    min_duration: Duration, // Minimum silence duration
    current_silence_start: ?Timestamp = null,
    current_silence_duration: Duration,

    const Self = @This();

    pub fn init(threshold: f32, min_duration: Duration) Self {
        return .{
            .threshold = threshold,
            .min_duration = min_duration,
            .current_silence_duration = Duration.fromMicroseconds(0),
        };
    }

    pub fn detectSilence(self: *Self, frame: *const AudioFrame) bool {
        const is_silent = self.isFrameSilent(frame);
        const frame_duration_us = @as(i64, @intCast(frame.sample_count)) * 1_000_000 / @as(i64, @intCast(frame.sample_rate));
        const frame_duration = Duration.fromMicroseconds(frame_duration_us);

        if (is_silent) {
            if (self.current_silence_start == null) {
                self.current_silence_start = frame.pts;
                self.current_silence_duration = frame_duration;
            } else {
                self.current_silence_duration = self.current_silence_duration.add(frame_duration.toMicroseconds());
            }

            return self.current_silence_duration.toMicroseconds() >= self.min_duration.toMicroseconds();
        } else {
            self.current_silence_start = null;
            self.current_silence_duration = Duration.fromMicroseconds(0);
            return false;
        }
    }

    fn isFrameSilent(self: *const Self, frame: *const AudioFrame) bool {
        // Check if all samples are below threshold
        for (0..frame.channels) |ch| {
            for (0..frame.sample_count) |i| {
                if (@abs(frame.data[ch][i]) > self.threshold) {
                    return false;
                }
            }
        }
        return true;
    }
};

/// Audio delay/offset filter
pub const AudioDelayFilter = struct {
    delay: Duration,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, delay: Duration) Self {
        return .{
            .allocator = allocator,
            .delay = delay,
        };
    }

    pub fn apply(self: *Self, frame: *const AudioFrame) !*AudioFrame {
        const output = try self.allocator.create(AudioFrame);
        output.* = try frame.clone(self.allocator);

        // Adjust timestamp
        output.pts = frame.pts.add(self.delay.toMicroseconds());

        return output;
    }
};
