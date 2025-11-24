// Home Video Library - Ogg Container Parser
// Ogg container format for Vorbis, Opus, FLAC, Theora, etc.

const std = @import("std");
const err = @import("../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// Ogg Page Header
// ============================================================================

pub const PageHeader = struct {
    version: u8,
    header_type: HeaderType,
    granule_position: u64,
    serial_number: u32,
    page_sequence: u32,
    checksum: u32,
    segment_count: u8,
    segment_table: [255]u8,
    header_size: usize,
    body_size: usize,

    pub const HeaderType = packed struct {
        continued: bool,
        bos: bool, // Beginning of stream
        eos: bool, // End of stream
        _padding: u5 = 0,
    };

    pub fn isContinuation(self: *const PageHeader) bool {
        return self.header_type.continued;
    }

    pub fn isBeginningOfStream(self: *const PageHeader) bool {
        return self.header_type.bos;
    }

    pub fn isEndOfStream(self: *const PageHeader) bool {
        return self.header_type.eos;
    }
};

// ============================================================================
// Ogg Stream Types
// ============================================================================

pub const StreamType = enum {
    vorbis,
    opus,
    flac,
    theora,
    unknown,

    pub fn fromMagic(data: []const u8) StreamType {
        if (data.len >= 7 and std.mem.eql(u8, data[1..7], "vorbis")) {
            return .vorbis;
        }
        if (data.len >= 8 and std.mem.eql(u8, data[0..8], "OpusHead")) {
            return .opus;
        }
        if (data.len >= 5 and std.mem.eql(u8, data[1..5], "FLAC")) {
            return .flac;
        }
        if (data.len >= 7 and std.mem.eql(u8, data[1..7], "theora")) {
            return .theora;
        }
        return .unknown;
    }
};

// ============================================================================
// Ogg Stream Info
// ============================================================================

pub const StreamInfo = struct {
    serial_number: u32,
    stream_type: StreamType,
    start_granule: u64,
    end_granule: u64,
    page_count: u32,
};

// ============================================================================
// Vorbis Info
// ============================================================================

pub const VorbisInfo = struct {
    version: u32,
    channels: u8,
    sample_rate: u32,
    bitrate_max: i32,
    bitrate_nominal: i32,
    bitrate_min: i32,
    blocksize_0: u8,
    blocksize_1: u8,

    pub fn parse(data: []const u8) !VorbisInfo {
        if (data.len < 23) return VideoError.TruncatedData;
        if (data[0] != 1 or !std.mem.eql(u8, data[1..7], "vorbis")) {
            return VideoError.InvalidHeader;
        }

        return VorbisInfo{
            .version = std.mem.readInt(u32, data[7..11], .little),
            .channels = data[11],
            .sample_rate = std.mem.readInt(u32, data[12..16], .little),
            .bitrate_max = @bitCast(std.mem.readInt(u32, data[16..20], .little)),
            .bitrate_nominal = @bitCast(std.mem.readInt(u32, data[20..24], .little)),
            .bitrate_min = @bitCast(std.mem.readInt(u32, data[24..28], .little)),
            .blocksize_0 = data[28] & 0x0F,
            .blocksize_1 = (data[28] >> 4) & 0x0F,
        };
    }
};

// ============================================================================
// Ogg Reader
// ============================================================================

pub const OggReader = struct {
    data: []const u8,
    pos: usize,
    streams: std.ArrayListUnmanaged(StreamInfo),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (!isOgg(data)) {
            return VideoError.InvalidHeader;
        }

        var self = Self{
            .data = data,
            .pos = 0,
            .streams = .empty,
            .allocator = allocator,
        };

        // Scan for streams
        try self.scanStreams();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.streams.deinit(self.allocator);
    }

    fn scanStreams(self: *Self) !void {
        var pos: usize = 0;

        while (pos < self.data.len) {
            const page = readPageHeader(self.data[pos..]) catch break;
            const page_data = self.data[pos + page.header_size ..];

            if (page.header_type.bos) {
                // New stream - identify type
                const body_start = page.header_size;
                const body_end = body_start + page.body_size;
                if (body_end <= self.data.len - pos) {
                    const body = self.data[pos + body_start .. pos + body_end];
                    const stream_type = StreamType.fromMagic(body);

                    try self.streams.append(self.allocator, StreamInfo{
                        .serial_number = page.serial_number,
                        .stream_type = stream_type,
                        .start_granule = page.granule_position,
                        .end_granule = page.granule_position,
                        .page_count = 1,
                    });
                }
            } else {
                // Update existing stream info
                for (self.streams.items) |*stream| {
                    if (stream.serial_number == page.serial_number) {
                        stream.end_granule = page.granule_position;
                        stream.page_count += 1;
                        break;
                    }
                }
            }

            pos += page.header_size + page.body_size;
            _ = page_data;
        }
    }

    /// Read next page header
    pub fn readPage(self: *Self) !?PageHeader {
        if (self.pos >= self.data.len) return null;

        const page = try readPageHeader(self.data[self.pos..]);
        return page;
    }

    /// Skip to next page
    pub fn nextPage(self: *Self) !bool {
        if (self.pos >= self.data.len) return false;

        const page = readPageHeader(self.data[self.pos..]) catch return false;
        self.pos += page.header_size + page.body_size;
        return self.pos < self.data.len;
    }

    /// Get page body data
    pub fn getPageBody(self: *const Self) ?[]const u8 {
        const page = readPageHeader(self.data[self.pos..]) catch return null;
        const body_start = self.pos + page.header_size;
        const body_end = body_start + page.body_size;
        if (body_end > self.data.len) return null;
        return self.data[body_start..body_end];
    }

    /// Reset to beginning
    pub fn reset(self: *Self) void {
        self.pos = 0;
    }

    /// Get stream count
    pub fn streamCount(self: *const Self) usize {
        return self.streams.items.len;
    }

    /// Get stream by index
    pub fn getStream(self: *const Self, index: usize) ?StreamInfo {
        if (index >= self.streams.items.len) return null;
        return self.streams.items[index];
    }

    /// Find stream by serial number
    pub fn findStream(self: *const Self, serial: u32) ?StreamInfo {
        for (self.streams.items) |stream| {
            if (stream.serial_number == serial) {
                return stream;
            }
        }
        return null;
    }

    /// Get Vorbis info if stream is Vorbis
    pub fn getVorbisInfo(self: *Self, serial: u32) !?VorbisInfo {
        self.reset();

        while (try self.readPage()) |page| {
            if (page.serial_number == serial and page.header_type.bos) {
                if (self.getPageBody()) |body| {
                    if (body.len > 0 and body[0] == 1) {
                        return try VorbisInfo.parse(body);
                    }
                }
            }
            _ = try self.nextPage();
        }
        return null;
    }
};

