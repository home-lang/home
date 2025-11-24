// Home Audio Library - DSD/DSF Format
// Direct Stream Digital format reader (audiophile high-resolution audio)

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const AudioFormat = types.AudioFormat;
const SampleFormat = types.SampleFormat;
const ChannelLayout = types.ChannelLayout;
const Duration = types.Duration;

const audio_error = @import("../core/error.zig");
const AudioError = audio_error.AudioError;

/// DSD sample rates
pub const DsdRate = enum(u32) {
    dsd64 = 2822400, // 64x CD sample rate (44.1kHz * 64)
    dsd128 = 5644800, // 128x CD sample rate
    dsd256 = 11289600, // 256x CD sample rate
    dsd512 = 22579200, // 512x CD sample rate

    pub fn fromHz(hz: u32) ?DsdRate {
        return switch (hz) {
            2822400 => .dsd64,
            5644800 => .dsd128,
            11289600 => .dsd256,
            22579200 => .dsd512,
            else => null,
        };
    }

    pub fn toHz(self: DsdRate) u32 {
        return @intFromEnum(self);
    }

    pub fn toString(self: DsdRate) []const u8 {
        return switch (self) {
            .dsd64 => "DSD64",
            .dsd128 => "DSD128",
            .dsd256 => "DSD256",
            .dsd512 => "DSD512",
        };
    }
};

/// DSF file reader (Sony's DSD format)
pub const DsfReader = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // File info
    format_version: u32,
    format_id: u32,
    channel_type: u32,
    channels: u8,
    sample_rate: u32,
    bits_per_sample: u8,
    sample_count: u64,
    block_size: u32,

    // Data location
    data_offset: u64,
    data_size: u64,

    // Metadata offset
    metadata_offset: u64,

    const Self = @This();

    /// DSF chunk IDs
    const DSD_CHUNK = "DSD ".*;
    const FMT_CHUNK = "fmt ".*;
    const DATA_CHUNK = "data".*;

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .format_version = 0,
            .format_id = 0,
            .channel_type = 0,
            .channels = 0,
            .sample_rate = 0,
            .bits_per_sample = 1,
            .sample_count = 0,
            .block_size = 4096,
            .data_offset = 0,
            .data_size = 0,
            .metadata_offset = 0,
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

    fn readU32Le(self: *Self) ?u32 {
        const bytes = self.readBytes(4) orelse return null;
        return std.mem.readInt(u32, bytes, .little);
    }

    fn readU64Le(self: *Self) ?u64 {
        const bytes = self.readBytes(8) orelse return null;
        return std.mem.readInt(u64, bytes, .little);
    }

    fn parseHeader(self: *Self) !void {
        // DSD chunk
        const dsd_id = self.readBytes(4) orelse return AudioError.TruncatedData;
        if (!std.mem.eql(u8, dsd_id, &DSD_CHUNK)) return AudioError.InvalidFormat;

        const dsd_size = self.readU64Le() orelse return AudioError.TruncatedData;
        if (dsd_size < 28) return AudioError.InvalidFormat;

        const total_size = self.readU64Le() orelse return AudioError.TruncatedData;
        _ = total_size;

        self.metadata_offset = self.readU64Le() orelse return AudioError.TruncatedData;

        // fmt chunk
        const fmt_id = self.readBytes(4) orelse return AudioError.TruncatedData;
        if (!std.mem.eql(u8, fmt_id, &FMT_CHUNK)) return AudioError.InvalidFormat;

        const fmt_size = self.readU64Le() orelse return AudioError.TruncatedData;
        if (fmt_size < 52) return AudioError.InvalidFormat;

        self.format_version = self.readU32Le() orelse return AudioError.TruncatedData;
        self.format_id = self.readU32Le() orelse return AudioError.TruncatedData;
        self.channel_type = self.readU32Le() orelse return AudioError.TruncatedData;
        self.channels = @intCast(self.readU32Le() orelse return AudioError.TruncatedData);
        self.sample_rate = self.readU32Le() orelse return AudioError.TruncatedData;
        self.bits_per_sample = @intCast(self.readU32Le() orelse return AudioError.TruncatedData);
        self.sample_count = self.readU64Le() orelse return AudioError.TruncatedData;
        self.block_size = self.readU32Le() orelse return AudioError.TruncatedData;
        _ = self.readU32Le(); // reserved

        // data chunk
        const data_id = self.readBytes(4) orelse return AudioError.TruncatedData;
        if (!std.mem.eql(u8, data_id, &DATA_CHUNK)) return AudioError.InvalidFormat;

        const data_chunk_size = self.readU64Le() orelse return AudioError.TruncatedData;
        self.data_offset = self.pos;
        self.data_size = data_chunk_size - 12; // Subtract chunk header
    }

    /// Get DSD rate category
    pub fn getDsdRate(self: *const Self) ?DsdRate {
        return DsdRate.fromHz(self.sample_rate);
    }

    /// Get channel layout
    pub fn getChannelLayout(self: *const Self) ChannelLayout {
        return ChannelLayout.fromChannelCount(self.channels);
    }

    /// Get duration
    pub fn getDuration(self: *const Self) Duration {
        if (self.sample_rate == 0) return Duration.ZERO;
        const us = self.sample_count * 1_000_000 / self.sample_rate;
        return Duration.fromMicroseconds(us);
    }

    /// Get equivalent PCM sample rate (for DSD->PCM conversion)
    pub fn getPcmSampleRate(self: *const Self) u32 {
        // DSD64 -> 88.2kHz, DSD128 -> 176.4kHz, etc.
        return self.sample_rate / 64;
    }
};

