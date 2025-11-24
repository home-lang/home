// Home Video Library - RTMP Protocol
// Real-Time Messaging Protocol for streaming

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// RTMP Constants
// ============================================================================

pub const RTMP_VERSION = 3;
pub const RTMP_HANDSHAKE_SIZE = 1536;
pub const RTMP_DEFAULT_CHUNK_SIZE = 128;
pub const RTMP_MAX_CHUNK_SIZE = 65536;

// Message Type IDs
pub const MSG_SET_CHUNK_SIZE = 1;
pub const MSG_ABORT = 2;
pub const MSG_ACKNOWLEDGEMENT = 3;
pub const MSG_USER_CONTROL = 4;
pub const MSG_WINDOW_ACK_SIZE = 5;
pub const MSG_SET_PEER_BANDWIDTH = 6;
pub const MSG_AUDIO = 8;
pub const MSG_VIDEO = 9;
pub const MSG_DATA_AMF3 = 15;
pub const MSG_SHARED_OBJECT_AMF3 = 16;
pub const MSG_COMMAND_AMF3 = 17;
pub const MSG_DATA_AMF0 = 18;
pub const MSG_SHARED_OBJECT_AMF0 = 19;
pub const MSG_COMMAND_AMF0 = 20;
pub const MSG_AGGREGATE = 22;

// ============================================================================
// RTMP Chunk Format
// ============================================================================

pub const ChunkFormat = enum(u2) {
    type_0 = 0, // 11 bytes header
    type_1 = 1, // 7 bytes header
    type_2 = 2, // 3 bytes header
    type_3 = 3, // 0 bytes header (continuation)
};

pub const ChunkBasicHeader = struct {
    format: ChunkFormat,
    chunk_stream_id: u32, // Can be 2-65599

    pub fn encode(self: *const ChunkBasicHeader, out: []u8) usize {
        if (self.chunk_stream_id < 64) {
            // 1 byte form
            out[0] = (@as(u8, @intFromEnum(self.format)) << 6) | @as(u8, @intCast(self.chunk_stream_id));
            return 1;
        } else if (self.chunk_stream_id < 320) {
            // 2 byte form
            out[0] = (@as(u8, @intFromEnum(self.format)) << 6);
            out[1] = @intCast(self.chunk_stream_id - 64);
            return 2;
        } else {
            // 3 byte form
            out[0] = (@as(u8, @intFromEnum(self.format)) << 6) | 1;
            const id_minus_64 = self.chunk_stream_id - 64;
            out[1] = @intCast(id_minus_64 & 0xFF);
            out[2] = @intCast((id_minus_64 >> 8) & 0xFF);
            return 3;
        }
    }

    pub fn decode(data: []const u8) ?struct { header: ChunkBasicHeader, bytes_read: usize } {
        if (data.len < 1) return null;

        const fmt: ChunkFormat = @enumFromInt(@as(u2, @truncate(data[0] >> 6)));
        const cs_id_low = data[0] & 0x3F;

        if (cs_id_low == 0) {
            // 2 byte form
            if (data.len < 2) return null;
            return .{
                .header = .{
                    .format = fmt,
                    .chunk_stream_id = @as(u32, data[1]) + 64,
                },
                .bytes_read = 2,
            };
        } else if (cs_id_low == 1) {
            // 3 byte form
            if (data.len < 3) return null;
            return .{
                .header = .{
                    .format = fmt,
                    .chunk_stream_id = (@as(u32, data[2]) << 8) | @as(u32, data[1]) + 64,
                },
                .bytes_read = 3,
            };
        } else {
            // 1 byte form
            return .{
                .header = .{
                    .format = fmt,
                    .chunk_stream_id = cs_id_low,
                },
                .bytes_read = 1,
            };
        }
    }
};

pub const ChunkMessageHeader = struct {
    timestamp: u32 = 0,
    message_length: u32 = 0,
    message_type_id: u8 = 0,
    message_stream_id: u32 = 0,
    extended_timestamp: bool = false,
};

// ============================================================================
// RTMP Message
// ============================================================================

pub const RtmpMessage = struct {
    chunk_stream_id: u32,
    timestamp: u32,
    message_type_id: u8,
    message_stream_id: u32,
    payload: []u8,

    pub fn deinit(self: *RtmpMessage, allocator: Allocator) void {
        allocator.free(self.payload);
    }
};

// ============================================================================
// RTMP Handshake
// ============================================================================

