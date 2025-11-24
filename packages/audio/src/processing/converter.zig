// Home Audio Library - Sample Format Converter
// Convert between audio sample formats (s16/s24/s32/f32)

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;

/// Convert samples between formats
pub fn convert(
    allocator: Allocator,
    input: []const u8,
    src_format: SampleFormat,
    dst_format: SampleFormat,
) ![]u8 {
    if (src_format == dst_format) {
        return try allocator.dupe(u8, input);
    }

    const src_bps = src_format.bytesPerSample();
    const dst_bps = dst_format.bytesPerSample();
    const num_samples = input.len / src_bps;

    const output = try allocator.alloc(u8, num_samples * dst_bps);
    errdefer allocator.free(output);

    for (0..num_samples) |i| {
        const src_offset = i * src_bps;
        const dst_offset = i * dst_bps;

        // Convert to f64 intermediate
        const f64_val = sampleToF64(input[src_offset..][0..src_bps], src_format);

        // Convert from f64 to destination
        f64ToSample(f64_val, output[dst_offset..][0..dst_bps], dst_format);
    }

    return output;
}

/// Convert in-place between float formats (f32 only)
pub fn convertInPlaceF32(samples: []f32, src_format: SampleFormat, dst_format: SampleFormat) void {
    if (src_format == dst_format) return;

    // For in-place, we only support normalizing between integer-like and float-like ranges
    const src_is_normalized = src_format.isFloat();
    const dst_is_normalized = dst_format.isFloat();

    if (src_is_normalized == dst_is_normalized) return;

    if (src_is_normalized and !dst_is_normalized) {
        // Float to integer range - scale up
        const scale = getScale(dst_format);
        for (samples) |*s| {
            s.* = math.clamp(s.* * scale, -scale, scale - 1);
        }
    } else {
        // Integer range to float - scale down
        const scale = getScale(src_format);
        for (samples) |*s| {
            s.* = s.* / scale;
        }
    }
}

fn getScale(format: SampleFormat) f32 {
    return switch (format) {
        .u8 => 128.0,
        .s16le, .s16be => 32768.0,
        .s24le, .s24be => 8388608.0,
        .s32le, .s32be => 2147483648.0,
        .f32le, .f32be, .f64le, .f64be => 1.0,
        .alaw, .ulaw => 32768.0,
    };
}

/// Convert any sample to f64 (-1.0 to 1.0)
fn sampleToF64(bytes: []const u8, format: SampleFormat) f64 {
    return switch (format) {
        .u8 => (@as(f64, @floatFromInt(bytes[0])) - 128.0) / 128.0,
        .s16le => blk: {
            const val = std.mem.readInt(i16, bytes[0..2], .little);
            break :blk @as(f64, @floatFromInt(val)) / 32768.0;
        },
        .s16be => blk: {
            const val = std.mem.readInt(i16, bytes[0..2], .big);
            break :blk @as(f64, @floatFromInt(val)) / 32768.0;
        },
        .s24le => blk: {
            var arr: [4]u8 = .{ bytes[0], bytes[1], bytes[2], 0 };
            if (bytes[2] & 0x80 != 0) arr[3] = 0xFF;
            const val = std.mem.readInt(i32, &arr, .little);
            break :blk @as(f64, @floatFromInt(val)) / 8388608.0;
        },
        .s24be => blk: {
            var arr: [4]u8 = .{ 0, bytes[0], bytes[1], bytes[2] };
            if (bytes[0] & 0x80 != 0) arr[0] = 0xFF;
            const val = std.mem.readInt(i32, &arr, .big);
            break :blk @as(f64, @floatFromInt(val)) / 8388608.0;
        },
        .s32le => blk: {
            const val = std.mem.readInt(i32, bytes[0..4], .little);
            break :blk @as(f64, @floatFromInt(val)) / 2147483648.0;
        },
        .s32be => blk: {
            const val = std.mem.readInt(i32, bytes[0..4], .big);
            break :blk @as(f64, @floatFromInt(val)) / 2147483648.0;
        },
        .f32le => blk: {
            const bits = std.mem.readInt(u32, bytes[0..4], .little);
            break :blk @floatCast(@as(f32, @bitCast(bits)));
        },
        .f32be => blk: {
            const bits = std.mem.readInt(u32, bytes[0..4], .big);
            break :blk @floatCast(@as(f32, @bitCast(bits)));
        },
        .f64le => @bitCast(std.mem.readInt(u64, bytes[0..8], .little)),
        .f64be => @bitCast(std.mem.readInt(u64, bytes[0..8], .big)),
        .alaw => decodeAlaw(bytes[0]),
        .ulaw => decodeUlaw(bytes[0]),
    };
}

