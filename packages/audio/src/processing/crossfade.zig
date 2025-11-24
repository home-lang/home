// Home Audio Library - Audio Crossfade Utilities
// Crossfade curves and utilities for seamless audio transitions

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Crossfade curve type
pub const CrossfadeCurve = enum {
    linear, // Simple linear fade
    equal_power, // Constant power (smooth)
    s_curve, // Smooth S-curve
    logarithmic, // Logarithmic curve
    exponential, // Exponential curve
    cosine, // Cosine-based

    /// Calculate fade value for position (0.0 to 1.0)
    pub fn apply(self: CrossfadeCurve, position: f32) struct { out_level: f32, in_level: f32 } {
        const p = std.math.clamp(position, 0.0, 1.0);

        return switch (self) {
            .linear => .{
                .out_level = 1.0 - p,
                .in_level = p,
            },
            .equal_power => .{
                // -3dB at crossover point
                .out_level = @cos(p * math.pi / 2.0),
                .in_level = @sin(p * math.pi / 2.0),
            },
            .s_curve => blk: {
                // Smoother than linear, uses smoothstep
                const s = p * p * (3.0 - 2.0 * p);
                break :blk .{
                    .out_level = 1.0 - s,
                    .in_level = s,
                };
            },
            .logarithmic => blk: {
                // Better for perceived loudness
                const out = if (p < 1.0) -@log10(1.0 - p * 0.99) / 2.0 else 1.0;
                const in = if (p > 0.0) -@log10(1.0 - (1.0 - p) * 0.99) / 2.0 else 0.0;
                break :blk .{
                    .out_level = 1.0 - std.math.clamp(out, 0.0, 1.0),
                    .in_level = std.math.clamp(in, 0.0, 1.0),
                };
            },
            .exponential => blk: {
                const exp_p = (math.pow(f32, 10.0, p) - 1.0) / 9.0;
                const exp_1mp = (math.pow(f32, 10.0, 1.0 - p) - 1.0) / 9.0;
                break :blk .{
                    .out_level = exp_1mp,
                    .in_level = exp_p,
                };
            },
            .cosine => blk: {
                const cos_val = (1.0 - @cos(p * math.pi)) / 2.0;
                break :blk .{
                    .out_level = 1.0 - cos_val,
                    .in_level = cos_val,
                };
            },
        };
    }
};

/// Crossfade processor
pub const Crossfader = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,
    curve: CrossfadeCurve,
    duration_samples: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8) Self {
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .curve = .equal_power,
            .duration_samples = sample_rate, // Default 1 second
        };
    }

    /// Set crossfade duration in seconds
    pub fn setDuration(self: *Self, seconds: f32) void {
        self.duration_samples = @intFromFloat(@max(0.001, seconds) * @as(f32, @floatFromInt(self.sample_rate)));
    }

    /// Set crossfade duration in milliseconds
    pub fn setDurationMs(self: *Self, ms: f32) void {
        self.setDuration(ms / 1000.0);
    }

    /// Set crossfade curve
    pub fn setCurve(self: *Self, curve: CrossfadeCurve) void {
        self.curve = curve;
    }

    /// Crossfade between two audio buffers
    /// Returns a new buffer containing the crossfade region
    pub fn crossfade(self: *Self, outgoing: []const f32, incoming: []const f32) ![]f32 {
        const fade_samples = self.duration_samples * self.channels;
        const out_len = @min(outgoing.len, fade_samples);
        const in_len = @min(incoming.len, fade_samples);
        const result_len = @max(out_len, in_len);

        var result = try self.allocator.alloc(f32, result_len);

        for (0..result_len) |i| {
            const frame = i / self.channels;
            const position = @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(self.duration_samples));
            const levels = self.curve.apply(position);

            var out_sample: f32 = 0;
            var in_sample: f32 = 0;

            if (i < out_len) {
                out_sample = outgoing[outgoing.len - out_len + i];
            }
            if (i < in_len) {
                in_sample = incoming[i];
            }

            result[i] = out_sample * levels.out_level + in_sample * levels.in_level;
        }

        return result;
    }

    /// Apply fade-in to buffer (in-place)
    pub fn fadeIn(self: *Self, buffer: []f32) void {
        const fade_samples = @min(self.duration_samples * self.channels, buffer.len);

        for (0..fade_samples) |i| {
            const frame = i / self.channels;
            const position = @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(self.duration_samples));
            const levels = self.curve.apply(position);
            buffer[i] *= levels.in_level;
        }
    }

    /// Apply fade-out to buffer (in-place)
    pub fn fadeOut(self: *Self, buffer: []f32) void {
        const fade_samples = @min(self.duration_samples * self.channels, buffer.len);
        const start_idx = buffer.len - fade_samples;

        for (0..fade_samples) |i| {
            const frame = i / self.channels;
            const position = @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(self.duration_samples));
            const levels = self.curve.apply(position);
            buffer[start_idx + i] *= levels.out_level;
        }
    }

    /// Create crossfade between two full tracks
    pub fn crossfadeTracks(
        self: *Self,
        track_a: []const f32,
        track_b: []const f32,
    ) ![]f32 {
        const fade_samples = self.duration_samples * self.channels;

        // Total length: track_a (minus fade) + crossfade region + track_b (minus fade)
        const a_non_fade = if (track_a.len > fade_samples) track_a.len - fade_samples else 0;
        const b_non_fade = if (track_b.len > fade_samples) track_b.len - fade_samples else 0;
        const total_len = a_non_fade + fade_samples + b_non_fade;

        var result = try self.allocator.alloc(f32, total_len);

        // Copy track A (before fade)
        if (a_non_fade > 0) {
            @memcpy(result[0..a_non_fade], track_a[0..a_non_fade]);
        }

        // Crossfade region
        const fade_region = try self.crossfade(
            track_a[a_non_fade..],
            track_b[0..@min(fade_samples, track_b.len)],
        );
        defer self.allocator.free(fade_region);
        @memcpy(result[a_non_fade .. a_non_fade + fade_region.len], fade_region);

        // Copy track B (after fade)
        if (b_non_fade > 0 and track_b.len > fade_samples) {
            @memcpy(result[a_non_fade + fade_samples ..], track_b[fade_samples..]);
        }

        return result;
    }
};

