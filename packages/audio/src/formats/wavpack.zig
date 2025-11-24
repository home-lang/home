// Home Audio Library - WavPack Format
// WavPack hybrid lossless/lossy codec reader

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;
const ChannelLayout = types.ChannelLayout;
const Duration = types.Duration;

const audio_error = @import("../core/error.zig");
const AudioError = audio_error.AudioError;

/// WavPack mode flags
pub const WavPackFlags = packed struct(u32) {
    bytes_per_sample_lsb: u2 = 0, // bits 0-1: bytes per sample - 1
    mono: bool = false, // bit 2: mono
    hybrid: bool = false, // bit 3: hybrid mode
    joint_stereo: bool = false, // bit 4: joint stereo
    cross_decorrelation: bool = false, // bit 5: cross-channel decorrelation
    hybrid_noise_shaping: bool = false, // bit 6: hybrid noise shaping
    float_data: bool = false, // bit 7: IEEE float data
    int32_data: bool = false, // bit 8: extended int handling
    hybrid_bitrate: bool = false, // bit 9: hybrid bitrate noise shaping
    hybrid_balance: bool = false, // bit 10: hybrid stereo balance
    initial_block: bool = false, // bit 11: initial block in sequence
    final_block: bool = false, // bit 12: final block in sequence
    left_shift_lsb: u5 = 0, // bits 13-17: left shift applied
    max_magnitude: u5 = 0, // bits 18-22: max magnitude
    sample_rate_idx: u4 = 0, // bits 23-26: sample rate index
    _reserved: u2 = 0, // bits 27-28
    use_iir: bool = false, // bit 29: IIR filter
    false_stereo: bool = false, // bit 30: false stereo
    dsd_audio: bool = false, // bit 31: DSD audio

    pub fn getBytesPerSample(self: WavPackFlags) u8 {
        return self.bytes_per_sample_lsb + 1;
    }
};

/// WavPack sample rate table
const SAMPLE_RATES = [_]u32{
    6000,  8000,  9600,  11025, 12000, 16000, 22050,  24000,
    32000, 44100, 48000, 64000, 88200, 96000, 192000, 0,
};

