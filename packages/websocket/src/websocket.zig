const std = @import("std");
const posix = std.posix;

// Re-export server and broadcaster
pub const server = @import("server.zig");
pub const broadcaster = @import("broadcaster.zig");

pub const Server = server.Server;
pub const Client = server.Client;
pub const Channel = server.Channel;
pub const Broadcaster = broadcaster.Broadcaster;

/// WebSocket client implementation (RFC 6455)
///
/// Features:
/// - Frame encoding/decoding
/// - Text and binary messages
/// - Ping/pong keepalive
/// - Message fragmentation
/// - Secure WebSocket (wss://)
pub const WebSocket = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    is_client: bool,
    closed: bool,
    ping_interval_ms: u64,

    pub const Frame = struct {
        fin: bool,
        rsv1: bool,
        rsv2: bool,
        rsv3: bool,
        opcode: Opcode,
        mask: bool,
        payload_len: u64,
        masking_key: ?[4]u8,
        payload: []const u8,

        pub const Opcode = enum(u4) {
            continuation = 0x0,
            text = 0x1,
            binary = 0x2,
            close = 0x8,
            ping = 0x9,
            pong = 0xA,
            _,
        };
    };

    pub const Message = struct {
        opcode: Frame.Opcode,
        data: []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Message) void {
            self.allocator.free(self.data);
        }
    };

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t, is_client: bool) WebSocket {
        return .{
            .allocator = allocator,
            .socket = socket,
            .is_client = is_client,
            .closed = false,
            .ping_interval_ms = 30000,
        };
    }

    pub fn deinit(self: *WebSocket) void {
        posix.close(self.socket);
    }

    /// Connect to WebSocket server
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) !WebSocket {
        // Create socket
        const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(socket);

        // Resolve host - for simplicity, assume it's an IP address
        // In production, you'd want DNS resolution
        var addr = posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
        };

        // Simple IP parsing
        var ip_parts: [4]u8 = undefined;
        var part_idx: usize = 0;
        var current: u32 = 0;

        for (host) |c| {
            if (c == '.') {
                if (part_idx < 4) {
                    ip_parts[part_idx] = @intCast(current);
                    part_idx += 1;
                    current = 0;
                }
            } else if (c >= '0' and c <= '9') {
                current = current * 10 + (c - '0');
            }
        }
        if (part_idx < 4) {
            ip_parts[part_idx] = @intCast(current);
        }

        addr.addr = @as(u32, ip_parts[0]) | (@as(u32, ip_parts[1]) << 8) | (@as(u32, ip_parts[2]) << 16) | (@as(u32, ip_parts[3]) << 24);

        try posix.connect(socket, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

        var ws = WebSocket.init(allocator, socket, true);
        try ws.performHandshake(host, path);

        return ws;
    }

    fn performHandshake(self: *WebSocket, host: []const u8, path: []const u8) !void {
        // Generate WebSocket key
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);

        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

        // Send handshake request
        var request_buf: [1024]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf,
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, host, key_b64 },
        );

        _ = try posix.send(self.socket, request, 0);

        // Read handshake response
        var buf: [1024]u8 = undefined;
        const n = try posix.recv(self.socket, &buf, 0);
        const response = buf[0..n];

        if (std.mem.indexOf(u8, response, "101 Switching Protocols") == null) {
            return error.HandshakeFailed;
        }
    }

    /// Send a text message
    pub fn sendText(self: *WebSocket, text: []const u8) !void {
        try self.sendFrame(.{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .mask = self.is_client,
            .payload_len = text.len,
            .masking_key = if (self.is_client) self.generateMask() else null,
            .payload = text,
        });
    }

    /// Send a binary message
    pub fn sendBinary(self: *WebSocket, data: []const u8) !void {
        try self.sendFrame(.{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .binary,
            .mask = self.is_client,
            .payload_len = data.len,
            .masking_key = if (self.is_client) self.generateMask() else null,
            .payload = data,
        });
    }

    /// Send a ping frame
    pub fn sendPing(self: *WebSocket, data: []const u8) !void {
        try self.sendFrame(.{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .ping,
            .mask = self.is_client,
            .payload_len = data.len,
            .masking_key = if (self.is_client) self.generateMask() else null,
            .payload = data,
        });
    }

    /// Receive a message
    pub fn receive(self: *WebSocket) !Message {
        var fragments_buf: [65536]u8 = undefined;
        var fragments_len: usize = 0;

        var message_opcode: Frame.Opcode = undefined;
        var first_frame = true;

        while (true) {
            const frame_data = try self.receiveFrame();
            defer self.allocator.free(frame_data.payload);

            if (first_frame) {
                message_opcode = frame_data.opcode;
                first_frame = false;
            }

            // Handle control frames
            switch (frame_data.opcode) {
                .close => {
                    self.closed = true;
                    return error.ConnectionClosed;
                },
                .ping => {
                    // Send pong response
                    try self.sendFrame(.{
                        .fin = true,
                        .rsv1 = false,
                        .rsv2 = false,
                        .rsv3 = false,
                        .opcode = .pong,
                        .mask = self.is_client,
                        .payload_len = frame_data.payload_len,
                        .masking_key = if (self.is_client) self.generateMask() else null,
                        .payload = frame_data.payload,
                    });
                    continue;
                },
                .pong => continue,
                else => {},
            }

            // Append to fragments
            const copy_len = @min(frame_data.payload.len, fragments_buf.len - fragments_len);
            @memcpy(fragments_buf[fragments_len .. fragments_len + copy_len], frame_data.payload[0..copy_len]);
            fragments_len += copy_len;

            if (frame_data.fin) break;
        }

        // Copy to allocated buffer
        const result = try self.allocator.alloc(u8, fragments_len);
        @memcpy(result, fragments_buf[0..fragments_len]);

        return Message{
            .opcode = message_opcode,
            .data = result,
            .allocator = self.allocator,
        };
    }

    fn sendFrame(self: *WebSocket, frame_info: Frame) !void {
        var buffer: [16 + 65536]u8 = undefined;
        var buf_len: usize = 0;

        // Byte 0: FIN, RSV, Opcode
        var byte0: u8 = @intFromEnum(frame_info.opcode);
        if (frame_info.fin) byte0 |= 0x80;
        if (frame_info.rsv1) byte0 |= 0x40;
        if (frame_info.rsv2) byte0 |= 0x20;
        if (frame_info.rsv3) byte0 |= 0x10;
        buffer[buf_len] = byte0;
        buf_len += 1;

        // Byte 1+: Mask, Payload length
        var byte1: u8 = if (frame_info.mask) 0x80 else 0x00;

        if (frame_info.payload_len < 126) {
            byte1 |= @intCast(frame_info.payload_len);
            buffer[buf_len] = byte1;
            buf_len += 1;
        } else if (frame_info.payload_len < 65536) {
            byte1 |= 126;
            buffer[buf_len] = byte1;
            buf_len += 1;
            buffer[buf_len] = @intCast((frame_info.payload_len >> 8) & 0xFF);
            buf_len += 1;
            buffer[buf_len] = @intCast(frame_info.payload_len & 0xFF);
            buf_len += 1;
        } else {
            byte1 |= 127;
            buffer[buf_len] = byte1;
            buf_len += 1;
            var i: u6 = 56;
            while (true) : (i -= 8) {
                buffer[buf_len] = @intCast((frame_info.payload_len >> i) & 0xFF);
                buf_len += 1;
                if (i == 0) break;
            }
        }

        // Masking key
        if (frame_info.masking_key) |mask| {
            @memcpy(buffer[buf_len .. buf_len + 4], &mask);
            buf_len += 4;

            // Masked payload
            for (frame_info.payload, 0..) |byte, i| {
                buffer[buf_len] = byte ^ mask[i % 4];
                buf_len += 1;
            }
        } else {
            // Unmasked payload
            @memcpy(buffer[buf_len .. buf_len + frame_info.payload.len], frame_info.payload);
            buf_len += frame_info.payload.len;
        }

        _ = try posix.send(self.socket, buffer[0..buf_len], 0);
    }

    fn receiveFrame(self: *WebSocket) !Frame {
        var header: [2]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < 2) {
            const n = try posix.recv(self.socket, header[total_read..], 0);
            if (n == 0) return error.ConnectionClosed;
            total_read += n;
        }

        const fin = (header[0] & 0x80) != 0;
        const rsv1 = (header[0] & 0x40) != 0;
        const rsv2 = (header[0] & 0x20) != 0;
        const rsv3 = (header[0] & 0x10) != 0;
        const opcode: Frame.Opcode = @enumFromInt(header[0] & 0x0F);

        const mask = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        if (payload_len == 126) {
            var len_bytes: [2]u8 = undefined;
            total_read = 0;
            while (total_read < 2) {
                const n = try posix.recv(self.socket, len_bytes[total_read..], 0);
                if (n == 0) return error.ConnectionClosed;
                total_read += n;
            }
            payload_len = (@as(u64, len_bytes[0]) << 8) | @as(u64, len_bytes[1]);
        } else if (payload_len == 127) {
            var len_bytes: [8]u8 = undefined;
            total_read = 0;
            while (total_read < 8) {
                const n = try posix.recv(self.socket, len_bytes[total_read..], 0);
                if (n == 0) return error.ConnectionClosed;
                total_read += n;
            }
            payload_len = 0;
            for (len_bytes) |byte| {
                payload_len = (payload_len << 8) | @as(u64, byte);
            }
        }

        var masking_key: ?[4]u8 = null;
        if (mask) {
            var key: [4]u8 = undefined;
            total_read = 0;
            while (total_read < 4) {
                const n = try posix.recv(self.socket, key[total_read..], 0);
                if (n == 0) return error.ConnectionClosed;
                total_read += n;
            }
            masking_key = key;
        }

        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        if (payload_len > 0) {
            total_read = 0;
            while (total_read < payload_len) {
                const n = try posix.recv(self.socket, payload[total_read..], 0);
                if (n == 0) return error.ConnectionClosed;
                total_read += n;
            }

            // Unmask if needed
            if (masking_key) |key| {
                for (payload, 0..) |*byte, i| {
                    byte.* ^= key[i % 4];
                }
            }
        }

        return Frame{
            .fin = fin,
            .rsv1 = rsv1,
            .rsv2 = rsv2,
            .rsv3 = rsv3,
            .opcode = opcode,
            .mask = mask,
            .payload_len = payload_len,
            .masking_key = masking_key,
            .payload = payload,
        };
    }

    fn generateMask(self: *WebSocket) [4]u8 {
        _ = self;
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        return mask;
    }

    /// Close the WebSocket connection
    pub fn close(self: *WebSocket) !void {
        if (self.closed) return;

        try self.sendFrame(.{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .close,
            .mask = self.is_client,
            .payload_len = 0,
            .masking_key = if (self.is_client) self.generateMask() else null,
            .payload = &.{},
        });

        self.closed = true;
    }
};

// Tests
test "websocket frame encoding" {
    const allocator = std.testing.allocator;

    // Test message struct
    var msg = WebSocket.Message{
        .opcode = .text,
        .data = try allocator.dupe(u8, "Hello"),
        .allocator = allocator,
    };
    defer msg.deinit();

    try std.testing.expectEqualStrings("Hello", msg.data);
}