pub const RtmpHandshake = struct {
    pub const State = enum {
        uninitialized,
        version_sent,
        ack_sent,
        done,
    };

    state: State = .uninitialized,
    c0_c1: [1 + RTMP_HANDSHAKE_SIZE]u8 = undefined,
    s0_s1: [1 + RTMP_HANDSHAKE_SIZE]u8 = undefined,
    c2: [RTMP_HANDSHAKE_SIZE]u8 = undefined,
    s2: [RTMP_HANDSHAKE_SIZE]u8 = undefined,

    pub fn init() RtmpHandshake {
        return .{};
    }

    /// Generate C0+C1 for client
    pub fn generateC0C1(self: *RtmpHandshake) []const u8 {
        // C0: version
        self.c0_c1[0] = RTMP_VERSION;

        // C1: time + zero + random
        const timestamp = @as(u32, @intCast(std.time.milliTimestamp() & 0xFFFFFFFF));
        std.mem.writeInt(u32, self.c0_c1[1..5], timestamp, .big);
        std.mem.writeInt(u32, self.c0_c1[5..9], 0, .big); // Zero

        // Random bytes
        var prng = std.rand.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
        const random = prng.random();
        random.bytes(self.c0_c1[9..][0..RTMP_HANDSHAKE_SIZE - 8]);

        self.state = .version_sent;
        return &self.c0_c1;
    }

    /// Process S0+S1+S2 from server
    pub fn processS0S1S2(self: *RtmpHandshake, data: []const u8) ![]const u8 {
        if (data.len < 1 + RTMP_HANDSHAKE_SIZE * 2) return error.InvalidHandshake;

        // Verify S0
        if (data[0] != RTMP_VERSION) return error.VersionMismatch;

        // Store S1
        @memcpy(&self.s0_s1, data[0 .. 1 + RTMP_HANDSHAKE_SIZE]);

        // Generate C2 (echo S1)
        @memcpy(&self.c2, data[1 .. 1 + RTMP_HANDSHAKE_SIZE]);

        self.state = .done;
        return &self.c2;
    }

    /// Generate S0+S1 for server
    pub fn generateS0S1(self: *RtmpHandshake) []const u8 {
        // S0: version
        self.s0_s1[0] = RTMP_VERSION;

        // S1: time + zero + random
        const timestamp = @as(u32, @intCast(std.time.milliTimestamp() & 0xFFFFFFFF));
        std.mem.writeInt(u32, self.s0_s1[1..5], timestamp, .big);
        std.mem.writeInt(u32, self.s0_s1[5..9], 0, .big);

        var prng = std.rand.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
        const random = prng.random();
        random.bytes(self.s0_s1[9..][0..RTMP_HANDSHAKE_SIZE - 8]);

        return &self.s0_s1;
    }

    /// Process C2 and generate S2
    pub fn processC2AndGenerateS2(self: *RtmpHandshake, c1: []const u8, c2: []const u8) ![]const u8 {
        if (c1.len != RTMP_HANDSHAKE_SIZE or c2.len != RTMP_HANDSHAKE_SIZE) {
            return error.InvalidHandshake;
        }

        // S2 echoes C1
        @memcpy(&self.s2, c1);
        self.state = .done;

        return &self.s2;
    }
};

// ============================================================================
// RTMP Chunk Stream
// ============================================================================

