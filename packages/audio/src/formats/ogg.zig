// Home Audio Library - OGG/Vorbis Format
// OGG container and Vorbis audio codec

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
// OGG Constants
// ============================================================================

const OGG_MAGIC = "OggS".*;

/// OGG page header type flags
pub const PageFlags = packed struct {
    continuation: bool,
    bos: bool, // Beginning of stream
    eos: bool, // End of stream
    _padding: u5 = 0,
};

// ============================================================================
// OGG Page
// ============================================================================

pub const OggPage = struct {
    /// Version (always 0)
    version: u8,

    /// Header type flags
    flags: PageFlags,

    /// Absolute granule position
    granule_position: i64,

    /// Stream serial number
    serial_number: u32,

    /// Page sequence number
    page_number: u32,

    /// CRC checksum
    crc: u32,

    /// Number of segments
    segment_count: u8,

    /// Segment table
    segment_table: []const u8,

    /// Page data
    data: []const u8,

    /// Total page size (header + data)
    total_size: usize,

    const Self = @This();

    /// Parse OGG page from data
    pub fn parse(data: []const u8) !Self {
        if (data.len < 27) return AudioError.TruncatedData;

        // Check magic
        if (!std.mem.eql(u8, data[0..4], &OGG_MAGIC)) {
            return AudioError.SyncLost;
        }

        const version = data[4];
        if (version != 0) return AudioError.UnsupportedFormat;

        const flags: PageFlags = @bitCast(data[5]);
        const granule_position = std.mem.readInt(i64, data[6..14], .little);
        const serial_number = std.mem.readInt(u32, data[14..18], .little);
        const page_number = std.mem.readInt(u32, data[18..22], .little);
        const crc = std.mem.readInt(u32, data[22..26], .little);
        const segment_count = data[26];

        if (data.len < 27 + segment_count) return AudioError.TruncatedData;

        const segment_table = data[27..][0..segment_count];

        // Calculate total data size from segment table
        var data_size: usize = 0;
        for (segment_table) |seg| {
            data_size += seg;
        }

        const header_size = 27 + segment_count;
        if (data.len < header_size + data_size) return AudioError.TruncatedData;

        return Self{
            .version = version,
            .flags = flags,
            .granule_position = granule_position,
            .serial_number = serial_number,
            .page_number = page_number,
            .crc = crc,
            .segment_count = segment_count,
            .segment_table = segment_table,
            .data = data[header_size..][0..data_size],
            .total_size = header_size + data_size,
        };
    }

    /// Check if this is the first page of the stream
    pub fn isFirstPage(self: Self) bool {
        return self.flags.bos;
    }

    /// Check if this is the last page of the stream
    pub fn isLastPage(self: Self) bool {
        return self.flags.eos;
    }
};

// ============================================================================
// Vorbis Identification Header
// ============================================================================

pub const VorbisIdHeader = struct {
    /// Vorbis version (always 0)
    version: u32,

    /// Number of audio channels
    channels: u8,

    /// Sample rate in Hz
    sample_rate: u32,

    /// Maximum bitrate (0 = unset)
    bitrate_max: i32,

    /// Nominal bitrate (0 = unset)
    bitrate_nominal: i32,

    /// Minimum bitrate (0 = unset)
    bitrate_min: i32,

    /// Block size exponents
    blocksize_0: u4,
    blocksize_1: u4,

    const Self = @This();

    /// Parse from packet data
    pub fn parse(data: []const u8) !Self {
        if (data.len < 30) return AudioError.TruncatedData;

        // Check packet type (1 = identification header)
        if (data[0] != 1) return AudioError.InvalidHeader;

        // Check "vorbis" magic
        if (!std.mem.eql(u8, data[1..7], "vorbis")) {
            return AudioError.InvalidFormat;
        }

        const version = std.mem.readInt(u32, data[7..11], .little);
        if (version != 0) return AudioError.UnsupportedFormat;

        const channels = data[11];
        if (channels == 0) return AudioError.InvalidHeader;

        const sample_rate = std.mem.readInt(u32, data[12..16], .little);
        if (sample_rate == 0) return AudioError.InvalidHeader;

        const bitrate_max = std.mem.readInt(i32, data[16..20], .little);
        const bitrate_nominal = std.mem.readInt(i32, data[20..24], .little);
        const bitrate_min = std.mem.readInt(i32, data[24..28], .little);

        const blocksizes = data[28];
        const blocksize_0: u4 = @truncate(blocksizes & 0x0F);
        const blocksize_1: u4 = @truncate((blocksizes >> 4) & 0x0F);

        // Validate block sizes (must be powers of 2, 64-8192)
        if (blocksize_0 < 6 or blocksize_0 > 13 or blocksize_1 < 6 or blocksize_1 > 13) {
            return AudioError.InvalidHeader;
        }

        // blocksize_0 <= blocksize_1
        if (blocksize_0 > blocksize_1) {
            return AudioError.InvalidHeader;
        }

        // Framing bit
        if ((data[29] & 0x01) != 1) {
            return AudioError.InvalidHeader;
        }

        return Self{
            .version = version,
            .channels = channels,
            .sample_rate = sample_rate,
            .bitrate_max = bitrate_max,
            .bitrate_nominal = bitrate_nominal,
            .bitrate_min = bitrate_min,
            .blocksize_0 = blocksize_0,
            .blocksize_1 = blocksize_1,
        };
    }

    /// Get nominal bitrate in kbps
    pub fn getNominalBitrateKbps(self: Self) u32 {
        if (self.bitrate_nominal > 0) {
            return @intCast(@divFloor(self.bitrate_nominal, 1000));
        }
        return 0;
    }
};