/// WavPack file reader
pub const WavPackReader = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // Block header info
    version: u16,
    block_index: u64,
    total_samples: u64,
    block_samples: u32,
    flags: WavPackFlags,
    crc: u32,

    // Derived info
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,

    const Self = @This();

    /// WavPack magic signature
    const WVPK_MAGIC = "wvpk".*;

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .version = 0,
            .block_index = 0,
            .total_samples = 0,
            .block_samples = 0,
            .flags = @bitCast(@as(u32, 0)),
            .crc = 0,
            .sample_rate = 44100,
            .channels = 2,
            .bits_per_sample = 16,
        };

        try self.parseHeader();
        return self;
    }

    fn readBytes(self: *Self, comptime N: usize) ?*const [N]u8 {
        if (self.pos + N > self.data.len) return null;
        const result = self.data[self.pos..][0..N];
        self.pos += N;
        return result;
    }

    fn readU16Le(self: *Self) ?u16 {
        const bytes = self.readBytes(2) orelse return null;
        return std.mem.readInt(u16, bytes, .little);
    }

    fn readU32Le(self: *Self) ?u32 {
        const bytes = self.readBytes(4) orelse return null;
        return std.mem.readInt(u32, bytes, .little);
    }

    fn parseHeader(self: *Self) !void {
        // Check magic
        const magic = self.readBytes(4) orelse return AudioError.TruncatedData;
        if (!std.mem.eql(u8, magic, &WVPK_MAGIC)) return AudioError.InvalidFormat;

        // Block size (not including magic)
        _ = self.readU32Le() orelse return AudioError.TruncatedData;

        // Version
        self.version = self.readU16Le() orelse return AudioError.TruncatedData;
        if (self.version < 0x402 or self.version > 0x410) {
            // Version out of supported range
        }

        // Track/index info
        _ = self.readBytes(2) orelse return AudioError.TruncatedData;

        // Total samples
        self.total_samples = self.readU32Le() orelse return AudioError.TruncatedData;

        // Block index
        self.block_index = self.readU32Le() orelse return AudioError.TruncatedData;

        // Block samples
        self.block_samples = self.readU32Le() orelse return AudioError.TruncatedData;

        // Flags
        const flags_raw = self.readU32Le() orelse return AudioError.TruncatedData;
        self.flags = @bitCast(flags_raw);

        // CRC
        self.crc = self.readU32Le() orelse return AudioError.TruncatedData;

        // Derive audio info from flags
        self.derivedInfo();
    }

    fn derivedInfo(self: *Self) void {
        // Sample rate
        const sr_idx = self.flags.sample_rate_idx;
        if (sr_idx < SAMPLE_RATES.len) {
            self.sample_rate = SAMPLE_RATES[sr_idx];
        }

        // Channels
        self.channels = if (self.flags.mono) 1 else 2;

        // Bits per sample
        const bps = self.flags.getBytesPerSample();
        self.bits_per_sample = bps * 8;
    }

    /// Get sample format
    pub fn getSampleFormat(self: *const Self) SampleFormat {
        if (self.flags.float_data) {
            return .f32le;
        }
        return switch (self.bits_per_sample) {
            8 => .u8,
            16 => .s16le,
            24 => .s24le,
            32 => .s32le,
            else => .s16le,
        };
    }

    /// Get channel layout
    pub fn getChannelLayout(self: *const Self) ChannelLayout {
        return ChannelLayout.fromChannelCount(self.channels);
    }

    /// Get duration
    pub fn getDuration(self: *const Self) Duration {
        if (self.sample_rate == 0) return Duration.ZERO;
        const us = self.total_samples * 1_000_000 / self.sample_rate;
        return Duration.fromMicroseconds(us);
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return self.sample_rate;
    }

    /// Get channel count
    pub fn getChannels(self: *const Self) u8 {
        return self.channels;
    }

    /// Get bits per sample
    pub fn getBitsPerSample(self: *const Self) u8 {
        return self.bits_per_sample;
    }

    /// Check if hybrid mode
    pub fn isHybrid(self: *const Self) bool {
        return self.flags.hybrid;
    }

    /// Check if lossless
    pub fn isLossless(self: *const Self) bool {
        return !self.flags.hybrid;
    }

    /// Check if DSD audio
    pub fn isDsd(self: *const Self) bool {
        return self.flags.dsd_audio;
    }

    /// Get version string
    pub fn getVersionString(self: *const Self) []const u8 {
        if (self.version >= 0x410) return "5.x";
        if (self.version >= 0x407) return "4.x";
        if (self.version >= 0x402) return "4.0";
        return "Unknown";
    }
};

/// Detect if data is WavPack format
pub fn isWavPack(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], "wvpk");
}

// ============================================================================
// Tests
// ============================================================================

test "WavPackFlags bytes per sample" {
    var flags: WavPackFlags = @bitCast(@as(u32, 0));
    flags.bytes_per_sample_lsb = 0;
    try std.testing.expectEqual(@as(u8, 1), flags.getBytesPerSample());

    flags.bytes_per_sample_lsb = 1;
    try std.testing.expectEqual(@as(u8, 2), flags.getBytesPerSample());

    flags.bytes_per_sample_lsb = 2;
    try std.testing.expectEqual(@as(u8, 3), flags.getBytesPerSample());
}

test "WavPack detection" {
    const wvpk_magic = "wvpk" ++ [_]u8{0} ** 20;
    try std.testing.expect(isWavPack(wvpk_magic));

    const not_wvpk = "RIFF" ++ [_]u8{0} ** 20;
    try std.testing.expect(!isWavPack(not_wvpk));
}

test "Sample rate table" {
    try std.testing.expectEqual(@as(u32, 44100), SAMPLE_RATES[9]);
    try std.testing.expectEqual(@as(u32, 48000), SAMPLE_RATES[10]);
    try std.testing.expectEqual(@as(u32, 96000), SAMPLE_RATES[13]);
}
