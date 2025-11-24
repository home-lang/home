// Home Video Library - RTP/RTSP Protocol
// Real-time Transport Protocol and Real Time Streaming Protocol

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// RTP Constants
// ============================================================================

pub const RTP_VERSION = 2;
pub const RTP_HEADER_MIN_SIZE = 12;

// Common payload types
pub const PT_PCMU = 0;
pub const PT_GSM = 3;
pub const PT_G723 = 4;
pub const PT_PCMA = 8;
pub const PT_G722 = 9;
pub const PT_L16_STEREO = 10;
pub const PT_L16_MONO = 11;
pub const PT_QCELP = 12;
pub const PT_MPA = 14; // MPEG Audio
pub const PT_G728 = 15;
pub const PT_G729 = 18;
pub const PT_H261 = 31;
pub const PT_MPV = 32; // MPEG Video
pub const PT_MP2T = 33; // MPEG-2 Transport
pub const PT_H263 = 34;
pub const PT_H264 = 96; // Dynamic
pub const PT_H265 = 97; // Dynamic

// ============================================================================
// RTP Header
// ============================================================================

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
    csrc: [15]u32 = [_]u32{0} ** 15, // Contributing sources

    pub fn encode(self: *const RtpHeader, out: []u8) !usize {
        if (out.len < RTP_HEADER_MIN_SIZE) return error.BufferTooSmall;

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
            std.mem.writeInt(u32, out[offset .. offset + 4], self.csrc[i], .big);
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
            header.csrc[i] = std.mem.readInt(u32, data[offset .. offset + 4], .big);
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
        const header_size = header.getHeaderSize();

        if (data.len < header_size) return error.InvalidPacket;

        return RtpPacket{
            .header = header,
            .payload = data[header_size..],
        };
    }
};

// ============================================================================
// RTCP (RTP Control Protocol)
// ============================================================================

pub const RtcpPacketType = enum(u8) {
    sr = 200, // Sender Report
    rr = 201, // Receiver Report
    sdes = 202, // Source Description
    bye = 203, // Goodbye
    app = 204, // Application-defined
    _,
};

pub const RtcpHeader = struct {
    version: u2 = RTP_VERSION,
    padding: bool = false,
    count: u5 = 0, // Report count or subtype
    packet_type: RtcpPacketType,
    length: u16, // Length in 32-bit words minus 1

    pub fn decode(data: []const u8) !RtcpHeader {
        if (data.len < 4) return error.InvalidPacket;

        return .{
            .version = @truncate(data[0] >> 6),
            .padding = (data[0] & 0x20) != 0,
            .count = @truncate(data[0] & 0x1F),
            .packet_type = @enumFromInt(data[1]),
            .length = std.mem.readInt(u16, data[2..4], .big),
        };
    }
};

pub const RtcpSenderReport = struct {
    ssrc: u32,
    ntp_timestamp: u64, // NTP timestamp
    rtp_timestamp: u32,
    sender_packet_count: u32,
    sender_octet_count: u32,

    pub fn decode(data: []const u8) !RtcpSenderReport {
        if (data.len < 24) return error.InvalidPacket;

        return .{
            .ssrc = std.mem.readInt(u32, data[0..4], .big),
            .ntp_timestamp = std.mem.readInt(u64, data[4..12], .big),
            .rtp_timestamp = std.mem.readInt(u32, data[12..16], .big),
            .sender_packet_count = std.mem.readInt(u32, data[16..20], .big),
            .sender_octet_count = std.mem.readInt(u32, data[20..24], .big),
        };
    }
};

// ============================================================================
// RTSP (Real Time Streaming Protocol)
// ============================================================================

pub const RtspMethod = enum {
    options,
    describe,
    setup,
    play,
    pause,
    teardown,
    get_parameter,
    set_parameter,
    announce,
    record,
};

