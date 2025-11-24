// Home Video Library - PCM Audio Codec
// Uncompressed audio encoding/decoding and format conversion

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");

pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const AudioFrame = frame.AudioFrame;
pub const VideoError = err.VideoError;

// ============================================================================
// PCM Decoder
// ============================================================================

pub const PcmDecoder = struct {
    /// Input format
    input_format: SampleFormat,

    /// Output format (usually f32le for processing)
    output_format: SampleFormat,

    /// Number of channels
    channels: u8,

    /// Sample rate
    sample_rate: u32,

    /// Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        input_format: SampleFormat,
        output_format: SampleFormat,
        channels: u8,
        sample_rate: u32,
    ) Self {
        return Self{
            .input_format = input_format,
            .output_format = output_format,
            .channels = channels,
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    /// Decode raw PCM data to audio frame
    pub fn decode(self: *Self, data: []const u8) !AudioFrame {
        const input_bps = self.input_format.bytesPerSample();
        const samples_per_channel = @as(u32, @intCast(data.len / (input_bps * self.channels)));

        var output = try AudioFrame.init(
            self.allocator,
            samples_per_channel,
            self.output_format,
            self.channels,
            self.sample_rate,
        );
        errdefer output.deinit();

        // Convert samples
        if (self.input_format == self.output_format) {
            // Direct copy
            @memcpy(output.data[0..data.len], data);
        } else {
            // Convert format
            try convertSamples(
                data,
                self.input_format,
                output.data,
                self.output_format,
                self.channels,
                samples_per_channel,
            );
        }

        return output;
    }

    /// Decode into existing frame
    pub fn decodeInto(self: *Self, data: []const u8, output: *AudioFrame) !void {
        if (output.channels != self.channels) return VideoError.InvalidChannelLayout;

        const input_bps = self.input_format.bytesPerSample();
        const samples = @as(u32, @intCast(data.len / (input_bps * self.channels)));

        if (samples > output.num_samples) return VideoError.BufferTooSmall;

        if (self.input_format == self.output_format) {
            @memcpy(output.data[0..data.len], data);
        } else {
            try convertSamples(
                data,
                self.input_format,
                output.data,
                self.output_format,
                self.channels,
                samples,
            );
        }
    }
};

// ============================================================================
// PCM Encoder
// ============================================================================

pub const PcmEncoder = struct {
    /// Input format
    input_format: SampleFormat,

    /// Output format
    output_format: SampleFormat,

    /// Number of channels
    channels: u8,

    /// Sample rate
    sample_rate: u32,

    /// Allocator
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        input_format: SampleFormat,
        output_format: SampleFormat,
        channels: u8,
        sample_rate: u32,
    ) Self {
        return Self{
            .input_format = input_format,
            .output_format = output_format,
            .channels = channels,
            .sample_rate = sample_rate,
            .allocator = allocator,
        };
    }

    /// Encode audio frame to raw PCM data
    pub fn encode(self: *Self, audio: *const AudioFrame) ![]u8 {
        const output_bps = self.output_format.bytesPerSample();
        const output_size = @as(usize, audio.num_samples) * @as(usize, self.channels) * @as(usize, output_bps);

        const output = try self.allocator.alloc(u8, output_size);
        errdefer self.allocator.free(output);

        if (audio.format == self.output_format) {
            @memcpy(output, audio.data[0..output_size]);
        } else {
            try convertSamples(
                audio.data,
                audio.format,
                output,
                self.output_format,
                self.channels,
                audio.num_samples,
            );
        }

        return output;
    }

    /// Encode into existing buffer
    pub fn encodeInto(self: *Self, audio: *const AudioFrame, output: []u8) !usize {
        const output_bps = self.output_format.bytesPerSample();
        const required_size = @as(usize, audio.num_samples) * @as(usize, self.channels) * @as(usize, output_bps);

        if (output.len < required_size) return VideoError.BufferTooSmall;

        if (audio.format == self.output_format) {
            @memcpy(output[0..required_size], audio.data[0..required_size]);
        } else {
            try convertSamples(
                audio.data,
                audio.format,
                output,
                self.output_format,
                self.channels,
                audio.num_samples,
            );
        }

        return required_size;
    }
};

// ============================================================================
// Sample Format Conversion
// ============================================================================

/// Convert samples from one format to another
pub fn convertSamples(
    input: []const u8,
    input_format: SampleFormat,
    output: []u8,
    output_format: SampleFormat,
    channels: u8,
    num_samples: u32,
) !void {
    const total_samples = @as(usize, num_samples) * @as(usize, channels);

    // Read input samples as f64 (maximum precision)
    // Then write to output format
    var i: usize = 0;
    while (i < total_samples) : (i += 1) {
        const sample = readSampleF64(input, input_format, i);
        writeSampleF64(output, output_format, i, sample);
    }
}

