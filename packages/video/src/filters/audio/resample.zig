// Home Video Library - Audio Resampling
// Sample rate conversion with various quality levels

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const AudioFrame = frame.AudioFrame;
const SampleFormat = types.SampleFormat;

// ============================================================================
// Resample Quality
// ============================================================================

pub const ResampleQuality = enum {
    /// Fast but lower quality (linear interpolation)
    low,
    /// Balanced (cubic interpolation)
    medium,
    /// High quality (sinc interpolation)
    high,
};

// ============================================================================
// Resample Filter
// ============================================================================

pub const ResampleFilter = struct {
    target_rate: u32,
    quality: ResampleQuality,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, target_rate: u32, quality: ResampleQuality) Self {
        return .{
            .target_rate = target_rate,
            .quality = quality,
            .allocator = allocator,
        };
    }

    /// Resample an audio frame to the target sample rate
    pub fn apply(self: *const Self, input: *const AudioFrame) !AudioFrame {
        if (input.sample_rate == self.target_rate) {
            return try input.clone(self.allocator);
        }

        const ratio = @as(f64, @floatFromInt(self.target_rate)) / @as(f64, @floatFromInt(input.sample_rate));
        const output_samples: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(input.num_samples)) * ratio));

        var output = try AudioFrame.init(
            self.allocator,
            output_samples,
            input.channels,
            input.format,
        );
        errdefer output.deinit();

        switch (input.format) {
            .s16le, .s16be => try self.resampleS16(input, &output, ratio),
            .f32le, .f32be => try self.resampleF32(input, &output, ratio),
            else => return VideoError.UnsupportedSampleFormat,
        }

        output.pts = input.pts;
        output.sample_rate = self.target_rate;
        return output;
    }

    fn resampleS16(self: *const Self, input: *const AudioFrame, output: *AudioFrame, ratio: f64) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;

        const channels = input.channels;
        const in_samples = input.num_samples;
        const out_samples = output.num_samples;

        for (0..out_samples) |out_idx| {
            const in_pos = @as(f64, @floatFromInt(out_idx)) / ratio;

            for (0..channels) |ch| {
                const sample = switch (self.quality) {
                    .low => self.interpolateLinearS16(src, in_pos, ch, channels, in_samples),
                    .medium => self.interpolateCubicS16(src, in_pos, ch, channels, in_samples),
                    .high => self.interpolateSincS16(src, in_pos, ch, channels, in_samples),
                };

                const dst_offset = (out_idx * channels + ch) * 2;
                if (dst_offset + 1 < dst.len) {
                    const clamped = clampI16(sample);
                    const bytes = @as([2]u8, @bitCast(clamped));
                    dst[dst_offset] = bytes[0];
                    dst[dst_offset + 1] = bytes[1];
                }
            }
        }
    }

    fn resampleF32(self: *const Self, input: *const AudioFrame, output: *AudioFrame, ratio: f64) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;

        const channels = input.channels;
        const in_samples = input.num_samples;
        const out_samples = output.num_samples;

        for (0..out_samples) |out_idx| {
            const in_pos = @as(f64, @floatFromInt(out_idx)) / ratio;

            for (0..channels) |ch| {
                const sample = switch (self.quality) {
                    .low => self.interpolateLinearF32(src, in_pos, ch, channels, in_samples),
                    .medium => self.interpolateCubicF32(src, in_pos, ch, channels, in_samples),
                    .high => self.interpolateSincF32(src, in_pos, ch, channels, in_samples),
                };

                const dst_offset = (out_idx * channels + ch) * 4;
                if (dst_offset + 3 < dst.len) {
                    const clamped = @max(-1.0, @min(1.0, @as(f32, @floatCast(sample))));
                    const bytes = @as([4]u8, @bitCast(clamped));
                    @memcpy(dst[dst_offset..][0..4], &bytes);
                }
            }
        }
    }

    // Linear interpolation (low quality)
    fn interpolateLinearS16(_: *const Self, src: []u8, pos: f64, ch: usize, channels: u8, max_samples: u64) f64 {
        const idx0: usize = @intFromFloat(@floor(pos));
        const idx1 = @min(idx0 + 1, max_samples - 1);
        const frac = pos - @floor(pos);

        const s0 = getSampleS16(src, idx0, ch, channels);
        const s1 = getSampleS16(src, idx1, ch, channels);

        return s0 + (s1 - s0) * frac;
    }

    fn interpolateLinearF32(_: *const Self, src: []u8, pos: f64, ch: usize, channels: u8, max_samples: u64) f64 {
        const idx0: usize = @intFromFloat(@floor(pos));
        const idx1 = @min(idx0 + 1, max_samples - 1);
        const frac = pos - @floor(pos);

        const s0 = getSampleF32(src, idx0, ch, channels);
        const s1 = getSampleF32(src, idx1, ch, channels);

        return s0 + (s1 - s0) * frac;
    }

    // Cubic interpolation (medium quality)
    fn interpolateCubicS16(_: *const Self, src: []u8, pos: f64, ch: usize, channels: u8, max_samples: u64) f64 {
        const idx1: usize = @intFromFloat(@floor(pos));
        const idx0 = if (idx1 > 0) idx1 - 1 else 0;
        const idx2 = @min(idx1 + 1, max_samples - 1);
        const idx3 = @min(idx1 + 2, max_samples - 1);
        const frac = pos - @floor(pos);

        const s0 = getSampleS16(src, idx0, ch, channels);
        const s1 = getSampleS16(src, idx1, ch, channels);
        const s2 = getSampleS16(src, idx2, ch, channels);
        const s3 = getSampleS16(src, idx3, ch, channels);

        return cubicInterpolate(s0, s1, s2, s3, frac);
    }

    fn interpolateCubicF32(_: *const Self, src: []u8, pos: f64, ch: usize, channels: u8, max_samples: u64) f64 {
        const idx1: usize = @intFromFloat(@floor(pos));
        const idx0 = if (idx1 > 0) idx1 - 1 else 0;
        const idx2 = @min(idx1 + 1, max_samples - 1);
        const idx3 = @min(idx1 + 2, max_samples - 1);
        const frac = pos - @floor(pos);

        const s0 = getSampleF32(src, idx0, ch, channels);
        const s1 = getSampleF32(src, idx1, ch, channels);
        const s2 = getSampleF32(src, idx2, ch, channels);
        const s3 = getSampleF32(src, idx3, ch, channels);

        return cubicInterpolate(s0, s1, s2, s3, frac);
    }

    // Sinc interpolation (high quality)
    fn interpolateSincS16(_: *const Self, src: []u8, pos: f64, ch: usize, channels: u8, max_samples: u64) f64 {
        const center: i64 = @intFromFloat(@floor(pos));
        const frac = pos - @floor(pos);

        const taps = 8; // Number of sinc lobes
        var result: f64 = 0;
        var weight_sum: f64 = 0;

        var i: i64 = -taps + 1;
        while (i <= taps) : (i += 1) {
            const idx = center + i;
            if (idx >= 0 and idx < @as(i64, @intCast(max_samples))) {
                const x = @as(f64, @floatFromInt(i)) - frac;
                const w = sincWindow(x, taps);
                const sample = getSampleS16(src, @intCast(idx), ch, channels);
                result += sample * w;
                weight_sum += w;
            }
        }

        return if (weight_sum > 0) result / weight_sum else 0;
    }

    fn interpolateSincF32(_: *const Self, src: []u8, pos: f64, ch: usize, channels: u8, max_samples: u64) f64 {
        const center: i64 = @intFromFloat(@floor(pos));
        const frac = pos - @floor(pos);

        const taps = 8;
        var result: f64 = 0;
        var weight_sum: f64 = 0;

        var i: i64 = -taps + 1;
        while (i <= taps) : (i += 1) {
            const idx = center + i;
            if (idx >= 0 and idx < @as(i64, @intCast(max_samples))) {
                const x = @as(f64, @floatFromInt(i)) - frac;
                const w = sincWindow(x, taps);
                const sample = getSampleF32(src, @intCast(idx), ch, channels);
                result += sample * w;
                weight_sum += w;
            }
        }

        return if (weight_sum > 0) result / weight_sum else 0;
    }
};

