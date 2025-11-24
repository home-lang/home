// Home Audio Library - MP3 Format
// MPEG Audio Layer III decoder

const std = @import("std");
const types = @import("../core/types.zig");
const frame_mod = @import("../core/frame.zig");
const err = @import("../core/error.zig");

pub const AudioFrame = frame_mod.AudioFrame;
pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const Metadata = types.Metadata;
pub const AudioError = err.AudioError;

// ============================================================================
// MP3 Constants
// ============================================================================

/// MPEG version
pub const MpegVersion = enum(u2) {
    mpeg25 = 0, // MPEG 2.5
    reserved = 1,
    mpeg2 = 2, // MPEG 2
    mpeg1 = 3, // MPEG 1
};

/// MPEG layer
pub const MpegLayer = enum(u2) {
    reserved = 0,
    layer3 = 1,
    layer2 = 2,
    layer1 = 3,
};

/// Channel mode
pub const ChannelMode = enum(u2) {
    stereo = 0,
    joint_stereo = 1,
    dual_channel = 2,
    mono = 3,
};

/// Emphasis
pub const Emphasis = enum(u2) {
    none = 0,
    ms50_15 = 1, // 50/15 ms
    reserved = 2,
    ccitt_j17 = 3, // CCITT J.17
};

// Bitrate table [version][layer][index]
const BITRATE_TABLE = [4][4][16]u16{
    // MPEG 2.5
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // Reserved
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 }, // Layer 3
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 }, // Layer 2
        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0 }, // Layer 1
    },
    // Reserved
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    // MPEG 2
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // Reserved
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 }, // Layer 3
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 }, // Layer 2
        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0 }, // Layer 1
    },
    // MPEG 1
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // Reserved
        .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 }, // Layer 3
        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0 }, // Layer 2
        .{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0 }, // Layer 1
    },
};

// Sample rate table [version][index]
const SAMPLE_RATE_TABLE = [4][4]u32{
    .{ 11025, 12000, 8000, 0 }, // MPEG 2.5
    .{ 0, 0, 0, 0 }, // Reserved
    .{ 22050, 24000, 16000, 0 }, // MPEG 2
    .{ 44100, 48000, 32000, 0 }, // MPEG 1
};

// Samples per frame [version][layer]
const SAMPLES_PER_FRAME = [4][4]u32{
    .{ 0, 576, 1152, 384 }, // MPEG 2.5
    .{ 0, 0, 0, 0 }, // Reserved
    .{ 0, 576, 1152, 384 }, // MPEG 2
    .{ 0, 1152, 1152, 384 }, // MPEG 1
};

// ============================================================================
// MP3 Frame Header
// ============================================================================

pub const Mp3FrameHeader = struct {
    version: MpegVersion,
    layer: MpegLayer,
    has_crc: bool,
    bitrate_index: u4,
    sample_rate_index: u2,
    padding: bool,
    private: bool,
    channel_mode: ChannelMode,
    mode_extension: u2,
    copyright: bool,
    original: bool,
    emphasis: Emphasis,

    const Self = @This();

    /// Parse frame header from 4 bytes
    pub fn parse(bytes: [4]u8) !Self {
        // Check sync word (11 bits of 1s)
        if (bytes[0] != 0xFF or (bytes[1] & 0xE0) != 0xE0) {
            return AudioError.SyncLost;
        }

        const version: MpegVersion = @enumFromInt((bytes[1] >> 3) & 0x03);
        const layer: MpegLayer = @enumFromInt((bytes[1] >> 1) & 0x03);

        if (version == .reserved or layer == .reserved) {
            return AudioError.InvalidFrameData;
        }

        return Self{
            .version = version,
            .layer = layer,
            .has_crc = (bytes[1] & 0x01) == 0,
            .bitrate_index = @truncate(bytes[2] >> 4),
            .sample_rate_index = @truncate((bytes[2] >> 2) & 0x03),
            .padding = (bytes[2] & 0x02) != 0,
            .private = (bytes[2] & 0x01) != 0,
            .channel_mode = @enumFromInt((bytes[3] >> 6) & 0x03),
            .mode_extension = @truncate((bytes[3] >> 4) & 0x03),
            .copyright = (bytes[3] & 0x08) != 0,
            .original = (bytes[3] & 0x04) != 0,
            .emphasis = @enumFromInt(bytes[3] & 0x03),
        };
    }

    /// Get bitrate in kbps
    pub fn getBitrate(self: Self) u16 {
        return BITRATE_TABLE[@intFromEnum(self.version)][@intFromEnum(self.layer)][self.bitrate_index];
    }

    /// Get sample rate in Hz
    pub fn getSampleRate(self: Self) u32 {
        return SAMPLE_RATE_TABLE[@intFromEnum(self.version)][self.sample_rate_index];
    }

    /// Get number of samples per frame
    pub fn getSamplesPerFrame(self: Self) u32 {
        return SAMPLES_PER_FRAME[@intFromEnum(self.version)][@intFromEnum(self.layer)];
    }

    /// Get number of channels
    pub fn getChannels(self: Self) u8 {
        return if (self.channel_mode == .mono) 1 else 2;
    }

    /// Get frame size in bytes
    pub fn getFrameSize(self: Self) u32 {
        const bitrate = @as(u32, self.getBitrate()) * 1000;
        const sample_rate = self.getSampleRate();
        const samples = self.getSamplesPerFrame();

        if (bitrate == 0 or sample_rate == 0) return 0;

        var size: u32 = (samples * bitrate) / (8 * sample_rate);
        if (self.padding) {
            size += if (self.layer == .layer1) 4 else 1;
        }
        return size;
    }
};