/// Read a single sample as f64 (-1.0 to 1.0)
fn readSampleF64(data: []const u8, format: SampleFormat, index: usize) f64 {
    const bps = format.bytesPerSample();
    const offset = index * bps;

    if (offset + bps > data.len) return 0.0;

    return switch (format) {
        .u8 => blk: {
            const val = data[offset];
            break :blk (@as(f64, @floatFromInt(val)) - 128.0) / 128.0;
        },
        .s8 => blk: {
            const val: i8 = @bitCast(data[offset]);
            break :blk @as(f64, @floatFromInt(val)) / 128.0;
        },
        .s16le, .s16p => blk: {
            const val = std.mem.readInt(i16, data[offset..][0..2], .little);
            break :blk @as(f64, @floatFromInt(val)) / 32768.0;
        },
        .s16be => blk: {
            const val = std.mem.readInt(i16, data[offset..][0..2], .big);
            break :blk @as(f64, @floatFromInt(val)) / 32768.0;
        },
        .s24le => blk: {
            // Read 24-bit as 3 bytes
            const b0: i32 = data[offset];
            const b1: i32 = data[offset + 1];
            const b2: i32 = @as(i8, @bitCast(data[offset + 2])); // Sign extend
            const val = b0 | (b1 << 8) | (b2 << 16);
            break :blk @as(f64, @floatFromInt(val)) / 8388608.0;
        },
        .s24be => blk: {
            const b0: i32 = @as(i8, @bitCast(data[offset])); // Sign extend
            const b1: i32 = data[offset + 1];
            const b2: i32 = data[offset + 2];
            const val = b2 | (b1 << 8) | (b0 << 16);
            break :blk @as(f64, @floatFromInt(val)) / 8388608.0;
        },
        .s32le, .s32p => blk: {
            const val = std.mem.readInt(i32, data[offset..][0..4], .little);
            break :blk @as(f64, @floatFromInt(val)) / 2147483648.0;
        },
        .s32be => blk: {
            const val = std.mem.readInt(i32, data[offset..][0..4], .big);
            break :blk @as(f64, @floatFromInt(val)) / 2147483648.0;
        },
        .f32le, .f32p => blk: {
            const int_val = std.mem.readInt(u32, data[offset..][0..4], .little);
            const val: f32 = @bitCast(int_val);
            break :blk @as(f64, val);
        },
        .f32be => blk: {
            const int_val = std.mem.readInt(u32, data[offset..][0..4], .big);
            const val: f32 = @bitCast(int_val);
            break :blk @as(f64, val);
        },
        .f64le, .f64p => blk: {
            const int_val = std.mem.readInt(u64, data[offset..][0..8], .little);
            break :blk @bitCast(int_val);
        },
        .f64be => blk: {
            const int_val = std.mem.readInt(u64, data[offset..][0..8], .big);
            break :blk @bitCast(int_val);
        },
    };
}

/// Write a single sample from f64 (-1.0 to 1.0)
fn writeSampleF64(data: []u8, format: SampleFormat, index: usize, value: f64) void {
    const bps = format.bytesPerSample();
    const offset = index * bps;

    if (offset + bps > data.len) return;

    const clamped = std.math.clamp(value, -1.0, 1.0);

    switch (format) {
        .u8 => {
            data[offset] = @intFromFloat((clamped + 1.0) * 127.5);
        },
        .s8 => {
            const val: i8 = @intFromFloat(clamped * 127.0);
            data[offset] = @bitCast(val);
        },
        .s16le, .s16p => {
            const val: i16 = @intFromFloat(clamped * 32767.0);
            std.mem.writeInt(i16, data[offset..][0..2], val, .little);
        },
        .s16be => {
            const val: i16 = @intFromFloat(clamped * 32767.0);
            std.mem.writeInt(i16, data[offset..][0..2], val, .big);
        },
        .s24le => {
            const val: i32 = @intFromFloat(clamped * 8388607.0);
            data[offset] = @truncate(@as(u32, @bitCast(val)));
            data[offset + 1] = @truncate(@as(u32, @bitCast(val)) >> 8);
            data[offset + 2] = @truncate(@as(u32, @bitCast(val)) >> 16);
        },
        .s24be => {
            const val: i32 = @intFromFloat(clamped * 8388607.0);
            data[offset] = @truncate(@as(u32, @bitCast(val)) >> 16);
            data[offset + 1] = @truncate(@as(u32, @bitCast(val)) >> 8);
            data[offset + 2] = @truncate(@as(u32, @bitCast(val)));
        },
        .s32le, .s32p => {
            const val: i32 = @intFromFloat(clamped * 2147483647.0);
            std.mem.writeInt(i32, data[offset..][0..4], val, .little);
        },
        .s32be => {
            const val: i32 = @intFromFloat(clamped * 2147483647.0);
            std.mem.writeInt(i32, data[offset..][0..4], val, .big);
        },
        .f32le, .f32p => {
            const val: f32 = @floatCast(clamped);
            const int_val: u32 = @bitCast(val);
            std.mem.writeInt(u32, data[offset..][0..4], int_val, .little);
        },
        .f32be => {
            const val: f32 = @floatCast(clamped);
            const int_val: u32 = @bitCast(val);
            std.mem.writeInt(u32, data[offset..][0..4], int_val, .big);
        },
        .f64le, .f64p => {
            const int_val: u64 = @bitCast(clamped);
            std.mem.writeInt(u64, data[offset..][0..8], int_val, .little);
        },
        .f64be => {
            const int_val: u64 = @bitCast(clamped);
            std.mem.writeInt(u64, data[offset..][0..8], int_val, .big);
        },
    }
}

