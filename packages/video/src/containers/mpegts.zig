// Home Video Library - MPEG Transport Stream Parser
// MPEG-TS container support for broadcast and streaming

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// MPEG-TS Constants
// ============================================================================

pub const TS_PACKET_SIZE: usize = 188;
pub const TS_SYNC_BYTE: u8 = 0x47;

// Well-known PIDs
pub const PID = struct {
    pub const PAT: u16 = 0x0000; // Program Association Table
    pub const CAT: u16 = 0x0001; // Conditional Access Table
    pub const TSDT: u16 = 0x0002; // Transport Stream Description Table
    pub const NULL: u16 = 0x1FFF; // Null packet
};

// Stream types
pub const StreamType = enum(u8) {
    mpeg1_video = 0x01,
    mpeg2_video = 0x02,
    mpeg1_audio = 0x03,
    mpeg2_audio = 0x04,
    private_sections = 0x05,
    private_pes = 0x06,
    mheg = 0x07,
    mpeg2_dsmcc = 0x08,
    h222_aux = 0x09,
    mpeg2_dsmcc_a = 0x0A,
    mpeg2_dsmcc_b = 0x0B,
    mpeg2_dsmcc_c = 0x0C,
    mpeg2_dsmcc_d = 0x0D,
    mpeg2_aux = 0x0E,
    aac = 0x0F,
    mpeg4_visual = 0x10,
    aac_latm = 0x11,
    mpeg4_flexmux_pes = 0x12,
    mpeg4_flexmux_sections = 0x13,
    synchronized_download = 0x14,
    metadata_pes = 0x15,
    metadata_sections = 0x16,
    metadata_data_carousel = 0x17,
    metadata_object_carousel = 0x18,
    metadata_synchronized_download = 0x19,
    mpeg2_ipmp = 0x1A,
    h264 = 0x1B,
    h265 = 0x24,
    h266 = 0x33,
    vvc_sei = 0x34,
    ac3 = 0x81,
    dts = 0x82,
    truehd = 0x83,
    dolby_digital_plus = 0x84,
    dts_hd = 0x85,
    dts_hd_master = 0x86,
    dolby_digital_plus_atmos = 0x87,
    unknown = 0xFF,

    pub fn isVideo(self: StreamType) bool {
        return switch (self) {
            .mpeg1_video, .mpeg2_video, .mpeg4_visual, .h264, .h265, .h266 => true,
            else => false,
        };
    }

    pub fn isAudio(self: StreamType) bool {
        return switch (self) {
            .mpeg1_audio, .mpeg2_audio, .aac, .aac_latm, .ac3, .dts, .truehd, .dolby_digital_plus, .dts_hd, .dts_hd_master, .dolby_digital_plus_atmos => true,
            else => false,
        };
    }
};

// ============================================================================
// TS Packet Header
// ============================================================================

pub const TsPacketHeader = struct {
    sync_byte: u8,
    transport_error: bool,
    payload_unit_start: bool,
    transport_priority: bool,
    pid: u16,
    scrambling_control: u2,
    adaptation_field_control: u2,
    continuity_counter: u4,

    pub fn parse(data: *const [4]u8) TsPacketHeader {
        return .{
            .sync_byte = data[0],
            .transport_error = (data[1] & 0x80) != 0,
            .payload_unit_start = (data[1] & 0x40) != 0,
            .transport_priority = (data[1] & 0x20) != 0,
            .pid = (@as(u16, data[1] & 0x1F) << 8) | data[2],
            .scrambling_control = @truncate((data[3] >> 6) & 0x03),
            .adaptation_field_control = @truncate((data[3] >> 4) & 0x03),
            .continuity_counter = @truncate(data[3] & 0x0F),
        };
    }

    pub fn hasAdaptationField(self: *const TsPacketHeader) bool {
        return (self.adaptation_field_control & 0x02) != 0;
    }

    pub fn hasPayload(self: *const TsPacketHeader) bool {
        return (self.adaptation_field_control & 0x01) != 0;
    }
};

// ============================================================================
// Adaptation Field
// ============================================================================

