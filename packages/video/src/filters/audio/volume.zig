// Home Video Library - Volume Filter
// Audio volume adjustment and normalization

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;
const AudioFrame = frame.AudioFrame;
const SampleFormat = types.SampleFormat;

// ============================================================================
// Volume Filter
// ============================================================================

pub const VolumeFilter = struct {
    /// Volume multiplier (1.0 = no change, 0.5 = -6dB, 2.0 = +6dB)
    gain: f32,
    /// Soft clipping threshold (0.0 = hard clip, 1.0 = no soft clip)
    soft_clip_threshold: f32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, gain: f32) Self {
        return .{
            .gain = gain,
            .soft_clip_threshold = 0.95,
            .allocator = allocator,
        };
    }

    /// Create volume filter from decibels
    pub fn fromDb(allocator: std.mem.Allocator, db: f32) Self {
        const gain = std.math.pow(f32, 10.0, db / 20.0);
        return init(allocator, gain);
    }

    /// Apply volume adjustment to an audio frame
    pub fn apply(self: *const Self, input: *const AudioFrame) !AudioFrame {
        if (self.gain == 1.0) {
            return try input.clone(self.allocator);
        }

        var output = try AudioFrame.init(
            self.allocator,
            input.num_samples,
            @intCast(input.channels),
            input.format,
        );
        errdefer output.deinit();

        switch (input.format) {
            .s16le, .s16be => try self.applyS16(input, &output),
            .s32le, .s32be => try self.applyS32(input, &output),
            .f32le, .f32be => try self.applyF32(input, &output),
            .f64le, .f64be => try self.applyF64(input, &output),
            else => return VideoError.UnsupportedSampleFormat,
        }

        output.pts = input.pts;
        output.sample_rate = input.sample_rate;
        return output;
    }

    fn applyS16(self: *const Self, input: *const AudioFrame, output: *AudioFrame) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;
        const samples = @min(src.len / 2, dst.len / 2);

        for (0..samples) |i| {
            const offset = i * 2;
            const sample = @as(i16, @bitCast([2]u8{ src[offset], src[offset + 1] }));
            const adjusted = @as(f32, @floatFromInt(sample)) * self.gain;
            const clamped = self.softClipS16(adjusted);
            const bytes = @as([2]u8, @bitCast(clamped));
            dst[offset] = bytes[0];
            dst[offset + 1] = bytes[1];
        }
    }

    fn applyS32(self: *const Self, input: *const AudioFrame, output: *AudioFrame) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;
        const samples = @min(src.len / 4, dst.len / 4);

        for (0..samples) |i| {
            const offset = i * 4;
            const sample = @as(i32, @bitCast([4]u8{
                src[offset],
                src[offset + 1],
                src[offset + 2],
                src[offset + 3],
            }));
            const adjusted = @as(f64, @floatFromInt(sample)) * @as(f64, self.gain);
            const clamped = self.softClipS32(adjusted);
            const bytes = @as([4]u8, @bitCast(clamped));
            @memcpy(dst[offset..][0..4], &bytes);
        }
    }

    fn applyF32(self: *const Self, input: *const AudioFrame, output: *AudioFrame) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;
        const samples = @min(src.len / 4, dst.len / 4);

        for (0..samples) |i| {
            const offset = i * 4;
            const sample = @as(f32, @bitCast([4]u8{
                src[offset],
                src[offset + 1],
                src[offset + 2],
                src[offset + 3],
            }));
            const adjusted = sample * self.gain;
            const clamped = self.softClipF32(adjusted);
            const bytes = @as([4]u8, @bitCast(clamped));
            @memcpy(dst[offset..][0..4], &bytes);
        }
    }

    fn applyF64(self: *const Self, input: *const AudioFrame, output: *AudioFrame) !void {
        if (input.data[0] == null or output.data[0] == null) return;

        const src = input.data[0].?;
        const dst = output.data[0].?;
        const samples = @min(src.len / 8, dst.len / 8);

        for (0..samples) |i| {
            const offset = i * 8;
            var bytes: [8]u8 = undefined;
            @memcpy(&bytes, src[offset..][0..8]);
            const sample = @as(f64, @bitCast(bytes));
            const adjusted = sample * @as(f64, self.gain);
            const clamped = self.softClipF64(adjusted);
            const out_bytes = @as([8]u8, @bitCast(clamped));
            @memcpy(dst[offset..][0..8], &out_bytes);
        }
    }

    fn softClipS16(self: *const Self, sample: f32) i16 {
        const max: f32 = 32767;
        const threshold = max * self.soft_clip_threshold;

        if (@abs(sample) <= threshold) {
            return @intFromFloat(@round(@max(-32768, @min(32767, sample))));
        }

        // Soft clip using tanh-like curve
        const sign: f32 = if (sample >= 0) 1 else -1;
        const abs_sample = @abs(sample);
        const over = abs_sample - threshold;
        const range = max - threshold;
        const compressed = threshold + range * @as(f32, @floatCast(std.math.tanh(@as(f64, over / range))));
        return @intFromFloat(@round(sign * compressed));
    }

    fn softClipS32(self: *const Self, sample: f64) i32 {
        const max: f64 = 2147483647;
        const threshold = max * @as(f64, self.soft_clip_threshold);

        if (@abs(sample) <= threshold) {
            return @intFromFloat(@round(@max(-2147483648, @min(2147483647, sample))));
        }

        const sign: f64 = if (sample >= 0) 1 else -1;
        const abs_sample = @abs(sample);
        const over = abs_sample - threshold;
        const range = max - threshold;
        const compressed = threshold + range * std.math.tanh(over / range);
        return @intFromFloat(@round(sign * compressed));
    }

    fn softClipF32(self: *const Self, sample: f32) f32 {
        const threshold = self.soft_clip_threshold;

        if (@abs(sample) <= threshold) {
            return @max(-1.0, @min(1.0, sample));
        }

        const sign: f32 = if (sample >= 0) 1 else -1;
        const abs_sample = @abs(sample);
        const over = abs_sample - threshold;
        const range = 1.0 - threshold;
        return sign * (threshold + range * @as(f32, @floatCast(std.math.tanh(@as(f64, over / range)))));
    }

    fn softClipF64(self: *const Self, sample: f64) f64 {
        const threshold: f64 = self.soft_clip_threshold;

        if (@abs(sample) <= threshold) {
            return @max(-1.0, @min(1.0, sample));
        }

        const sign: f64 = if (sample >= 0) 1 else -1;
        const abs_sample = @abs(sample);
        const over = abs_sample - threshold;
        const range = 1.0 - threshold;
        return sign * (threshold + range * std.math.tanh(over / range));
    }

    /// Get gain in decibels
    pub fn getDb(self: *const Self) f32 {
        return 20.0 * std.math.log10(self.gain);
    }
};

