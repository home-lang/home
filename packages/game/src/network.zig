// Home Game Development Framework - Multiplayer Networking
// Client/server architecture with state synchronization

const std = @import("std");

// ============================================================================
// Zig 0.16 Compatibility - Time Helper
// ============================================================================

/// Get current time in milliseconds (Zig 0.16 compatible)
fn getMilliTimestamp() i64 {
    const instant = std.time.Instant.now() catch return 0;
    return @intCast(@as(i128, instant.timestamp.sec) * 1000 + @divFloor(instant.timestamp.nsec, 1_000_000));
}

// ============================================================================
// Network Message Types
// ============================================================================

pub const MessageType = enum(u8) {
    // Connection
    connect_request,
    connect_accept,
    connect_reject,
    disconnect,
    ping,
    pong,

    // Game state
    state_full,
    state_delta,
    state_ack,

    // Input
    input_command,
    input_batch,

    // Entity
    entity_spawn,
    entity_destroy,
    entity_update,

    // Events
    game_event,
    chat_message,

    // Reliability
    reliable_ack,
    reliable_resend,

    // Custom
    custom,
};

pub const MessageHeader = packed struct {
    message_type: MessageType,
    sequence: u16,
    flags: u8,
    payload_size: u16,
    timestamp: u32,
};

pub const MessageFlags = struct {
    pub const RELIABLE: u8 = 0x01;
    pub const ORDERED: u8 = 0x02;
    pub const COMPRESSED: u8 = 0x04;
    pub const ENCRYPTED: u8 = 0x08;
};

// ============================================================================
// Network Message
// ============================================================================

pub const NetworkMessage = struct {
    header: MessageHeader,
    payload: []const u8,

    pub fn serialize(self: *const NetworkMessage, buffer: []u8) !usize {
        if (buffer.len < @sizeOf(MessageHeader) + self.payload.len) {
            return error.BufferTooSmall;
        }

        const header_bytes = std.mem.asBytes(&self.header);
        @memcpy(buffer[0..@sizeOf(MessageHeader)], header_bytes);
        @memcpy(buffer[@sizeOf(MessageHeader)..][0..self.payload.len], self.payload);

        return @sizeOf(MessageHeader) + self.payload.len;
    }

    pub fn deserialize(data: []const u8) !NetworkMessage {
        if (data.len < @sizeOf(MessageHeader)) {
            return error.InvalidMessage;
        }

        const header: *const MessageHeader = @ptrCast(@alignCast(data[0..@sizeOf(MessageHeader)]));
        const payload_end = @sizeOf(MessageHeader) + header.payload_size;

        if (data.len < payload_end) {
            return error.InvalidMessage;
        }

        return NetworkMessage{
            .header = header.*,
            .payload = data[@sizeOf(MessageHeader)..payload_end],
        };
    }
};

// ============================================================================
// Connection State
// ============================================================================

pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    disconnecting,
};

pub const Connection = struct {
    id: u32,
    state: ConnectionState,
    address: []const u8,
    port: u16,

    // Statistics
    rtt_ms: u32,
    packet_loss: f32,
    bytes_sent: u64,
    bytes_received: u64,

    // Reliability
    local_sequence: u16,
    remote_sequence: u16,
    ack_bits: u32,

    // Timing
    last_send_time: i64,
    last_receive_time: i64,
    timeout_ms: u32,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u32) Connection {
        return Connection{
            .id = id,
            .state = .disconnected,
            .address = "",
            .port = 0,
            .rtt_ms = 0,
            .packet_loss = 0,
            .bytes_sent = 0,
            .bytes_received = 0,
            .local_sequence = 0,
            .remote_sequence = 0,
            .ack_bits = 0,
            .last_send_time = 0,
            .last_receive_time = 0,
            .timeout_ms = 10000,
            .allocator = allocator,
        };
    }

    pub fn isTimedOut(self: *const Connection) bool {
        const now = getMilliTimestamp();
        return (now - self.last_receive_time) > self.timeout_ms;
    }

    pub fn getNextSequence(self: *Connection) u16 {
        const seq = self.local_sequence;
        self.local_sequence +%= 1;
        return seq;
    }

    pub fn processAck(self: *Connection, ack_sequence: u16, ack_bits: u32) void {
        // Update RTT based on acked packets
        _ = ack_sequence;
        self.ack_bits = ack_bits;
    }
};

// ============================================================================
// Network Client
// ============================================================================

