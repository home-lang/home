// Home Audio Library - WMA Format
// Windows Media Audio decoder (ASF container)

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
// ASF/WMA Constants
// ============================================================================

/// ASF Header GUID
const ASF_HEADER_GUID = [16]u8{
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
};

/// ASF File Properties GUID
const ASF_FILE_PROPERTIES_GUID = [16]u8{
    0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11,
    0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
};

/// ASF Stream Properties GUID
const ASF_STREAM_PROPERTIES_GUID = [16]u8{
    0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11,
    0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65,
};

/// ASF Audio Media GUID
const ASF_AUDIO_MEDIA_GUID = [16]u8{
    0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11,
    0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B,
};

/// ASF Content Description GUID
const ASF_CONTENT_DESCRIPTION_GUID = [16]u8{
    0x33, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
};

/// ASF Extended Content Description GUID
const ASF_EXTENDED_CONTENT_GUID = [16]u8{
    0x40, 0xA4, 0xD0, 0xD2, 0x07, 0xE3, 0xD2, 0x11,
    0x97, 0xF0, 0x00, 0xA0, 0xC9, 0x5E, 0xA8, 0x50,
};

/// ASF Data Object GUID
const ASF_DATA_GUID = [16]u8{
    0x36, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
    0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
};

/// WMA codec IDs
pub const WmaCodecId = enum(u16) {
    wma_v1 = 0x0160, // WMA v1
    wma_v2 = 0x0161, // WMA v2
    wma_pro = 0x0162, // WMA Pro
    wma_lossless = 0x0163, // WMA Lossless
    wma_voice = 0x000A, // WMA Voice
    _,
};

// ============================================================================
// ASF Object Header
// ============================================================================

pub const AsfObjectHeader = struct {
    /// Object GUID
    guid: [16]u8,

    /// Object size (including header)
    size: u64,

    const Self = @This();
    const HEADER_SIZE = 24;

    pub fn parse(data: []const u8) !Self {
        if (data.len < HEADER_SIZE) return AudioError.TruncatedData;

        return Self{
            .guid = data[0..16].*,
            .size = std.mem.readInt(u64, data[16..24], .little),
        };
    }

    pub fn isHeader(self: Self) bool {
        return std.mem.eql(u8, &self.guid, &ASF_HEADER_GUID);
    }

    pub fn isFileProperties(self: Self) bool {
        return std.mem.eql(u8, &self.guid, &ASF_FILE_PROPERTIES_GUID);
    }

    pub fn isStreamProperties(self: Self) bool {
        return std.mem.eql(u8, &self.guid, &ASF_STREAM_PROPERTIES_GUID);
    }

    pub fn isContentDescription(self: Self) bool {
        return std.mem.eql(u8, &self.guid, &ASF_CONTENT_DESCRIPTION_GUID);
    }

    pub fn isExtendedContent(self: Self) bool {
        return std.mem.eql(u8, &self.guid, &ASF_EXTENDED_CONTENT_GUID);
    }

    pub fn isData(self: Self) bool {
        return std.mem.eql(u8, &self.guid, &ASF_DATA_GUID);
    }
};

// ============================================================================
// ASF File Properties
// ============================================================================

pub const AsfFileProperties = struct {
    /// File ID GUID
    file_id: [16]u8,

    /// File size in bytes
    file_size: u64,

    /// Creation date (100-nanosecond units since Jan 1, 1601)
    creation_date: u64,

    /// Number of data packets
    data_packets_count: u64,

    /// Play duration (100-nanosecond units)
    play_duration: u64,

    /// Send duration (100-nanosecond units)
    send_duration: u64,

    /// Preroll in milliseconds
    preroll: u64,

    /// Flags
    flags: u32,

    /// Minimum data packet size
    min_packet_size: u32,

    /// Maximum data packet size
    max_packet_size: u32,

    /// Maximum bitrate
    max_bitrate: u32,

    const Self = @This();

    pub fn parse(data: []const u8) !Self {
        if (data.len < 80) return AudioError.TruncatedData;

        return Self{
            .file_id = data[0..16].*,
            .file_size = std.mem.readInt(u64, data[16..24], .little),
            .creation_date = std.mem.readInt(u64, data[24..32], .little),
            .data_packets_count = std.mem.readInt(u64, data[32..40], .little),
            .play_duration = std.mem.readInt(u64, data[40..48], .little),
            .send_duration = std.mem.readInt(u64, data[48..56], .little),
            .preroll = std.mem.readInt(u64, data[56..64], .little),
            .flags = std.mem.readInt(u32, data[64..68], .little),
            .min_packet_size = std.mem.readInt(u32, data[68..72], .little),
            .max_packet_size = std.mem.readInt(u32, data[72..76], .little),
            .max_bitrate = std.mem.readInt(u32, data[76..80], .little),
        };
    }

    /// Get duration in seconds
    pub fn getDuration(self: Self) f64 {
        // Play duration is in 100-nanosecond units, preroll is in milliseconds
        const duration_100ns = self.play_duration;
        const preroll_100ns = self.preroll * 10000; // Convert ms to 100ns
        const actual_duration = if (duration_100ns > preroll_100ns) duration_100ns - preroll_100ns else 0;
        return @as(f64, @floatFromInt(actual_duration)) / 10_000_000.0;
    }

    /// Get bitrate in bits per second
    pub fn getBitrate(self: Self) u32 {
        return self.max_bitrate;
    }
};