// ============================================================================
// Ogg Writer
// ============================================================================

pub const OggWriter = struct {
    pages: std.ArrayListUnmanaged(Page),
    allocator: std.mem.Allocator,
    serial_counter: u32,

    const Self = @This();

    pub const Page = struct {
        header: PageHeader,
        data: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .pages = .empty,
            .allocator = allocator,
            .serial_counter = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pages.items) |page| {
            self.allocator.free(page.data);
        }
        self.pages.deinit(self.allocator);
    }

    /// Create a new stream and return serial number
    pub fn newStream(self: *Self) u32 {
        const serial = self.serial_counter;
        self.serial_counter += 1;
        return serial;
    }

    /// Write a page
    pub fn writePage(self: *Self, serial: u32, granule: u64, data: []const u8, flags: PageHeader.HeaderType) !void {
        // Calculate segment table
        var segment_count: u8 = 0;
        var segment_table: [255]u8 = undefined;
        var remaining = data.len;

        while (remaining > 0 and segment_count < 255) {
            if (remaining >= 255) {
                segment_table[segment_count] = 255;
                remaining -= 255;
            } else {
                segment_table[segment_count] = @intCast(remaining);
                remaining = 0;
            }
            segment_count += 1;
        }

        const header_size = 27 + segment_count;

        const page_data = try self.allocator.alloc(u8, header_size + data.len);
        errdefer self.allocator.free(page_data);

        // Write capture pattern
        @memcpy(page_data[0..4], "OggS");
        page_data[4] = 0; // Version
        page_data[5] = @bitCast(flags);

        // Granule position (little-endian)
        std.mem.writeInt(u64, page_data[6..14], granule, .little);
        // Serial number
        std.mem.writeInt(u32, page_data[14..18], serial, .little);
        // Page sequence (we'd need to track this per stream)
        std.mem.writeInt(u32, page_data[18..22], @intCast(self.pages.items.len), .little);
        // Checksum placeholder
        std.mem.writeInt(u32, page_data[22..26], 0, .little);
        // Segment count
        page_data[26] = segment_count;
        // Segment table
        @memcpy(page_data[27..][0..segment_count], segment_table[0..segment_count]);
        // Data
        @memcpy(page_data[header_size..][0..data.len], data);

        // Calculate and write checksum
        const checksum = calculateCrc(page_data);
        std.mem.writeInt(u32, page_data[22..26], checksum, .little);

        try self.pages.append(self.allocator, Page{
            .header = PageHeader{
                .version = 0,
                .header_type = flags,
                .granule_position = granule,
                .serial_number = serial,
                .page_sequence = @intCast(self.pages.items.len),
                .checksum = checksum,
                .segment_count = segment_count,
                .segment_table = segment_table,
                .header_size = header_size,
                .body_size = data.len,
            },
            .data = page_data,
        });
    }

    /// Generate complete Ogg file
    pub fn generate(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var total_size: usize = 0;
        for (self.pages.items) |page| {
            total_size += page.data.len;
        }

        const result = try allocator.alloc(u8, total_size);
        var pos: usize = 0;

        for (self.pages.items) |page| {
            @memcpy(result[pos..][0..page.data.len], page.data);
            pos += page.data.len;
        }

        return result;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn readPageHeader(data: []const u8) !PageHeader {
    if (data.len < 27) return VideoError.TruncatedData;

    // Check capture pattern
    if (!std.mem.eql(u8, data[0..4], "OggS")) {
        return VideoError.InvalidHeader;
    }

    const version = data[4];
    if (version != 0) return VideoError.UnsupportedVersion;

    const header_type: PageHeader.HeaderType = @bitCast(data[5]);
    const granule_position = std.mem.readInt(u64, data[6..14], .little);
    const serial_number = std.mem.readInt(u32, data[14..18], .little);
    const page_sequence = std.mem.readInt(u32, data[18..22], .little);
    const checksum = std.mem.readInt(u32, data[22..26], .little);
    const segment_count = data[26];

    if (data.len < 27 + segment_count) return VideoError.TruncatedData;

    var segment_table: [255]u8 = undefined;
    @memcpy(segment_table[0..segment_count], data[27..][0..segment_count]);

    var body_size: usize = 0;
    for (0..segment_count) |i| {
        body_size += segment_table[i];
    }

    return PageHeader{
        .version = version,
        .header_type = header_type,
        .granule_position = granule_position,
        .serial_number = serial_number,
        .page_sequence = page_sequence,
        .checksum = checksum,
        .segment_count = segment_count,
        .segment_table = segment_table,
        .header_size = 27 + segment_count,
        .body_size = body_size,
    };
}

/// Ogg CRC32 lookup table
const crc_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var r: u32 = @intCast(i << 24);
        for (0..8) |_| {
            if (r & 0x80000000 != 0) {
                r = (r << 1) ^ 0x04c11db7;
            } else {
                r = r << 1;
            }
        }
        table[i] = r;
    }
    break :blk table;
};

