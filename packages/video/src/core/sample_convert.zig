// Home Video Library - Audio Sample Format Conversion
// Convert between PCM sample formats and resample audio

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Sample Formats
// ============================================================================

pub const SampleFormat = enum {
    u8, // Unsigned 8-bit (center = 128)
    s16, // Signed 16-bit little-endian
    s24, // Signed 24-bit little-endian (packed)
    s32, // Signed 32-bit little-endian
    f32, // 32-bit float (-1.0 to 1.0)
    f64, // 64-bit float (-1.0 to 1.0)

    /// Get bytes per sample for this format
    pub fn bytesPerSample(self: SampleFormat) usize {
        return switch (self) {
            .u8 => 1,
            .s16 => 2,
            .s24 => 3,
            .s32 => 4,
            .f32 => 4,
            .f64 => 8,
        };
    }

    /// Get bit depth for this format
    pub fn bitDepth(self: SampleFormat) u8 {
        return switch (self) {
            .u8 => 8,
            .s16 => 16,
            .s24 => 24,
            .s32 => 32,
            .f32 => 32,
            .f64 => 64,
        };
    }

    /// Check if format is floating point
    pub fn isFloat(self: SampleFormat) bool {
        return self == .f32 or self == .f64;
    }
};

// ============================================================================
// Sample Conversion
// ============================================================================

/// Convert audio samples from one format to another
pub fn convertSamples(
    input: []const u8,
    input_format: SampleFormat,
    output_format: SampleFormat,
    allocator: Allocator,
) ![]u8 {
    const sample_count = input.len / input_format.bytesPerSample();
    const output_size = sample_count * output_format.bytesPerSample();
    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        // Read sample as normalized float
        const sample = readSampleNormalized(input, input_format, i);

        // Write sample in output format
        writeSampleNormalized(output, output_format, i, sample);
    }

    return output;
}

/// Read a sample as normalized float (-1.0 to 1.0)
pub fn readSampleNormalized(data: []const u8, format: SampleFormat, index: usize) f64 {
    const offset = index * format.bytesPerSample();

    return switch (format) {
        .u8 => {
            const sample = data[offset];
            return (@as(f64, @floatFromInt(sample)) - 128.0) / 128.0;
        },
        .s16 => {
            const sample = std.mem.readInt(i16, data[offset..][0..2], .little);
            return @as(f64, @floatFromInt(sample)) / 32768.0;
        },
        .s24 => {
            // 24-bit packed: read 3 bytes, sign-extend to i32
            const b0: u32 = data[offset];
            const b1: u32 = data[offset + 1];
            const b2: u32 = data[offset + 2];
            var raw: i32 = @intCast((b2 << 16) | (b1 << 8) | b0);
            if (raw >= 0x800000) {
                raw -= 0x1000000;
            }
            return @as(f64, @floatFromInt(raw)) / 8388608.0;
        },
        .s32 => {
            const sample = std.mem.readInt(i32, data[offset..][0..4], .little);
            return @as(f64, @floatFromInt(sample)) / 2147483648.0;
        },
        .f32 => {
            const bits = std.mem.readInt(u32, data[offset..][0..4], .little);
            return @floatCast(@as(f32, @bitCast(bits)));
        },
        .f64 => {
            const bits = std.mem.readInt(u64, data[offset..][0..8], .little);
            return @bitCast(bits);
        },
    };
}

/// Write a normalized float sample to buffer
pub fn writeSampleNormalized(data: []u8, format: SampleFormat, index: usize, sample: f64) void {
    const offset = index * format.bytesPerSample();

    // Clamp to valid range
    const clamped = std.math.clamp(sample, -1.0, 1.0);

    switch (format) {
        .u8 => {
            const value: u8 = @intFromFloat(clamped * 127.0 + 128.0);
            data[offset] = value;
        },
        .s16 => {
            const value: i16 = @intFromFloat(clamped * 32767.0);
            std.mem.writeInt(i16, data[offset..][0..2], value, .little);
        },
        .s24 => {
            const value: i32 = @intFromFloat(clamped * 8388607.0);
            const unsigned: u32 = @bitCast(value);
            data[offset] = @truncate(unsigned & 0xFF);
            data[offset + 1] = @truncate((unsigned >> 8) & 0xFF);
            data[offset + 2] = @truncate((unsigned >> 16) & 0xFF);
        },
        .s32 => {
            const value: i32 = @intFromFloat(clamped * 2147483647.0);
            std.mem.writeInt(i32, data[offset..][0..4], value, .little);
        },
        .f32 => {
            const value: f32 = @floatCast(clamped);
            const bits: u32 = @bitCast(value);
            std.mem.writeInt(u32, data[offset..][0..4], bits, .little);
        },
        .f64 => {
            const bits: u64 = @bitCast(clamped);
            std.mem.writeInt(u64, data[offset..][0..8], bits, .little);
        },
    }
}