pub const AdaptationField = struct {
    length: u8,
    discontinuity: bool = false,
    random_access: bool = false,
    es_priority: bool = false,
    pcr_flag: bool = false,
    opcr_flag: bool = false,
    splicing_point_flag: bool = false,
    transport_private_data_flag: bool = false,
    adaptation_extension_flag: bool = false,
    pcr: ?u64 = null, // 90kHz clock
    opcr: ?u64 = null,

    pub fn parse(data: []const u8) AdaptationField {
        if (data.len == 0) return .{ .length = 0 };

        const length = data[0];
        if (length == 0 or data.len < 2) return .{ .length = length };

        var af = AdaptationField{
            .length = length,
            .discontinuity = (data[1] & 0x80) != 0,
            .random_access = (data[1] & 0x40) != 0,
            .es_priority = (data[1] & 0x20) != 0,
            .pcr_flag = (data[1] & 0x10) != 0,
            .opcr_flag = (data[1] & 0x08) != 0,
            .splicing_point_flag = (data[1] & 0x04) != 0,
            .transport_private_data_flag = (data[1] & 0x02) != 0,
            .adaptation_extension_flag = (data[1] & 0x01) != 0,
        };

        var offset: usize = 2;

        // PCR (6 bytes)
        if (af.pcr_flag and offset + 6 <= data.len) {
            const pcr_base = (@as(u64, data[offset]) << 25) |
                (@as(u64, data[offset + 1]) << 17) |
                (@as(u64, data[offset + 2]) << 9) |
                (@as(u64, data[offset + 3]) << 1) |
                ((data[offset + 4] >> 7) & 0x01);
            const pcr_ext = (@as(u64, data[offset + 4] & 0x01) << 8) | data[offset + 5];
            af.pcr = pcr_base * 300 + pcr_ext;
            offset += 6;
        }

        // OPCR (6 bytes)
        if (af.opcr_flag and offset + 6 <= data.len) {
            const opcr_base = (@as(u64, data[offset]) << 25) |
                (@as(u64, data[offset + 1]) << 17) |
                (@as(u64, data[offset + 2]) << 9) |
                (@as(u64, data[offset + 3]) << 1) |
                ((data[offset + 4] >> 7) & 0x01);
            const opcr_ext = (@as(u64, data[offset + 4] & 0x01) << 8) | data[offset + 5];
            af.opcr = opcr_base * 300 + opcr_ext;
        }

        return af;
    }
};

// ============================================================================
// Program Association Table (PAT)
// ============================================================================

pub const PatEntry = struct {
    program_number: u16,
    pid: u16, // PMT PID for this program (or NIT if program_number == 0)
};

pub const Pat = struct {
    transport_stream_id: u16,
    version: u5,
    current_next: bool,
    programs: std.ArrayListUnmanaged(PatEntry) = .empty,

    pub fn deinit(self: *Pat, allocator: Allocator) void {
        self.programs.deinit(allocator);
    }
};

// ============================================================================
// Program Map Table (PMT)
// ============================================================================

pub const ElementaryStream = struct {
    stream_type: StreamType,
    pid: u16,
    descriptors: []const u8 = &.{},
};

pub const Pmt = struct {
    program_number: u16,
    version: u5,
    current_next: bool,
    pcr_pid: u16,
    program_info: []const u8 = &.{},
    streams: std.ArrayListUnmanaged(ElementaryStream) = .empty,

    pub fn deinit(self: *Pmt, allocator: Allocator) void {
        self.streams.deinit(allocator);
    }

    pub fn getVideoStream(self: *const Pmt) ?*const ElementaryStream {
        for (self.streams.items) |*stream| {
            if (stream.stream_type.isVideo()) return stream;
        }
        return null;
    }

    pub fn getAudioStreams(self: *const Pmt, allocator: Allocator) !std.ArrayListUnmanaged(*const ElementaryStream) {
        var audio: std.ArrayListUnmanaged(*const ElementaryStream) = .empty;
        for (self.streams.items) |*stream| {
            if (stream.stream_type.isAudio()) {
                try audio.append(allocator, stream);
            }
        }
        return audio;
    }
};

// ============================================================================
// MPEG-TS Reader
// ============================================================================