// ============================================================================
// ID3 Tag Parser
// ============================================================================

pub const Id3Version = enum {
    v1,
    v1_1,
    v2_2,
    v2_3,
    v2_4,
};

pub const Id3Tag = struct {
    version: Id3Version,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    year: ?u16 = null,
    comment: ?[]const u8 = null,
    track: ?u8 = null,
    genre: ?u8 = null,
    size: usize = 0,

    allocator: ?std.mem.Allocator = null,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (self.allocator) |alloc| {
            if (self.title) |t| alloc.free(t);
            if (self.artist) |a| alloc.free(a);
            if (self.album) |a| alloc.free(a);
            if (self.comment) |c| alloc.free(c);
        }
    }

    /// Parse ID3v1 tag (last 128 bytes of file)
    pub fn parseV1(allocator: std.mem.Allocator, data: []const u8) !?Self {
        if (data.len < 128) return null;

        const tag_data = data[data.len - 128 ..];
        if (!std.mem.eql(u8, tag_data[0..3], "TAG")) {
            return null;
        }

        var tag = Self{
            .version = .v1,
            .size = 128,
            .allocator = allocator,
        };

        tag.title = try trimAndDupe(allocator, tag_data[3..33]);
        tag.artist = try trimAndDupe(allocator, tag_data[33..63]);
        tag.album = try trimAndDupe(allocator, tag_data[63..93]);

        // Year
        const year_str = tag_data[93..97];
        tag.year = std.fmt.parseInt(u16, std.mem.trim(u8, year_str, &[_]u8{ 0, ' ' }), 10) catch null;

        // ID3v1.1: Track number in last byte of comment if byte 125 is 0
        if (tag_data[125] == 0 and tag_data[126] != 0) {
            tag.version = .v1_1;
            tag.track = tag_data[126];
            tag.comment = try trimAndDupe(allocator, tag_data[97..125]);
        } else {
            tag.comment = try trimAndDupe(allocator, tag_data[97..127]);
        }

        tag.genre = tag_data[127];

        return tag;
    }

    /// Parse ID3v2 header
    pub fn parseV2Header(data: []const u8) !?struct { version: Id3Version, size: usize } {
        if (data.len < 10) return null;
        if (!std.mem.eql(u8, data[0..3], "ID3")) return null;

        const major_version = data[3];
        const version: Id3Version = switch (major_version) {
            2 => .v2_2,
            3 => .v2_3,
            4 => .v2_4,
            else => return null,
        };

        // Syncsafe integer (7 bits per byte)
        const size: usize = (@as(usize, data[6]) << 21) |
            (@as(usize, data[7]) << 14) |
            (@as(usize, data[8]) << 7) |
            @as(usize, data[9]);

        return .{ .version = version, .size = size + 10 };
    }

    fn trimAndDupe(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
        const trimmed = std.mem.trim(u8, data, &[_]u8{ 0, ' ' });
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }
};

// ============================================================================
// MP3 Reader
// ============================================================================