// ============================================================================
// Normalize Filter
// ============================================================================

pub const NormalizeFilter = struct {
    /// Target peak level (0.0 to 1.0)
    target_peak: f32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, target_peak: f32) Self {
        return .{
            .target_peak = @max(0.01, @min(1.0, target_peak)),
            .allocator = allocator,
        };
    }

    /// Analyze peak level of an audio frame (returns 0.0 to 1.0 for float, or max sample ratio for int)
    pub fn analyzePeak(input: *const AudioFrame) f32 {
        if (input.data[0] == null) return 0;
        const src = input.data[0].?;

        var max_sample: f32 = 0;

        switch (input.format) {
            .s16le, .s16be => {
                const samples = src.len / 2;
                for (0..samples) |i| {
                    const sample = @as(i16, @bitCast([2]u8{ src[i * 2], src[i * 2 + 1] }));
                    const normalized = @abs(@as(f32, @floatFromInt(sample))) / 32768.0;
                    max_sample = @max(max_sample, normalized);
                }
            },
            .f32le, .f32be => {
                const samples = src.len / 4;
                for (0..samples) |i| {
                    const offset = i * 4;
                    const sample = @as(f32, @bitCast([4]u8{
                        src[offset],
                        src[offset + 1],
                        src[offset + 2],
                        src[offset + 3],
                    }));
                    max_sample = @max(max_sample, @abs(sample));
                }
            },
            else => {},
        }

        return max_sample;
    }

    /// Apply normalization to an audio frame
    pub fn apply(self: *const Self, input: *const AudioFrame) !AudioFrame {
        const peak = analyzePeak(input);

        if (peak == 0) {
            return try input.clone(self.allocator);
        }

        const gain = self.target_peak / peak;
        const volume = VolumeFilter.init(self.allocator, gain);
        return try volume.apply(input);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "VolumeFilter initialization" {
    const allocator = std.testing.allocator;
    const filter = VolumeFilter.init(allocator, 0.5);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), filter.gain, 0.001);
}

test "VolumeFilter from dB" {
    const allocator = std.testing.allocator;

    // 0 dB = gain of 1.0
    const filter0 = VolumeFilter.fromDb(allocator, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), filter0.gain, 0.001);

    // -6 dB ≈ gain of 0.5
    const filter_6 = VolumeFilter.fromDb(allocator, -6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), filter_6.gain, 0.02);

    // +6 dB ≈ gain of 2.0
    const filter6 = VolumeFilter.fromDb(allocator, 6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), filter6.gain, 0.02);
}

test "VolumeFilter getDb" {
    const allocator = std.testing.allocator;

    const filter = VolumeFilter.init(allocator, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -6.02), filter.getDb(), 0.1);
}

test "NormalizeFilter initialization" {
    const allocator = std.testing.allocator;
    const filter = NormalizeFilter.init(allocator, 0.9);

    try std.testing.expectApproxEqAbs(@as(f32, 0.9), filter.target_peak, 0.001);
}

test "NormalizeFilter clamping" {
    const allocator = std.testing.allocator;

    // Should clamp to valid range
    const filter_high = NormalizeFilter.init(allocator, 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), filter_high.target_peak, 0.001);

    const filter_low = NormalizeFilter.init(allocator, -1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.01), filter_low.target_peak, 0.001);
}
