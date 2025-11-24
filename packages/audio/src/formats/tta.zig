// Home Audio Library - TTA Format
// True Audio lossless codec reader

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;
const ChannelLayout = types.ChannelLayout;
const Duration = types.Duration;

const audio_error = @import("../core/error.zig");
const AudioError = audio_error.AudioError;

/// TTA audio format (TTA1 = lossless, TTA2 = lossy)
pub const TtaFormat = enum(u32) {
    tta1 = 0x31415454, // "TTA1"
    tta2 = 0x32415454, // "TTA2"

    pub fn isLossless(self: TtaFormat) bool {
        return self == .tta1;
    }
};

/// TTA file reader
pub const TtaReader = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // Header info
    format: TtaFormat,
    audio_format: u16,
    channels: u16,
    bits_per_sample: u16,
    sample_rate: u32,
    data_length: u32,

    // CRC
    crc32: u32,

    // Seek table
    seek_table_offset: usize,
    num_frames: u32,

    const Self = @This();

    /// TTA1 magic signature
    const TTA1_MAGIC = "TTA1".*;
    const TTA2_MAGIC = "TTA2".*;

    /// Samples per frame (fixed in TTA)
    const SAMPLES_PER_FRAME = 256 * 245; // 62720

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .format = .tta1,
            .audio_format = 0,
            .channels = 0,
            .bits_per_sample = 0,
            .sample_rate = 0,
            .data_length = 0,
            .crc32 = 0,
            .seek_table_offset = 0,
            .num_frames = 0,
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

        if (std.mem.eql(u8, magic, &TTA1_MAGIC)) {
            self.format = .tta1;
        } else if (std.mem.eql(u8, magic, &TTA2_MAGIC)) {
            self.format = .tta2;
        } else {
            return AudioError.InvalidFormat;
        }

        // Audio format (1 = PCM)
        self.audio_format = self.readU16Le() orelse return AudioError.TruncatedData;

        // Channels
        self.channels = self.readU16Le() orelse return AudioError.TruncatedData;

        // Bits per sample
        self.bits_per_sample = self.readU16Le() orelse return AudioError.TruncatedData;

        // Sample rate
        self.sample_rate = self.readU32Le() orelse return AudioError.TruncatedData;

        // Data length (total samples)
        self.data_length = self.readU32Le() orelse return AudioError.TruncatedData;

        // CRC32 of header
        self.crc32 = self.readU32Le() orelse return AudioError.TruncatedData;

        // Calculate number of frames
        self.num_frames = (self.data_length + SAMPLES_PER_FRAME - 1) / SAMPLES_PER_FRAME;

        // Seek table starts after header
        self.seek_table_offset = self.pos;
    }

    /// Get sample format
    pub fn getSampleFormat(self: *const Self) SampleFormat {
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
        return ChannelLayout.fromChannelCount(@intCast(self.channels));
    }

    /// Get duration
    pub fn getDuration(self: *const Self) Duration {
        if (self.sample_rate == 0) return Duration.ZERO;
        const us = @as(u64, self.data_length) * 1_000_000 / self.sample_rate;
        return Duration.fromMicroseconds(us);
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return self.sample_rate;
    }

    /// Get channel count
    pub fn getChannels(self: *const Self) u8 {
        return @intCast(self.channels);
    }

    /// Get bits per sample
    pub fn getBitsPerSample(self: *const Self) u16 {
        return self.bits_per_sample;
    }

    /// Get total samples
    pub fn getTotalSamples(self: *const Self) u32 {
        return self.data_length;
    }

    /// Check if lossless
    pub fn isLossless(self: *const Self) bool {
        return self.format.isLossless();
    }

    /// Get compression ratio estimate
    pub fn getCompressionRatio(self: *const Self) f32 {
        const uncompressed_size = @as(u64, self.data_length) * self.channels * (self.bits_per_sample / 8);
        if (uncompressed_size == 0) return 1.0;
        return @as(f32, @floatFromInt(self.data.len)) / @as(f32, @floatFromInt(uncompressed_size));
    }
};

/// Detect if data is TTA format
pub fn isTta(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], "TTA1") or std.mem.eql(u8, data[0..4], "TTA2");
}

// ============================================================================
// Tests
// ============================================================================

test "TtaFormat lossless check" {
    try std.testing.expect(TtaFormat.tta1.isLossless());
    try std.testing.expect(!TtaFormat.tta2.isLossless());
}

test "TTA detection" {
    const tta1_magic = "TTA1" ++ [_]u8{0} ** 20;
    try std.testing.expect(isTta(tta1_magic));

    const tta2_magic = "TTA2" ++ [_]u8{0} ** 20;
    try std.testing.expect(isTta(tta2_magic));

    const not_tta = "RIFF" ++ [_]u8{0} ** 20;
    try std.testing.expect(!isTta(not_tta));
}