// ============================================================================
// Channel Mixer
// ============================================================================

pub const ChannelMixer = struct {
    target_channels: u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, target_channels: u8) Self {
        return .{
            .target_channels = target_channels,
            .allocator = allocator,
        };
    }

    /// Mix channels to target count
    pub fn apply(self: *const Self, input: *const AudioFrame) !AudioFrame {
        if (input.channels == self.target_channels) {
            return try input.clone(self.allocator);
        }

        var output = try AudioFrame.init(
            self.allocator,
            input.num_samples,
            self.target_channels,
            input.format,
        );
        errdefer output.deinit();

        switch (input.format) {
            .s16le, .s16be => try self.mixS16(input, &output),
            .f32le, .f32be => try self.mixF32(input, &output),
            else => return VideoError.UnsupportedSampleFormat,
        }

        output.pts = input.pts;
        output.sample_rate = input.sample_rate;
        return output;
    }

    fn mixS16(self: *const Self, input: *const AudioFrame, output: *AudioFrame) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;
        const in_ch = input.channels;
        const out_ch = self.target_channels;

        for (0..input.num_samples) |sample_idx| {
            if (in_ch == 2 and out_ch == 1) {
                // Stereo to mono
                const l = getSampleS16(src, sample_idx, 0, 2);
                const r = getSampleS16(src, sample_idx, 1, 2);
                const mono = (l + r) / 2.0;
                setSampleS16(dst, sample_idx, 0, 1, clampI16(mono));
            } else if (in_ch == 1 and out_ch == 2) {
                // Mono to stereo
                const mono = getSampleS16(src, sample_idx, 0, 1);
                setSampleS16(dst, sample_idx, 0, 2, @intFromFloat(@round(mono)));
                setSampleS16(dst, sample_idx, 1, 2, @intFromFloat(@round(mono)));
            } else {
                // Generic upmix/downmix
                for (0..out_ch) |ch| {
                    const src_ch = ch % in_ch;
                    const sample = getSampleS16(src, sample_idx, src_ch, in_ch);
                    setSampleS16(dst, sample_idx, ch, out_ch, @intFromFloat(@round(sample)));
                }
            }
        }
    }

    fn mixF32(self: *const Self, input: *const AudioFrame, output: *AudioFrame) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;
        const in_ch = input.channels;
        const out_ch = self.target_channels;

        for (0..input.num_samples) |sample_idx| {
            if (in_ch == 2 and out_ch == 1) {
                const l = getSampleF32(src, sample_idx, 0, 2);
                const r = getSampleF32(src, sample_idx, 1, 2);
                const mono = (l + r) / 2.0;
                setSampleF32(dst, sample_idx, 0, 1, @floatCast(mono));
            } else if (in_ch == 1 and out_ch == 2) {
                const mono = getSampleF32(src, sample_idx, 0, 1);
                setSampleF32(dst, sample_idx, 0, 2, @floatCast(mono));
                setSampleF32(dst, sample_idx, 1, 2, @floatCast(mono));
            } else {
                for (0..out_ch) |ch| {
                    const src_ch = ch % in_ch;
                    const sample = getSampleF32(src, sample_idx, src_ch, in_ch);
                    setSampleF32(dst, sample_idx, ch, out_ch, @floatCast(sample));
                }
            }
        }
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn getSampleS16(data: []u8, sample_idx: usize, channel: usize, channels: u8) f64 {
    const offset = (sample_idx * channels + channel) * 2;
    if (offset + 1 >= data.len) return 0;
    const sample = @as(i16, @bitCast([2]u8{ data[offset], data[offset + 1] }));
    return @floatFromInt(sample);
}

