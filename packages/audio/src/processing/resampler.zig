// Home Audio Library - Resampler
// Audio sample rate conversion utilities

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const frame = @import("../core/frame.zig");
const AudioFrame = frame.AudioFrame;
const AudioBuffer = frame.AudioBuffer;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;

/// Resampling quality levels
pub const Quality = enum {
    /// Fast, lower quality (linear interpolation)
    fast,
    /// Balanced quality/speed (cubic interpolation)
    medium,
    /// High quality (sinc interpolation with 8 taps)
    high,
    /// Highest quality (sinc interpolation with 32 taps)
    best,

    pub fn getFilterTaps(self: Quality) u8 {
        return switch (self) {
            .fast => 2,
            .medium => 4,
            .high => 8,
            .best => 32,
        };
    }
};

/// Resampler for converting audio between sample rates
pub const Resampler = struct {
    allocator: Allocator,
    source_rate: u32,
    target_rate: u32,
    channels: u8,
    quality: Quality,

    // Sinc table for high quality resampling
    sinc_table: ?[]f32,
    sinc_table_size: usize,

    // History buffer for filter
    history: []f32,
    history_pos: usize,

    const Self = @This();

    /// Initialize resampler
    pub fn init(
        allocator: Allocator,
        source_rate: u32,
        target_rate: u32,
        channels: u8,
        quality: Quality,
    ) !Self {
        const taps = quality.getFilterTaps();

        // Allocate history buffer
        const history_size = @as(usize, taps) * channels;
        const history = try allocator.alloc(f32, history_size);
        @memset(history, 0);

        // Pre-compute sinc table for high/best quality
        var sinc_table: ?[]f32 = null;
        var sinc_table_size: usize = 0;

        if (quality == .high or quality == .best) {
            sinc_table_size = @as(usize, 1024) * @as(usize, taps);
            const table = try allocator.alloc(f32, sinc_table_size);

            // Generate windowed sinc table
            const half_taps = @as(f32, @floatFromInt(taps)) / 2.0;
            for (0..sinc_table_size) |i| {
                const x = @as(f32, @floatFromInt(i)) / 1024.0 - half_taps;
                table[i] = windowedSinc(x, half_taps);
            }

            sinc_table = table;
        }

        return Self{
            .allocator = allocator,
            .source_rate = source_rate,
            .target_rate = target_rate,
            .channels = channels,
            .quality = quality,
            .sinc_table = sinc_table,
            .sinc_table_size = sinc_table_size,
            .history = history,
            .history_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.history);
        if (self.sinc_table) |table| {
            self.allocator.free(table);
        }
    }

    /// Windowed sinc function (Blackman-Harris window)
    fn windowedSinc(x: f32, half_width: f32) f32 {
        if (@abs(x) < 0.0001) return 1.0;
        if (@abs(x) >= half_width) return 0.0;

        // Sinc function
        const pi_x = math.pi * x;
        const sinc = @sin(pi_x) / pi_x;

        // Blackman-Harris window
        const t = (x + half_width) / (2.0 * half_width);
        const a0 = 0.35875;
        const a1 = 0.48829;
        const a2 = 0.14128;
        const a3 = 0.01168;

        const window = a0 - a1 * @cos(2.0 * math.pi * t) +
            a2 * @cos(4.0 * math.pi * t) -
            a3 * @cos(6.0 * math.pi * t);

        return sinc * window;
    }

    /// Calculate output sample count for given input
    pub fn getOutputSamples(self: *const Self, input_samples: u64) u64 {
        return (input_samples * self.target_rate + self.source_rate - 1) / self.source_rate;
    }

    /// Resample audio data
    pub fn resample(self: *Self, input: []const f32, output: []f32) void {
        const ratio = @as(f64, @floatFromInt(self.source_rate)) /
            @as(f64, @floatFromInt(self.target_rate));

        const channels = self.channels;
        const input_frames = input.len / channels;
        const output_frames = output.len / channels;

        switch (self.quality) {
            .fast => self.resampleLinear(input, output, input_frames, output_frames, ratio),
            .medium => self.resampleCubic(input, output, input_frames, output_frames, ratio),
            .high, .best => self.resampleSinc(input, output, input_frames, output_frames, ratio),
        }
    }

    /// Linear interpolation (fastest)
    fn resampleLinear(
        self: *Self,
        input: []const f32,
        output: []f32,
        input_frames: usize,
        output_frames: usize,
        ratio: f64,
    ) void {
        const channels = self.channels;

        for (0..output_frames) |out_idx| {
            const pos = @as(f64, @floatFromInt(out_idx)) * ratio;
            const idx0 = @as(usize, @intFromFloat(pos));
            const frac = @as(f32, @floatCast(pos - @as(f64, @floatFromInt(idx0))));
            const idx1 = @min(idx0 + 1, input_frames - 1);

            for (0..channels) |ch| {
                const s0 = if (idx0 < input_frames) input[idx0 * channels + ch] else 0;
                const s1 = if (idx1 < input_frames) input[idx1 * channels + ch] else 0;
                output[out_idx * channels + ch] = s0 + (s1 - s0) * frac;
            }
        }
    }

    /// Cubic interpolation (balanced)
    fn resampleCubic(
        self: *Self,
        input: []const f32,
        output: []f32,
        input_frames: usize,
        output_frames: usize,
        ratio: f64,
    ) void {
        const channels = self.channels;

        for (0..output_frames) |out_idx| {
            const pos = @as(f64, @floatFromInt(out_idx)) * ratio;
            const idx1 = @as(usize, @intFromFloat(pos));
            const frac = @as(f32, @floatCast(pos - @as(f64, @floatFromInt(idx1))));

            const idx0 = if (idx1 > 0) idx1 - 1 else 0;
            const idx2 = @min(idx1 + 1, input_frames - 1);
            const idx3 = @min(idx1 + 2, input_frames - 1);

            for (0..channels) |ch| {
                const s0 = if (idx0 < input_frames) input[idx0 * channels + ch] else 0;
                const s1 = if (idx1 < input_frames) input[idx1 * channels + ch] else 0;
                const s2 = if (idx2 < input_frames) input[idx2 * channels + ch] else 0;
                const s3 = if (idx3 < input_frames) input[idx3 * channels + ch] else 0;

                // Catmull-Rom spline
                const a0 = -0.5 * s0 + 1.5 * s1 - 1.5 * s2 + 0.5 * s3;
                const a1 = s0 - 2.5 * s1 + 2.0 * s2 - 0.5 * s3;
                const a2 = -0.5 * s0 + 0.5 * s2;
                const a3 = s1;

                output[out_idx * channels + ch] = ((a0 * frac + a1) * frac + a2) * frac + a3;
            }
        }
    }

    /// Sinc interpolation (highest quality)
    fn resampleSinc(
        self: *Self,
        input: []const f32,
        output: []f32,
        input_frames: usize,
        output_frames: usize,
        ratio: f64,
    ) void {
        const channels = self.channels;
        const taps = self.quality.getFilterTaps();
        const half_taps = @as(i32, @intCast(taps / 2));
        const table = self.sinc_table orelse return;

        for (0..output_frames) |out_idx| {
            const pos = @as(f64, @floatFromInt(out_idx)) * ratio;
            const center_idx = @as(i64, @intFromFloat(pos));
            const frac = @as(f32, @floatCast(pos - @as(f64, @floatFromInt(center_idx))));

            for (0..channels) |ch| {
                var sum: f32 = 0;

                var tap: i32 = -half_taps;
                while (tap < half_taps) : (tap += 1) {
                    const sample_idx = center_idx + tap;
                    if (sample_idx >= 0 and sample_idx < input_frames) {
                        // Look up sinc value from table
                        const table_pos = (@as(f32, @floatFromInt(tap)) + @as(f32, @floatFromInt(half_taps)) - frac) * 1024.0;
                        const table_idx = @as(usize, @intFromFloat(@max(0, @min(table_pos, @as(f32, @floatFromInt(self.sinc_table_size - 1))))));
                        const sinc_val = table[table_idx];

                        sum += input[@as(usize, @intCast(sample_idx)) * channels + ch] * sinc_val;
                    }
                }

                output[out_idx * channels + ch] = sum;
            }
        }
    }

    /// Resample an AudioFrame
    pub fn resampleFrame(self: *Self, input_frame: *const AudioFrame) !AudioFrame {
        // Convert to f32 for processing
        const input_samples = input_frame.num_samples;
        const output_samples = self.getOutputSamples(input_samples);

        const input_f32 = try self.allocator.alloc(f32, input_samples * self.channels);
        defer self.allocator.free(input_f32);

        const output_f32 = try self.allocator.alloc(f32, output_samples * self.channels);
        defer self.allocator.free(output_f32);

        // Convert input to f32
        for (0..input_samples * self.channels) |i| {
            input_f32[i] = input_frame.getSampleF32(i / self.channels, @intCast(i % self.channels)) orelse 0;
        }

        // Resample
        self.resample(input_f32, output_f32);

        // Create output frame
        var out_frame = try AudioFrame.init(
            self.allocator,
            self.channels,
            @intCast(output_samples),
            .f32le,
        );

        // Copy data
        for (0..output_samples) |sample| {
            for (0..self.channels) |ch| {
                out_frame.setSampleF32(sample, @intCast(ch), output_f32[sample * self.channels + ch]);
            }
        }

        return out_frame;
    }
};