// ============================================================================
// Channel Conversion
// ============================================================================

pub const ChannelLayout = enum {
    mono,
    stereo,
    surround_5_1,
    surround_7_1,

    pub fn channelCount(self: ChannelLayout) u8 {
        return switch (self) {
            .mono => 1,
            .stereo => 2,
            .surround_5_1 => 6,
            .surround_7_1 => 8,
        };
    }
};

/// Convert between channel layouts
pub fn convertChannels(
    input: []const u8,
    input_layout: ChannelLayout,
    output_layout: ChannelLayout,
    format: SampleFormat,
    allocator: Allocator,
) ![]u8 {
    const input_channels = input_layout.channelCount();
    const output_channels = output_layout.channelCount();
    const bytes_per_sample = format.bytesPerSample();

    const frame_count = input.len / (input_channels * bytes_per_sample);
    const output_size = frame_count * output_channels * bytes_per_sample;
    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    var frame: usize = 0;
    while (frame < frame_count) : (frame += 1) {
        // Read input samples for this frame
        var samples: [8]f64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var ch: usize = 0;
        while (ch < input_channels) : (ch += 1) {
            const idx = frame * input_channels + ch;
            samples[ch] = readSampleNormalized(input, format, idx);
        }

        // Mix to output channels
        var out_samples: [8]f64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        mixChannels(&samples, input_layout, &out_samples, output_layout);

        // Write output samples
        ch = 0;
        while (ch < output_channels) : (ch += 1) {
            const idx = frame * output_channels + ch;
            writeSampleNormalized(output, format, idx, out_samples[ch]);
        }
    }

    return output;
}