fn calculateCrc(data: []const u8) u32 {
    var crc: u32 = 0;
    for (data) |byte| {
        crc = (crc << 8) ^ crc_table[((crc >> 24) & 0xff) ^ byte];
    }
    return crc;
}

/// Check if data starts with Ogg signature
pub fn isOgg(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "OggS");
}

// ============================================================================
// Tests
// ============================================================================

test "isOgg" {
    const ogg_data = "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00";
    try std.testing.expect(isOgg(ogg_data));
    try std.testing.expect(!isOgg("RIFF"));
}

test "StreamType.fromMagic" {
    const vorbis_id = "\x01vorbis";
    try std.testing.expectEqual(StreamType.vorbis, StreamType.fromMagic(vorbis_id));

    const opus_id = "OpusHead";
    try std.testing.expectEqual(StreamType.opus, StreamType.fromMagic(opus_id));

    const flac_id = "\x7fFLAC";
    try std.testing.expectEqual(StreamType.flac, StreamType.fromMagic(flac_id));

    const theora_id = "\x80theora";
    try std.testing.expectEqual(StreamType.theora, StreamType.fromMagic(theora_id));
}

test "PageHeader.HeaderType" {
    const flags = PageHeader.HeaderType{ .continued = false, .bos = true, .eos = false };
    try std.testing.expect(flags.bos);
    try std.testing.expect(!flags.continued);
    try std.testing.expect(!flags.eos);
}

test "OggWriter basic" {
    const allocator = std.testing.allocator;

    var writer = OggWriter.init(allocator);
    defer writer.deinit();

    const serial = writer.newStream();
    try writer.writePage(serial, 0, "test data", .{ .continued = false, .bos = true, .eos = false });

    const output = try writer.generate(allocator);
    defer allocator.free(output);

    try std.testing.expect(isOgg(output));
}

test "crc_table generation" {
    // Verify some known CRC table entries
    try std.testing.expectEqual(@as(u32, 0), crc_table[0]);
    try std.testing.expectEqual(@as(u32, 0x04c11db7), crc_table[1]);
}