// ============================================================================
// A-law / μ-law Conversion
// ============================================================================

/// Decode A-law to linear PCM (s16)
pub fn decodeAlaw(input: []const u8, output: []i16) void {
    const alaw_table = comptime blk: {
        var table: [256]i16 = undefined;
        for (0..256) |i| {
            var val: u8 = @intCast(i ^ 0x55);
            const sign: i16 = if (val & 0x80 != 0) -1 else 1;
            val &= 0x7F;

            const segment = (val >> 4) & 0x07;
            const quant = val & 0x0F;

            var linear: i16 = switch (segment) {
                0 => (@as(i16, quant) << 4) + 8,
                else => ((@as(i16, quant) << 4) + 0x108) << (@as(u4, @intCast(segment)) - 1),
            };
            linear *= sign;
            table[i] = linear;
        }
        break :blk table;
    };

    for (input, 0..) |byte, i| {
        if (i < output.len) {
            output[i] = alaw_table[byte];
        }
    }
}

/// Decode μ-law to linear PCM (s16)
pub fn decodeUlaw(input: []const u8, output: []i16) void {
    const ulaw_table = comptime blk: {
        var table: [256]i16 = undefined;
        for (0..256) |i| {
            var val: u8 = @intCast(~i);
            const sign: i16 = if (val & 0x80 != 0) -1 else 1;
            val &= 0x7F;

            const segment = (val >> 4) & 0x07;
            const quant = val & 0x0F;

            var linear: i16 = ((@as(i16, quant) << 3) + 0x84) << @as(u4, @intCast(segment));
            linear -= 0x84;
            linear *= sign;
            table[i] = linear;
        }
        break :blk table;
    };

    for (input, 0..) |byte, i| {
        if (i < output.len) {
            output[i] = ulaw_table[byte];
        }
    }
}

/// Encode linear PCM (s16) to A-law
pub fn encodeAlaw(input: []const i16, output: []u8) void {
    for (input, 0..) |sample, i| {
        if (i >= output.len) break;

        var val = sample;
        const sign: u8 = if (val < 0) 0x80 else 0;
        if (val < 0) val = -val;
        if (val > 32635) val = 32635;

        var segment: u8 = 0;
        var mask: i16 = 0x4000;
        while (segment < 8 and (val & mask) == 0) {
            segment += 1;
            mask >>= 1;
        }

        const encoded: u8 = if (segment >= 8)
            sign | 0x00
        else
            sign | ((7 - segment) << 4) | @as(u8, @truncate(@as(u16, @bitCast(val >> (segment + 3))) & 0x0F));

        output[i] = encoded ^ 0x55;
    }
}

/// Encode linear PCM (s16) to μ-law
pub fn encodeUlaw(input: []const i16, output: []u8) void {
    for (input, 0..) |sample, i| {
        if (i >= output.len) break;

        var val: i32 = sample;
        const sign: u8 = if (val < 0) 0x80 else 0;
        if (val < 0) val = -val;
        val += 0x84; // Bias
        if (val > 32767) val = 32767;

        var segment: u8 = 0;
        var shifted = val >> 7;
        while (shifted > 0 and segment < 8) {
            segment += 1;
            shifted >>= 1;
        }

        const quant: u8 = @truncate(@as(u32, @intCast(val >> (segment + 3))) & 0x0F);
        const encoded: u8 = ~(sign | (segment << 4) | quant);

        output[i] = encoded;
    }
}