// ============================================================================
// WMA Audio Format
// ============================================================================

pub const WmaAudioFormat = struct {
    /// Codec ID
    codec_id: WmaCodecId,

    /// Number of channels
    channels: u16,

    /// Sample rate in Hz
    sample_rate: u32,

    /// Average bytes per second
    avg_bytes_per_sec: u32,

    /// Block align
    block_align: u16,

    /// Bits per sample
    bits_per_sample: u16,

    /// Codec-specific data size
    extra_size: u16,

    const Self = @This();

    pub fn parse(data: []const u8) !Self {
        if (data.len < 18) return AudioError.TruncatedData;

        const codec_id_raw = std.mem.readInt(u16, data[0..2], .little);

        return Self{
            .codec_id = @enumFromInt(codec_id_raw),
            .channels = std.mem.readInt(u16, data[2..4], .little),
            .sample_rate = std.mem.readInt(u32, data[4..8], .little),
            .avg_bytes_per_sec = std.mem.readInt(u32, data[8..12], .little),
            .block_align = std.mem.readInt(u16, data[12..14], .little),
            .bits_per_sample = std.mem.readInt(u16, data[14..16], .little),
            .extra_size = std.mem.readInt(u16, data[16..18], .little),
        };
    }

    /// Get sample format
    pub fn getSampleFormat(self: Self) SampleFormat {
        return switch (self.bits_per_sample) {
            8 => .u8,
            16 => .s16le,
            24 => .s24le,
            32 => .s32le,
            else => .s16le,
        };
    }

    /// Get bitrate in kbps
    pub fn getBitrateKbps(self: Self) u32 {
        return (self.avg_bytes_per_sec * 8) / 1000;
    }

    /// Check if lossless
    pub fn isLossless(self: Self) bool {
        return self.codec_id == .wma_lossless;
    }
};

// ============================================================================
// WMA Reader
// ============================================================================