pub const RtspRequest = struct {
    method: RtspMethod,
    url: []const u8,
    version: []const u8 = "RTSP/1.0",
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8 = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, method: RtspMethod, url: []const u8) RtspRequest {
        return .{
            .method = method,
            .url = url,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RtspRequest) void {
        self.headers.deinit();
    }

    pub fn addHeader(self: *RtspRequest, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    pub fn serialize(self: *const RtspRequest, allocator: Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        var writer = output.writer();

        // Request line
        try writer.print("{s} {s} {s}\r\n", .{
            @tagName(self.method),
            self.url,
            self.version,
        });

        // Headers
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Empty line
        try writer.writeAll("\r\n");

        // Body
        if (self.body) |body| {
            try writer.writeAll(body);
        }

        return output.toOwnedSlice();
    }

    pub fn parse(data: []const u8, allocator: Allocator) !RtspRequest {
        var lines = std.mem.splitScalar(u8, data, '\n');

        // Parse request line
        const request_line = lines.next() orelse return error.InvalidRequest;
        var parts = std.mem.tokenizeScalar(u8, request_line, ' ');

        const method_str = parts.next() orelse return error.InvalidRequest;
        const url = parts.next() orelse return error.InvalidRequest;
        const version = parts.next() orelse return error.InvalidRequest;

        const method = std.meta.stringToEnum(RtspMethod, method_str) orelse return error.InvalidMethod;

        var request = RtspRequest.init(allocator, method, url);

        // Parse headers
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len == 0) break; // End of headers

            if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
                const name = std.mem.trim(u8, trimmed[0..colon_idx], " ");
                const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " ");
                try request.addHeader(name, value);
            }
        }

        return request;
    }
};

pub const RtspResponse = struct {
    status_code: u16,
    reason_phrase: []const u8,
    version: []const u8 = "RTSP/1.0",
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8 = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, status_code: u16, reason_phrase: []const u8) RtspResponse {
        return .{
            .status_code = status_code,
            .reason_phrase = reason_phrase,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RtspResponse) void {
        self.headers.deinit();
    }

    pub fn addHeader(self: *RtspResponse, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    pub fn serialize(self: *const RtspResponse, allocator: Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        var writer = output.writer();

        // Status line
        try writer.print("{s} {d} {s}\r\n", .{
            self.version,
            self.status_code,
            self.reason_phrase,
        });

        // Headers
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Empty line
        try writer.writeAll("\r\n");

        // Body
        if (self.body) |body| {
            try writer.writeAll(body);
        }

        return output.toOwnedSlice();
    }

    pub fn parse(data: []const u8, allocator: Allocator) !RtspResponse {
        var lines = std.mem.splitScalar(u8, data, '\n');

        // Parse status line
        const status_line = lines.next() orelse return error.InvalidResponse;
        var parts = std.mem.tokenizeScalar(u8, status_line, ' ');

        const version = parts.next() orelse return error.InvalidResponse;
        _ = version;
        const status_str = parts.next() orelse return error.InvalidResponse;
        const status_code = try std.fmt.parseInt(u16, status_str, 10);

        // Remaining is reason phrase
        const reason_start = std.mem.indexOf(u8, status_line, status_str).? + status_str.len + 1;
        const reason_phrase = std.mem.trim(u8, status_line[reason_start..], "\r\n ");

        var response = RtspResponse.init(allocator, status_code, reason_phrase);

        // Parse headers
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len == 0) break;

            if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
                const name = std.mem.trim(u8, trimmed[0..colon_idx], " ");
                const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " ");
                try response.addHeader(name, value);
            }
        }

        return response;
    }
};

// ============================================================================
// SDP (Session Description Protocol)
// ============================================================================

pub const SdpOrigin = struct {
    username: []const u8,
    session_id: u64,
    session_version: u64,
    network_type: []const u8, // Usually "IN"
    address_type: []const u8, // Usually "IP4" or "IP6"
    address: []const u8,
};

pub const SdpConnection = struct {
    network_type: []const u8,
    address_type: []const u8,
    address: []const u8,
};

pub const SdpMedia = struct {
    media_type: []const u8, // "audio", "video", "application"
    port: u16,
    protocol: []const u8, // Usually "RTP/AVP"
    formats: []const []const u8, // Payload type numbers
    attributes: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn deinit(self: *SdpMedia) void {
        for (self.formats) |fmt| {
            self.allocator.free(fmt);
        }
        self.allocator.free(self.formats);
        self.attributes.deinit();
    }
};

