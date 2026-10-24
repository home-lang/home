//! RTP version 2 fixed header, CSRCs, extension and padding boundaries.
const std = @import("std");
pub const RTP_VERSION = 2;
pub const RTP_HEADER_MIN_SIZE = 12;
pub const RtpHeader = struct {
    version: u2 = RTP_VERSION,
    padding: bool = false,
    extension: bool = false,
    csrc_count: u4 = 0,
    marker: bool = false,
    payload_type: u7,
    sequence_number: u16,
    timestamp: u32,
    ssrc: u32,
    csrc: [15]u32 = @splat(0), // Contributing sources

    pub fn encode(self: *const RtpHeader, out: []u8) !usize {
        if (self.version != RTP_VERSION) return error.UnsupportedVersion;
        if (out.len < self.getHeaderSize()) return error.BufferTooSmall;

        // Byte 0: V, P, X, CC
        out[0] = (@as(u8, self.version) << 6) |
            (@as(u8, if (self.padding) 1 else 0) << 5) |
            (@as(u8, if (self.extension) 1 else 0) << 4) |
            self.csrc_count;

        // Byte 1: M, PT
        out[1] = (@as(u8, if (self.marker) 1 else 0) << 7) | self.payload_type;

        // Bytes 2-3: Sequence number
        std.mem.writeInt(u16, out[2..4], self.sequence_number, .big);

        // Bytes 4-7: Timestamp
        std.mem.writeInt(u32, out[4..8], self.timestamp, .big);

        // Bytes 8-11: SSRC
        std.mem.writeInt(u32, out[8..12], self.ssrc, .big);

        var offset: usize = 12;

        // CSRC list
        for (0..self.csrc_count) |i| {
            if (offset + 4 > out.len) return error.BufferTooSmall;
            std.mem.writeInt(u32, out[offset..][0..4], self.csrc[i], .big);
            offset += 4;
        }

        return offset;
    }

    pub fn decode(data: []const u8) !RtpHeader {
        if (data.len < RTP_HEADER_MIN_SIZE) return error.InvalidPacket;

        var header = RtpHeader{
            .payload_type = 0,
            .sequence_number = 0,
            .timestamp = 0,
            .ssrc = 0,
        };

        // Byte 0
        header.version = @truncate(data[0] >> 6);
        header.padding = (data[0] & 0x20) != 0;
        header.extension = (data[0] & 0x10) != 0;
        header.csrc_count = @truncate(data[0] & 0x0F);

        if (header.version != RTP_VERSION) return error.UnsupportedVersion;

        // Byte 1
        header.marker = (data[1] & 0x80) != 0;
        header.payload_type = @truncate(data[1] & 0x7F);

        // Sequence number
        header.sequence_number = std.mem.readInt(u16, data[2..4], .big);

        // Timestamp
        header.timestamp = std.mem.readInt(u32, data[4..8], .big);

        // SSRC
        header.ssrc = std.mem.readInt(u32, data[8..12], .big);

        // CSRC list
        var offset: usize = 12;
        for (0..header.csrc_count) |i| {
            if (offset + 4 > data.len) return error.InvalidPacket;
            header.csrc[i] = std.mem.readInt(u32, data[offset..][0..4], .big);
            offset += 4;
        }

        return header;
    }

    pub fn getHeaderSize(self: *const RtpHeader) usize {
        return RTP_HEADER_MIN_SIZE + @as(usize, self.csrc_count) * 4;
    }
};

// ============================================================================
// RTP Packet
// ============================================================================

pub const RtpPacket = struct {
    header: RtpHeader,
    payload: []const u8,

    pub fn parse(data: []const u8) !RtpPacket {
        const header = try RtpHeader.decode(data);
        var header_size = header.getHeaderSize();
        if (data.len < header_size) return error.InvalidPacket;
        if (header.extension) {
            if (data.len - header_size < 4) return error.InvalidPacket;
            const words = std.mem.readInt(u16, data[header_size + 2 ..][0..2], .big);
            const extra = 4 + @as(usize, words) * 4;
            if (extra > data.len - header_size) return error.InvalidPacket;
            header_size += extra;
        }
        var end = data.len;
        if (header.padding) {
            if (end == header_size) return error.InvalidPacket;
            const padding = data[end - 1];
            if (padding == 0 or padding > end - header_size) return error.InvalidPacket;
            end -= padding;
        }

        return RtpPacket{
            .header = header,
            .payload = data[header_size..end],
        };
    }
};

test "RTP header encode short CSRC buffers leave every byte unchanged" {
    const t = std.testing;
    const header = RtpHeader{ .payload_type = 96, .sequence_number = 1, .timestamp = 2, .ssrc = 3, .csrc_count = 2, .csrc = .{ 4, 5 } ++ @as([13]u32, @splat(0)) };
    for (0..20) |length| {
        var bytes: [20]u8 = @splat(0xa5);
        try t.expectError(error.BufferTooSmall, header.encode(bytes[0..length]));
        for (bytes) |v| try t.expectEqual(@as(u8, 0xa5), v);
    }
}
test "RTP packet excludes complete extensions and validated padding and rejects every truncation" {
    const t = std.testing;
    const bytes = [_]u8{ 0xb1, 0xe0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0xbe, 0xde, 0, 1, 1, 2, 3, 4, 0x65, 0x80, 0, 2 };
    const parsed = try RtpPacket.parse(&bytes);
    try t.expectEqualSlices(u8, &.{ 0x65, 0x80 }, parsed.payload);
    for (0..26) |length| try t.expectError(error.InvalidPacket, RtpPacket.parse(bytes[0..length]));
    var invalid = bytes;
    invalid[27] = 0;
    try t.expectError(error.InvalidPacket, RtpPacket.parse(&invalid));
    invalid[27] = 5;
    try t.expectError(error.InvalidPacket, RtpPacket.parse(&invalid));
    invalid = bytes;
    invalid[18] = 0xff;
    try t.expectError(error.InvalidPacket, RtpPacket.parse(&invalid));
}
