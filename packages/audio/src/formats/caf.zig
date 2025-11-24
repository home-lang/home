// Home Audio Library - CAF Format
// Core Audio Format reader (Apple's flexible container)

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("../core/types.zig");
const SampleFormat = types.SampleFormat;
const ChannelLayout = types.ChannelLayout;
const Duration = types.Duration;

const audio_error = @import("../core/error.zig");
const AudioError = audio_error.AudioError;

/// CAF audio format codes
pub const CafFormatCode = enum(u32) {
    lpcm = 0x6C70636D, // 'lpcm' - Linear PCM
    aac = 0x61616320, // 'aac ' - AAC
    alac = 0x616C6163, // 'alac' - Apple Lossless
    mp3 = 0x2E6D7033, // '.mp3' - MP3
    ima4 = 0x696D6134, // 'ima4' - IMA 4:1 ADPCM
    ulaw = 0x756C6177, // 'ulaw' - μ-law
    alaw = 0x616C6177, // 'alaw' - A-law
    opus = 0x6F707573, // 'opus' - Opus
    flac = 0x666C6163, // 'flac' - FLAC

    pub fn toString(self: CafFormatCode) []const u8 {
        return switch (self) {
            .lpcm => "Linear PCM",
            .aac => "AAC",
            .alac => "Apple Lossless",
            .mp3 => "MP3",
            .ima4 => "IMA ADPCM",
            .ulaw => "μ-law",
            .alaw => "A-law",
            .opus => "Opus",
            .flac => "FLAC",
        };
    }
};

/// CAF format flags for LPCM
pub const CafFormatFlags = packed struct(u32) {
    is_float: bool = false,
    is_little_endian: bool = false,
    _reserved: u30 = 0,
};

