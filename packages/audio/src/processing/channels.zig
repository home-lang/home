// Home Audio Library - Channel Remapping
// Upmix/downmix between channel configurations

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const ChannelLayout = types.ChannelLayout;

/// Downmix coefficients based on ITU-R BS.775
pub const DownmixCoefficients = struct {
    /// Center channel attenuation (typically -3dB)
    center_attenuation: f32 = 0.707,
    /// Surround channel attenuation (typically -3dB)
    surround_attenuation: f32 = 0.707,
    /// LFE channel attenuation (typically -10dB or muted)
    lfe_attenuation: f32 = 0.0,

    pub const DEFAULT = DownmixCoefficients{};
    pub const ITU_775 = DownmixCoefficients{
        .center_attenuation = 0.707, // -3dB
        .surround_attenuation = 0.707, // -3dB
        .lfe_attenuation = 0.0, // Muted
    };
    pub const DOLBY = DownmixCoefficients{
        .center_attenuation = 0.707,
        .surround_attenuation = 0.5, // -6dB
        .lfe_attenuation = 0.0,
    };
};

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

/// Downmix 5.1 to stereo
/// Channel order: L, R, C, LFE, Ls, Rs
pub fn downmix51ToStereo(allocator: Allocator, surround: []const f32, coef: DownmixCoefficients) ![]f32 {
    const num_frames = surround.len / 6;
    const stereo = try allocator.alloc(f32, num_frames * 2);

    for (0..num_frames) |i| {
        const offset = i * 6;
        const l = surround[offset + 0];
        const r = surround[offset + 1];
        const c = surround[offset + 2];
        const lfe = surround[offset + 3];
        const ls = surround[offset + 4];
        const rs = surround[offset + 5];

        // ITU-R BS.775 downmix formula
        const left = l + c * coef.center_attenuation + ls * coef.surround_attenuation + lfe * coef.lfe_attenuation;
        const right = r + c * coef.center_attenuation + rs * coef.surround_attenuation + lfe * coef.lfe_attenuation;

        stereo[i * 2] = left;
        stereo[i * 2 + 1] = right;
    }

    return stereo;
}

/// Downmix 7.1 to stereo
/// Channel order: L, R, C, LFE, Lss, Rss, Lsr, Rsr
pub fn downmix71ToStereo(allocator: Allocator, surround: []const f32, coef: DownmixCoefficients) ![]f32 {
    const num_frames = surround.len / 8;
    const stereo = try allocator.alloc(f32, num_frames * 2);

    for (0..num_frames) |i| {
        const offset = i * 8;
        const l = surround[offset + 0];
        const r = surround[offset + 1];
        const c = surround[offset + 2];
        const lfe = surround[offset + 3];
        const lss = surround[offset + 4]; // Left side surround
        const rss = surround[offset + 5]; // Right side surround
        const lsr = surround[offset + 6]; // Left surround rear
        const rsr = surround[offset + 7]; // Right surround rear

        const left = l + c * coef.center_attenuation +
            (lss + lsr) * coef.surround_attenuation * 0.707 +
            lfe * coef.lfe_attenuation;
        const right = r + c * coef.center_attenuation +
            (rss + rsr) * coef.surround_attenuation * 0.707 +
            lfe * coef.lfe_attenuation;

        stereo[i * 2] = left;
        stereo[i * 2 + 1] = right;
    }

    return stereo;
}

/// Downmix 5.1 to mono
pub fn downmix51ToMono(allocator: Allocator, surround: []const f32, coef: DownmixCoefficients) ![]f32 {
    const stereo = try downmix51ToStereo(allocator, surround, coef);
    defer allocator.free(stereo);
    return stereoToMono(allocator, stereo);
}

/// Upmix stereo to 5.1 (simple upmix)
/// Uses ambient extraction for surround channels
pub fn upmixStereoTo51(allocator: Allocator, stereo: []const f32) ![]f32 {
    const num_frames = stereo.len / 2;
    const surround = try allocator.alloc(f32, num_frames * 6);

    for (0..num_frames) |i| {
        const l = stereo[i * 2];
        const r = stereo[i * 2 + 1];

        // Simple upmix algorithm
        const center = (l + r) * 0.5; // Center from sum
        const diff = (l - r) * 0.5; // Difference for ambient

        const offset = i * 6;
        surround[offset + 0] = l * 0.707; // L
        surround[offset + 1] = r * 0.707; // R
        surround[offset + 2] = center * 0.707; // C
        surround[offset + 3] = 0; // LFE (no bass management here)
        surround[offset + 4] = diff * 0.5; // Ls (ambient)
        surround[offset + 5] = -diff * 0.5; // Rs (ambient, inverted)
    }

    return surround;
}

/// Upmix mono to 5.1 (center channel only)
pub fn upmixMonoTo51(allocator: Allocator, mono: []const f32) ![]f32 {
    const surround = try allocator.alloc(f32, mono.len * 6);
    @memset(surround, 0);

    for (0..mono.len) |i| {
        // Put mono signal in center channel
        surround[i * 6 + 2] = mono[i];
    }

    return surround;
}

