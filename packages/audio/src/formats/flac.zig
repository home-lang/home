// Home Audio Library - FLAC Format
// Free Lossless Audio Codec decoder/encoder

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
// FLAC Constants
// ============================================================================

const FLAC_MAGIC = "fLaC".*;

/// Metadata block types
pub const MetadataBlockType = enum(u7) {
    streaminfo = 0,
    padding = 1,
    application = 2,
    seektable = 3,
    vorbis_comment = 4,
    cuesheet = 5,
    picture = 6,
    invalid = 127,
    _,
};

/// Channel assignment
pub const ChannelAssignment = enum(u4) {
    independent = 0, // Independent channels
    left_side = 1, // Left + Side
    right_side = 2, // Right + Side
    mid_side = 3, // Mid + Side
    _,
};

// ============================================================================
// FLAC Stream Info
// ============================================================================

pub const StreamInfo = struct {
    /// Minimum block size (in samples)
    min_block_size: u16,

    /// Maximum block size (in samples)
    max_block_size: u16,

    /// Minimum frame size (in bytes, 0 = unknown)
    min_frame_size: u24,

    /// Maximum frame size (in bytes, 0 = unknown)
    max_frame_size: u24,

    /// Sample rate in Hz
    sample_rate: u20,

    /// Number of channels (1-8)
    channels: u3,

    /// Bits per sample (4-32)
    bits_per_sample: u5,

    /// Total samples (0 = unknown)
    total_samples: u36,

    /// MD5 signature of unencoded audio
    md5_signature: [16]u8,

    const Self = @This();

    /// Parse from 34-byte STREAMINFO block
    pub fn parse(data: []const u8) !Self {
        if (data.len < 34) return AudioError.TruncatedData;

        return Self{
            .min_block_size = std.mem.readInt(u16, data[0..2], .big),
            .max_block_size = std.mem.readInt(u16, data[2..4], .big),
            .min_frame_size = @truncate(std.mem.readInt(u24, data[4..7], .big)),
            .max_frame_size = @truncate(std.mem.readInt(u24, data[7..10], .big)),
            .sample_rate = @truncate(std.mem.readInt(u32, data[10..14], .big) >> 12),
            .channels = @truncate((std.mem.readInt(u16, data[12..14], .big) >> 1) & 0x07),
            .bits_per_sample = @truncate(((std.mem.readInt(u16, data[12..14], .big) & 0x01) << 4) |
                ((data[14] >> 4) & 0x0F)),
            .total_samples = @truncate((@as(u64, data[14] & 0x0F) << 32) |
                std.mem.readInt(u32, data[15..19], .big)),
            .md5_signature = data[18..34].*,
        };
    }

    /// Get duration in seconds
    pub fn getDuration(self: Self) f64 {
        if (self.total_samples == 0 or self.sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(self.total_samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Get sample format
    pub fn getSampleFormat(self: Self) SampleFormat {
        return switch (self.bits_per_sample + 1) {
            1...8 => .u8,
            9...16 => .s16le,
            17...24 => .s24le,
            25...32 => .s32le,
            else => .s16le,
        };
    }

    /// Get channel count
    pub fn getChannelCount(self: Self) u8 {
        return @as(u8, self.channels) + 1;
    }
};

// ============================================================================
// Vorbis Comment
// ============================================================================

pub const VorbisComment = struct {
    vendor: []const u8,
    comments: std.ArrayList(Comment),
    allocator: std.mem.Allocator,

    pub const Comment = struct {
        field: []const u8,
        value: []const u8,
    };

    const Self = @This();

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 8) return AudioError.TruncatedData;

        var pos: usize = 0;

        // Vendor length (little-endian)
        const vendor_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (pos + vendor_len > data.len) return AudioError.TruncatedData;
        const vendor = try allocator.dupe(u8, data[pos..][0..vendor_len]);
        pos += vendor_len;

        // Comment count
        if (pos + 4 > data.len) return AudioError.TruncatedData;
        const comment_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        var comments = std.ArrayList(Comment).init(allocator);
        errdefer {
            for (comments.items) |c| {
                allocator.free(c.field);
                allocator.free(c.value);
            }
            comments.deinit();
        }

        for (0..comment_count) |_| {
            if (pos + 4 > data.len) break;

            const comment_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            if (pos + comment_len > data.len) break;
            const comment_data = data[pos..][0..comment_len];
            pos += comment_len;

            // Find '=' separator
            if (std.mem.indexOf(u8, comment_data, "=")) |eq_pos| {
                const field = try allocator.dupe(u8, comment_data[0..eq_pos]);
                const value = try allocator.dupe(u8, comment_data[eq_pos + 1 ..]);
                try comments.append(.{ .field = field, .value = value });
            }
        }

        return Self{
            .vendor = vendor,
            .comments = comments,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.vendor);
        for (self.comments.items) |c| {
            self.allocator.free(c.field);
            self.allocator.free(c.value);
        }
        self.comments.deinit();
    }

    /// Get a field value (case-insensitive)
    pub fn get(self: *const Self, field: []const u8) ?[]const u8 {
        for (self.comments.items) |c| {
            if (std.ascii.eqlIgnoreCase(c.field, field)) {
                return c.value;
            }
        }
        return null;
    }

    /// Convert to Metadata
    pub fn toMetadata(self: *const Self) Metadata {
        var meta = Metadata{};

        meta.title = self.get("TITLE");
        meta.artist = self.get("ARTIST");
        meta.album = self.get("ALBUM");
        meta.album_artist = self.get("ALBUMARTIST");
        meta.genre = self.get("GENRE");
        meta.comment = self.get("COMMENT");

        if (self.get("DATE") orelse self.get("YEAR")) |year_str| {
            meta.year = std.fmt.parseInt(u16, year_str[0..@min(4, year_str.len)], 10) catch null;
        }

        if (self.get("TRACKNUMBER")) |track_str| {
            meta.track_number = std.fmt.parseInt(u16, track_str, 10) catch null;
        }

        return meta;
    }
};

// ============================================================================
// FLAC Frame Header
// ============================================================================

pub const FlacFrameHeader = struct {
    /// Variable block size (vs fixed)
    variable_block_size: bool,

    /// Block size in samples
    block_size: u16,

    /// Sample rate (0 = use streaminfo)
    sample_rate: u32,

    /// Channel assignment
    channel_assignment: u4,

    /// Bits per sample (0 = use streaminfo)
    bits_per_sample: u8,

    /// Frame or sample number
    frame_or_sample_number: u64,

    /// CRC-8 of header
    crc8: u8,

    const Self = @This();

    pub fn parse(data: []const u8) !Self {
        if (data.len < 4) return AudioError.TruncatedData;

        // Sync code (14 bits: 0x3FFE)
        if (data[0] != 0xFF or (data[1] & 0xFC) != 0xF8) {
            return AudioError.SyncLost;
        }

        const variable = (data[1] & 0x01) != 0;
        const block_size_code = (data[2] >> 4) & 0x0F;
        const sample_rate_code = data[2] & 0x0F;
        const channel_assignment: u4 = @truncate((data[3] >> 4) & 0x0F);
        const bits_per_sample_code = (data[3] >> 1) & 0x07;

        // Decode block size
        const block_size: u16 = switch (block_size_code) {
            0 => return AudioError.InvalidFrameData,
            1 => 192,
            2...5 => |c| @as(u16, 576) << @intCast(c - 2),
            6 => 0, // Get from end of header (8-bit)
            7 => 0, // Get from end of header (16-bit)
            8...15 => |c| @as(u16, 256) << @intCast(c - 8),
        };

        // Decode sample rate
        const sample_rate: u32 = switch (sample_rate_code) {
            0 => 0, // Use streaminfo
            1 => 88200,
            2 => 176400,
            3 => 192000,
            4 => 8000,
            5 => 16000,
            6 => 22050,
            7 => 24000,
            8 => 32000,
            9 => 44100,
            10 => 48000,
            11 => 96000,
            12...14 => 0, // Get from end of header
            15 => return AudioError.InvalidFrameData,
        };

        // Decode bits per sample
        const bits_per_sample: u8 = switch (bits_per_sample_code) {
            0 => 0, // Use streaminfo
            1 => 8,
            2 => 12,
            3 => return AudioError.InvalidFrameData,
            4 => 16,
            5 => 20,
            6 => 24,
            7 => return AudioError.InvalidFrameData,
        };

        return Self{
            .variable_block_size = variable,
            .block_size = block_size,
            .sample_rate = sample_rate,
            .channel_assignment = channel_assignment,
            .bits_per_sample = bits_per_sample,
            .frame_or_sample_number = 0,
            .crc8 = 0,
        };
    }

    pub fn getChannels(self: Self) u8 {
        return switch (self.channel_assignment) {
            0...7 => self.channel_assignment + 1,
            8, 9, 10 => 2, // Stereo with side coding
            else => 2,
        };
    }
};

// ============================================================================
// FLAC Reader
// ============================================================================

pub const FlacReader = struct {
    data: []const u8,
    pos: usize,
    stream_info: StreamInfo,
    vorbis_comment: ?VorbisComment,
    audio_data_start: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 42) return AudioError.TruncatedData;

        // Verify FLAC magic
        if (!std.mem.eql(u8, data[0..4], &FLAC_MAGIC)) {
            return AudioError.InvalidFormat;
        }

        var reader = Self{
            .data = data,
            .pos = 4,
            .stream_info = undefined,
            .vorbis_comment = null,
            .audio_data_start = 0,
            .allocator = allocator,
        };

        try reader.parseMetadata();
        return reader;
    }

    fn parseMetadata(self: *Self) !void {
        var found_streaminfo = false;

        while (self.pos + 4 <= self.data.len) {
            const header = self.data[self.pos];
            const is_last = (header & 0x80) != 0;
            const block_type: MetadataBlockType = @enumFromInt(header & 0x7F);
            self.pos += 1;

            const block_size = std.mem.readInt(u24, self.data[self.pos..][0..3], .big);
            self.pos += 3;

            if (self.pos + block_size > self.data.len) {
                return AudioError.TruncatedData;
            }

            const block_data = self.data[self.pos..][0..block_size];

            switch (block_type) {
                .streaminfo => {
                    self.stream_info = try StreamInfo.parse(block_data);
                    found_streaminfo = true;
                },
                .vorbis_comment => {
                    self.vorbis_comment = try VorbisComment.parse(self.allocator, block_data);
                },
                else => {},
            }

            self.pos += block_size;

            if (is_last) break;
        }

        if (!found_streaminfo) return AudioError.InvalidHeader;
        self.audio_data_start = self.pos;
    }

    pub fn deinit(self: *Self) void {
        if (self.vorbis_comment) |*vc| {
            vc.deinit();
        }
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return self.stream_info.sample_rate;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        return self.stream_info.getChannelCount();
    }

    /// Get bits per sample
    pub fn getBitsPerSample(self: *const Self) u8 {
        return @as(u8, self.stream_info.bits_per_sample) + 1;
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        return self.stream_info.getDuration();
    }

    /// Get total samples
    pub fn getTotalSamples(self: *const Self) u64 {
        return self.stream_info.total_samples;
    }

    /// Get metadata
    pub fn getMetadata(self: *const Self) ?Metadata {
        if (self.vorbis_comment) |*vc| {
            return vc.toMetadata();
        }
        return null;
    }
};

