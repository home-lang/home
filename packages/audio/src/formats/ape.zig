// Home Audio Library - APE Format
// Monkey's Audio lossless codec reader

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;
const ChannelLayout = types.ChannelLayout;
const Duration = types.Duration;

const audio_error = @import("../core/error.zig");
const AudioError = audio_error.AudioError;

/// APE compression levels
pub const ApeCompression = enum(u16) {
    fast = 1000,
    normal = 2000,
    high = 3000,
    extra_high = 4000,
    insane = 5000,

    pub fn fromValue(value: u16) ?ApeCompression {
        return switch (value) {
            1000 => .fast,
            2000 => .normal,
            3000 => .high,
            4000 => .extra_high,
            5000 => .insane,
            else => null,
        };
    }

    pub fn toString(self: ApeCompression) []const u8 {
        return switch (self) {
            .fast => "Fast",
            .normal => "Normal",
            .high => "High",
            .extra_high => "Extra High",
            .insane => "Insane",
        };
    }
};

/// APE file reader
pub const ApeReader = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // Header info
    version: u16,
    compression_type: u16,
    format_flags: u16,
    blocks_per_frame: u32,
    final_frame_blocks: u32,
    total_frames: u32,

    // Audio info
    bits_per_sample: u16,
    channels: u16,
    sample_rate: u32,

    // Calculated
    total_samples: u64,

    // Descriptor (v3.98+)
    descriptor_bytes: u32,
    header_bytes: u32,
    seektable_bytes: u32,
    header_data_bytes: u32,
    ape_frame_data_bytes: u64,
    terminating_data_bytes: u64,

    const Self = @This();

    /// APE magic signature
    const APE_MAGIC = "MAC ".*;

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .version = 0,
            .compression_type = 0,
            .format_flags = 0,
            .blocks_per_frame = 0,
            .final_frame_blocks = 0,
            .total_frames = 0,
            .bits_per_sample = 16,
            .channels = 2,
            .sample_rate = 44100,
            .total_samples = 0,
            .descriptor_bytes = 0,
            .header_bytes = 0,
            .seektable_bytes = 0,
            .header_data_bytes = 0,
            .ape_frame_data_bytes = 0,
            .terminating_data_bytes = 0,
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

    fn skip(self: *Self, count: usize) bool {
        if (self.pos + count > self.data.len) return false;
        self.pos += count;
        return true;
    }

    fn parseHeader(self: *Self) !void {
        // Check magic
        const magic = self.readBytes(4) orelse return AudioError.TruncatedData;
        if (!std.mem.eql(u8, magic, &APE_MAGIC)) return AudioError.InvalidFormat;

        // File version
        self.version = self.readU16Le() orelse return AudioError.TruncatedData;

        if (self.version >= 3980) {
            // New format (3.98+) with descriptor
            try self.parseNewFormat();
        } else {
            // Old format
            try self.parseOldFormat();
        }

        // Calculate total samples
        if (self.total_frames > 0) {
            self.total_samples = (@as(u64, self.total_frames) - 1) * self.blocks_per_frame + self.final_frame_blocks;
        }
    }

    fn parseNewFormat(self: *Self) !void {
        // Descriptor
        _ = self.readU16Le(); // Padding
        self.descriptor_bytes = self.readU32Le() orelse return AudioError.TruncatedData;
        self.header_bytes = self.readU32Le() orelse return AudioError.TruncatedData;
        self.seektable_bytes = self.readU32Le() orelse return AudioError.TruncatedData;
        self.header_data_bytes = self.readU32Le() orelse return AudioError.TruncatedData;
        self.ape_frame_data_bytes = @as(u64, self.readU32Le() orelse return AudioError.TruncatedData);
        _ = self.readU32Le(); // High bytes
        self.terminating_data_bytes = @as(u64, self.readU32Le() orelse return AudioError.TruncatedData);
        _ = self.readU32Le(); // High bytes

        // Skip MD5
        if (!self.skip(16)) return AudioError.TruncatedData;

        // Header
        self.compression_type = self.readU16Le() orelse return AudioError.TruncatedData;
        self.format_flags = self.readU16Le() orelse return AudioError.TruncatedData;
        self.blocks_per_frame = self.readU32Le() orelse return AudioError.TruncatedData;
        self.final_frame_blocks = self.readU32Le() orelse return AudioError.TruncatedData;
        self.total_frames = self.readU32Le() orelse return AudioError.TruncatedData;
        self.bits_per_sample = self.readU16Le() orelse return AudioError.TruncatedData;
        self.channels = self.readU16Le() orelse return AudioError.TruncatedData;
        self.sample_rate = self.readU32Le() orelse return AudioError.TruncatedData;
    }

    fn parseOldFormat(self: *Self) !void {
        self.compression_type = self.readU16Le() orelse return AudioError.TruncatedData;
        self.format_flags = self.readU16Le() orelse return AudioError.TruncatedData;
        self.channels = self.readU16Le() orelse return AudioError.TruncatedData;
        self.sample_rate = self.readU32Le() orelse return AudioError.TruncatedData;

        _ = self.readU32Le(); // Header bytes
        _ = self.readU32Le(); // Terminating bytes

        self.total_frames = self.readU32Le() orelse return AudioError.TruncatedData;
        self.final_frame_blocks = self.readU32Le() orelse return AudioError.TruncatedData;

        // Blocks per frame depends on version
        if (self.version >= 3950) {
            self.blocks_per_frame = 73728 * 4;
        } else if (self.version >= 3900) {
            self.blocks_per_frame = 73728;
        } else if (self.version >= 3800) {
            self.blocks_per_frame = 73728;
        } else {
            self.blocks_per_frame = 9216;
        }

        // Bits per sample
        if (self.format_flags & 0x01 != 0) {
            self.bits_per_sample = 8;
        } else if (self.format_flags & 0x08 != 0) {
            self.bits_per_sample = 24;
        } else {
            self.bits_per_sample = 16;
        }
    }

    /// Get compression level
    pub fn getCompression(self: *const Self) ?ApeCompression {
        return ApeCompression.fromValue(self.compression_type);
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
        const us = self.total_samples * 1_000_000 / self.sample_rate;
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

    /// Get version string
    pub fn getVersionString(self: *const Self) []const u8 {
        if (self.version >= 3990) return "3.99+";
        if (self.version >= 3980) return "3.98+";
        if (self.version >= 3970) return "3.97+";
        if (self.version >= 3950) return "3.95+";
        if (self.version >= 3900) return "3.90+";
        return "3.x";
    }
};

/// Detect if data is APE format
pub fn isApe(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], "MAC ");
}

// ============================================================================
// Tests
// ============================================================================

test "ApeCompression values" {
    try std.testing.expectEqual(ApeCompression.fast, ApeCompression.fromValue(1000).?);
    try std.testing.expectEqual(ApeCompression.insane, ApeCompression.fromValue(5000).?);
    try std.testing.expectEqualStrings("Normal", ApeCompression.normal.toString());
}

test "APE detection" {
    const ape_magic = "MAC " ++ [_]u8{0} ** 20;
    try std.testing.expect(isApe(ape_magic));

    const not_ape = "RIFF" ++ [_]u8{0} ** 20;
    try std.testing.expect(!isApe(not_ape));
}
