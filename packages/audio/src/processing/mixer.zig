// Home Audio Library - Audio Mixer
// Utilities for mixing and manipulating audio channels

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const frame = @import("../core/frame.zig");
const AudioFrame = frame.AudioFrame;
const AudioBuffer = frame.AudioBuffer;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;
const ChannelLayout = types.ChannelLayout;

/// Pan law for stereo panning
pub const PanLaw = enum {
    /// Linear panning (-3dB center)
    linear,
    /// Constant power (-3dB center, maintains perceived loudness)
    constant_power,
    /// -4.5dB center (compromise between linear and constant power)
    balanced,

    pub fn getGains(self: PanLaw, pan: f32) struct { left: f32, right: f32 } {
        // pan: -1.0 = full left, 0.0 = center, 1.0 = full right
        const clamped = math.clamp(pan, -1.0, 1.0);
        const normalized = (clamped + 1.0) / 2.0; // 0.0 to 1.0

        return switch (self) {
            .linear => .{
                .left = 1.0 - normalized,
                .right = normalized,
            },
            .constant_power => .{
                .left = @cos(normalized * math.pi / 2.0),
                .right = @sin(normalized * math.pi / 2.0),
            },
            .balanced => .{
                .left = @sqrt((1.0 - normalized) * (1.0 - normalized * 0.5)),
                .right = @sqrt(normalized * (1.0 - (1.0 - normalized) * 0.5)),
            },
        };
    }
};