/// CAF file reader
pub const CafReader = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // Audio description
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,

    // Data location
    data_offset: u64,
    data_size: u64,
    num_packets: u64,

    // Metadata
    title: ?[]const u8,
    artist: ?[]const u8,
    album: ?[]const u8,

    const Self = @This();

    /// CAF magic and chunk types
    const CAF_MAGIC = "caff".*;
    const CHUNK_DESC = "desc".*;
    const CHUNK_DATA = "data".*;
    const CHUNK_PAKT = "pakt".*;
    const CHUNK_INFO = "info".*;
    const CHUNK_CHAN = "chan".*;

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .sample_rate = 0,
            .format_id = 0,
            .format_flags = 0,
            .bytes_per_packet = 0,
            .frames_per_packet = 0,
            .channels_per_frame = 0,
            .bits_per_channel = 0,
            .data_offset = 0,
            .data_size = 0,
            .num_packets = 0,
            .title = null,
            .artist = null,
            .album = null,
        };

        try self.parseHeader();
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.title) |t| self.allocator.free(t);
        if (self.artist) |a| self.allocator.free(a);
        if (self.album) |a| self.allocator.free(a);
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

    fn readF64Be(self: *Self) ?f64 {
        const bytes = self.readBytes(8) orelse return null;
        return @bitCast(std.mem.readInt(u64, bytes, .big));
    }

    fn skip(self: *Self, count: u64) bool {
        if (self.pos + count > self.data.len) return false;
        self.pos += @intCast(count);
        return true;
    }

    fn parseHeader(self: *Self) !void {
        // CAF file header
        const magic = self.readBytes(4) orelse return AudioError.TruncatedData;
        if (!std.mem.eql(u8, magic, &CAF_MAGIC)) return AudioError.InvalidFormat;

        const version = self.readBytes(2) orelse return AudioError.TruncatedData;
        if (std.mem.readInt(u16, version, .big) != 1) return AudioError.InvalidFormat;

        _ = self.readBytes(2); // flags

        // Parse chunks
        while (self.pos < self.data.len) {
            const chunk_type = self.readBytes(4) orelse break;
            const chunk_size = self.readU64Be() orelse break;
            const chunk_start = self.pos;

            if (std.mem.eql(u8, chunk_type, &CHUNK_DESC)) {
                try self.parseDescChunk();
            } else if (std.mem.eql(u8, chunk_type, &CHUNK_DATA)) {
                _ = self.readU32Be(); // edit count
                self.data_offset = self.pos;
                self.data_size = chunk_size - 4;
            } else if (std.mem.eql(u8, chunk_type, &CHUNK_INFO)) {
                try self.parseInfoChunk(chunk_size);
            }

            // Move to next chunk
            self.pos = chunk_start + @as(usize, @intCast(chunk_size));
        }
    }

    fn parseDescChunk(self: *Self) !void {
        self.sample_rate = self.readF64Be() orelse return;
        self.format_id = self.readU32Be() orelse return;
        self.format_flags = self.readU32Be() orelse return;
        self.bytes_per_packet = self.readU32Be() orelse return;
        self.frames_per_packet = self.readU32Be() orelse return;
        self.channels_per_frame = self.readU32Be() orelse return;
        self.bits_per_channel = self.readU32Be() orelse return;
    }

    fn parseInfoChunk(self: *Self, size: u64) !void {
        const end_pos = self.pos + @as(usize, @intCast(size));
        const num_entries = self.readU32Be() orelse return;

        for (0..num_entries) |_| {
            if (self.pos >= end_pos) break;

            // Read null-terminated key
            const key_start = self.pos;
            while (self.pos < end_pos and self.data[self.pos] != 0) {
                self.pos += 1;
            }
            const key = self.data[key_start..self.pos];
            self.pos += 1; // Skip null

            // Read null-terminated value
            const val_start = self.pos;
            while (self.pos < end_pos and self.data[self.pos] != 0) {
                self.pos += 1;
            }
            const value = self.data[val_start..self.pos];
            self.pos += 1; // Skip null

            // Store known keys
            if (std.mem.eql(u8, key, "title")) {
                self.title = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "artist")) {
                self.artist = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, key, "album")) {
                self.album = try self.allocator.dupe(u8, value);
            }
        }
    }

    /// Get sample format
    pub fn getSampleFormat(self: *const Self) SampleFormat {
        if (self.format_id != @intFromEnum(CafFormatCode.lpcm)) {
            return .f32le; // Decoded format
        }

        const flags: CafFormatFlags = @bitCast(self.format_flags);

        if (flags.is_float) {
            return if (flags.is_little_endian) .f32le else .f32be;
        }

        const is_le = flags.is_little_endian;
        return switch (self.bits_per_channel) {
            8 => .u8,
            16 => if (is_le) .s16le else .s16be,
            24 => if (is_le) .s24le else .s24be,
            32 => if (is_le) .s32le else .s32be,
            else => .s16le,
        };
    }

    /// Get channel layout
    pub fn getChannelLayout(self: *const Self) ChannelLayout {
        return ChannelLayout.fromChannelCount(@intCast(self.channels_per_frame));
    }

    /// Get duration
    pub fn getDuration(self: *const Self) Duration {
        if (self.sample_rate == 0 or self.bytes_per_packet == 0) return Duration.ZERO;

        const total_frames = if (self.frames_per_packet > 0)
            (self.data_size / self.bytes_per_packet) * self.frames_per_packet
        else
            self.data_size / (self.channels_per_frame * self.bits_per_channel / 8);

        const us = @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_frames)) / self.sample_rate * 1_000_000));
        return Duration.fromMicroseconds(us);
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return @intFromFloat(self.sample_rate);
    }

    /// Get channel count
    pub fn getChannels(self: *const Self) u8 {
        return @intCast(self.channels_per_frame);
    }

    /// Get format name
    pub fn getFormatName(self: *const Self) []const u8 {
        const format_code: CafFormatCode = @enumFromInt(self.format_id);
        return format_code.toString();
    }
};

/// Detect if data is CAF format
pub fn isCaf(data: []const u8) bool {
    if (data.len < 8) return false;
    return std.mem.eql(u8, data[0..4], "caff") and
        std.mem.readInt(u16, data[4..6], .big) == 1;
}

// ============================================================================
// Tests
// ============================================================================

test "CAF detection" {
    const caf_magic = "caff" ++ [_]u8{ 0, 1, 0, 0 };
    try std.testing.expect(isCaf(caf_magic));

    const not_caf = "RIFF" ++ [_]u8{ 0, 0, 0, 0 };
    try std.testing.expect(!isCaf(not_caf));
}

test "CafFormatCode toString" {
    try std.testing.expectEqualStrings("Linear PCM", CafFormatCode.lpcm.toString());
    try std.testing.expectEqualStrings("Apple Lossless", CafFormatCode.alac.toString());
}
