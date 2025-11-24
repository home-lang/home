// Home Audio Library - ReplayGain Support
// ReplayGain 2.0 metadata parsing and calculation

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// ReplayGain metadata
pub const ReplayGain = struct {
    /// Track gain in dB
    track_gain: ?f32 = null,
    /// Track peak (linear, 0.0 to 1.0+)
    track_peak: ?f32 = null,
    /// Album gain in dB
    album_gain: ?f32 = null,
    /// Album peak (linear, 0.0 to 1.0+)
    album_peak: ?f32 = null,

    /// Reference loudness (-18 LUFS for RG2.0, -14 LUFS for streaming)
    reference_loudness: f32 = -18.0,

    pub const REFERENCE_LOUDNESS_RG1 = -89.0; // RG1 reference (dB SPL)
    pub const REFERENCE_LOUDNESS_RG2 = -18.0; // RG2 reference (LUFS)
    pub const REFERENCE_LOUDNESS_STREAMING = -14.0; // Streaming reference

    /// Check if has track info
    pub fn hasTrack(self: ReplayGain) bool {
        return self.track_gain != null;
    }

    /// Check if has album info
    pub fn hasAlbum(self: ReplayGain) bool {
        return self.album_gain != null;
    }

    /// Get gain to apply (track preferred)
    pub fn getGain(self: ReplayGain, prefer_album: bool) ?f32 {
        if (prefer_album and self.album_gain != null) {
            return self.album_gain;
        }
        return self.track_gain orelse self.album_gain;
    }

    /// Get peak (track preferred)
    pub fn getPeak(self: ReplayGain, prefer_album: bool) ?f32 {
        if (prefer_album and self.album_peak != null) {
            return self.album_peak;
        }
        return self.track_peak orelse self.album_peak;
    }

    /// Calculate linear gain factor
    pub fn getLinearGain(self: ReplayGain, prefer_album: bool, preamp_db: f32) f32 {
        const gain = self.getGain(prefer_album) orelse 0;
        return math.pow(f32, 10.0, (gain + preamp_db) / 20.0);
    }

    /// Calculate gain with clipping prevention
    pub fn getSafeGain(self: ReplayGain, prefer_album: bool, preamp_db: f32) f32 {
        const gain = self.getLinearGain(prefer_album, preamp_db);
        const peak = self.getPeak(prefer_album) orelse 1.0;

        // Reduce gain if it would cause clipping
        if (peak * gain > 1.0) {
            return 1.0 / peak;
        }
        return gain;
    }
};

/// Parse ReplayGain from tag string
pub fn parseGain(value: []const u8) ?f32 {
    // Format: "+0.50 dB" or "-3.21 dB"
    var end = value.len;

    // Remove " dB" suffix
    if (std.mem.endsWith(u8, value, " dB") or std.mem.endsWith(u8, value, " db")) {
        end -= 3;
    } else if (std.mem.endsWith(u8, value, "dB") or std.mem.endsWith(u8, value, "db")) {
        end -= 2;
    }

    // Trim whitespace
    const trimmed = std.mem.trim(u8, value[0..end], " \t");

    return std.fmt.parseFloat(f32, trimmed) catch null;
}

/// Parse ReplayGain peak from tag string
pub fn parsePeak(value: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, value, " \t");
    return std.fmt.parseFloat(f32, trimmed) catch null;
}

/// ReplayGain tag names (various formats)
pub const TagNames = struct {
    pub const TRACK_GAIN = [_][]const u8{
        "REPLAYGAIN_TRACK_GAIN",
        "replaygain_track_gain",
        "TXXX:REPLAYGAIN_TRACK_GAIN",
    };
    pub const TRACK_PEAK = [_][]const u8{
        "REPLAYGAIN_TRACK_PEAK",
        "replaygain_track_peak",
        "TXXX:REPLAYGAIN_TRACK_PEAK",
    };
    pub const ALBUM_GAIN = [_][]const u8{
        "REPLAYGAIN_ALBUM_GAIN",
        "replaygain_album_gain",
        "TXXX:REPLAYGAIN_ALBUM_GAIN",
    };
    pub const ALBUM_PEAK = [_][]const u8{
        "REPLAYGAIN_ALBUM_PEAK",
        "replaygain_album_peak",
        "TXXX:REPLAYGAIN_ALBUM_PEAK",
    };
    pub const REFERENCE_LOUDNESS = [_][]const u8{
        "REPLAYGAIN_REFERENCE_LOUDNESS",
        "replaygain_reference_loudness",
    };
};

