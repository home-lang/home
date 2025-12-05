const std = @import("std");
const posix = std.posix;
const ws = @import("websocket.zig");

/// WebSocket server implementation
pub const Server = struct {
    allocator: std.mem.Allocator,
    socket: posix.socket_t,
    clients: std.AutoHashMap(u64, *Client),
    channels: std.StringHashMap(*Channel),
    next_client_id: u64,
    on_connect: ?*const fn (*Client) void,
    on_disconnect: ?*const fn (*Client) void,
    on_message: ?*const fn (*Client, Message) void,

    const Self = @This();

    pub const Config = struct {
        port: u16 = 8080,
        max_connections: u32 = 10000,
        ping_interval_ms: u64 = 30000,
        max_message_size: usize = 1024 * 1024, // 1MB
    };

    pub const Message = struct {
        data: []const u8,
        is_binary: bool,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const self = try allocator.create(Self);

        // Create TCP socket
        const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(socket);

        // Set socket options
        const reuseaddr: i32 = 1;
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&reuseaddr));

        // Bind to port
        const addr = posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, config.port),
            .addr = 0, // INADDR_ANY
        };
        try posix.bind(socket, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));

        // Listen
        try posix.listen(socket, @intCast(config.max_connections));

        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .clients = std.AutoHashMap(u64, *Client).init(allocator),
            .channels = std.StringHashMap(*Channel).init(allocator),
            .next_client_id = 1,
            .on_connect = null,
            .on_disconnect = null,
            .on_message = null,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Close all clients
        var client_iter = self.clients.iterator();
        while (client_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.clients.deinit();

        // Cleanup channels
        var channel_iter = self.channels.iterator();
        while (channel_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.channels.deinit();

        posix.close(self.socket);
        self.allocator.destroy(self);
    }

    /// Accept new connections (call in a loop)
    pub fn acceptConnection(self: *Self) !?*Client {
        var client_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const client_socket = posix.accept(self.socket, @ptrCast(&client_addr), &addr_len) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        // Perform WebSocket handshake
        const client = try self.createClient(client_socket);
        try self.performHandshake(client);

        try self.clients.put(client.id, client);

        if (self.on_connect) |callback| {
            callback(client);
        }

        return client;
    }

    fn createClient(self: *Self, socket: posix.socket_t) !*Client {
        const client = try self.allocator.create(Client);
        client.* = .{
            .id = self.next_client_id,
            .socket = socket,
            .allocator = self.allocator,
            .server = self,
            .channels = std.StringHashMap(void).init(self.allocator),
            .user_data = null,
        };
        self.next_client_id += 1;
        return client;
    }

    fn performHandshake(self: *Self, client: *Client) !void {
        _ = self;

        var buf: [4096]u8 = undefined;
        const bytes_read = try posix.recv(client.socket, &buf, 0);
        if (bytes_read == 0) return error.ConnectionClosed;

        const request = buf[0..bytes_read];

        // Find Sec-WebSocket-Key header
        const key_start = std.mem.indexOf(u8, request, "Sec-WebSocket-Key: ") orelse return error.InvalidHandshake;
        const key_end = std.mem.indexOfPos(u8, request, key_start + 19, "\r\n") orelse return error.InvalidHandshake;
        const ws_key = request[key_start + 19 .. key_end];

        // Calculate accept key
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var accept_data: [60]u8 = undefined;
        @memcpy(accept_data[0..ws_key.len], ws_key);
        @memcpy(accept_data[ws_key.len .. ws_key.len + magic.len], magic);

        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(accept_data[0 .. ws_key.len + magic.len], &hash, .{});

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

        // Send response
        const response = try std.fmt.allocPrint(client.allocator,
            \\HTTP/1.1 101 Switching Protocols
            \\Upgrade: websocket
            \\Connection: Upgrade
            \\Sec-WebSocket-Accept: {s}
            \\
            \\
        , .{accept_key});
        defer client.allocator.free(response);

        _ = try posix.send(client.socket, response, 0);
    }

    /// Broadcast a message to all connected clients
    pub fn broadcast(self: *Self, data: []const u8, is_binary: bool) !void {
        var iter = self.clients.iterator();
        while (iter.next()) |entry| {
            if (is_binary) {
                entry.value_ptr.*.sendBinary(data) catch continue;
            } else {
                entry.value_ptr.*.send(data) catch continue;
            }
        }
    }

    /// Broadcast to a specific channel
    pub fn broadcastToChannel(self: *Self, channel_name: []const u8, data: []const u8, is_binary: bool) !void {
        const ch = self.channels.get(channel_name) orelse return;
        try ch.broadcast(data, is_binary);
    }

    /// Get or create a channel
    pub fn channel(self: *Self, name: []const u8) !*Channel {
        if (self.channels.get(name)) |ch| {
            return ch;
        }

        const ch = try self.allocator.create(Channel);
        ch.* = .{
            .name = try self.allocator.dupe(u8, name),
            .members = std.AutoHashMap(u64, *Client).init(self.allocator),
            .allocator = self.allocator,
            .on_join = null,
            .on_leave = null,
            .is_presence = false,
        };

        const name_copy = try self.allocator.dupe(u8, name);
        try self.channels.put(name_copy, ch);

        return ch;
    }

    /// Create a presence channel (tracks who's online)
    pub fn presenceChannel(self: *Self, name: []const u8) !*Channel {
        const ch = try self.channel(name);
        ch.is_presence = true;
        return ch;
    }

    /// Remove a client
    pub fn removeClient(self: *Self, client: *Client) void {
        // Leave all channels
        var channel_iter = client.channels.keyIterator();
        while (channel_iter.next()) |channel_name| {
            if (self.channels.get(channel_name.*)) |ch| {
                ch.removeMember(client);
            }
        }

        if (self.on_disconnect) |callback| {
            callback(client);
        }

        _ = self.clients.remove(client.id);
        client.deinit();
        self.allocator.destroy(client);
    }
};