fn setSampleS16(data: []u8, sample_idx: usize, channel: usize, channels: u8, value: i16) void {
    const offset = (sample_idx * channels + channel) * 2;
    if (offset + 1 >= data.len) return;
    const bytes = @as([2]u8, @bitCast(value));
    data[offset] = bytes[0];
    data[offset + 1] = bytes[1];
}

fn getSampleF32(data: []u8, sample_idx: usize, channel: usize, channels: u8) f64 {
    const offset = (sample_idx * channels + channel) * 4;
    if (offset + 3 >= data.len) return 0;
    const sample = @as(f32, @bitCast([4]u8{ data[offset], data[offset + 1], data[offset + 2], data[offset + 3] }));
    return @floatCast(sample);
}

fn setSampleF32(data: []u8, sample_idx: usize, channel: usize, channels: u8, value: f32) void {
    const offset = (sample_idx * channels + channel) * 4;
    if (offset + 3 >= data.len) return;
    const bytes = @as([4]u8, @bitCast(value));
    @memcpy(data[offset..][0..4], &bytes);
}

fn cubicInterpolate(y0: f64, y1: f64, y2: f64, y3: f64, t: f64) f64 {
    const a0 = y3 - y2 - y0 + y1;
    const a1 = y0 - y1 - a0;
    const a2 = y2 - y0;
    const a3 = y1;

    return a0 * t * t * t + a1 * t * t + a2 * t + a3;
}

fn sincWindow(x: f64, taps: i32) f64 {
    if (x == 0) return 1;

    const a = @as(f64, @floatFromInt(taps));
    const pi_x = std.math.pi * x;

    // Lanczos window
    if (@abs(x) >= a) return 0;

    const sinc = @sin(pi_x) / pi_x;
    const window = @sin(pi_x / a) / (pi_x / a);
    return sinc * window;
}

fn clampI16(val: f64) i16 {
    return @intFromFloat(@round(@max(-32768, @min(32767, val))));
}

// ============================================================================
// Tests
// ============================================================================

test "ResampleFilter initialization" {
    const allocator = std.testing.allocator;
    const filter = ResampleFilter.init(allocator, 48000, .high);

    try std.testing.expectEqual(@as(u32, 48000), filter.target_rate);
    try std.testing.expectEqual(ResampleQuality.high, filter.quality);
}

test "ChannelMixer initialization" {
    const allocator = std.testing.allocator;
    const mixer = ChannelMixer.init(allocator, 1);

    try std.testing.expectEqual(@as(u8, 1), mixer.target_channels);
}

test "cubicInterpolate" {
    // At t=0, should return y1
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), cubicInterpolate(1, 2, 3, 4, 0), 0.001);
    // At t=1, should return y2
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), cubicInterpolate(1, 2, 3, 4, 1), 0.001);
}

test "sincWindow" {
    // At x=0, should return 1
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), sincWindow(0, 8), 0.001);
    // Outside window, should return 0
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), sincWindow(10, 8), 0.001);
}

test "clampI16" {
    try std.testing.expectEqual(@as(i16, 0), clampI16(0));
    try std.testing.expectEqual(@as(i16, 32767), clampI16(40000));
    try std.testing.expectEqual(@as(i16, -32768), clampI16(-40000));
}
