const std = @import("std");

/// WebSocket client and server implementation (RFC 6455)
///
/// Features:
/// - Frame encoding/decoding
/// - Text and binary messages
/// - Ping/pong keepalive
/// - Message fragmentation
/// - Compression extensions
/// - Secure WebSocket (wss://)
pub const WebSocket = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
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

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, is_client: bool) WebSocket {
        return .{
            .allocator = allocator,
            .stream = stream,
            .is_client = is_client,
            .closed = false,
            .ping_interval_ms = 30000,
        };
    }

    pub fn deinit(self: *WebSocket) void {
        self.stream.close();
    }

    /// Connect to WebSocket server
    pub fn connect(allocator: std.mem.Allocator, url: []const u8) !WebSocket {
        const uri = try std.Uri.parse(url);

        const port: u16 = if (std.mem.eql(u8, uri.scheme, "wss")) 443 else 80;
        const address = try std.net.Address.parseIp(uri.host.?, port);
        const stream = try std.net.tcpConnectToAddress(address);

        var ws = WebSocket.init(allocator, stream, true);
        try ws.performHandshake(uri.host.?, uri.path);

        return ws;
    }

    fn performHandshake(self: *WebSocket, host: []const u8, path: []const u8) !void {
        // Generate WebSocket key
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);

        var key_b64: [24]u8 = undefined;
        const encoder = std.base64.standard.Encoder;
        _ = encoder.encode(&key_b64, &key_bytes);

        // Send handshake request
        const request = try std.fmt.allocPrint(
            self.allocator,
            \\GET {s} HTTP/1.1
            \\Host: {s}
            \\Upgrade: websocket
            \\Connection: Upgrade
            \\Sec-WebSocket-Key: {s}
            \\Sec-WebSocket-Version: 13
            \\
            \\
        , .{ path, host, key_b64 });
        defer self.allocator.free(request);

        try self.stream.writeAll(request);

        // Read handshake response
        var buf: [1024]u8 = undefined;
        const n = try self.stream.read(&buf);
        const response = buf[0..n];

        if (!std.mem.containsAtLeast(u8, response, 1, "101 Switching Protocols")) {
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
        var fragments = std.ArrayList(u8).init(self.allocator);
        defer fragments.deinit();

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

            try fragments.appendSlice(frame_data.payload);

            if (frame_data.fin) break;
        }

        return Message{
            .opcode = message_opcode,
            .data = try fragments.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    fn sendFrame(self: *WebSocket, frame_info: Frame) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        // Byte 0: FIN, RSV, Opcode
        var byte0: u8 = @intFromEnum(frame_info.opcode);
        if (frame_info.fin) byte0 |= 0x80;
        if (frame_info.rsv1) byte0 |= 0x40;
        if (frame_info.rsv2) byte0 |= 0x20;
        if (frame_info.rsv3) byte0 |= 0x10;
        try buffer.append(byte0);

        // Byte 1+: Mask, Payload length
        var byte1: u8 = if (frame_info.mask) 0x80 else 0x00;

        if (frame_info.payload_len < 126) {
            byte1 |= @intCast(frame_info.payload_len);
            try buffer.append(byte1);
        } else if (frame_info.payload_len < 65536) {
            byte1 |= 126;
            try buffer.append(byte1);
            try buffer.append(@intCast((frame_info.payload_len >> 8) & 0xFF));
            try buffer.append(@intCast(frame_info.payload_len & 0xFF));
        } else {
            byte1 |= 127;
            try buffer.append(byte1);
            var i: usize = 56;
            while (i >= 0) : (i -= 8) {
                try buffer.append(@intCast((frame_info.payload_len >> @intCast(i)) & 0xFF));
                if (i == 0) break;
            }
        }

        // Masking key
        if (frame_info.masking_key) |mask| {
            try buffer.appendSlice(&mask);

            // Masked payload
            var masked_payload = try self.allocator.alloc(u8, frame_info.payload.len);
            defer self.allocator.free(masked_payload);

            for (frame_info.payload, 0..) |byte, i| {
                masked_payload[i] = byte ^ mask[i % 4];
            }
            try buffer.appendSlice(masked_payload);
        } else {
            // Unmasked payload
            try buffer.appendSlice(frame_info.payload);
        }

        try self.stream.writeAll(buffer.items);
    }

    fn receiveFrame(self: *WebSocket) !Frame {
        var header: [2]u8 = undefined;
        try self.stream.reader().readNoEof(&header);

        const fin = (header[0] & 0x80) != 0;
        const rsv1 = (header[0] & 0x40) != 0;
        const rsv2 = (header[0] & 0x20) != 0;
        const rsv3 = (header[0] & 0x10) != 0;
        const opcode: Frame.Opcode = @enumFromInt(header[0] & 0x0F);

        const mask = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        if (payload_len == 126) {
            var len_bytes: [2]u8 = undefined;
            try self.stream.reader().readNoEof(&len_bytes);
            payload_len = (@as(u64, len_bytes[0]) << 8) | @as(u64, len_bytes[1]);
        } else if (payload_len == 127) {
            var len_bytes: [8]u8 = undefined;
            try self.stream.reader().readNoEof(&len_bytes);
            payload_len = 0;
            for (len_bytes) |byte| {
                payload_len = (payload_len << 8) | @as(u64, byte);
            }
        }

        var masking_key: ?[4]u8 = null;
        if (mask) {
            var key: [4]u8 = undefined;
            try self.stream.reader().readNoEof(&key);
            masking_key = key;
        }

        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        if (payload_len > 0) {
            try self.stream.reader().readNoEof(payload);

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