pub const NetworkClient = struct {
    allocator: std.mem.Allocator,
    connection: Connection,
    receive_buffer: []u8,
    send_buffer: []u8,
    pending_reliable: std.ArrayList(NetworkMessage),

    // Callbacks
    on_connect: ?*const fn () void,
    on_disconnect: ?*const fn () void,
    on_message: ?*const fn (NetworkMessage) void,

    pub fn init(allocator: std.mem.Allocator) !*NetworkClient {
        const self = try allocator.create(NetworkClient);
        self.* = NetworkClient{
            .allocator = allocator,
            .connection = Connection.init(allocator, 0),
            .receive_buffer = try allocator.alloc(u8, 65536),
            .send_buffer = try allocator.alloc(u8, 65536),
            .pending_reliable = .{},
            .on_connect = null,
            .on_disconnect = null,
            .on_message = null,
        };
        return self;
    }

    pub fn deinit(self: *NetworkClient) void {
        self.allocator.free(self.receive_buffer);
        self.allocator.free(self.send_buffer);
        self.pending_reliable.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn connect(self: *NetworkClient, address: []const u8, port: u16) !void {
        self.connection.address = address;
        self.connection.port = port;
        self.connection.state = .connecting;

        // Send connect request
        try self.sendMessage(.{
            .header = .{
                .message_type = .connect_request,
                .sequence = self.connection.getNextSequence(),
                .flags = MessageFlags.RELIABLE,
                .payload_size = 0,
                .timestamp = @truncate(@as(u64, @intCast(getMilliTimestamp()))),
            },
            .payload = &[_]u8{},
        });
    }

    pub fn disconnect(self: *NetworkClient) void {
        if (self.connection.state == .connected) {
            self.connection.state = .disconnecting;
            // Would send disconnect message
        }
    }

    pub fn sendMessage(self: *NetworkClient, message: NetworkMessage) !void {
        const size = try message.serialize(self.send_buffer);
        self.connection.bytes_sent += size;
        self.connection.last_send_time = getMilliTimestamp();
        // Would actually send via socket here
    }

    pub fn sendReliable(self: *NetworkClient, message: NetworkMessage) !void {
        try self.pending_reliable.append(self.allocator, message);
        try self.sendMessage(message);
    }

    pub fn update(self: *NetworkClient) void {
        // Check for timeout
        if (self.connection.state == .connected and self.connection.isTimedOut()) {
            self.connection.state = .disconnected;
            if (self.on_disconnect) |callback| {
                callback();
            }
        }

        // Resend unacked reliable messages
        // Would implement retransmission logic
    }

    pub fn isConnected(self: *const NetworkClient) bool {
        return self.connection.state == .connected;
    }
};

// ============================================================================
// Network Server
// ============================================================================

pub const NetworkServer = struct {
    allocator: std.mem.Allocator,
    connections: std.AutoHashMap(u32, *Connection),
    max_connections: u32,
    next_client_id: u32,
    port: u16,
    running: bool,

    // Callbacks
    on_client_connect: ?*const fn (u32) void,
    on_client_disconnect: ?*const fn (u32) void,
    on_message: ?*const fn (u32, NetworkMessage) void,

    pub fn init(allocator: std.mem.Allocator, max_connections: u32) !*NetworkServer {
        const self = try allocator.create(NetworkServer);
        self.* = NetworkServer{
            .allocator = allocator,
            .connections = std.AutoHashMap(u32, *Connection).init(allocator),
            .max_connections = max_connections,
            .next_client_id = 1,
            .port = 0,
            .running = false,
            .on_client_connect = null,
            .on_client_disconnect = null,
            .on_message = null,
        };
        return self;
    }

    pub fn deinit(self: *NetworkServer) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *NetworkServer, port: u16) !void {
        self.port = port;
        self.running = true;
        // Would bind socket
    }

    pub fn stop(self: *NetworkServer) void {
        self.running = false;
        // Would close socket and disconnect all clients
    }

    pub fn broadcast(self: *NetworkServer, message: NetworkMessage) !void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            _ = entry;
            // Would send to each connection
            _ = message;
        }
    }

    pub fn sendTo(self: *NetworkServer, client_id: u32, message: NetworkMessage) !void {
        if (self.connections.get(client_id)) |_| {
            // Would send message to specific client
            _ = message;
        }
    }

    pub fn kick(self: *NetworkServer, client_id: u32) void {
        if (self.connections.fetchRemove(client_id)) |entry| {
            self.allocator.destroy(entry.value);
            if (self.on_client_disconnect) |callback| {
                callback(client_id);
            }
        }
    }

    pub fn update(self: *NetworkServer) void {
        // Check for timed out connections
        var to_remove: std.ArrayList(u32) = .{};
        defer to_remove.deinit(self.allocator);

        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.isTimedOut()) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |client_id| {
            self.kick(client_id);
        }
    }

    pub fn getClientCount(self: *const NetworkServer) usize {
        return self.connections.count();
    }

    pub fn isRunning(self: *const NetworkServer) bool {
        return self.running;
    }
};