/// Convert f64 (-1.0 to 1.0) to sample bytes
fn f64ToSample(val: f64, bytes: []u8, format: SampleFormat) void {
    const clamped = math.clamp(val, -1.0, 1.0 - 1e-10);

    switch (format) {
        .u8 => {
            bytes[0] = @intFromFloat(clamped * 128.0 + 128.0);
        },
        .s16le => {
            const i: i16 = @intFromFloat(clamped * 32768.0);
            std.mem.writeInt(i16, bytes[0..2], i, .little);
        },
        .s16be => {
            const i: i16 = @intFromFloat(clamped * 32768.0);
            std.mem.writeInt(i16, bytes[0..2], i, .big);
        },
        .s24le => {
            const i: i32 = @intFromFloat(clamped * 8388608.0);
            bytes[0] = @truncate(@as(u32, @bitCast(i)));
            bytes[1] = @truncate(@as(u32, @bitCast(i)) >> 8);
            bytes[2] = @truncate(@as(u32, @bitCast(i)) >> 16);
        },
        .s24be => {
            const i: i32 = @intFromFloat(clamped * 8388608.0);
            bytes[0] = @truncate(@as(u32, @bitCast(i)) >> 16);
            bytes[1] = @truncate(@as(u32, @bitCast(i)) >> 8);
            bytes[2] = @truncate(@as(u32, @bitCast(i)));
        },
        .s32le => {
            const i: i32 = @intFromFloat(clamped * 2147483648.0);
            std.mem.writeInt(i32, bytes[0..4], i, .little);
        },
        .s32be => {
            const i: i32 = @intFromFloat(clamped * 2147483648.0);
            std.mem.writeInt(i32, bytes[0..4], i, .big);
        },
        .f32le => {
            const f: f32 = @floatCast(clamped);
            std.mem.writeInt(u32, bytes[0..4], @bitCast(f), .little);
        },
        .f32be => {
            const f: f32 = @floatCast(clamped);
            std.mem.writeInt(u32, bytes[0..4], @bitCast(f), .big);
        },
        .f64le => {
            std.mem.writeInt(u64, bytes[0..8], @bitCast(clamped), .little);
        },
        .f64be => {
            std.mem.writeInt(u64, bytes[0..8], @bitCast(clamped), .big);
        },
        .alaw => {
            bytes[0] = encodeAlaw(clamped);
        },
        .ulaw => {
            bytes[0] = encodeUlaw(clamped);
        },
    }
}

/// A-law decoding table
const ALAW_DECODE: [256]i16 = blk: {
    var table: [256]i16 = undefined;
    for (0..256) |i| {
        var val = @as(u8, @intCast(i)) ^ 0x55;
        const sign: i16 = if (val & 0x80 != 0) -1 else 1;
        val &= 0x7F;

        const seg = (val >> 4) & 0x07;
        const quant = val & 0x0F;

        var linear: i16 = undefined;
        if (seg == 0) {
            linear = (@as(i16, quant) << 1) | 1;
        } else {
            linear = ((@as(i16, quant) << 1) | 0x21) << @intCast(seg - 1);
        }

        table[i] = sign * linear;
    }
    break :blk table;
};

fn decodeAlaw(val: u8) f64 {
    return @as(f64, @floatFromInt(ALAW_DECODE[val])) / 32768.0;
}

fn encodeAlaw(val: f64) u8 {
    const sample: i16 = @intFromFloat(val * 32768.0);
    const sign: u8 = if (sample >= 0) 0x00 else 0x80;
    var mag = if (sample < 0) -sample else sample;
    if (mag > 32767) mag = 32767;

    var seg: u8 = 0;
    var mask: i16 = 0x4000;
    while (seg < 8 and (mag & mask) == 0) : ({
        seg += 1;
        mask >>= 1;
    }) {}

    if (seg >= 8) return sign ^ 0x55;

    const quant: u8 = @intCast((mag >> @intCast(if (seg > 0) seg + 3 else 4)) & 0x0F);
    return (sign | ((7 - seg) << 4) | quant) ^ 0x55;
}