pub const WmaReader = struct {
    data: []const u8,
    pos: usize,
    file_properties: ?AsfFileProperties,
    audio_format: ?WmaAudioFormat,
    metadata: Metadata,
    data_offset: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 30) return AudioError.TruncatedData;

        var reader = Self{
            .data = data,
            .pos = 0,
            .file_properties = null,
            .audio_format = null,
            .metadata = Metadata{ .allocator = allocator },
            .data_offset = 0,
            .allocator = allocator,
        };

        try reader.parseHeader();
        return reader;
    }

    fn parseHeader(self: *Self) !void {
        // Parse ASF header object
        const header = try AsfObjectHeader.parse(self.data);
        if (!header.isHeader()) {
            return AudioError.InvalidFormat;
        }

        // Number of header objects
        if (self.data.len < 30) return AudioError.TruncatedData;
        const num_objects = std.mem.readInt(u32, self.data[24..28], .little);

        self.pos = 30; // Skip header object header + object count + reserved

        // Parse header sub-objects
        for (0..num_objects) |_| {
            if (self.pos + 24 > self.data.len) break;

            const obj = try AsfObjectHeader.parse(self.data[self.pos..]);
            const obj_data_start = self.pos + 24;
            const obj_data_end = self.pos + @as(usize, @intCast(obj.size));

            if (obj_data_end > self.data.len) break;

            const obj_data = self.data[obj_data_start..obj_data_end];

            if (obj.isFileProperties()) {
                self.file_properties = try AsfFileProperties.parse(obj_data);
            } else if (obj.isStreamProperties()) {
                try self.parseStreamProperties(obj_data);
            } else if (obj.isContentDescription()) {
                try self.parseContentDescription(obj_data);
            } else if (obj.isExtendedContent()) {
                try self.parseExtendedContent(obj_data);
            }

            self.pos = obj_data_end;
        }

        // Find data object
        while (self.pos + 24 <= self.data.len) {
            const obj = try AsfObjectHeader.parse(self.data[self.pos..]);
            if (obj.isData()) {
                self.data_offset = self.pos + 50; // Data object header + packet info
                break;
            }
            self.pos += @intCast(obj.size);
        }
    }

    fn parseStreamProperties(self: *Self, data: []const u8) !void {
        if (data.len < 54) return;

        // Check if audio stream
        const stream_type = data[0..16];
        if (!std.mem.eql(u8, stream_type, &ASF_AUDIO_MEDIA_GUID)) {
            return;
        }

        // Type-specific data offset
        const type_specific_len = std.mem.readInt(u32, data[40..44], .little);
        if (data.len < 54 + type_specific_len) return;

        const format_data = data[54..][0..@min(type_specific_len, data.len - 54)];
        self.audio_format = WmaAudioFormat.parse(format_data) catch null;
    }

    fn parseContentDescription(self: *Self, data: []const u8) !void {
        if (data.len < 10) return;

        const title_len = std.mem.readInt(u16, data[0..2], .little);
        const author_len = std.mem.readInt(u16, data[2..4], .little);
        const copyright_len = std.mem.readInt(u16, data[4..6], .little);
        const description_len = std.mem.readInt(u16, data[6..8], .little);
        _ = std.mem.readInt(u16, data[8..10], .little); // rating_len

        var pos: usize = 10;

        // Title (UTF-16LE)
        if (title_len > 0 and pos + title_len <= data.len) {
            self.metadata.title = try self.decodeUtf16Le(data[pos..][0..title_len]);
            pos += title_len;
        }

        // Author (UTF-16LE)
        if (author_len > 0 and pos + author_len <= data.len) {
            self.metadata.artist = try self.decodeUtf16Le(data[pos..][0..author_len]);
            pos += author_len;
        }

        // Copyright (UTF-16LE)
        if (copyright_len > 0 and pos + copyright_len <= data.len) {
            self.metadata.copyright = try self.decodeUtf16Le(data[pos..][0..copyright_len]);
            pos += copyright_len;
        }

        // Description (UTF-16LE)
        if (description_len > 0 and pos + description_len <= data.len) {
            self.metadata.comment = try self.decodeUtf16Le(data[pos..][0..description_len]);
        }
    }

    fn parseExtendedContent(self: *Self, data: []const u8) !void {
        if (data.len < 2) return;

        const count = std.mem.readInt(u16, data[0..2], .little);
        var pos: usize = 2;

        for (0..count) |_| {
            if (pos + 2 > data.len) break;

            const name_len = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;

            if (pos + name_len > data.len) break;
            const name_data = data[pos..][0..name_len];
            pos += name_len;

            if (pos + 4 > data.len) break;
            const value_type = std.mem.readInt(u16, data[pos..][0..2], .little);
            const value_len = std.mem.readInt(u16, data[pos + 2 ..][0..2], .little);
            pos += 4;

            if (pos + value_len > data.len) break;
            const value_data = data[pos..][0..value_len];
            pos += value_len;

            // Decode name
            const name = self.decodeUtf16Le(name_data) catch continue;
            defer self.allocator.free(name);

            // Handle known fields
            if (value_type == 0) { // Unicode string
                const value = self.decodeUtf16Le(value_data) catch continue;

                if (std.mem.eql(u8, name, "WM/AlbumTitle")) {
                    self.metadata.album = value;
                } else if (std.mem.eql(u8, name, "WM/Genre")) {
                    self.metadata.genre = value;
                } else if (std.mem.eql(u8, name, "WM/Year")) {
                    self.metadata.year = std.fmt.parseInt(u16, value, 10) catch null;
                    self.allocator.free(value);
                } else if (std.mem.eql(u8, name, "WM/TrackNumber")) {
                    self.metadata.track_number = std.fmt.parseInt(u16, value, 10) catch null;
                    self.allocator.free(value);
                } else if (std.mem.eql(u8, name, "WM/AlbumArtist")) {
                    self.metadata.album_artist = value;
                } else {
                    self.allocator.free(value);
                }
            }
        }
    }

    fn decodeUtf16Le(self: *Self, data: []const u8) ![]const u8 {
        if (data.len < 2) return "";

        // Simple UTF-16LE to UTF-8 conversion
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i + 1 < data.len) {
            const code_unit = std.mem.readInt(u16, data[i..][0..2], .little);
            i += 2;

            if (code_unit == 0) break; // Null terminator

            // Simple ASCII range
            if (code_unit < 0x80) {
                try result.append(@truncate(code_unit));
            } else if (code_unit < 0x800) {
                try result.append(@truncate(0xC0 | (code_unit >> 6)));
                try result.append(@truncate(0x80 | (code_unit & 0x3F)));
            } else {
                try result.append(@truncate(0xE0 | (code_unit >> 12)));
                try result.append(@truncate(0x80 | ((code_unit >> 6) & 0x3F)));
                try result.append(@truncate(0x80 | (code_unit & 0x3F)));
            }
        }

        return try result.toOwnedSlice();
    }

    pub fn deinit(self: *Self) void {
        self.metadata.deinit();
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        if (self.audio_format) |fmt| return fmt.sample_rate;
        return 44100;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        if (self.audio_format) |fmt| return @intCast(fmt.channels);
        return 2;
    }

    /// Get bitrate in kbps
    pub fn getBitrate(self: *const Self) u32 {
        if (self.audio_format) |fmt| return fmt.getBitrateKbps();
        if (self.file_properties) |props| return props.getBitrate() / 1000;
        return 128;
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        if (self.file_properties) |props| return props.getDuration();
        return 0;
    }

    /// Get metadata
    pub fn getMetadata(self: *const Self) Metadata {
        return self.metadata;
    }

    /// Check if lossless
    pub fn isLossless(self: *const Self) bool {
        if (self.audio_format) |fmt| return fmt.isLossless();
        return false;
    }

    /// Get codec name
    pub fn getCodecName(self: *const Self) []const u8 {
        if (self.audio_format) |fmt| {
            return switch (fmt.codec_id) {
                .wma_v1 => "WMA v1",
                .wma_v2 => "WMA v2",
                .wma_pro => "WMA Pro",
                .wma_lossless => "WMA Lossless",
                .wma_voice => "WMA Voice",
                else => "WMA",
            };
        }
        return "WMA";
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if data is a WMA/ASF file
pub fn isWma(data: []const u8) bool {
    if (data.len < 16) return false;
    return std.mem.eql(u8, data[0..16], &ASF_HEADER_GUID);
}

/// Decode WMA from memory
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !AudioFrame {
    _ = allocator;
    _ = data;
    // Full WMA decoding is proprietary and complex
    return AudioError.NotImplemented;
}

// ============================================================================
// Tests
// ============================================================================

test "WMA/ASF detection" {
    var wma_data: [16]u8 = undefined;
    @memcpy(&wma_data, &ASF_HEADER_GUID);

    try std.testing.expect(isWma(&wma_data));

    const not_wma = [_]u8{ 'R', 'I', 'F', 'F' } ++ [_]u8{0} ** 12;
    try std.testing.expect(!isWma(&not_wma));
}

test "ASF Object Header parsing" {
    var header_data: [24]u8 = undefined;
    @memcpy(header_data[0..16], &ASF_HEADER_GUID);
    std.mem.writeInt(u64, header_data[16..24], 1000, .little);

    const header = try AsfObjectHeader.parse(&header_data);
    try std.testing.expect(header.isHeader());
    try std.testing.expectEqual(@as(u64, 1000), header.size);
}

test "WMA Audio Format parsing" {
    var format_data: [18]u8 = undefined;
    std.mem.writeInt(u16, format_data[0..2], 0x0161, .little); // WMA v2
    std.mem.writeInt(u16, format_data[2..4], 2, .little); // Channels
    std.mem.writeInt(u32, format_data[4..8], 44100, .little); // Sample rate
    std.mem.writeInt(u32, format_data[8..12], 16000, .little); // Avg bytes/sec
    std.mem.writeInt(u16, format_data[12..14], 8192, .little); // Block align
    std.mem.writeInt(u16, format_data[14..16], 16, .little); // Bits per sample
    std.mem.writeInt(u16, format_data[16..18], 0, .little); // Extra size

    const format = try WmaAudioFormat.parse(&format_data);
    try std.testing.expectEqual(WmaCodecId.wma_v2, format.codec_id);
    try std.testing.expectEqual(@as(u16, 2), format.channels);
    try std.testing.expectEqual(@as(u32, 44100), format.sample_rate);
}