/// Audio mixer for combining multiple audio sources
pub const Mixer = struct {
    allocator: Allocator,
    channels: u8,
    sample_rate: u32,

    // Mixing state
    master_volume: f32,
    channel_volumes: []f32,
    channel_pans: []f32,
    channel_mutes: []bool,
    channel_solos: []bool,

    // Internal buffer
    mix_buffer: []f32,
    buffer_size: usize,

    const Self = @This();

    /// Maximum number of input channels/tracks
    pub const MAX_TRACKS = 32;

    /// Initialize mixer
    pub fn init(
        allocator: Allocator,
        output_channels: u8,
        sample_rate: u32,
        buffer_size: usize,
    ) !Self {
        const channel_volumes = try allocator.alloc(f32, MAX_TRACKS);
        @memset(channel_volumes, 1.0);

        const channel_pans = try allocator.alloc(f32, MAX_TRACKS);
        @memset(channel_pans, 0.0);

        const channel_mutes = try allocator.alloc(bool, MAX_TRACKS);
        @memset(channel_mutes, false);

        const channel_solos = try allocator.alloc(bool, MAX_TRACKS);
        @memset(channel_solos, false);

        const mix_buffer = try allocator.alloc(f32, buffer_size * output_channels);
        @memset(mix_buffer, 0);

        return Self{
            .allocator = allocator,
            .channels = output_channels,
            .sample_rate = sample_rate,
            .master_volume = 1.0,
            .channel_volumes = channel_volumes,
            .channel_pans = channel_pans,
            .channel_mutes = channel_mutes,
            .channel_solos = channel_solos,
            .mix_buffer = mix_buffer,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.channel_volumes);
        self.allocator.free(self.channel_pans);
        self.allocator.free(self.channel_mutes);
        self.allocator.free(self.channel_solos);
        self.allocator.free(self.mix_buffer);
    }

    /// Set master volume (0.0 to 1.0+)
    pub fn setMasterVolume(self: *Self, volume: f32) void {
        self.master_volume = @max(0.0, volume);
    }

    /// Set track volume
    pub fn setTrackVolume(self: *Self, track: usize, volume: f32) void {
        if (track < MAX_TRACKS) {
            self.channel_volumes[track] = @max(0.0, volume);
        }
    }

    /// Set track pan (-1.0 left, 0.0 center, 1.0 right)
    pub fn setTrackPan(self: *Self, track: usize, pan: f32) void {
        if (track < MAX_TRACKS) {
            self.channel_pans[track] = math.clamp(pan, -1.0, 1.0);
        }
    }

    /// Mute/unmute track
    pub fn setTrackMute(self: *Self, track: usize, muted: bool) void {
        if (track < MAX_TRACKS) {
            self.channel_mutes[track] = muted;
        }
    }

    /// Solo track
    pub fn setTrackSolo(self: *Self, track: usize, soloed: bool) void {
        if (track < MAX_TRACKS) {
            self.channel_solos[track] = soloed;
        }
    }

    /// Check if any track is soloed
    fn hasAnySolo(self: *const Self) bool {
        for (self.channel_solos[0..MAX_TRACKS]) |solo| {
            if (solo) return true;
        }
        return false;
    }

    /// Check if track should play (considering mute/solo)
    fn shouldPlay(self: *const Self, track: usize) bool {
        if (self.channel_mutes[track]) return false;
        if (self.hasAnySolo() and !self.channel_solos[track]) return false;
        return true;
    }

    /// Clear mix buffer
    pub fn clear(self: *Self) void {
        @memset(self.mix_buffer, 0);
    }

    /// Add mono audio to mix
    pub fn addMono(self: *Self, track: usize, input: []const f32, pan_law: PanLaw) void {
        if (!self.shouldPlay(track)) return;

        const volume = self.channel_volumes[track];
        const gains = pan_law.getGains(self.channel_pans[track]);
        const samples = @min(input.len, self.buffer_size);

        if (self.channels == 1) {
            // Mono output
            for (0..samples) |i| {
                self.mix_buffer[i] += input[i] * volume;
            }
        } else if (self.channels >= 2) {
            // Stereo or surround output
            for (0..samples) |i| {
                self.mix_buffer[i * self.channels + 0] += input[i] * volume * gains.left;
                self.mix_buffer[i * self.channels + 1] += input[i] * volume * gains.right;
            }
        }
    }

    /// Add stereo audio to mix
    pub fn addStereo(self: *Self, track: usize, input: []const f32, pan_law: PanLaw) void {
        if (!self.shouldPlay(track)) return;

        const volume = self.channel_volumes[track];
        const gains = pan_law.getGains(self.channel_pans[track]);
        const samples = @min(input.len / 2, self.buffer_size);

        if (self.channels == 1) {
            // Mix to mono
            for (0..samples) |i| {
                const left = input[i * 2];
                const right = input[i * 2 + 1];
                self.mix_buffer[i] += (left + right) * 0.5 * volume;
            }
        } else if (self.channels >= 2) {
            // Apply pan to stereo
            for (0..samples) |i| {
                const left = input[i * 2];
                const right = input[i * 2 + 1];

                // Cross-feed based on pan
                const out_left = left * gains.left + right * (1.0 - gains.right) * 0.5;
                const out_right = right * gains.right + left * (1.0 - gains.left) * 0.5;

                self.mix_buffer[i * self.channels + 0] += out_left * volume;
                self.mix_buffer[i * self.channels + 1] += out_right * volume;
            }
        }
    }

    /// Get mixed output (applies master volume and clipping)
    pub fn getOutput(self: *Self, output: []f32, soft_clip: bool) void {
        const samples = @min(output.len, self.mix_buffer.len);

        for (0..samples) |i| {
            var sample = self.mix_buffer[i] * self.master_volume;

            if (soft_clip) {
                // Soft clipping using tanh
                sample = @as(f32, @floatCast(math.tanh(@as(f64, sample))));
            } else {
                // Hard clipping
                sample = math.clamp(sample, -1.0, 1.0);
            }

            output[i] = sample;
        }
    }

    /// Get peak level of output (for metering)
    pub fn getPeakLevel(self: *const Self) f32 {
        var peak: f32 = 0;
        for (self.mix_buffer) |sample| {
            peak = @max(peak, @abs(sample * self.master_volume));
        }
        return peak;
    }

    /// Get RMS level of output (for metering)
    pub fn getRmsLevel(self: *const Self) f32 {
        if (self.mix_buffer.len == 0) return 0;

        var sum: f64 = 0;
        for (self.mix_buffer) |sample| {
            const s = @as(f64, sample * self.master_volume);
            sum += s * s;
        }
        return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(self.mix_buffer.len))));
    }
};

/// Mix two audio buffers together
pub fn mix(a: []const f32, b: []const f32, output: []f32, volume_a: f32, volume_b: f32) void {
    const len = @min(@min(a.len, b.len), output.len);
    for (0..len) |i| {
        output[i] = a[i] * volume_a + b[i] * volume_b;
    }
}