/// μ-law decoding
fn decodeUlaw(val: u8) f64 {
    const v = ~val;
    const sign: i16 = if (v & 0x80 != 0) -1 else 1;
    const seg = (v >> 4) & 0x07;
    const quant = v & 0x0F;

    var linear: i16 = ((@as(i16, quant) << 1) | 0x21) << @intCast(seg);
    linear -= 0x21;

    return @as(f64, @floatFromInt(sign * linear)) / 32768.0;
}

fn encodeUlaw(val: f64) u8 {
    const sample: i16 = @intFromFloat(val * 32768.0);
    const sign: u8 = if (sample >= 0) 0x00 else 0x80;
    var mag = if (sample < 0) -sample else sample;
    mag += 0x21;
    if (mag > 32767) mag = 32767;

    var seg: u8 = 0;
    var mask: i16 = 0x4000;
    while (seg < 8 and (mag & mask) == 0) : ({
        seg += 1;
        mask >>= 1;
    }) {}

    if (seg >= 8) return ~(sign | 0x7F);

    const quant: u8 = @intCast((mag >> @intCast(seg + 3)) & 0x0F);
    return ~(sign | ((7 - seg) << 4) | quant);
}

/// Convenience function: convert f32 buffer to s16le
pub fn f32ToS16le(allocator: Allocator, input: []const f32) ![]i16 {
    const output = try allocator.alloc(i16, input.len);
    for (0..input.len) |i| {
        const clamped = math.clamp(input[i], -1.0, 1.0 - 1e-6);
        output[i] = @intFromFloat(clamped * 32768.0);
    }
    return output;
}

/// Convenience function: convert s16le buffer to f32
pub fn s16leToF32(allocator: Allocator, input: []const i16) ![]f32 {
    const output = try allocator.alloc(f32, input.len);
    for (0..input.len) |i| {
        output[i] = @as(f32, @floatFromInt(input[i])) / 32768.0;
    }
    return output;
}

/// Convert byte buffer from one format to another (f32 output)
pub fn toF32(allocator: Allocator, input: []const u8, src_format: SampleFormat) ![]f32 {
    const src_bps = src_format.bytesPerSample();
    const num_samples = input.len / src_bps;

    const output = try allocator.alloc(f32, num_samples);
    for (0..num_samples) |i| {
        const src_offset = i * src_bps;
        output[i] = @floatCast(sampleToF64(input[src_offset..][0..src_bps], src_format));
    }
    return output;
}

/// Convert f32 buffer to byte buffer in specified format
pub fn fromF32(allocator: Allocator, input: []const f32, dst_format: SampleFormat) ![]u8 {
    const dst_bps = dst_format.bytesPerSample();
    const output = try allocator.alloc(u8, input.len * dst_bps);

    for (0..input.len) |i| {
        const dst_offset = i * dst_bps;
        f64ToSample(@floatCast(input[i]), output[dst_offset..][0..dst_bps], dst_format);
    }
    return output;
}

// ============================================================================
// Tests
// ============================================================================

test "s16le to f32 conversion" {
    const allocator = std.testing.allocator;

    const input = [_]i16{ 0, 16384, -16384, 32767 };
    const output = try s16leToF32(allocator, &input);
    defer allocator.free(output);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), output[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), output[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), output[2], 0.001);
}

test "f32 to s16le conversion" {
    const allocator = std.testing.allocator;

    const input = [_]f32{ 0.0, 0.5, -0.5, 0.999 };
    const output = try f32ToS16le(allocator, &input);
    defer allocator.free(output);

    try std.testing.expectEqual(@as(i16, 0), output[0]);
    try std.testing.expectEqual(@as(i16, 16384), output[1]);
    try std.testing.expectEqual(@as(i16, -16384), output[2]);
}

test "round-trip conversion" {
    const allocator = std.testing.allocator;

    // s16le -> f32 -> s16le
    const original = [_]i16{ 1000, -2000, 3000, -4000 };
    const f32_buf = try s16leToF32(allocator, &original);
    defer allocator.free(f32_buf);

    const converted = try f32ToS16le(allocator, f32_buf);
    defer allocator.free(converted);

    try std.testing.expectEqualSlices(i16, &original, converted);
}