/// Parse ReplayGain from a set of tags
pub fn parseFromTags(tags: anytype) ReplayGain {
    var rg = ReplayGain{};

    // Helper to find matching tag
    const findTag = struct {
        fn find(t: @TypeOf(tags), names: []const []const u8) ?[]const u8 {
            for (names) |name| {
                if (t.get(name)) |value| {
                    return value;
                }
            }
            return null;
        }
    }.find;

    if (findTag(tags, &TagNames.TRACK_GAIN)) |v| {
        rg.track_gain = parseGain(v);
    }
    if (findTag(tags, &TagNames.TRACK_PEAK)) |v| {
        rg.track_peak = parsePeak(v);
    }
    if (findTag(tags, &TagNames.ALBUM_GAIN)) |v| {
        rg.album_gain = parseGain(v);
    }
    if (findTag(tags, &TagNames.ALBUM_PEAK)) |v| {
        rg.album_peak = parsePeak(v);
    }

    return rg;
}

/// Format ReplayGain value for storage
pub fn formatGain(gain: f32) [16]u8 {
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:+.2} dB", .{gain}) catch {};
    return buf;
}

/// Format peak value for storage
pub fn formatPeak(peak: f32) [16]u8 {
    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:.6}", .{peak}) catch {};
    return buf;
}

/// Apply ReplayGain to audio samples
pub fn applyGain(samples: []f32, gain: f32) void {
    for (samples) |*s| {
        s.* *= gain;
    }
}

/// Apply ReplayGain with clipping prevention
pub fn applyGainSafe(samples: []f32, gain: f32, peak: ?f32) void {
    var safe_gain = gain;

    // Reduce gain if it would cause clipping
    if (peak) |p| {
        if (p * gain > 1.0) {
            safe_gain = 1.0 / p;
        }
    }

    for (samples) |*s| {
        s.* = math.clamp(s.* * safe_gain, -1.0, 1.0);
    }
}

/// Calculate peak from samples
pub fn calculatePeak(samples: []const f32) f32 {
    var peak: f32 = 0;
    for (samples) |s| {
        const abs = @abs(s);
        if (abs > peak) peak = abs;
    }
    return peak;
}

/// EBU R128 integrated loudness (simplified)
/// For accurate results, use the full LoudnessMeter from loudness.zig
pub fn calculateLoudness(samples: []const f32, sample_rate: u32) f32 {
    _ = sample_rate;

    var sum_squared: f64 = 0;
    for (samples) |s| {
        sum_squared += @as(f64, s) * @as(f64, s);
    }

    const rms = @sqrt(sum_squared / @as(f64, @floatFromInt(samples.len)));
    const lufs: f32 = @floatCast(-0.691 + 10.0 * @log10(rms + 1e-10));

    return lufs;
}

/// Calculate ReplayGain from loudness
pub fn calculateReplayGain(loudness_lufs: f32, reference: f32) f32 {
    return reference - loudness_lufs;
}

// ============================================================================
// Tests
// ============================================================================

test "parseGain" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), parseGain("+0.50 dB").?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -3.21), parseGain("-3.21 dB").?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), parseGain("1.0dB").?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), parseGain("-5.0").?, 0.01);
}

test "parsePeak" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.999), parsePeak("0.999").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), parsePeak("1.5").?, 0.01);
}

test "ReplayGain linear gain" {
    var rg = ReplayGain{
        .track_gain = 0.0,
        .track_peak = 1.0,
    };

    // 0 dB = linear gain of 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rg.getLinearGain(false, 0), 0.001);

    // +6 dB = linear gain of ~2.0
    rg.track_gain = 6.0;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), rg.getLinearGain(false, 0), 0.1);

    // -6 dB = linear gain of ~0.5
    rg.track_gain = -6.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rg.getLinearGain(false, 0), 0.05);
}

test "ReplayGain safe gain" {
    const rg = ReplayGain{
        .track_gain = 6.0, // Would double the signal
        .track_peak = 0.8, // Peak at 0.8
    };

    // Safe gain should limit to prevent clipping
    const safe = rg.getSafeGain(false, 0);
    try std.testing.expect(safe <= 1.25); // 1.0 / 0.8
}

test "calculatePeak" {
    const samples = [_]f32{ 0.1, -0.5, 0.3, 0.8, -0.2 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), calculatePeak(&samples), 0.001);
}