// ============================================================================
// State Synchronization
// ============================================================================

pub const SyncMode = enum {
    /// Server is authoritative
    server_authoritative,
    /// Client prediction with server reconciliation
    client_prediction,
    /// Peer-to-peer lockstep
    lockstep,
};

pub const NetworkEntity = struct {
    id: u32,
    owner_id: u32, // 0 = server owned
    sync_priority: u8,
    last_update_frame: u64,
    interpolation_delay: u32, // ms

    pub fn shouldSync(self: *const NetworkEntity, current_frame: u64) bool {
        return current_frame >= self.last_update_frame + self.sync_priority;
    }
};

pub const StateSynchronizer = struct {
    allocator: std.mem.Allocator,
    mode: SyncMode,
    entities: std.AutoHashMap(u32, NetworkEntity),
    next_entity_id: u32,
    current_frame: u64,
    interpolation_buffer_size: u32,

    pub fn init(allocator: std.mem.Allocator, mode: SyncMode) !*StateSynchronizer {
        const self = try allocator.create(StateSynchronizer);
        self.* = StateSynchronizer{
            .allocator = allocator,
            .mode = mode,
            .entities = std.AutoHashMap(u32, NetworkEntity).init(allocator),
            .next_entity_id = 1,
            .current_frame = 0,
            .interpolation_buffer_size = 3,
        };
        return self;
    }

    pub fn deinit(self: *StateSynchronizer) void {
        self.entities.deinit();
        self.allocator.destroy(self);
    }

    pub fn registerEntity(self: *StateSynchronizer, owner_id: u32, priority: u8) !u32 {
        const id = self.next_entity_id;
        self.next_entity_id += 1;

        try self.entities.put(id, NetworkEntity{
            .id = id,
            .owner_id = owner_id,
            .sync_priority = priority,
            .last_update_frame = 0,
            .interpolation_delay = 100,
        });

        return id;
    }

    pub fn unregisterEntity(self: *StateSynchronizer, entity_id: u32) void {
        _ = self.entities.remove(entity_id);
    }

    pub fn advanceFrame(self: *StateSynchronizer) void {
        self.current_frame += 1;
    }

    pub fn getEntitiesNeedingSync(self: *StateSynchronizer) ![]u32 {
        var result: std.ArrayList(u32) = .{};
        errdefer result.deinit(self.allocator);

        var iter = self.entities.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.shouldSync(self.current_frame)) {
                try result.append(self.allocator, entry.key_ptr.*);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "NetworkMessage serialization" {
    const payload = [_]u8{ 1, 2, 3, 4 };
    const msg = NetworkMessage{
        .header = .{
            .message_type = .game_event,
            .sequence = 1,
            .flags = 0,
            .payload_size = 4,
            .timestamp = 1000,
        },
        .payload = &payload,
    };

    var buffer: [256]u8 = undefined;
    const size = try msg.serialize(&buffer);
    try std.testing.expect(size > 0);

    const deserialized = try NetworkMessage.deserialize(buffer[0..size]);
    try std.testing.expectEqual(msg.header.message_type, deserialized.header.message_type);
    try std.testing.expectEqual(msg.header.sequence, deserialized.header.sequence);
}

test "Connection" {
    var conn = Connection.init(std.testing.allocator, 1);
    try std.testing.expectEqual(ConnectionState.disconnected, conn.state);

    const seq1 = conn.getNextSequence();
    const seq2 = conn.getNextSequence();
    try std.testing.expect(seq2 == seq1 + 1);
}

test "NetworkClient" {
    var client = try NetworkClient.init(std.testing.allocator);
    defer client.deinit();

    try std.testing.expect(!client.isConnected());
}

test "NetworkServer" {
    var server = try NetworkServer.init(std.testing.allocator, 16);
    defer server.deinit();

    try std.testing.expect(!server.isRunning());
    try std.testing.expectEqual(@as(usize, 0), server.getClientCount());
}

test "StateSynchronizer" {
    var sync = try StateSynchronizer.init(std.testing.allocator, .server_authoritative);
    defer sync.deinit();

    const entity_id = try sync.registerEntity(0, 1);
    try std.testing.expect(entity_id > 0);
}