// ============================================================================
// FLAC Writer
// ============================================================================

pub const FlacWriter = struct {
    buffer: std.ArrayList(u8),
    channels: u8,
    sample_rate: u32,
    bits_per_sample: u8,
    total_samples: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new FLAC writer
    pub fn init(
        allocator: std.mem.Allocator,
        channels: u8,
        sample_rate: u32,
        bits_per_sample: u8,
    ) !Self {
        var writer = Self{
            .buffer = std.ArrayList(u8).init(allocator),
            .channels = channels,
            .sample_rate = sample_rate,
            .bits_per_sample = bits_per_sample,
            .total_samples = 0,
            .allocator = allocator,
        };

        // Write magic and placeholder STREAMINFO
        try writer.buffer.appendSlice(&FLAC_MAGIC);
        // Placeholder for metadata blocks
        try writer.writeStreamInfoPlaceholder();

        return writer;
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    fn writeStreamInfoPlaceholder(self: *Self) !void {
        // Last metadata block flag + STREAMINFO type
        try self.buffer.append(0x80); // Last block, type 0

        // Block size: 34 bytes
        try self.buffer.append(0);
        try self.buffer.append(0);
        try self.buffer.append(34);

        // Placeholder STREAMINFO (34 bytes)
        try self.buffer.appendNTimes(0, 34);
    }

    /// Finalize and get the FLAC data
    pub fn finalize(self: *Self) ![]u8 {
        // Update STREAMINFO block
        // This is a simplified version - full implementation would compute MD5
        const info_start: usize = 8; // After magic + header

        // Min/max block size (use 4096)
        std.mem.writeInt(u16, self.buffer.items[info_start..][0..2], 4096, .big);
        std.mem.writeInt(u16, self.buffer.items[info_start + 2 ..][0..2], 4096, .big);

        // Sample rate, channels, bits per sample, total samples
        const sample_rate_bits: u32 = @as(u32, self.sample_rate) << 12;
        const channels_bits: u32 = (@as(u32, self.channels) - 1) << 9;
        const bps_bits: u32 = (@as(u32, self.bits_per_sample) - 1) << 4;
        const samples_high: u32 = @truncate(self.total_samples >> 32);

        std.mem.writeInt(u32, self.buffer.items[info_start + 10 ..][0..4], sample_rate_bits | channels_bits | bps_bits | samples_high, .big);

        const samples_low: u32 = @truncate(self.total_samples);
        std.mem.writeInt(u32, self.buffer.items[info_start + 14 ..][0..4], samples_low, .big);

        return try self.allocator.dupe(u8, self.buffer.items);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if data is a FLAC file
pub fn isFlac(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], "fLaC");
}

/// Decode FLAC from memory
/// Note: Full FLAC decoding requires implementing LPC, Rice coding, etc.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !AudioFrame {
    _ = allocator;
    _ = data;
    // Full FLAC decoding is complex and requires implementing:
    // - Rice/Golomb decoding
    // - LPC prediction
    // - Fixed prediction
    // - Stereo decorrelation
    return AudioError.NotImplemented;
}

/// Encode to FLAC format
pub fn encode(allocator: std.mem.Allocator, audio_frame: *const AudioFrame) ![]u8 {
    _ = allocator;
    _ = audio_frame;
    // Full FLAC encoding is complex
    return AudioError.NotImplemented;
}

// ============================================================================
// Tests
// ============================================================================

test "FLAC detection" {
    const flac_data = [_]u8{ 'f', 'L', 'a', 'C', 0x80, 0, 0, 34 } ++ [_]u8{0} ** 34;
    try std.testing.expect(isFlac(&flac_data));

    const not_flac = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expect(!isFlac(&not_flac));
}

test "StreamInfo getSampleFormat" {
    var info = StreamInfo{
        .min_block_size = 4096,
        .max_block_size = 4096,
        .min_frame_size = 0,
        .max_frame_size = 0,
        .sample_rate = 44100,
        .channels = 1, // 2 channels (1 + 1)
        .bits_per_sample = 15, // 16 bits (15 + 1)
        .total_samples = 0,
        .md5_signature = [_]u8{0} ** 16,
    };

    try std.testing.expectEqual(SampleFormat.s16le, info.getSampleFormat());
    try std.testing.expectEqual(@as(u8, 2), info.getChannelCount());
}