pub const ChunkStream = struct {
    chunk_stream_id: u32,
    last_header: ChunkMessageHeader = .{},
    buffer: std.ArrayList(u8),
    bytes_read: u32 = 0,

    pub fn init(allocator: Allocator, chunk_stream_id: u32) ChunkStream {
        return .{
            .chunk_stream_id = chunk_stream_id,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *ChunkStream) void {
        self.buffer.deinit();
    }

    pub fn reset(self: *ChunkStream) void {
        self.buffer.clearRetainingCapacity();
        self.bytes_read = 0;
    }
};

// ============================================================================
// RTMP Connection
// ============================================================================

pub const RtmpConnection = struct {
    chunk_size: u32 = RTMP_DEFAULT_CHUNK_SIZE,
    peer_chunk_size: u32 = RTMP_DEFAULT_CHUNK_SIZE,
    window_ack_size: u32 = 2500000,
    peer_bandwidth: u32 = 2500000,
    chunk_streams: std.AutoHashMap(u32, ChunkStream),
    allocator: Allocator,

    pub fn init(allocator: Allocator) RtmpConnection {
        return .{
            .chunk_streams = std.AutoHashMap(u32, ChunkStream).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RtmpConnection) void {
        var it = self.chunk_streams.valueIterator();
        while (it.next()) |stream| {
            stream.deinit();
        }
        self.chunk_streams.deinit();
    }

    pub fn getOrCreateChunkStream(self: *RtmpConnection, cs_id: u32) !*ChunkStream {
        const result = try self.chunk_streams.getOrPut(cs_id);
        if (!result.found_existing) {
            result.value_ptr.* = ChunkStream.init(self.allocator, cs_id);
        }
        return result.value_ptr;
    }

    /// Decode RTMP chunks from stream
    pub fn decodeChunk(self: *RtmpConnection, data: []const u8) !?RtmpMessage {
        if (data.len < 1) return null;

        // Parse basic header
        const basic_result = ChunkBasicHeader.decode(data) orelse return null;
        var offset = basic_result.bytes_read;

        const stream = try self.getOrCreateChunkStream(basic_result.header.chunk_stream_id);

        // Parse message header based on format
        var header = stream.last_header;
        const extended_timestamp: bool = switch (basic_result.header.format) {
            .type_0 => blk: {
                if (offset + 11 > data.len) return null;
                const ts_bytes = data[offset .. offset + 3];
                header.timestamp = (@as(u32, ts_bytes[0]) << 16) |
                    (@as(u32, ts_bytes[1]) << 8) |
                    @as(u32, ts_bytes[2]);
                offset += 3;

                const len_bytes = data[offset .. offset + 3];
                header.message_length = (@as(u32, len_bytes[0]) << 16) |
                    (@as(u32, len_bytes[1]) << 8) |
                    @as(u32, len_bytes[2]);
                offset += 3;

                header.message_type_id = data[offset];
                offset += 1;

                header.message_stream_id = std.mem.readInt(u32, data[offset .. offset + 4], .little);
                offset += 4;

                break :blk header.timestamp == 0xFFFFFF;
            },
            .type_1 => blk: {
                if (offset + 7 > data.len) return null;
                const ts_bytes = data[offset .. offset + 3];
                const ts_delta = (@as(u32, ts_bytes[0]) << 16) |
                    (@as(u32, ts_bytes[1]) << 8) |
                    @as(u32, ts_bytes[2]);
                header.timestamp += ts_delta;
                offset += 3;

                const len_bytes = data[offset .. offset + 3];
                header.message_length = (@as(u32, len_bytes[0]) << 16) |
                    (@as(u32, len_bytes[1]) << 8) |
                    @as(u32, len_bytes[2]);
                offset += 3;

                header.message_type_id = data[offset];
                offset += 1;

                break :blk ts_delta == 0xFFFFFF;
            },
            .type_2 => blk: {
                if (offset + 3 > data.len) return null;
                const ts_bytes = data[offset .. offset + 3];
                const ts_delta = (@as(u32, ts_bytes[0]) << 16) |
                    (@as(u32, ts_bytes[1]) << 8) |
                    @as(u32, ts_bytes[2]);
                header.timestamp += ts_delta;
                offset += 3;

                break :blk ts_delta == 0xFFFFFF;
            },
            .type_3 => false, // Use previous header
        };

        // Read extended timestamp if present
        if (extended_timestamp) {
            if (offset + 4 > data.len) return null;
            header.timestamp = std.mem.readInt(u32, data[offset .. offset + 4], .big);
            offset += 4;
        }

        stream.last_header = header;

        // Read chunk data
        const chunk_size = @min(self.peer_chunk_size, header.message_length - stream.bytes_read);
        if (offset + chunk_size > data.len) return null;

        try stream.buffer.appendSlice(data[offset .. offset + chunk_size]);
        stream.bytes_read += chunk_size;

        // Check if message is complete
        if (stream.bytes_read >= header.message_length) {
            const message = RtmpMessage{
                .chunk_stream_id = basic_result.header.chunk_stream_id,
                .timestamp = header.timestamp,
                .message_type_id = header.message_type_id,
                .message_stream_id = header.message_stream_id,
                .payload = try stream.buffer.toOwnedSlice(),
            };

            stream.reset();
            return message;
        }

        return null;
    }
};

// ============================================================================
// AMF0 Encoding/Decoding (for RTMP commands)
// ============================================================================

pub const Amf0Type = enum(u8) {
    number = 0x00,
    boolean = 0x01,
    string = 0x02,
    object = 0x03,
    null = 0x05,
    undefined = 0x06,
    ecma_array = 0x08,
    object_end = 0x09,
    strict_array = 0x0A,
};

pub const Amf0Value = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
    null_value: void,
    undefined: void,

    pub fn encodeNumber(value: f64, out: []u8) usize {
        out[0] = @intFromEnum(Amf0Type.number);
        const bits: u64 = @bitCast(value);
        std.mem.writeInt(u64, out[1..9], bits, .big);
        return 9;
    }

    pub fn encodeString(value: []const u8, out: []u8) usize {
        out[0] = @intFromEnum(Amf0Type.string);
        std.mem.writeInt(u16, out[1..3], @intCast(value.len), .big);
        @memcpy(out[3 .. 3 + value.len], value);
        return 3 + value.len;
    }

    pub fn encodeBoolean(value: bool, out: []u8) usize {
        out[0] = @intFromEnum(Amf0Type.boolean);
        out[1] = if (value) 1 else 0;
        return 2;
    }

    pub fn encodeNull(out: []u8) usize {
        out[0] = @intFromEnum(Amf0Type.null);
        return 1;
    }
};

// ============================================================================
// RTMP URL Parsing
// ============================================================================

pub const RtmpUrl = struct {
    scheme: []const u8, // "rtmp" or "rtmps"
    host: []const u8,
    port: u16 = 1935,
    app: []const u8,
    stream_name: []const u8,

    pub fn parse(url: []const u8, allocator: Allocator) !RtmpUrl {
        // rtmp://host:port/app/stream
        var scheme_end: usize = 0;
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            scheme_end = idx;
        } else {
            return error.InvalidUrl;
        }

        const scheme = url[0..scheme_end];
        var remaining = url[scheme_end + 3 ..];

        // Extract host:port
        var host: []const u8 = undefined;
        var port: u16 = 1935;

        if (std.mem.indexOf(u8, remaining, "/")) |slash_idx| {
            const host_port = remaining[0..slash_idx];
            remaining = remaining[slash_idx + 1 ..];

            if (std.mem.indexOf(u8, host_port, ":")) |colon_idx| {
                host = host_port[0..colon_idx];
                port = try std.fmt.parseInt(u16, host_port[colon_idx + 1 ..], 10);
            } else {
                host = host_port;
            }
        } else {
            return error.InvalidUrl;
        }

        // Extract app and stream
        if (std.mem.indexOf(u8, remaining, "/")) |app_end| {
            const app = remaining[0..app_end];
            const stream_name = remaining[app_end + 1 ..];

            return RtmpUrl{
                .scheme = try allocator.dupe(u8, scheme),
                .host = try allocator.dupe(u8, host),
                .port = port,
                .app = try allocator.dupe(u8, app),
                .stream_name = try allocator.dupe(u8, stream_name),
            };
        }

        return error.InvalidUrl;
    }

    pub fn deinit(self: *RtmpUrl, allocator: Allocator) void {
        allocator.free(self.scheme);
        allocator.free(self.host);
        allocator.free(self.app);
        allocator.free(self.stream_name);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RTMP chunk basic header encode/decode" {
    const testing = std.testing;

    var out: [3]u8 = undefined;
    const header = ChunkBasicHeader{
        .format = .type_0,
        .chunk_stream_id = 3,
    };

    const size = header.encode(&out);
    try testing.expectEqual(@as(usize, 1), size);

    const decoded = ChunkBasicHeader.decode(out[0..size]);
    try testing.expect(decoded != null);
    try testing.expectEqual(header.format, decoded.?.header.format);
    try testing.expectEqual(header.chunk_stream_id, decoded.?.header.chunk_stream_id);
}

test "RTMP handshake C0C1 generation" {
    const testing = std.testing;

    var handshake = RtmpHandshake.init();
    const c0c1 = handshake.generateC0C1();

    try testing.expectEqual(@as(usize, 1 + RTMP_HANDSHAKE_SIZE), c0c1.len);
    try testing.expectEqual(@as(u8, RTMP_VERSION), c0c1[0]);
}

test "RTMP URL parsing" {
    const testing = std.testing;

    var url = try RtmpUrl.parse("rtmp://localhost:1935/live/stream", testing.allocator);
    defer url.deinit(testing.allocator);

    try testing.expect(std.mem.eql(u8, url.scheme, "rtmp"));
    try testing.expect(std.mem.eql(u8, url.host, "localhost"));
    try testing.expectEqual(@as(u16, 1935), url.port);
    try testing.expect(std.mem.eql(u8, url.app, "live"));
    try testing.expect(std.mem.eql(u8, url.stream_name, "stream"));
}

test "AMF0 number encoding" {
    const testing = std.testing;

    var out: [9]u8 = undefined;
    const size = Amf0Value.encodeNumber(42.0, &out);

    try testing.expectEqual(@as(usize, 9), size);
    try testing.expectEqual(@as(u8, 0x00), out[0]);
}