/// Mix audio with clipping protection
pub fn mixWithClipping(a: []const f32, b: []const f32, output: []f32, volume_a: f32, volume_b: f32) void {
    const len = @min(@min(a.len, b.len), output.len);
    for (0..len) |i| {
        output[i] = math.clamp(a[i] * volume_a + b[i] * volume_b, -1.0, 1.0);
    }
}

/// Convert mono to stereo
pub fn monoToStereo(allocator: Allocator, mono: []const f32) ![]f32 {
    const stereo = try allocator.alloc(f32, mono.len * 2);
    for (0..mono.len) |i| {
        stereo[i * 2] = mono[i];
        stereo[i * 2 + 1] = mono[i];
    }
    return stereo;
}

/// Convert stereo to mono (average)
pub fn stereoToMono(allocator: Allocator, stereo: []const f32) ![]f32 {
    const mono = try allocator.alloc(f32, stereo.len / 2);
    for (0..mono.len) |i| {
        mono[i] = (stereo[i * 2] + stereo[i * 2 + 1]) * 0.5;
    }
    return mono;
}

/// Apply gain to audio
pub fn applyGain(audio: []f32, gain: f32) void {
    for (audio) |*sample| {
        sample.* *= gain;
    }
}

/// Apply gain with soft clipping
pub fn applyGainSoftClip(audio: []f32, gain: f32) void {
    for (audio) |*sample| {
        sample.* = @floatCast(math.tanh(@as(f64, sample.* * gain)));
    }
}

/// Normalize audio to peak level
pub fn normalize(audio: []f32, target_peak: f32) void {
    var peak: f32 = 0;
    for (audio) |sample| {
        peak = @max(peak, @abs(sample));
    }

    if (peak > 0.00001) {
        const gain = target_peak / peak;
        applyGain(audio, gain);
    }
}

/// Crossfade between two audio buffers
pub fn crossfade(a: []const f32, b: []const f32, output: []f32, curve: CrossfadeCurve) void {
    const len = @min(@min(a.len, b.len), output.len);

    for (0..len) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(len));
        const gains = curve.getGains(t);
        output[i] = a[i] * gains.a + b[i] * gains.b;
    }
}

/// Crossfade curve types
pub const CrossfadeCurve = enum {
    /// Linear crossfade
    linear,
    /// Equal power crossfade (constant loudness)
    equal_power,
    /// S-curve (smooth)
    s_curve,

    pub fn getGains(self: CrossfadeCurve, t: f32) struct { a: f32, b: f32 } {
        return switch (self) {
            .linear => .{
                .a = 1.0 - t,
                .b = t,
            },
            .equal_power => .{
                .a = @cos(t * math.pi / 2.0),
                .b = @sin(t * math.pi / 2.0),
            },
            .s_curve => blk: {
                // Smoothstep
                const s = t * t * (3.0 - 2.0 * t);
                break :blk .{
                    .a = 1.0 - s,
                    .b = s,
                };
            },
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Mixer init/deinit" {
    const allocator = std.testing.allocator;

    var mixer = try Mixer.init(allocator, 2, 44100, 1024);
    defer mixer.deinit();

    try std.testing.expectEqual(@as(u8, 2), mixer.channels);
    try std.testing.expectEqual(@as(u32, 44100), mixer.sample_rate);
}

test "PanLaw gains" {
    // Center pan should give equal gains
    const linear = PanLaw.linear.getGains(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), linear.left, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), linear.right, 0.01);

    // Full left
    const left = PanLaw.linear.getGains(-1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), left.left, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), left.right, 0.01);
}

test "mix function" {
    const a = [_]f32{ 0.5, 0.5, 0.5 };
    const b = [_]f32{ 0.3, 0.3, 0.3 };
    var output: [3]f32 = undefined;

    mix(&a, &b, &output, 1.0, 1.0);

    try std.testing.expectApproxEqAbs(@as(f32, 0.8), output[0], 0.01);
}

test "normalize" {
    var audio = [_]f32{ 0.5, -0.25, 0.125 };
    normalize(&audio, 1.0);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), audio[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), audio[1], 0.01);
}

test "CrossfadeCurve" {
    // At t=0, should be all A
    const start = CrossfadeCurve.linear.getGains(0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), start.a, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), start.b, 0.01);

    // At t=1, should be all B
    const end = CrossfadeCurve.linear.getGains(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), end.a, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), end.b, 0.01);
}