pub const TsReader = struct {
    data: []const u8,
    offset: usize,
    allocator: Allocator,
    pat: ?Pat = null,
    pmts: std.AutoHashMap(u16, Pmt),

    pub fn init(data: []const u8, allocator: Allocator) !TsReader {
        var reader = TsReader{
            .data = data,
            .offset = 0,
            .allocator = allocator,
            .pmts = std.AutoHashMap(u16, Pmt).init(allocator),
        };

        // Find sync
        try reader.findSync();

        return reader;
    }

    pub fn deinit(self: *TsReader) void {
        if (self.pat) |*pat| pat.deinit(self.allocator);
        var it = self.pmts.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.pmts.deinit();
    }

    fn findSync(self: *TsReader) !void {
        while (self.offset < self.data.len) {
            if (self.data[self.offset] == TS_SYNC_BYTE) {
                // Verify next packet also has sync byte
                if (self.offset + TS_PACKET_SIZE < self.data.len) {
                    if (self.data[self.offset + TS_PACKET_SIZE] == TS_SYNC_BYTE) {
                        return;
                    }
                } else {
                    return; // At end of file, accept
                }
            }
            self.offset += 1;
        }
        return error.NoSyncFound;
    }

    /// Read next TS packet
    pub fn nextPacket(self: *TsReader) ?*const [TS_PACKET_SIZE]u8 {
        if (self.offset + TS_PACKET_SIZE > self.data.len) return null;

        const packet: *const [TS_PACKET_SIZE]u8 = @ptrCast(self.data[self.offset..][0..TS_PACKET_SIZE]);
        self.offset += TS_PACKET_SIZE;

        // Verify sync byte
        if (packet[0] != TS_SYNC_BYTE) return null;

        return packet;
    }

    /// Parse tables (PAT and PMT)
    pub fn parseTables(self: *TsReader) !void {
        const saved_offset = self.offset;
        self.offset = 0;
        try self.findSync();

        while (self.nextPacket()) |packet| {
            const header = TsPacketHeader.parse(packet[0..4]);

            if (header.pid == PID.PAT) {
                try self.parsePat(packet);
            } else if (self.pat) |pat| {
                for (pat.programs.items) |prog| {
                    if (prog.program_number != 0 and prog.pid == header.pid) {
                        try self.parsePmt(packet, prog.program_number);
                    }
                }
            }

            // Stop once we have all PMTs
            if (self.pat) |pat| {
                var all_found = true;
                for (pat.programs.items) |prog| {
                    if (prog.program_number != 0 and !self.pmts.contains(prog.pid)) {
                        all_found = false;
                        break;
                    }
                }
                if (all_found) break;
            }
        }

        self.offset = saved_offset;
    }

    fn parsePat(self: *TsReader, packet: *const [TS_PACKET_SIZE]u8) !void {
        const header = TsPacketHeader.parse(packet[0..4]);
        if (!header.payload_unit_start) return;

        var offset: usize = 4;

        // Skip adaptation field
        if (header.hasAdaptationField()) {
            offset += 1 + packet[offset];
        }

        // Skip pointer field
        offset += 1 + packet[offset];

        if (offset + 8 > TS_PACKET_SIZE) return;

        // PAT header
        const table_id = packet[offset];
        if (table_id != 0x00) return;

        const section_length = ((@as(u16, packet[offset + 1] & 0x0F) << 8) | packet[offset + 2]);
        const transport_stream_id = (@as(u16, packet[offset + 3]) << 8) | packet[offset + 4];
        const version_info = packet[offset + 5];

        if (self.pat) |*pat| pat.deinit(self.allocator);

        self.pat = Pat{
            .transport_stream_id = transport_stream_id,
            .version = @truncate((version_info >> 1) & 0x1F),
            .current_next = (version_info & 0x01) != 0,
        };

        // Parse program entries (4 bytes each, skip first 5 header bytes and last 4 CRC bytes)
        offset += 8;
        const programs_end = offset + section_length - 5 - 4;

        while (offset + 4 <= programs_end and offset + 4 <= TS_PACKET_SIZE) {
            const program_number = (@as(u16, packet[offset]) << 8) | packet[offset + 1];
            const pid = (@as(u16, packet[offset + 2] & 0x1F) << 8) | packet[offset + 3];

            try self.pat.?.programs.append(self.allocator, .{
                .program_number = program_number,
                .pid = pid,
            });

            offset += 4;
        }
    }

    fn parsePmt(self: *TsReader, packet: *const [TS_PACKET_SIZE]u8, program_number: u16) !void {
        const header = TsPacketHeader.parse(packet[0..4]);
        if (!header.payload_unit_start) return;

        var offset: usize = 4;

        if (header.hasAdaptationField()) {
            offset += 1 + packet[offset];
        }

        offset += 1 + packet[offset];

        if (offset + 12 > TS_PACKET_SIZE) return;

        const table_id = packet[offset];
        if (table_id != 0x02) return;

        const section_length = (@as(u16, packet[offset + 1] & 0x0F) << 8) | packet[offset + 2];
        _ = section_length;
        const version_info = packet[offset + 5];
        const pcr_pid = (@as(u16, packet[offset + 8] & 0x1F) << 8) | packet[offset + 9];
        const program_info_length = (@as(u16, packet[offset + 10] & 0x0F) << 8) | packet[offset + 11];

        var pmt = Pmt{
            .program_number = program_number,
            .version = @truncate((version_info >> 1) & 0x1F),
            .current_next = (version_info & 0x01) != 0,
            .pcr_pid = pcr_pid,
        };

        offset += 12 + program_info_length;

        // Parse elementary streams
        while (offset + 5 <= TS_PACKET_SIZE - 4) {
            const stream_type_raw = packet[offset];
            const es_pid = (@as(u16, packet[offset + 1] & 0x1F) << 8) | packet[offset + 2];
            const es_info_length = (@as(u16, packet[offset + 3] & 0x0F) << 8) | packet[offset + 4];

            try pmt.streams.append(self.allocator, .{
                .stream_type = @enumFromInt(stream_type_raw),
                .pid = es_pid,
            });

            offset += 5 + es_info_length;
        }

        try self.pmts.put(header.pid, pmt);
    }

    /// Get duration estimate (from PCR values)
    pub fn getDurationMs(self: *TsReader) ?u64 {
        var first_pcr: ?u64 = null;
        var last_pcr: ?u64 = null;

        const saved = self.offset;
        self.offset = 0;
        self.findSync() catch return null;

        while (self.nextPacket()) |packet| {
            const header = TsPacketHeader.parse(packet[0..4]);

            if (header.hasAdaptationField() and packet[4] > 0) {
                const af = AdaptationField.parse(packet[4..]);
                if (af.pcr) |pcr| {
                    if (first_pcr == null) first_pcr = pcr;
                    last_pcr = pcr;
                }
            }
        }

        self.offset = saved;

        if (first_pcr != null and last_pcr != null) {
            const pcr_diff = last_pcr.? - first_pcr.?;
            return pcr_diff / 27000; // PCR is 27MHz, convert to ms
        }

        return null;
    }
};