// ============================================================================
// Interleaving / Deinterleaving
// ============================================================================

/// Convert interleaved audio to planar
pub fn interleavedToPlanar(
    input: []const u8,
    output: [][]u8,
    format: SampleFormat,
    channels: u8,
    num_samples: u32,
) !void {
    if (output.len < channels) return VideoError.InvalidArgument;

    const bps = format.bytesPerSample();
    const samples_per_channel = @as(usize, num_samples);
    const channel_size = samples_per_channel * bps;

    for (0..channels) |ch| {
        if (output[ch].len < channel_size) return VideoError.BufferTooSmall;

        for (0..samples_per_channel) |s| {
            const src_offset = (s * channels + ch) * bps;
            const dst_offset = s * bps;

            @memcpy(output[ch][dst_offset..][0..bps], input[src_offset..][0..bps]);
        }
    }
}

/// Convert planar audio to interleaved
pub fn planarToInterleaved(
    input: []const []const u8,
    output: []u8,
    format: SampleFormat,
    channels: u8,
    num_samples: u32,
) !void {
    if (input.len < channels) return VideoError.InvalidArgument;

    const bps = format.bytesPerSample();
    const samples_per_channel = @as(usize, num_samples);
    const required_size = samples_per_channel * channels * bps;

    if (output.len < required_size) return VideoError.BufferTooSmall;

    for (0..samples_per_channel) |s| {
        for (0..channels) |ch| {
            const src_offset = s * bps;
            const dst_offset = (s * channels + ch) * bps;

            @memcpy(output[dst_offset..][0..bps], input[ch][src_offset..][0..bps]);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Sample format conversion s16le to f32le" {
    var input: [4]u8 = undefined;
    var output: [8]u8 = undefined;

    // Write max positive s16
    std.mem.writeInt(i16, input[0..2], 32767, .little);
    // Write zero
    std.mem.writeInt(i16, input[2..4], 0, .little);

    try convertSamples(&input, .s16le, &output, .f32le, 1, 2);

    // Read back as f32
    const f1: f32 = @bitCast(std.mem.readInt(u32, output[0..4], .little));
    const f2: f32 = @bitCast(std.mem.readInt(u32, output[4..8], .little));

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), f1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), f2, 0.001);
}

test "PCM decoder" {
    const allocator = std.testing.allocator;

    var decoder = PcmDecoder.init(allocator, .s16le, .f32le, 2, 44100);

    // Create test input (2 samples, stereo = 8 bytes)
    var input: [8]u8 = undefined;
    std.mem.writeInt(i16, input[0..2], 16384, .little); // L0: 0.5
    std.mem.writeInt(i16, input[2..4], -16384, .little); // R0: -0.5
    std.mem.writeInt(i16, input[4..6], 0, .little); // L1: 0
    std.mem.writeInt(i16, input[6..8], 32767, .little); // R1: 1.0

    var audio = try decoder.decode(&input);
    defer audio.deinit();

    try std.testing.expectEqual(@as(u32, 2), audio.num_samples);
    try std.testing.expectEqual(@as(u8, 2), audio.channels);

    const l0 = audio.getSampleF32(0, 0);
    const r0 = audio.getSampleF32(1, 0);

    try std.testing.expect(l0 != null);
    try std.testing.expect(r0 != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), l0.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), r0.?, 0.01);
}

test "PCM encoder" {
    const allocator = std.testing.allocator;

    var audio = try AudioFrame.init(allocator, 2, .f32le, 2, 44100);
    defer audio.deinit();

    audio.setSampleF32(0, 0, 0.5);
    audio.setSampleF32(1, 0, -0.5);
    audio.setSampleF32(0, 1, 1.0);
    audio.setSampleF32(1, 1, -1.0);

    var encoder = PcmEncoder.init(allocator, .f32le, .s16le, 2, 44100);
    const encoded = try encoder.encode(&audio);
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 8), encoded.len); // 2 samples * 2 channels * 2 bytes

    const l0 = std.mem.readInt(i16, encoded[0..2], .little);
    const r0 = std.mem.readInt(i16, encoded[2..4], .little);

    try std.testing.expectApproxEqAbs(@as(f32, 16383.5), @as(f32, @floatFromInt(l0)), 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, -16383.5), @as(f32, @floatFromInt(r0)), 1.0);
}