fn mixChannels(
    input: *const [8]f64,
    input_layout: ChannelLayout,
    output: *[8]f64,
    output_layout: ChannelLayout,
) void {
    switch (input_layout) {
        .mono => {
            switch (output_layout) {
                .mono => {
                    output[0] = input[0];
                },
                .stereo => {
                    // Mono to stereo: duplicate to both channels
                    output[0] = input[0];
                    output[1] = input[0];
                },
                .surround_5_1 => {
                    // Mono to 5.1: center channel only
                    output[0] = 0; // L
                    output[1] = 0; // R
                    output[2] = input[0]; // C
                    output[3] = 0; // LFE
                    output[4] = 0; // Ls
                    output[5] = 0; // Rs
                },
                .surround_7_1 => {
                    output[0] = 0; // L
                    output[1] = 0; // R
                    output[2] = input[0]; // C
                    output[3] = 0; // LFE
                    output[4] = 0; // Ls
                    output[5] = 0; // Rs
                    output[6] = 0; // Lb
                    output[7] = 0; // Rb
                },
            }
        },
        .stereo => {
            switch (output_layout) {
                .mono => {
                    // Stereo to mono: average L and R
                    output[0] = (input[0] + input[1]) * 0.5;
                },
                .stereo => {
                    output[0] = input[0];
                    output[1] = input[1];
                },
                .surround_5_1 => {
                    output[0] = input[0]; // L
                    output[1] = input[1]; // R
                    output[2] = (input[0] + input[1]) * 0.5; // C (mix)
                    output[3] = 0; // LFE
                    output[4] = 0; // Ls
                    output[5] = 0; // Rs
                },
                .surround_7_1 => {
                    output[0] = input[0]; // L
                    output[1] = input[1]; // R
                    output[2] = (input[0] + input[1]) * 0.5; // C
                    output[3] = 0; // LFE
                    output[4] = 0; // Ls
                    output[5] = 0; // Rs
                    output[6] = 0; // Lb
                    output[7] = 0; // Rb
                },
            }
        },
        .surround_5_1 => {
            switch (output_layout) {
                .mono => {
                    // 5.1 to mono: mix all channels with proper weights
                    output[0] = input[2] + // Center
                        (input[0] + input[1]) * 0.707 + // L + R
                        (input[4] + input[5]) * 0.5; // Surround
                },
                .stereo => {
                    // 5.1 to stereo: standard downmix
                    output[0] = input[0] + input[2] * 0.707 + input[4] * 0.707; // L
                    output[1] = input[1] + input[2] * 0.707 + input[5] * 0.707; // R
                },
                .surround_5_1 => {
                    var i: usize = 0;
                    while (i < 6) : (i += 1) {
                        output[i] = input[i];
                    }
                },
                .surround_7_1 => {
                    var i: usize = 0;
                    while (i < 6) : (i += 1) {
                        output[i] = input[i];
                    }
                    output[6] = 0;
                    output[7] = 0;
                },
            }
        },
        .surround_7_1 => {
            switch (output_layout) {
                .mono => {
                    output[0] = input[2] + // Center
                        (input[0] + input[1]) * 0.707 + // L + R
                        (input[4] + input[5]) * 0.5 + // Side surround
                        (input[6] + input[7]) * 0.35; // Back surround
                },
                .stereo => {
                    output[0] = input[0] + input[2] * 0.707 + input[4] * 0.707 + input[6] * 0.5;
                    output[1] = input[1] + input[2] * 0.707 + input[5] * 0.707 + input[7] * 0.5;
                },
                .surround_5_1 => {
                    var i: usize = 0;
                    while (i < 4) : (i += 1) {
                        output[i] = input[i];
                    }
                    // Mix back channels into side surround
                    output[4] = input[4] + input[6] * 0.707;
                    output[5] = input[5] + input[7] * 0.707;
                },
                .surround_7_1 => {
                    var i: usize = 0;
                    while (i < 8) : (i += 1) {
                        output[i] = input[i];
                    }
                },
            }
        },
    }
}

// ============================================================================
// Sample Rate Conversion (Linear Interpolation)
// ============================================================================

/// Resample audio using linear interpolation
/// For production use, consider implementing sinc interpolation
pub fn resample(
    input: []const u8,
    input_rate: u32,
    output_rate: u32,
    format: SampleFormat,
    channels: u8,
    allocator: Allocator,
) ![]u8 {
    if (input_rate == output_rate) {
        // No resampling needed, just copy
        const output = try allocator.alloc(u8, input.len);
        @memcpy(output, input);
        return output;
    }

    const bytes_per_sample = format.bytesPerSample();
    const input_frames = input.len / (channels * bytes_per_sample);
    const output_frames = @as(usize, @intFromFloat(
        @as(f64, @floatFromInt(input_frames)) * @as(f64, @floatFromInt(output_rate)) / @as(f64, @floatFromInt(input_rate)),
    ));

    const output_size = output_frames * channels * bytes_per_sample;
    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    const ratio = @as(f64, @floatFromInt(input_rate)) / @as(f64, @floatFromInt(output_rate));

    var out_frame: usize = 0;
    while (out_frame < output_frames) : (out_frame += 1) {
        const in_pos = @as(f64, @floatFromInt(out_frame)) * ratio;
        const in_frame = @as(usize, @intFromFloat(in_pos));
        const frac = in_pos - @as(f64, @floatFromInt(in_frame));

        var ch: usize = 0;
        while (ch < channels) : (ch += 1) {
            // Linear interpolation between samples
            const idx0 = in_frame * channels + ch;
            const idx1 = @min((in_frame + 1) * channels + ch, (input_frames - 1) * channels + ch);

            const s0 = readSampleNormalized(input, format, idx0);
            const s1 = readSampleNormalized(input, format, idx1);
            const interpolated = s0 + (s1 - s0) * frac;

            const out_idx = out_frame * channels + ch;
            writeSampleNormalized(output, format, out_idx, interpolated);
        }
    }

    return output;
}

// ============================================================================
// Audio Level Adjustment
// ============================================================================

