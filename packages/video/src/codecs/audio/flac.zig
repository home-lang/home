// Home Video Library - FLAC Audio Codec
// Free Lossless Audio Codec parsing
// Reference: FLAC format specification

const std = @import("std");
const types = @import("../../core/types.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// FLAC Block Types
// ============================================================================

pub const BlockType = enum(u7) {
    streaminfo = 0,
    padding = 1,
    application = 2,
    seektable = 3,
    vorbis_comment = 4,
    cuesheet = 5,
    picture = 6,
    _,

    pub fn isValid(self: BlockType) bool {
        return @intFromEnum(self) <= 6 or @intFromEnum(self) >= 127;
    }
};

// ============================================================================
// FLAC Stream Info
// ============================================================================

pub const StreamInfo = struct {
    min_block_size: u16,
    max_block_size: u16,
    min_frame_size: u24,
    max_frame_size: u24,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    total_samples: u64,
    md5_signature: [16]u8,

    pub fn parse(data: []const u8) !StreamInfo {
        if (data.len < 34) {
            return VideoError.TruncatedData;
        }

        const min_block_size = std.mem.readInt(u16, data[0..2], .big);
        const max_block_size = std.mem.readInt(u16, data[2..4], .big);

        // 24-bit values
        const min_frame_size: u24 = @as(u24, data[4]) << 16 | @as(u24, data[5]) << 8 | @as(u24, data[6]);
        const max_frame_size: u24 = @as(u24, data[7]) << 16 | @as(u24, data[8]) << 8 | @as(u24, data[9]);

        // Sample rate (20 bits), channels (3 bits), bits per sample (5 bits), total samples (36 bits)
        const sample_rate: u32 = (@as(u32, data[10]) << 12) | (@as(u32, data[11]) << 4) | (@as(u32, data[12]) >> 4);
        const channels: u8 = ((data[12] >> 1) & 0x07) + 1;
        const bits_per_sample: u8 = (((data[12] & 0x01) << 4) | ((data[13] >> 4) & 0x0F)) + 1;

        // Total samples (36 bits)
        const total_samples: u64 = (@as(u64, data[13] & 0x0F) << 32) |
            (@as(u64, data[14]) << 24) |
            (@as(u64, data[15]) << 16) |
            (@as(u64, data[16]) << 8) |
            (@as(u64, data[17]));

        var md5: [16]u8 = undefined;
        @memcpy(&md5, data[18..34]);

        return StreamInfo{
            .min_block_size = min_block_size,
            .max_block_size = max_block_size,
            .min_frame_size = min_frame_size,
            .max_frame_size = max_frame_size,
            .sample_rate = sample_rate,
            .channels = channels,
            .bits_per_sample = bits_per_sample,
            .total_samples = total_samples,
            .md5_signature = md5,
        };
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const StreamInfo) f64 {
        if (self.sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(self.total_samples)) / @as(f64, @floatFromInt(self.sample_rate));
    }

    /// Get bitrate estimate
    pub fn getBitrate(self: *const StreamInfo) u32 {
        return self.sample_rate * @as(u32, self.channels) * @as(u32, self.bits_per_sample);
    }
};

// ============================================================================
// FLAC Seek Point
// ============================================================================

pub const SeekPoint = struct {
    sample_number: u64,
    stream_offset: u64,
    frame_samples: u16,

    pub fn parse(data: []const u8) !SeekPoint {
        if (data.len < 18) {
            return VideoError.TruncatedData;
        }

        return SeekPoint{
            .sample_number = std.mem.readInt(u64, data[0..8], .big),
            .stream_offset = std.mem.readInt(u64, data[8..16], .big),
            .frame_samples = std.mem.readInt(u16, data[16..18], .big),
        };
    }

    pub fn isPlaceholder(self: *const SeekPoint) bool {
        return self.sample_number == 0xFFFFFFFFFFFFFFFF;
    }
};

// ============================================================================
// FLAC Metadata Block Header
// ============================================================================

pub const MetadataBlockHeader = struct {
    is_last: bool,
    block_type: BlockType,
    length: u24,

    pub fn parse(data: []const u8) !MetadataBlockHeader {
        if (data.len < 4) {
            return VideoError.TruncatedData;
        }

        const is_last = (data[0] & 0x80) != 0;
        const block_type: BlockType = @enumFromInt(@as(u7, @truncate(data[0] & 0x7F)));
        const length: u24 = @as(u24, data[1]) << 16 | @as(u24, data[2]) << 8 | @as(u24, data[3]);

        return MetadataBlockHeader{
            .is_last = is_last,
            .block_type = block_type,
            .length = length,
        };
    }
};

// ============================================================================
// FLAC Picture
// ============================================================================

pub const PictureType = enum(u32) {
    other = 0,
    file_icon_32x32 = 1,
    other_file_icon = 2,
    cover_front = 3,
    cover_back = 4,
    leaflet_page = 5,
    media = 6,
    lead_artist = 7,
    artist = 8,
    conductor = 9,
    band = 10,
    composer = 11,
    lyricist = 12,
    recording_location = 13,
    during_recording = 14,
    during_performance = 15,
    screen_capture = 16,
    bright_fish = 17, // A bright coloured fish
    illustration = 18,
    band_logotype = 19,
    publisher_logotype = 20,
    _,
};

pub const Picture = struct {
    picture_type: PictureType,
    mime_type: []const u8,
    description: []const u8,
    width: u32,
    height: u32,
    color_depth: u32,
    colors_used: u32,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Picture {
        if (data.len < 32) {
            return VideoError.TruncatedData;
        }

        var pos: usize = 0;

        const picture_type: PictureType = @enumFromInt(std.mem.readInt(u32, data[pos..][0..4], .big));
        pos += 4;

        const mime_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;

        if (pos + mime_len > data.len) return VideoError.TruncatedData;
        const mime_type = try allocator.dupe(u8, data[pos..][0..mime_len]);
        errdefer allocator.free(mime_type);
        pos += mime_len;

        if (pos + 4 > data.len) return VideoError.TruncatedData;
        const desc_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;

        if (pos + desc_len > data.len) return VideoError.TruncatedData;
        const description = try allocator.dupe(u8, data[pos..][0..desc_len]);
        errdefer allocator.free(description);
        pos += desc_len;

        if (pos + 20 > data.len) {
            allocator.free(description);
            allocator.free(mime_type);
            return VideoError.TruncatedData;
        }

        const width = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;
        const height = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;
        const color_depth = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;
        const colors_used = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;
        const pic_data_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;

        if (pos + pic_data_len > data.len) {
            allocator.free(description);
            allocator.free(mime_type);
            return VideoError.TruncatedData;
        }
        const pic_data = try allocator.dupe(u8, data[pos..][0..pic_data_len]);

        return Picture{
            .picture_type = picture_type,
            .mime_type = mime_type,
            .description = description,
            .width = width,
            .height = height,
            .color_depth = color_depth,
            .colors_used = colors_used,
            .data = pic_data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Picture) void {
        self.allocator.free(self.mime_type);
        self.allocator.free(self.description);
        self.allocator.free(self.data);
    }
};

// ============================================================================
// FLAC Frame Header
// ============================================================================

pub const ChannelAssignment = enum(u4) {
    independent = 0, // 1-8 channels
    left_side = 8, // left/side stereo
    side_right = 9, // side/right stereo
    mid_side = 10, // mid/side stereo
    _,
};

pub const FrameHeader = struct {
    blocking_strategy: bool, // false = fixed, true = variable
    block_size: u16,
    sample_rate: u32,
    channel_assignment: ChannelAssignment,
    channels: u8,
    sample_size: u8,
    frame_or_sample_number: u64,
    crc8: u8,

    pub fn getBlockSize(code: u4, extended_data: []const u8) u16 {
        return switch (code) {
            0 => 0, // reserved
            1 => 192,
            2 => 576,
            3 => 1152,
            4 => 2304,
            5 => 4608,
            6 => if (extended_data.len >= 1) @as(u16, extended_data[0]) + 1 else 0,
            7 => if (extended_data.len >= 2) std.mem.readInt(u16, extended_data[0..2], .big) + 1 else 0,
            8 => 256,
            9 => 512,
            10 => 1024,
            11 => 2048,
            12 => 4096,
            13 => 8192,
            14 => 16384,
            15 => 32768,
        };
    }

    pub fn getSampleRate(code: u4, stream_info_rate: u32, extended_data: []const u8) u32 {
        return switch (code) {
            0 => stream_info_rate,
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
            12 => if (extended_data.len >= 1) @as(u32, extended_data[0]) * 1000 else 0,
            13 => if (extended_data.len >= 2) std.mem.readInt(u16, extended_data[0..2], .big) else 0,
            14 => if (extended_data.len >= 2) @as(u32, std.mem.readInt(u16, extended_data[0..2], .big)) * 10 else 0,
            15 => 0, // invalid
        };
    }

    pub fn getSampleSize(code: u3, stream_info_bits: u8) u8 {
        return switch (code) {
            0 => stream_info_bits,
            1 => 8,
            2 => 12,
            3 => 0, // reserved
            4 => 16,
            5 => 20,
            6 => 24,
            7 => 0, // reserved
        };
    }
};

// ============================================================================
// FLAC Reader
// ============================================================================

pub const FlacReader = struct {
    data: []const u8,
    pos: usize,
    stream_info: ?StreamInfo,
    seek_points: std.ArrayList(SeekPoint),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Self {
        var reader = Self{
            .data = data,
            .pos = 0,
            .stream_info = null,
            .seek_points = std.ArrayList(SeekPoint).init(allocator),
            .allocator = allocator,
        };

        try reader.parse();
        return reader;
    }

    pub fn deinit(self: *Self) void {
        self.seek_points.deinit();
    }

    fn parse(self: *Self) !void {
        // Check magic number "fLaC"
        if (self.data.len < 4 or !std.mem.eql(u8, self.data[0..4], "fLaC")) {
            return VideoError.InvalidMagicBytes;
        }
        self.pos = 4;

        // Parse metadata blocks
        var is_last = false;
        while (!is_last and self.pos < self.data.len) {
            const header = try MetadataBlockHeader.parse(self.data[self.pos..]);
            self.pos += 4;

            is_last = header.is_last;

            const block_end = self.pos + header.length;
            if (block_end > self.data.len) {
                return VideoError.TruncatedData;
            }

            const block_data = self.data[self.pos..block_end];

            switch (header.block_type) {
                .streaminfo => {
                    self.stream_info = try StreamInfo.parse(block_data);
                },
                .seektable => {
                    try self.parseSeekTable(block_data);
                },
                else => {},
            }

            self.pos = block_end;
        }

        if (self.stream_info == null) {
            return VideoError.InvalidHeader;
        }
    }

    fn parseSeekTable(self: *Self, data: []const u8) !void {
        var offset: usize = 0;
        while (offset + 18 <= data.len) {
            const seek_point = try SeekPoint.parse(data[offset..]);
            if (!seek_point.isPlaceholder()) {
                try self.seek_points.append(seek_point);
            }
            offset += 18;
        }
    }

    /// Get stream duration in seconds
    pub fn getDuration(self: *const Self) ?f64 {
        if (self.stream_info) |info| {
            return info.getDuration();
        }
        return null;
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) ?u32 {
        if (self.stream_info) |info| {
            return info.sample_rate;
        }
        return null;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) ?u8 {
        if (self.stream_info) |info| {
            return info.channels;
        }
        return null;
    }

    /// Get bits per sample
    pub fn getBitsPerSample(self: *const Self) ?u8 {
        if (self.stream_info) |info| {
            return info.bits_per_sample;
        }
        return null;
    }
};

// ============================================================================
// FLAC Detection
// ============================================================================

pub fn isFlac(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "fLaC");
}

// ============================================================================
// Tests
// ============================================================================

test "BlockType validity" {
    try std.testing.expect(BlockType.streaminfo.isValid());
    try std.testing.expect(BlockType.seektable.isValid());
    try std.testing.expect(BlockType.picture.isValid());
}

test "MetadataBlockHeader parsing" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x22 }; // streaminfo, not last, length 34
    const header = try MetadataBlockHeader.parse(&data);

    try std.testing.expectEqual(BlockType.streaminfo, header.block_type);
    try std.testing.expect(!header.is_last);
    try std.testing.expectEqual(@as(u24, 34), header.length);

    const last_data = [_]u8{ 0x83, 0x00, 0x00, 0x10 }; // seektable (3), is last, length 16
    const last_header = try MetadataBlockHeader.parse(&last_data);

    try std.testing.expect(last_header.is_last);
    try std.testing.expectEqual(BlockType.seektable, last_header.block_type);
}