/// Simple resample function (one-shot)
pub fn resample(
    allocator: Allocator,
    input: []const f32,
    source_rate: u32,
    target_rate: u32,
    channels: u8,
    quality: Quality,
) ![]f32 {
    var resampler = try Resampler.init(allocator, source_rate, target_rate, channels, quality);
    defer resampler.deinit();

    const input_frames = input.len / channels;
    const output_frames = resampler.getOutputSamples(input_frames);
    const output = try allocator.alloc(f32, output_frames * channels);

    resampler.resample(input, output);
    return output;
}

/// Convert sample rate of audio buffer
pub fn convertSampleRate(
    allocator: Allocator,
    buffer: *const AudioBuffer,
    target_rate: u32,
    quality: Quality,
) !AudioBuffer {
    var resampler = try Resampler.init(
        allocator,
        buffer.sample_rate,
        target_rate,
        buffer.channels,
        quality,
    );
    defer resampler.deinit();

    const input_samples = buffer.data.len / buffer.channels;
    const output_samples = resampler.getOutputSamples(input_samples);

    var new_buffer = try AudioBuffer.init(
        allocator,
        buffer.channels,
        @intCast(output_samples),
        .f32le,
    );
    new_buffer.sample_rate = target_rate;

    resampler.resample(buffer.data, new_buffer.data);

    return new_buffer;
}