/// Apply gain to audio samples (in dB)
pub fn applyGain(
    data: []u8,
    format: SampleFormat,
    gain_db: f64,
) void {
    const gain = std.math.pow(f64, 10.0, gain_db / 20.0);
    const sample_count = data.len / format.bytesPerSample();

    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const sample = readSampleNormalized(data, format, i);
        writeSampleNormalized(data, format, i, sample * gain);
    }
}

/// Normalize audio to peak level
pub fn normalize(
    data: []u8,
    format: SampleFormat,
    target_peak: f64, // e.g., 0.95 for -0.5dB headroom
) void {
    const sample_count = data.len / format.bytesPerSample();

    // Find peak
    var peak: f64 = 0.0;
    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const sample = @abs(readSampleNormalized(data, format, i));
        if (sample > peak) {
            peak = sample;
        }
    }

    if (peak > 0.0001) {
        const gain = target_peak / peak;
        i = 0;
        while (i < sample_count) : (i += 1) {
            const sample = readSampleNormalized(data, format, i);
            writeSampleNormalized(data, format, i, sample * gain);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Sample format properties" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 1), SampleFormat.u8.bytesPerSample());
    try testing.expectEqual(@as(usize, 2), SampleFormat.s16.bytesPerSample());
    try testing.expectEqual(@as(usize, 3), SampleFormat.s24.bytesPerSample());
    try testing.expectEqual(@as(usize, 4), SampleFormat.s32.bytesPerSample());
    try testing.expectEqual(@as(usize, 4), SampleFormat.f32.bytesPerSample());
    try testing.expectEqual(@as(usize, 8), SampleFormat.f64.bytesPerSample());

    try testing.expect(!SampleFormat.s16.isFloat());
    try testing.expect(SampleFormat.f32.isFloat());
}

test "u8 sample conversion" {
    const testing = std.testing;

    // Center value (128) should be ~0.0
    const center = [_]u8{128};
    const normalized = readSampleNormalized(&center, .u8, 0);
    try testing.expect(@abs(normalized) < 0.01);

    // Max value (255) should be ~1.0
    const max = [_]u8{255};
    const max_norm = readSampleNormalized(&max, .u8, 0);
    try testing.expect(max_norm > 0.99);

    // Min value (0) should be ~-1.0
    const min = [_]u8{0};
    const min_norm = readSampleNormalized(&min, .u8, 0);
    try testing.expect(min_norm < -0.99);
}

test "s16 sample conversion" {
    const testing = std.testing;

    // Zero
    var zero: [2]u8 = undefined;
    std.mem.writeInt(i16, &zero, 0, .little);
    const zero_norm = readSampleNormalized(&zero, .s16, 0);
    try testing.expect(@abs(zero_norm) < 0.0001);

    // Max
    var max: [2]u8 = undefined;
    std.mem.writeInt(i16, &max, 32767, .little);
    const max_norm = readSampleNormalized(&max, .s16, 0);
    try testing.expect(max_norm > 0.99);
}

test "Format conversion roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create s16 samples
    var input: [4]u8 = undefined;
    std.mem.writeInt(i16, input[0..2], 16384, .little); // ~0.5
    std.mem.writeInt(i16, input[2..4], -16384, .little); // ~-0.5

    // Convert to f32
    const f32_data = try convertSamples(&input, .s16, .f32, allocator);
    defer allocator.free(f32_data);

    try testing.expectEqual(@as(usize, 8), f32_data.len);

    // Convert back to s16
    const back = try convertSamples(f32_data, .f32, .s16, allocator);
    defer allocator.free(back);

    // Should be close to original
    const orig0 = std.mem.readInt(i16, input[0..2], .little);
    const back0 = std.mem.readInt(i16, back[0..2], .little);
    try testing.expect(@abs(orig0 - back0) < 10);
}

test "Channel layout" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 1), ChannelLayout.mono.channelCount());
    try testing.expectEqual(@as(u8, 2), ChannelLayout.stereo.channelCount());
    try testing.expectEqual(@as(u8, 6), ChannelLayout.surround_5_1.channelCount());
    try testing.expectEqual(@as(u8, 8), ChannelLayout.surround_7_1.channelCount());
}