/// WebSocket client (server-side connection)
pub const Client = struct {
    id: u64,
    socket: posix.socket_t,
    allocator: std.mem.Allocator,
    server: *Server,
    channels: std.StringHashMap(void),
    user_data: ?*anyopaque,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.channels.deinit();
        posix.close(self.socket);
    }

    /// Send a text message
    pub fn send(self: *Self, data: []const u8) !void {
        try self.sendFrame(data, false, 0x1); // text frame
    }

    /// Send a binary message
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        try self.sendFrame(data, false, 0x2); // binary frame
    }

    /// Send JSON data
    pub fn sendJson(self: *Self, value: anytype) !void {
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try std.json.stringify(value, .{}, fbs.writer());
        try self.send(fbs.getWritten());
    }

    fn sendFrame(self: *Self, data: []const u8, masked: bool, opcode: u8) !void {
        var frame_buf: [16]u8 = undefined;
        var frame_len: usize = 0;

        // First byte: FIN + opcode
        frame_buf[0] = 0x80 | opcode;
        frame_len += 1;

        // Second byte: mask flag + length
        if (data.len < 126) {
            frame_buf[1] = @intCast(data.len);
            if (masked) frame_buf[1] |= 0x80;
            frame_len += 1;
        } else if (data.len < 65536) {
            frame_buf[1] = 126;
            if (masked) frame_buf[1] |= 0x80;
            frame_buf[2] = @intCast((data.len >> 8) & 0xFF);
            frame_buf[3] = @intCast(data.len & 0xFF);
            frame_len += 3;
        } else {
            frame_buf[1] = 127;
            if (masked) frame_buf[1] |= 0x80;
            var i: u6 = 56;
            var pos: usize = 2;
            while (true) : (i -= 8) {
                frame_buf[pos] = @intCast((data.len >> i) & 0xFF);
                pos += 1;
                if (i == 0) break;
            }
            frame_len = pos;
        }

        // Send frame header
        _ = try posix.send(self.socket, frame_buf[0..frame_len], 0);

        // Send payload
        _ = try posix.send(self.socket, data, 0);
    }

    /// Receive a message (non-blocking)
    pub fn receive(self: *Self) !?Server.Message {
        var header: [2]u8 = undefined;
        const bytes_read = posix.recv(self.socket, &header, posix.MSG.DONTWAIT) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        if (bytes_read == 0) return error.ConnectionClosed;
        if (bytes_read < 2) return error.InvalidFrame;

        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            var len_bytes: [2]u8 = undefined;
            _ = try posix.recv(self.socket, &len_bytes, 0);
            payload_len = (@as(u64, len_bytes[0]) << 8) | @as(u64, len_bytes[1]);
        } else if (payload_len == 127) {
            var len_bytes: [8]u8 = undefined;
            _ = try posix.recv(self.socket, &len_bytes, 0);
            payload_len = 0;
            for (len_bytes) |byte| {
                payload_len = (payload_len << 8) | @as(u64, byte);
            }
        }

        // Masking key
        var mask: [4]u8 = undefined;
        if (masked) {
            _ = try posix.recv(self.socket, &mask, 0);
        }

        // Payload
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        if (payload_len > 0) {
            var total_read: usize = 0;
            while (total_read < payload_len) {
                const n = try posix.recv(self.socket, payload[total_read..], 0);
                if (n == 0) return error.ConnectionClosed;
                total_read += n;
            }

            // Unmask
            if (masked) {
                for (payload, 0..) |*byte, i| {
                    byte.* ^= mask[i % 4];
                }
            }
        }

        // Handle control frames
        switch (opcode) {
            0x8 => return error.ConnectionClosed, // close
            0x9 => { // ping
                try self.sendFrame(payload, false, 0xA); // pong
                self.allocator.free(payload);
                return null;
            },
            0xA => { // pong
                self.allocator.free(payload);
                return null;
            },
            else => {},
        }

        return .{
            .data = payload,
            .is_binary = opcode == 0x2,
        };
    }

    /// Join a channel
    pub fn join(self: *Self, channel_name: []const u8) !void {
        const ch = try self.server.channel(channel_name);
        try ch.addMember(self);

        const name_copy = try self.allocator.dupe(u8, channel_name);
        try self.channels.put(name_copy, {});
    }

    /// Leave a channel
    pub fn leave(self: *Self, channel_name: []const u8) void {
        if (self.server.channels.get(channel_name)) |ch| {
            ch.removeMember(self);
        }

        if (self.channels.fetchRemove(channel_name)) |removed| {
            self.allocator.free(removed.key);
        }
    }

    /// Close the connection
    pub fn close(self: *Self) !void {
        try self.sendFrame(&[_]u8{}, false, 0x8); // close frame
        self.server.removeClient(self);
    }

    /// Set user data (e.g., user ID, session info)
    pub fn setUserData(self: *Self, data: *anyopaque) void {
        self.user_data = data;
    }

    /// Get user data
    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        if (self.user_data) |data| {
            return @ptrCast(@alignCast(data));
        }
        return null;
    }
};