/// Check if data is MPEG-TS
pub fn isMpegTs(data: []const u8) bool {
    if (data.len < TS_PACKET_SIZE * 2) return false;

    // Look for sync bytes
    var sync_count: usize = 0;
    var i: usize = 0;
    while (i < data.len and sync_count < 5) {
        if (data[i] == TS_SYNC_BYTE) {
            if (i + TS_PACKET_SIZE < data.len and data[i + TS_PACKET_SIZE] == TS_SYNC_BYTE) {
                sync_count += 1;
            }
        }
        i += 1;
    }

    return sync_count >= 3;
}

// ============================================================================
// Tests
// ============================================================================

test "TS packet header parsing" {
    const testing = std.testing;

    // PAT packet header: sync=0x47, PID=0, PUSI=1
    const header_data = [4]u8{ 0x47, 0x40, 0x00, 0x10 };
    const header = TsPacketHeader.parse(&header_data);

    try testing.expectEqual(@as(u8, 0x47), header.sync_byte);
    try testing.expectEqual(@as(u16, 0), header.pid);
    try testing.expect(header.payload_unit_start);
    try testing.expect(header.hasPayload());
    try testing.expect(!header.hasAdaptationField());
}

test "Stream type classification" {
    const testing = std.testing;

    try testing.expect(StreamType.h264.isVideo());
    try testing.expect(StreamType.h265.isVideo());
    try testing.expect(!StreamType.h264.isAudio());

    try testing.expect(StreamType.aac.isAudio());
    try testing.expect(StreamType.ac3.isAudio());
    try testing.expect(!StreamType.aac.isVideo());
}

test "MPEG-TS detection" {
    const testing = std.testing;

    // Valid TS packets (sync bytes at 188-byte intervals)
    var data: [TS_PACKET_SIZE * 5]u8 = undefined;
    @memset(&data, 0);
    data[0] = TS_SYNC_BYTE;
    data[TS_PACKET_SIZE] = TS_SYNC_BYTE;
    data[TS_PACKET_SIZE * 2] = TS_SYNC_BYTE;
    data[TS_PACKET_SIZE * 3] = TS_SYNC_BYTE;
    data[TS_PACKET_SIZE * 4] = TS_SYNC_BYTE;

    try testing.expect(isMpegTs(&data));

    // Invalid data
    var invalid: [TS_PACKET_SIZE * 2]u8 = undefined;
    @memset(&invalid, 0);
    try testing.expect(!isMpegTs(&invalid));
}