/// Generic channel remapping
pub fn remap(
    allocator: Allocator,
    input: []const f32,
    src_channels: u8,
    dst_channels: u8,
) ![]f32 {
    if (src_channels == dst_channels) {
        return try allocator.dupe(f32, input);
    }

    // Handle common cases
    if (src_channels == 1 and dst_channels == 2) {
        return monoToStereo(allocator, input);
    }
    if (src_channels == 2 and dst_channels == 1) {
        return stereoToMono(allocator, input);
    }
    if (src_channels == 6 and dst_channels == 2) {
        return downmix51ToStereo(allocator, input, DownmixCoefficients.DEFAULT);
    }
    if (src_channels == 8 and dst_channels == 2) {
        return downmix71ToStereo(allocator, input, DownmixCoefficients.DEFAULT);
    }
    if (src_channels == 6 and dst_channels == 1) {
        return downmix51ToMono(allocator, input, DownmixCoefficients.DEFAULT);
    }
    if (src_channels == 2 and dst_channels == 6) {
        return upmixStereoTo51(allocator, input);
    }
    if (src_channels == 1 and dst_channels == 6) {
        return upmixMonoTo51(allocator, input);
    }

    // Generic fallback: truncate or zero-pad channels
    const num_frames = input.len / src_channels;
    const output = try allocator.alloc(f32, num_frames * dst_channels);

    for (0..num_frames) |i| {
        const src_offset = i * src_channels;
        const dst_offset = i * dst_channels;

        for (0..dst_channels) |ch| {
            if (ch < src_channels) {
                output[dst_offset + ch] = input[src_offset + ch];
            } else {
                output[dst_offset + ch] = 0;
            }
        }
    }

    return output;
}

/// Extract specific channels
pub fn extractChannels(
    allocator: Allocator,
    input: []const f32,
    src_channels: u8,
    channel_indices: []const u8,
) ![]f32 {
    const num_frames = input.len / src_channels;
    const output = try allocator.alloc(f32, num_frames * channel_indices.len);

    for (0..num_frames) |i| {
        const src_offset = i * src_channels;
        const dst_offset = i * channel_indices.len;

        for (0..channel_indices.len) |ch| {
            const src_ch = channel_indices[ch];
            if (src_ch < src_channels) {
                output[dst_offset + ch] = input[src_offset + src_ch];
            } else {
                output[dst_offset + ch] = 0;
            }
        }
    }

    return output;
}

/// Interleave separate channel buffers
pub fn interleave(
    allocator: Allocator,
    channels: []const []const f32,
) ![]f32 {
    if (channels.len == 0) return &[_]f32{};

    const num_channels = channels.len;
    const num_frames = channels[0].len;
    const output = try allocator.alloc(f32, num_frames * num_channels);

    for (0..num_frames) |i| {
        for (0..num_channels) |ch| {
            output[i * num_channels + ch] = channels[ch][i];
        }
    }

    return output;
}

/// Deinterleave to separate channel buffers
pub fn deinterleave(
    allocator: Allocator,
    input: []const f32,
    num_channels: u8,
) ![][]f32 {
    const num_frames = input.len / num_channels;
    const channels = try allocator.alloc([]f32, num_channels);
    errdefer {
        for (channels) |ch| {
            allocator.free(ch);
        }
        allocator.free(channels);
    }

    for (0..num_channels) |ch| {
        channels[ch] = try allocator.alloc(f32, num_frames);
        for (0..num_frames) |i| {
            channels[ch][i] = input[i * num_channels + ch];
        }
    }

    return channels;
}

/// Free deinterleaved channels
pub fn freeDeinterleaved(allocator: Allocator, channels: [][]f32) void {
    for (channels) |ch| {
        allocator.free(ch);
    }
    allocator.free(channels);
}

// ============================================================================
// Tests
// ============================================================================

test "mono to stereo" {
    const allocator = std.testing.allocator;

    const mono = [_]f32{ 0.5, -0.5, 0.25 };
    const stereo = try monoToStereo(allocator, &mono);
    defer allocator.free(stereo);

    try std.testing.expectEqual(@as(usize, 6), stereo.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stereo[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stereo[1], 0.001);
}

test "stereo to mono" {
    const allocator = std.testing.allocator;

    const stereo = [_]f32{ 0.4, 0.6, -0.2, 0.2 };
    const mono = try stereoToMono(allocator, &stereo);
    defer allocator.free(mono);

    try std.testing.expectEqual(@as(usize, 2), mono.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mono[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mono[1], 0.001);
}

test "channel remap" {
    const allocator = std.testing.allocator;

    // Mono to stereo via remap
    const mono = [_]f32{ 1.0, 0.5 };
    const stereo = try remap(allocator, &mono, 1, 2);
    defer allocator.free(stereo);

    try std.testing.expectEqual(@as(usize, 4), stereo.len);
}

test "deinterleave and interleave" {
    const allocator = std.testing.allocator;

    const stereo = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };
    const channels = try deinterleave(allocator, &stereo, 2);
    defer freeDeinterleaved(allocator, channels);

    try std.testing.expectEqual(@as(usize, 2), channels.len);
    try std.testing.expectEqual(@as(usize, 3), channels[0].len);

    // Re-interleave
    const reinterleaved = try interleave(allocator, channels);
    defer allocator.free(reinterleaved);

    try std.testing.expectEqualSlices(f32, &stereo, reinterleaved);
}