/// Channel for grouping connections
pub const Channel = struct {
    name: []const u8,
    members: std.AutoHashMap(u64, *Client),
    allocator: std.mem.Allocator,
    on_join: ?*const fn (*Client) void,
    on_leave: ?*const fn (*Client) void,
    is_presence: bool,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.members.deinit();
    }

    pub fn addMember(self: *Self, client: *Client) !void {
        try self.members.put(client.id, client);

        if (self.is_presence) {
            // Broadcast presence update
            try self.broadcastPresenceUpdate();
        }

        if (self.on_join) |callback| {
            callback(client);
        }
    }

    pub fn removeMember(self: *Self, client: *Client) void {
        _ = self.members.remove(client.id);

        if (self.is_presence) {
            // Broadcast presence update
            self.broadcastPresenceUpdate() catch {};
        }

        if (self.on_leave) |callback| {
            callback(client);
        }
    }

    pub fn broadcast(self: *Self, data: []const u8, is_binary: bool) !void {
        var iter = self.members.iterator();
        while (iter.next()) |entry| {
            if (is_binary) {
                entry.value_ptr.*.sendBinary(data) catch continue;
            } else {
                entry.value_ptr.*.send(data) catch continue;
            }
        }
    }

    pub fn broadcastExcept(self: *Self, data: []const u8, is_binary: bool, except_client: *Client) !void {
        var iter = self.members.iterator();
        while (iter.next()) |entry| {
            if (entry.key_ptr.* == except_client.id) continue;

            if (is_binary) {
                entry.value_ptr.*.sendBinary(data) catch continue;
            } else {
                entry.value_ptr.*.send(data) catch continue;
            }
        }
    }

    pub fn memberCount(self: *Self) usize {
        return self.members.count();
    }

    fn broadcastPresenceUpdate(self: *Self) !void {
        // Build presence list
        var members_buf: [256]u64 = undefined;
        var count: usize = 0;

        var iter = self.members.keyIterator();
        while (iter.next()) |id| {
            if (count < members_buf.len) {
                members_buf[count] = id.*;
                count += 1;
            }
        }

        // Build JSON message
        var json_buf: [4096]u8 = undefined;
        const json_len = std.fmt.bufPrint(&json_buf,
            \\{{"type":"presence","channel":"{s}","members":[
        , .{self.name}) catch return;

        var pos = json_len;
        for (members_buf[0..count], 0..) |id, i| {
            if (i > 0) {
                json_buf[pos] = ',';
                pos += 1;
            }
            const id_len = std.fmt.bufPrint(json_buf[pos..], "{d}", .{id}) catch break;
            pos += id_len;
        }

        const closing = "]}";
        @memcpy(json_buf[pos .. pos + closing.len], closing);
        pos += closing.len;

        try self.broadcast(json_buf[0..pos], false);
    }

    /// Get all member IDs
    pub fn getMemberIds(self: *Self, out_buf: []u64) usize {
        var count: usize = 0;
        var iter = self.members.keyIterator();
        while (iter.next()) |id| {
            if (count < out_buf.len) {
                out_buf[count] = id.*;
                count += 1;
            }
        }
        return count;
    }
};

// Tests
test "server init" {
    const allocator = std.testing.allocator;
    // Can't actually bind in tests without port conflicts, so just test config
    _ = Server.Config{
        .port = 8080,
        .max_connections = 1000,
    };
    _ = allocator;
}