/// DSDIFF file reader (Philips' DSD format)
pub const DsdiffReader = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // File info
    channels: u8,
    sample_rate: u32,
    sample_count: u64,

    // Data location
    data_offset: u64,
    data_size: u64,

    const Self = @This();

    /// DSDIFF chunk IDs
    const FORM_ID = "FRM8".*;
    const DSD_TYPE = "DSD ".*;
    const FVER_CHUNK = "FVER".*;
    const PROP_CHUNK = "PROP".*;
    const DSD_CHUNK = "DSD ".*;
    const FS_CHUNK = "FS  ".*;
    const CHNL_CHUNK = "CHNL".*;

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .channels = 0,
            .sample_rate = 0,
            .sample_count = 0,
            .data_offset = 0,
            .data_size = 0,
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

    fn readU32Be(self: *Self) ?u32 {
        const bytes = self.readBytes(4) orelse return null;
        return std.mem.readInt(u32, bytes, .big);
    }

    fn readU64Be(self: *Self) ?u64 {
        const bytes = self.readBytes(8) orelse return null;
        return std.mem.readInt(u64, bytes, .big);
    }

    fn skip(self: *Self, count: u64) bool {
        if (self.pos + count > self.data.len) return false;
        self.pos += @intCast(count);
        return true;
    }

    fn parseHeader(self: *Self) !void {
        // FORM chunk
        const form_id = self.readBytes(4) orelse return AudioError.TruncatedData;
        if (!std.mem.eql(u8, form_id, &FORM_ID)) return AudioError.InvalidFormat;

        _ = self.readU64Be(); // File size

        const form_type = self.readBytes(4) orelse return AudioError.TruncatedData;
        if (!std.mem.eql(u8, form_type, &DSD_TYPE)) return AudioError.InvalidFormat;

        // Parse chunks
        while (self.pos < self.data.len) {
            const chunk_id = self.readBytes(4) orelse break;
            const chunk_size = self.readU64Be() orelse break;

            if (std.mem.eql(u8, chunk_id, &PROP_CHUNK)) {
                try self.parsePropChunk(chunk_size);
            } else if (std.mem.eql(u8, chunk_id, &DSD_CHUNK)) {
                self.data_offset = self.pos;
                self.data_size = chunk_size;
                break;
            } else {
                if (!self.skip(chunk_size)) break;
            }
        }
    }

    fn parsePropChunk(self: *Self, size: u64) !void {
        const end_pos = self.pos + size;

        const prop_type = self.readBytes(4) orelse return;
        if (!std.mem.eql(u8, prop_type, "SND ")) return;

        while (self.pos < end_pos) {
            const chunk_id = self.readBytes(4) orelse break;
            const chunk_size = self.readU64Be() orelse break;

            if (std.mem.eql(u8, chunk_id, &FS_CHUNK)) {
                self.sample_rate = self.readU32Be() orelse 0;
            } else if (std.mem.eql(u8, chunk_id, &CHNL_CHUNK)) {
                const num_channels = self.readBytes(2) orelse break;
                self.channels = @intCast(std.mem.readInt(u16, num_channels, .big));
                if (!self.skip(chunk_size - 2)) break;
            } else {
                if (!self.skip(chunk_size)) break;
            }
        }

        self.pos = @intCast(end_pos);
    }

    /// Get DSD rate category
    pub fn getDsdRate(self: *const Self) ?DsdRate {
        return DsdRate.fromHz(self.sample_rate);
    }

    /// Get channel layout
    pub fn getChannelLayout(self: *const Self) ChannelLayout {
        return ChannelLayout.fromChannelCount(self.channels);
    }
};

/// Detect if data is DSF format
pub fn isDsf(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], "DSD ");
}

/// Detect if data is DSDIFF format
pub fn isDsdiff(data: []const u8) bool {
    if (data.len < 12) return false;
    return std.mem.eql(u8, data[0..4], "FRM8") and std.mem.eql(u8, data[8..12], "DSD ");
}

// ============================================================================
// Tests
// ============================================================================

test "DsdRate conversions" {
    try std.testing.expectEqual(DsdRate.dsd64, DsdRate.fromHz(2822400).?);
    try std.testing.expectEqual(DsdRate.dsd128, DsdRate.fromHz(5644800).?);
    try std.testing.expectEqualStrings("DSD64", DsdRate.dsd64.toString());
}

test "DSF detection" {
    const dsf_magic = "DSD " ++ [_]u8{0} ** 20;
    try std.testing.expect(isDsf(dsf_magic));

    const not_dsf = "RIFF" ++ [_]u8{0} ** 20;
    try std.testing.expect(!isDsf(not_dsf));
}

test "DSDIFF detection" {
    const dsdiff_magic = "FRM8" ++ [_]u8{0} ** 4 ++ "DSD ";
    try std.testing.expect(isDsdiff(dsdiff_magic));
}