pub const Mp3Reader = struct {
    data: []const u8,
    pos: usize,
    id3_tag: ?Id3Tag,
    first_frame_header: ?Mp3FrameHeader,
    total_frames: u64,
    current_frame: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        var reader = Self{
            .data = data,
            .pos = 0,
            .id3_tag = null,
            .first_frame_header = null,
            .total_frames = 0,
            .current_frame = 0,
            .allocator = allocator,
        };

        try reader.parse();
        return reader;
    }

    fn parse(self: *Self) !void {
        // Check for ID3v2 tag at beginning
        if (Id3Tag.parseV2Header(self.data)) |header| {
            self.pos = header.size;
        }

        // Find first frame
        try self.findNextFrame();

        // Parse first frame header for format info
        if (self.pos + 4 <= self.data.len) {
            const header_bytes = self.data[self.pos..][0..4];
            self.first_frame_header = try Mp3FrameHeader.parse(header_bytes.*);
        }

        // Try to parse ID3v1 at end
        self.id3_tag = try Id3Tag.parseV1(self.allocator, self.data);

        // Count frames (approximate)
        if (self.first_frame_header) |header| {
            const audio_size = self.data.len - self.pos - (if (self.id3_tag != null) @as(usize, 128) else 0);
            const avg_frame_size = header.getFrameSize();
            if (avg_frame_size > 0) {
                self.total_frames = audio_size / avg_frame_size;
            }
        }
    }

    fn findNextFrame(self: *Self) !void {
        while (self.pos + 4 <= self.data.len) {
            if (self.data[self.pos] == 0xFF and (self.data[self.pos + 1] & 0xE0) == 0xE0) {
                // Potential frame sync
                const header = Mp3FrameHeader.parse(self.data[self.pos..][0..4].*) catch {
                    self.pos += 1;
                    continue;
                };

                // Validate frame
                if (header.getBitrate() > 0 and header.getSampleRate() > 0) {
                    return;
                }
            }
            self.pos += 1;
        }
        return AudioError.SyncLost;
    }

    pub fn deinit(self: *Self) void {
        if (self.id3_tag) |*tag| {
            tag.deinit();
        }
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        if (self.first_frame_header) |h| return h.getSampleRate();
        return 44100;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        if (self.first_frame_header) |h| return h.getChannels();
        return 2;
    }

    /// Get bitrate in kbps
    pub fn getBitrate(self: *const Self) u16 {
        if (self.first_frame_header) |h| return h.getBitrate();
        return 128;
    }

    /// Get estimated duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        if (self.first_frame_header) |header| {
            const samples_per_frame = header.getSamplesPerFrame();
            const sample_rate = header.getSampleRate();
            if (sample_rate > 0) {
                return @as(f64, @floatFromInt(self.total_frames * samples_per_frame)) / @as(f64, @floatFromInt(sample_rate));
            }
        }
        return 0;
    }

    /// Get metadata
    pub fn getMetadata(self: *const Self) ?Metadata {
        if (self.id3_tag) |tag| {
            return Metadata{
                .title = tag.title,
                .artist = tag.artist,
                .album = tag.album,
                .year = tag.year,
                .comment = tag.comment,
                .track_number = if (tag.track) |t| t else null,
            };
        }
        return null;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if data is an MP3 file
pub fn isMp3(data: []const u8) bool {
    // Check for ID3v2 tag
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "ID3")) {
        return true;
    }

    // Check for frame sync
    if (data.len >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) {
        return true;
    }

    return false;
}

/// Decode MP3 from memory (returns decoded PCM audio)
/// Note: Full MP3 decoding requires implementing the MPEG audio decoder
/// This is a placeholder that returns an error for now
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !AudioFrame {
    _ = allocator;
    _ = data;
    // Full MP3 decoding is complex and requires implementing:
    // - Huffman decoding
    // - Inverse quantization
    // - Stereo decoding
    // - Inverse MDCT
    // - Polyphase synthesis filter bank
    return AudioError.NotImplemented;
}

// ============================================================================
// Tests
// ============================================================================

test "MP3 frame header parsing" {
    // Valid MPEG1 Layer 3 frame header
    // 0xFF 0xFB = sync + MPEG1 + Layer 3 + no CRC
    // 0x90 = 128kbps + 44100Hz + no padding
    // 0x00 = stereo + ...
    const header_bytes = [4]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    const header = try Mp3FrameHeader.parse(header_bytes);

    try std.testing.expectEqual(MpegVersion.mpeg1, header.version);
    try std.testing.expectEqual(MpegLayer.layer3, header.layer);
    try std.testing.expectEqual(@as(u16, 128), header.getBitrate());
    try std.testing.expectEqual(@as(u32, 44100), header.getSampleRate());
}

test "MP3 detection" {
    const mp3_with_id3 = [_]u8{ 'I', 'D', '3', 4, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(isMp3(&mp3_with_id3));

    const mp3_frame = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    try std.testing.expect(isMp3(&mp3_frame));

    const not_mp3 = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expect(!isMp3(&not_mp3));
}
