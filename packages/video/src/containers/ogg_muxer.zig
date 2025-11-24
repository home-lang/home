// Home Video Library - Ogg Muxer
// Ogg container with page structure and Vorbis comments

const std = @import("std");

/// Ogg page header
const PageHeader = struct {
    capture_pattern: [4]u8 = "OggS".*,
    stream_structure_version: u8 = 0,
    header_type_flag: u8,
    granule_position: i64,
    serial_number: u32,
    page_sequence_number: u32,
    checksum: u32,
    page_segments: u8,
    segment_table: []u8,
};

/// Ogg page header flags
pub const HeaderFlag = struct {
    pub const continued = 0x01;
    pub const first_page = 0x02;
    pub const last_page = 0x04;
};

/// Vorbis comment
pub const VorbisComment = struct {
    vendor: []const u8,
    comments: std.StringHashMap([]const u8),
};

/// Ogg muxer
pub const OggMuxer = struct {
    allocator: std.mem.Allocator,
    serial_number: u32,
    page_sequence: u32 = 0,
    granule_position: i64 = 0,

    // Packets waiting to be paged
    pending_packets: std.ArrayList([]const u8),

    // Completed pages
    pages: std.ArrayList([]u8),

    // Options
    max_page_size: usize = 4096,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, serial_number: u32) Self {
        return .{
            .allocator = allocator,
            .serial_number = serial_number,
            .pending_packets = std.ArrayList([]const u8).init(allocator),
            .pages = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_packets.deinit();
        for (self.pages.items) |page| {
            self.allocator.free(page);
        }
        self.pages.deinit();
    }

    pub fn addPacket(self: *Self, packet: []const u8, granule_pos: i64) !void {
        try self.pending_packets.append(packet);
        self.granule_position = granule_pos;

        // Flush if we have enough data
        if (self.shouldFlush()) {
            try self.flushPage(false, false);
        }
    }

    pub fn finalize(self: *Self) ![]u8 {
        // Flush any remaining packets
        if (self.pending_packets.items.len > 0) {
            try self.flushPage(false, true);
        }

        // Concatenate all pages
        var total_size: usize = 0;
        for (self.pages.items) |page| {
            total_size += page.len;
        }

        var output = try self.allocator.alloc(u8, total_size);
        var pos: usize = 0;

        for (self.pages.items) |page| {
            @memcpy(output[pos .. pos + page.len], page);
            pos += page.len;
        }

        return output;
    }

    fn shouldFlush(self: *Self) bool {
        var size: usize = 0;
        for (self.pending_packets.items) |packet| {
            size += packet.len;
        }
        return size >= self.max_page_size;
    }

    fn flushPage(self: *Self, is_first: bool, is_last: bool) !void {
        if (self.pending_packets.items.len == 0) return;

        var page = std.ArrayList(u8).init(self.allocator);
        errdefer page.deinit();

        // Build segment table
        var segment_table = std.ArrayList(u8).init(self.allocator);
        defer segment_table.deinit();

        for (self.pending_packets.items) |packet| {
            try self.addPacketToSegmentTable(&segment_table, packet);
        }

        // Header type flag
        var header_flag: u8 = 0;
        if (is_first) header_flag |= HeaderFlag.first_page;
        if (is_last) header_flag |= HeaderFlag.last_page;

        // Write page header (without checksum first)
        try page.appendSlice("OggS");
        try page.writer().writeByte(0); // version
        try page.writer().writeByte(header_flag);
        try page.writer().writeInt(i64, self.granule_position, .little);
        try page.writer().writeInt(u32, self.serial_number, .little);
        try page.writer().writeInt(u32, self.page_sequence, .little);
        try page.writer().writeInt(u32, 0, .little); // checksum placeholder
        try page.writer().writeByte(@intCast(segment_table.items.len));
        try page.appendSlice(segment_table.items);

        // Write packet data
        for (self.pending_packets.items) |packet| {
            try page.appendSlice(packet);
        }

        // Calculate and update checksum
        const checksum = self.calculateCRC(page.items);
        std.mem.writeInt(u32, page.items[22..26], checksum, .little);

        // Store page
        try self.pages.append(try page.toOwnedSlice());

        // Clear pending packets
        self.pending_packets.clearRetainingCapacity();
        self.page_sequence += 1;
    }

    fn addPacketToSegmentTable(self: *Self, table: *std.ArrayList(u8), packet: []const u8) !void {
        _ = self;

        var remaining = packet.len;
        while (remaining > 0) {
            const segment_size = @min(remaining, 255);
            try table.append(@intCast(segment_size));
            remaining -= segment_size;
        }

        // If packet size is multiple of 255, add a zero-length segment
        if (packet.len > 0 and packet.len % 255 == 0) {
            try table.append(0);
        }
    }

    fn calculateCRC(self: *Self, data: []const u8) u32 {
        _ = self;

        // CRC-32 polynomial used by Ogg: 0x04C11DB7
        const polynomial: u32 = 0x04C11DB7;
        var crc: u32 = 0;

        for (data) |byte| {
            crc = crc ^ (@as(u32, byte) << 24);

            var i: u8 = 0;
            while (i < 8) : (i += 1) {
                if (crc & 0x80000000 != 0) {
                    crc = (crc << 1) ^ polynomial;
                } else {
                    crc = crc << 1;
                }
            }
        }

        return crc;
    }

    pub fn createVorbisCommentPacket(self: *Self, comment: *const VorbisComment) ![]u8 {
        var packet = std.ArrayList(u8).init(self.allocator);
        errdefer packet.deinit();

        // Packet type (3 = comment header)
        try packet.writer().writeByte(3);

        // Codec identification
        try packet.appendSlice("vorbis");

        // Vendor string length + data
        try packet.writer().writeInt(u32, @intCast(comment.vendor.len), .little);
        try packet.appendSlice(comment.vendor);

        // User comment list length
        const num_comments: u32 = @intCast(comment.comments.count());
        try packet.writer().writeInt(u32, num_comments, .little);

        // User comments
        var iter = comment.comments.iterator();
        while (iter.next()) |entry| {
            const comment_str = try std.fmt.allocPrint(
                self.allocator,
                "{s}={s}",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
            defer self.allocator.free(comment_str);

            try packet.writer().writeInt(u32, @intCast(comment_str.len), .little);
            try packet.appendSlice(comment_str);
        }

        // Framing bit
        try packet.writer().writeByte(1);

        return packet.toOwnedSlice();
    }
};

/// Ogg demuxer for reading Ogg files
pub const OggDemuxer = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Self {
        return .{
            .allocator = allocator,
            .data = data,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn readPage(self: *Self) !?Page {
        if (self.pos + 27 > self.data.len) return null;

        // Check capture pattern
        if (!std.mem.eql(u8, self.data[self.pos .. self.pos + 4], "OggS")) {
            return error.InvalidOggPage;
        }

        const header_start = self.pos;
        self.pos += 4;

        const version = self.data[self.pos];
        self.pos += 1;
        if (version != 0) return error.UnsupportedOggVersion;

        const header_type = self.data[self.pos];
        self.pos += 1;

        const granule_pos = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;

        const serial = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;

        const sequence = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;

        const checksum = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;

        const num_segments = self.data[self.pos];
        self.pos += 1;

        // Read segment table
        if (self.pos + num_segments > self.data.len) return error.TruncatedOggPage;

        const segment_table = self.data[self.pos .. self.pos + num_segments];
        self.pos += num_segments;

        // Calculate total data size
        var data_size: usize = 0;
        for (segment_table) |segment_len| {
            data_size += segment_len;
        }

        if (self.pos + data_size > self.data.len) return error.TruncatedOggPage;

        const page_data = self.data[self.pos .. self.pos + data_size];
        self.pos += data_size;

        // Verify checksum
        var check_data = try self.allocator.alloc(u8, 27 + num_segments + data_size);
        defer self.allocator.free(check_data);

        @memcpy(check_data[0..27], self.data[header_start .. header_start + 27]);
        // Zero out checksum field
        @memset(check_data[22..26], 0);
        @memcpy(check_data[27 .. 27 + num_segments], segment_table);
        @memcpy(check_data[27 + num_segments ..], page_data);

        const calculated_crc = self.calculateCRC(check_data);
        if (calculated_crc != checksum) {
            return error.OggChecksumMismatch;
        }

        return Page{
            .header_type = header_type,
            .granule_position = granule_pos,
            .serial_number = serial,
            .page_sequence = sequence,
            .data = page_data,
        };
    }

    fn calculateCRC(self: *Self, data: []const u8) u32 {
        _ = self;

        const polynomial: u32 = 0x04C11DB7;
        var crc: u32 = 0;

        for (data) |byte| {
            crc = crc ^ (@as(u32, byte) << 24);

            var i: u8 = 0;
            while (i < 8) : (i += 1) {
                if (crc & 0x80000000 != 0) {
                    crc = (crc << 1) ^ polynomial;
                } else {
                    crc = crc << 1;
                }
            }
        }

        return crc;
    }

    pub const Page = struct {
        header_type: u8,
        granule_position: i64,
        serial_number: u32,
        page_sequence: u32,
        data: []const u8,
    };
};