test "SeekPoint parsing" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, // sample 4096
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // offset 0
        0x10, 0x00, // 4096 samples
    };

    const point = try SeekPoint.parse(&data);
    try std.testing.expectEqual(@as(u64, 4096), point.sample_number);
    try std.testing.expectEqual(@as(u64, 0), point.stream_offset);
    try std.testing.expectEqual(@as(u16, 4096), point.frame_samples);
    try std.testing.expect(!point.isPlaceholder());
}

test "SeekPoint placeholder" {
    const data = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    };

    const point = try SeekPoint.parse(&data);
    try std.testing.expect(point.isPlaceholder());
}

test "isFlac detection" {
    const flac_header = [_]u8{ 'f', 'L', 'a', 'C', 0x00 };
    try std.testing.expect(isFlac(&flac_header));

    const not_flac = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expect(!isFlac(&not_flac));
}

test "FrameHeader block size" {
    try std.testing.expectEqual(@as(u16, 192), FrameHeader.getBlockSize(1, &[_]u8{}));
    try std.testing.expectEqual(@as(u16, 4096), FrameHeader.getBlockSize(12, &[_]u8{}));
}

test "FrameHeader sample rate" {
    try std.testing.expectEqual(@as(u32, 44100), FrameHeader.getSampleRate(9, 0, &[_]u8{}));
    try std.testing.expectEqual(@as(u32, 48000), FrameHeader.getSampleRate(10, 0, &[_]u8{}));
}

test "FrameHeader sample size" {
    try std.testing.expectEqual(@as(u8, 16), FrameHeader.getSampleSize(4, 0));
    try std.testing.expectEqual(@as(u8, 24), FrameHeader.getSampleSize(6, 0));
}

test "PictureType values" {
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(PictureType.cover_front));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(PictureType.cover_back));
}