pub const SdpSession = struct {
    version: u8 = 0,
    origin: ?SdpOrigin = null,
    session_name: ?[]const u8 = null,
    connection: ?SdpConnection = null,
    timing_start: u64 = 0,
    timing_stop: u64 = 0,
    attributes: std.StringHashMap([]const u8),
    media: std.ArrayList(SdpMedia),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SdpSession {
        return .{
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .media = std.ArrayList(SdpMedia).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SdpSession) void {
        self.attributes.deinit();
        for (self.media.items) |*media| {
            media.deinit();
        }
        self.media.deinit();
    }

    pub fn parse(data: []const u8, allocator: Allocator) !SdpSession {
        var session = SdpSession.init(allocator);
        var lines = std.mem.splitScalar(u8, data, '\n');

        var current_media: ?*SdpMedia = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n ");
            if (trimmed.len < 2 or trimmed[1] != '=') continue;

            const type_char = trimmed[0];
            const value = trimmed[2..];

            switch (type_char) {
                'v' => session.version = try std.fmt.parseInt(u8, value, 10),
                's' => session.session_name = value,
                'o' => {
                    // Parse origin: username sess-id sess-version nettype addrtype address
                    var parts = std.mem.tokenizeScalar(u8, value, ' ');
                    session.origin = SdpOrigin{
                        .username = parts.next() orelse "",
                        .session_id = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0,
                        .session_version = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0,
                        .network_type = parts.next() orelse "IN",
                        .address_type = parts.next() orelse "IP4",
                        .address = parts.next() orelse "",
                    };
                },
                'c' => {
                    // Parse connection: nettype addrtype address
                    var parts = std.mem.tokenizeScalar(u8, value, ' ');
                    const conn = SdpConnection{
                        .network_type = parts.next() orelse "IN",
                        .address_type = parts.next() orelse "IP4",
                        .address = parts.next() orelse "",
                    };
                    if (current_media) |media| {
                        _ = media; // Would store per-media connection
                    } else {
                        session.connection = conn;
                    }
                },
                't' => {
                    // Parse timing: start stop
                    var parts = std.mem.tokenizeScalar(u8, value, ' ');
                    session.timing_start = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
                    session.timing_stop = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
                },
                'a' => {
                    // Parse attribute: name or name:value
                    if (std.mem.indexOf(u8, value, ":")) |colon_idx| {
                        const name = value[0..colon_idx];
                        const attr_value = value[colon_idx + 1 ..];
                        if (current_media) |media| {
                            try media.attributes.put(name, attr_value);
                        } else {
                            try session.attributes.put(name, attr_value);
                        }
                    }
                },
                'm' => {
                    // Parse media: type port proto format1 format2 ...
                    var parts = std.mem.tokenizeScalar(u8, value, ' ');
                    const media_type = parts.next() orelse return error.InvalidSdp;
                    const port_str = parts.next() orelse return error.InvalidSdp;
                    const port = try std.fmt.parseInt(u16, port_str, 10);
                    const protocol = parts.next() orelse return error.InvalidSdp;

                    var formats = std.ArrayList([]const u8).init(allocator);
                    while (parts.next()) |fmt| {
                        try formats.append(try allocator.dupe(u8, fmt));
                    }

                    var media = SdpMedia{
                        .media_type = media_type,
                        .port = port,
                        .protocol = protocol,
                        .formats = try formats.toOwnedSlice(),
                        .attributes = std.StringHashMap([]const u8).init(allocator),
                        .allocator = allocator,
                    };

                    try session.media.append(media);
                    current_media = &session.media.items[session.media.items.len - 1];
                },
                else => {},
            }
        }

        return session;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RTP header encode/decode" {
    const testing = std.testing;

    var header = RtpHeader{
        .payload_type = 96,
        .sequence_number = 12345,
        .timestamp = 987654,
        .ssrc = 0xDEADBEEF,
    };

    var buf: [256]u8 = undefined;
    const size = try header.encode(&buf);

    const decoded = try RtpHeader.decode(buf[0..size]);

    try testing.expectEqual(header.payload_type, decoded.payload_type);
    try testing.expectEqual(header.sequence_number, decoded.sequence_number);
    try testing.expectEqual(header.timestamp, decoded.timestamp);
    try testing.expectEqual(header.ssrc, decoded.ssrc);
}

test "RTSP request parsing" {
    const testing = std.testing;

    const request_data = "OPTIONS rtsp://example.com/stream RTSP/1.0\r\nCSeq: 1\r\n\r\n";

    var request = try RtspRequest.parse(request_data, testing.allocator);
    defer request.deinit();

    try testing.expectEqual(RtspMethod.options, request.method);
}

test "SDP parsing basic" {
    const testing = std.testing;

    const sdp_data =
        \\v=0
        \\s=Test Session
        \\t=0 0
        \\m=video 5004 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
    ;

    var session = try SdpSession.parse(sdp_data, testing.allocator);
    defer session.deinit();

    try testing.expectEqual(@as(u8, 0), session.version);
    try testing.expectEqual(@as(usize, 1), session.media.items.len);
    try testing.expectEqual(@as(u16, 5004), session.media.items[0].port);
}