/// Auto-crossfade detector
/// Finds optimal crossfade points based on audio content
pub const CrossfadeDetector = struct {
    sample_rate: u32,
    channels: u8,
    window_size: usize,

    const Self = @This();

    pub fn init(sample_rate: u32, channels: u8) Self {
        return Self{
            .sample_rate = sample_rate,
            .channels = channels,
            .window_size = sample_rate / 10, // 100ms windows
        };
    }

    /// Find optimal fade-out point in outgoing track
    /// Returns sample index where fade should start
    pub fn findFadeOutPoint(self: *Self, samples: []const f32) usize {
        // Look for low-energy region near the end
        const search_region = @min(samples.len, self.sample_rate * self.channels * 5); // Last 5 seconds
        const start_search = samples.len - search_region;

        var min_energy: f32 = std.math.floatMax(f32);
        var best_pos: usize = samples.len - self.window_size * self.channels;

        var pos = start_search;
        while (pos + self.window_size * self.channels <= samples.len) : (pos += self.window_size * self.channels / 4) {
            const energy = self.calculateEnergy(samples[pos .. pos + self.window_size * self.channels]);

            if (energy < min_energy) {
                min_energy = energy;
                best_pos = pos;
            }
        }

        return best_pos;
    }

    /// Find optimal fade-in point in incoming track
    /// Returns sample index where the actual content starts
    pub fn findFadeInPoint(self: *Self, samples: []const f32) usize {
        // Look for where energy increases
        const search_region = @min(samples.len, self.sample_rate * self.channels * 5);

        var pos: usize = 0;
        while (pos + self.window_size * self.channels <= search_region) : (pos += self.window_size * self.channels / 4) {
            const energy = self.calculateEnergy(samples[pos .. pos + self.window_size * self.channels]);

            if (energy > 0.01) { // Threshold
                return if (pos > self.window_size * self.channels)
                    pos - self.window_size * self.channels
                else
                    0;
            }
        }

        return 0;
    }

    fn calculateEnergy(self: *Self, window: []const f32) f32 {
        _ = self;
        var sum: f32 = 0;
        for (window) |s| {
            sum += s * s;
        }
        return sum / @as(f32, @floatFromInt(window.len));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CrossfadeCurve equal_power" {
    const result = CrossfadeCurve.equal_power.apply(0.5);

    // At midpoint, both should be approximately equal and sum to ~1
    try std.testing.expectApproxEqAbs(result.out_level, result.in_level, 0.01);
}

test "CrossfadeCurve linear" {
    const start = CrossfadeCurve.linear.apply(0.0);
    const mid = CrossfadeCurve.linear.apply(0.5);
    const end = CrossfadeCurve.linear.apply(1.0);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), start.out_level, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), start.in_level, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.out_level, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid.in_level, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), end.out_level, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), end.in_level, 0.001);
}

test "Crossfader basic" {
    const allocator = std.testing.allocator;

    var fader = Crossfader.init(allocator, 44100, 1);
    fader.setDurationMs(100);
    fader.setCurve(.equal_power);

    const out = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const in = [_]f32{ 0.5, 0.5, 0.5, 0.5 };

    const result = try fader.crossfade(&out, &in);
    defer allocator.free(result);

    try std.testing.expect(result.len > 0);
}

test "Crossfader fadeIn" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var fader = Crossfader.init(std.testing.allocator, 44100, 1);
    fader.setDurationMs(10);

    var buffer = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    fader.fadeIn(&buffer);

    // First sample should be attenuated
    try std.testing.expect(buffer[0] < 1.0);
}

test "CrossfadeDetector init" {
    var detector = CrossfadeDetector.init(44100, 2);
    try std.testing.expect(detector.window_size > 0);
}