// ============================================================================
// Vorbis Comment Header
// ============================================================================

pub const VorbisCommentHeader = struct {
    vendor: []const u8,
    comments: std.ArrayList(Comment),
    allocator: std.mem.Allocator,

    pub const Comment = struct {
        field: []const u8,
        value: []const u8,
    };

    const Self = @This();

    /// Parse from packet data
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 7) return AudioError.TruncatedData;

        // Check packet type (3 = comment header)
        if (data[0] != 3) return AudioError.InvalidHeader;

        // Check "vorbis" magic
        if (!std.mem.eql(u8, data[1..7], "vorbis")) {
            return AudioError.InvalidFormat;
        }

        var pos: usize = 7;

        // Vendor length
        if (pos + 4 > data.len) return AudioError.TruncatedData;
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
// OGG/Vorbis Reader
// ============================================================================

pub const OggReader = struct {
    data: []const u8,
    pos: usize,
    id_header: VorbisIdHeader,
    comment_header: ?VorbisCommentHeader,
    audio_data_start: usize,
    last_granule: i64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 28) return AudioError.TruncatedData;

        var reader = Self{
            .data = data,
            .pos = 0,
            .id_header = undefined,
            .comment_header = null,
            .audio_data_start = 0,
            .last_granule = 0,
            .allocator = allocator,
        };

        try reader.parseHeaders();
        return reader;
    }

    fn parseHeaders(self: *Self) !void {
        // First page: identification header
        const first_page = try OggPage.parse(self.data[self.pos..]);
        if (!first_page.isFirstPage()) return AudioError.InvalidFormat;

        self.id_header = try VorbisIdHeader.parse(first_page.data);
        self.pos += first_page.total_size;

        // Second page: comment header
        if (self.pos < self.data.len) {
            const second_page = try OggPage.parse(self.data[self.pos..]);
            self.comment_header = VorbisCommentHeader.parse(self.allocator, second_page.data) catch null;
            self.pos += second_page.total_size;
        }

        // Skip setup header page
        if (self.pos < self.data.len) {
            const third_page = try OggPage.parse(self.data[self.pos..]);
            self.pos += third_page.total_size;
        }

        self.audio_data_start = self.pos;

        // Find last granule position for duration
        self.findLastGranule();
    }

    fn findLastGranule(self: *Self) void {
        var pos = self.data.len;

        // Search backwards for last page
        while (pos > 27) {
            pos -= 1;
            if (pos + 4 <= self.data.len and std.mem.eql(u8, self.data[pos..][0..4], &OGG_MAGIC)) {
                if (OggPage.parse(self.data[pos..])) |page| {
                    if (page.isLastPage() and page.granule_position >= 0) {
                        self.last_granule = page.granule_position;
                        return;
                    }
                } else |_| {}
            }
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.comment_header) |*ch| {
            ch.deinit();
        }
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return self.id_header.sample_rate;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        return self.id_header.channels;
    }

    /// Get bitrate in kbps
    pub fn getBitrate(self: *const Self) u32 {
        return self.id_header.getNominalBitrateKbps();
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        if (self.last_granule > 0 and self.id_header.sample_rate > 0) {
            return @as(f64, @floatFromInt(self.last_granule)) / @as(f64, @floatFromInt(self.id_header.sample_rate));
        }
        return 0;
    }

    /// Get total samples
    pub fn getTotalSamples(self: *const Self) u64 {
        if (self.last_granule > 0) {
            return @intCast(self.last_granule);
        }
        return 0;
    }

    /// Get metadata
    pub fn getMetadata(self: *const Self) ?Metadata {
        if (self.comment_header) |*ch| {
            return ch.toMetadata();
        }
        return null;
    }
};