// ============================================================================
// Tests
// ============================================================================

test "Resampler init/deinit" {
    const allocator = std.testing.allocator;

    var resampler = try Resampler.init(allocator, 44100, 48000, 2, .medium);
    defer resampler.deinit();

    try std.testing.expectEqual(@as(u32, 44100), resampler.source_rate);
    try std.testing.expectEqual(@as(u32, 48000), resampler.target_rate);
}

test "Resampler output sample calculation" {
    const allocator = std.testing.allocator;

    var resampler = try Resampler.init(allocator, 44100, 48000, 2, .fast);
    defer resampler.deinit();

    // 44100 samples at 44100 Hz = 1 second
    // 1 second at 48000 Hz = 48000 samples
    const output = resampler.getOutputSamples(44100);
    try std.testing.expectEqual(@as(u64, 48000), output);
}

test "Resampler linear interpolation" {
    const allocator = std.testing.allocator;

    var resampler = try Resampler.init(allocator, 100, 200, 1, .fast);
    defer resampler.deinit();

    // Input: 4 samples
    const input = [_]f32{ 0.0, 1.0, 0.0, -1.0 };
    var output: [8]f32 = undefined;

    resampler.resample(&input, &output);

    // Check interpolation
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), output[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), output[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), output[2], 0.01);
}

test "Quality filter taps" {
    try std.testing.expectEqual(@as(u8, 2), Quality.fast.getFilterTaps());
    try std.testing.expectEqual(@as(u8, 4), Quality.medium.getFilterTaps());
    try std.testing.expectEqual(@as(u8, 8), Quality.high.getFilterTaps());
    try std.testing.expectEqual(@as(u8, 32), Quality.best.getFilterTaps());
}