// ============================================================================
// OGG Page Writer
// ============================================================================

pub const OggPageWriter = struct {
    buffer: std.ArrayList(u8),
    serial_number: u32,
    page_number: u32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, serial_number: u32) Self {
        return Self{
            .buffer = std.ArrayList(u8).init(allocator),
            .serial_number = serial_number,
            .page_number = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    /// Write a page with given data
    pub fn writePage(
        self: *Self,
        data: []const u8,
        granule_position: i64,
        flags: PageFlags,
    ) !void {
        // Create segment table
        var segments = std.ArrayList(u8).init(self.allocator);
        defer segments.deinit();

        var remaining = data.len;
        while (remaining > 0) {
            const seg_size: u8 = @min(255, @as(u8, @intCast(remaining)));
            try segments.append(seg_size);
            remaining -= seg_size;
            if (seg_size == 255 and remaining == 0) {
                try segments.append(0); // Terminating zero for exact multiple
            }
        }

        // Write OGG magic
        try self.buffer.appendSlice(&OGG_MAGIC);

        // Version
        try self.buffer.append(0);

        // Flags
        try self.buffer.append(@bitCast(flags));

        // Granule position
        var gp_bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &gp_bytes, granule_position, .little);
        try self.buffer.appendSlice(&gp_bytes);

        // Serial number
        var sn_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &sn_bytes, self.serial_number, .little);
        try self.buffer.appendSlice(&sn_bytes);

        // Page number
        var pn_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &pn_bytes, self.page_number, .little);
        try self.buffer.appendSlice(&pn_bytes);
        self.page_number += 1;

        // CRC placeholder (will be computed later)
        try self.buffer.appendSlice(&[_]u8{ 0, 0, 0, 0 });

        // Segment count
        try self.buffer.append(@intCast(segments.items.len));

        // Segment table
        try self.buffer.appendSlice(segments.items);

        // Data
        try self.buffer.appendSlice(data);

        // Compute CRC
        const page_start = self.buffer.items.len - (27 + segments.items.len + data.len);
        const crc = computeOggCrc(self.buffer.items[page_start..]);
        std.mem.writeInt(u32, self.buffer.items[page_start + 22 ..][0..4], crc, .little);
    }

    /// Get the written data
    pub fn getData(self: *const Self) []const u8 {
        return self.buffer.items;
    }
};

/// OGG CRC-32 polynomial
const OGG_CRC_POLY: u32 = 0x04C11DB7;

fn computeOggCrc(data: []const u8) u32 {
    var crc: u32 = 0;

    for (data) |byte| {
        // Skip the CRC field itself (bytes 22-25)
        crc ^= @as(u32, byte) << 24;
        for (0..8) |_| {
            if (crc & 0x80000000 != 0) {
                crc = (crc << 1) ^ OGG_CRC_POLY;
            } else {
                crc <<= 1;
            }
        }
    }

    return crc;
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if data is an OGG file
pub fn isOgg(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], "OggS");
}

/// Check if data is an OGG Vorbis file
pub fn isVorbis(data: []const u8) bool {
    if (!isOgg(data)) return false;

    // Parse first page and check for Vorbis identification header
    const page = OggPage.parse(data) catch return false;
    if (page.data.len < 7) return false;

    return page.data[0] == 1 and std.mem.eql(u8, page.data[1..7], "vorbis");
}

/// Decode OGG/Vorbis from memory
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !AudioFrame {
    _ = allocator;
    _ = data;
    // Full Vorbis decoding is complex and requires implementing:
    // - Vorbis codebook decoding
    // - Floor/residue decoding
    // - Inverse MDCT
    // - Window overlap-add
    return AudioError.NotImplemented;
}

// ============================================================================
// Tests
// ============================================================================

test "OGG detection" {
    const ogg_data = [_]u8{ 'O', 'g', 'g', 'S', 0, 0x02 } ++ [_]u8{0} ** 22;
    try std.testing.expect(isOgg(&ogg_data));

    const not_ogg = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expect(!isOgg(&not_ogg));
}

test "OGG page parsing" {
    // Minimal valid OGG page
    var page_data: [28]u8 = undefined;
    @memcpy(page_data[0..4], "OggS");
    page_data[4] = 0; // Version
    page_data[5] = 0x02; // BOS flag
    @memset(page_data[6..26], 0); // Granule, serial, page#, CRC
    page_data[26] = 1; // 1 segment
    page_data[27] = 0; // Empty segment

    const page = try OggPage.parse(&page_data);
    try std.testing.expect(page.isFirstPage());
    try std.testing.expect(!page.isLastPage());
}
