const std = @import("std");
const posix = std.posix;

/// Helper to get current timestamp (Zig 0.16 compatible)
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// Realtime driver types
pub const RealtimeDriverType = enum {
    pusher,
    socket_io,
    websocket, // Native WebSocket
    memory, // For testing
};

/// Channel types for different access levels
pub const ChannelType = enum {
    public, // Anyone can subscribe
    private, // Requires authentication
    presence, // Like private but tracks who's subscribed
};

/// Connection state
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    reconnecting,
    failed,
};

/// Presence member info
pub const PresenceMember = struct {
    user_id: []const u8,
    user_info: ?std.StringHashMap([]const u8),
    joined_at: i64,
};

/// Broadcast message structure
pub const BroadcastMessage = struct {
    channel: []const u8,
    event: []const u8,
    data: []const u8, // JSON payload
    channel_type: ChannelType = .public,
    except_socket_id: ?[]const u8 = null, // Exclude sender
    timestamp: i64,

    pub fn init(channel: []const u8, event: []const u8, data: []const u8) BroadcastMessage {
        return .{
            .channel = channel,
            .event = event,
            .data = data,
            .channel_type = .public,
            .except_socket_id = null,
            .timestamp = getTimestamp(),
        };
    }

    pub fn toPrivate(self: BroadcastMessage) BroadcastMessage {
        var msg = self;
        msg.channel_type = .private;
        return msg;
    }

    pub fn toPresence(self: BroadcastMessage) BroadcastMessage {
        var msg = self;
        msg.channel_type = .presence;
        return msg;
    }

    pub fn excludeSocket(self: BroadcastMessage, socket_id: []const u8) BroadcastMessage {
        var msg = self;
        msg.except_socket_id = socket_id;
        return msg;
    }
};

/// Subscription callback type
pub const SubscriptionCallback = *const fn (event: []const u8, data: []const u8) void;

/// Realtime configuration
pub const RealtimeConfig = struct {
    driver_type: RealtimeDriverType,

    // Pusher config
    pusher_app_id: ?[]const u8 = null,
    pusher_key: ?[]const u8 = null,
    pusher_secret: ?[]const u8 = null,
    pusher_cluster: ?[]const u8 = null,
    pusher_use_tls: bool = true,

    // Socket.IO config
    socket_io_path: ?[]const u8 = null,
    socket_io_port: u16 = 3000,

    // WebSocket config
    ws_host: ?[]const u8 = null,
    ws_port: u16 = 8080,
    ws_path: ?[]const u8 = null,
    ws_use_tls: bool = false,

    // General config
    reconnect: bool = true,
    reconnect_delay_ms: u64 = 1000,
    max_reconnect_attempts: u32 = 10,
    ping_interval_ms: u64 = 30000,

    pub fn pusher(app_id: []const u8, key: []const u8, secret: []const u8, cluster: []const u8) RealtimeConfig {
        return .{
            .driver_type = .pusher,
            .pusher_app_id = app_id,
            .pusher_key = key,
            .pusher_secret = secret,
            .pusher_cluster = cluster,
        };
    }

    pub fn socketIo(port: u16) RealtimeConfig {
        return .{
            .driver_type = .socket_io,
            .socket_io_port = port,
        };
    }

    pub fn websocket(host: []const u8, port: u16) RealtimeConfig {
        return .{
            .driver_type = .websocket,
            .ws_host = host,
            .ws_port = port,
        };
    }

    pub fn memory() RealtimeConfig {
        return .{
            .driver_type = .memory,
        };
    }
};

/// Realtime driver interface
pub const RealtimeDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        connect: *const fn (ptr: *anyopaque) anyerror!void,
        disconnect: *const fn (ptr: *anyopaque) void,
        isConnected: *const fn (ptr: *anyopaque) bool,
        subscribe: *const fn (ptr: *anyopaque, channel: []const u8, callback: SubscriptionCallback) anyerror!void,
        unsubscribe: *const fn (ptr: *anyopaque, channel: []const u8) void,
        broadcast: *const fn (ptr: *anyopaque, message: BroadcastMessage) anyerror!void,
        getSubscribers: *const fn (ptr: *anyopaque, channel: []const u8) []const []const u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn connect(self: *RealtimeDriver) !void {
        return self.vtable.connect(self.ptr);
    }

    pub fn disconnect(self: *RealtimeDriver) void {
        self.vtable.disconnect(self.ptr);
    }

    pub fn isConnected(self: *RealtimeDriver) bool {
        return self.vtable.isConnected(self.ptr);
    }

    pub fn subscribe(self: *RealtimeDriver, channel: []const u8, callback: SubscriptionCallback) !void {
        return self.vtable.subscribe(self.ptr, channel, callback);
    }

    pub fn unsubscribe(self: *RealtimeDriver, channel: []const u8) void {
        self.vtable.unsubscribe(self.ptr, channel);
    }

    pub fn broadcast(self: *RealtimeDriver, message: BroadcastMessage) !void {
        return self.vtable.broadcast(self.ptr, message);
    }

    pub fn getSubscribers(self: *RealtimeDriver, channel: []const u8) []const []const u8 {
        return self.vtable.getSubscribers(self.ptr, channel);
    }

    pub fn deinit(self: *RealtimeDriver) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Pusher driver implementation
pub const PusherDriver = struct {
    allocator: std.mem.Allocator,
    config: RealtimeConfig,
    state: ConnectionState,
    subscriptions: std.StringHashMap(SubscriptionCallback),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: RealtimeConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .state = .disconnected,
            .subscriptions = std.StringHashMap(SubscriptionCallback).init(allocator),
            .mutex = .{},
        };
        return self;
    }

    pub fn driver(self: *Self) RealtimeDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .connect = connect,
                .disconnect = disconnect,
                .isConnected = isConnected,
                .subscribe = subscribe,
                .unsubscribe = unsubscribe,
                .broadcast = broadcast,
                .getSubscribers = getSubscribers,
                .deinit = deinit,
            },
        };
    }

    fn connect(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .connecting;
        // In real implementation: WebSocket connection to Pusher
        // wss://ws-{cluster}.pusher.com/app/{key}
        self.state = .connected;
    }

    fn disconnect(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .disconnected;
    }

    fn isConnected(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.state == .connected;
    }

    fn subscribe(ptr: *anyopaque, channel: []const u8, callback: SubscriptionCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const channel_copy = try self.allocator.dupe(u8, channel);
        try self.subscriptions.put(channel_copy, callback);

        // In real implementation: Send subscribe message
        // {"event": "pusher:subscribe", "data": {"channel": channel}}
    }

    fn unsubscribe(ptr: *anyopaque, channel: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.subscriptions.fetchRemove(channel)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn broadcast(ptr: *anyopaque, message: BroadcastMessage) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = message;
        // POST https://api-{cluster}.pusher.com/apps/{app_id}/events
        // with authentication headers
    }

    fn getSubscribers(ptr: *anyopaque, channel: []const u8) []const []const u8 {
        _ = ptr;
        _ = channel;
        return &[_][]const u8{};
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit();
        self.allocator.destroy(self);
    }
};

/// Socket.IO driver implementation
pub const SocketIODriver = struct {
    allocator: std.mem.Allocator,
    config: RealtimeConfig,
    state: ConnectionState,
    subscriptions: std.StringHashMap(SubscriptionCallback),
    rooms: std.StringHashMap(std.ArrayList([]const u8)),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: RealtimeConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .state = .disconnected,
            .subscriptions = std.StringHashMap(SubscriptionCallback).init(allocator),
            .rooms = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .mutex = .{},
        };
        return self;
    }

    pub fn driver(self: *Self) RealtimeDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .connect = connect,
                .disconnect = disconnect,
                .isConnected = isConnected,
                .subscribe = subscribe,
                .unsubscribe = unsubscribe,
                .broadcast = broadcast,
                .getSubscribers = getSubscribers,
                .deinit = deinit,
            },
        };
    }

    fn connect(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .connecting;
        // Socket.IO handshake would happen here
        self.state = .connected;
    }

    fn disconnect(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.state = .disconnected;
    }

    fn isConnected(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.state == .connected;
    }

    fn subscribe(ptr: *anyopaque, channel: []const u8, callback: SubscriptionCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const channel_copy = try self.allocator.dupe(u8, channel);
        try self.subscriptions.put(channel_copy, callback);
    }

    fn unsubscribe(ptr: *anyopaque, channel: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.subscriptions.fetchRemove(channel)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn broadcast(ptr: *anyopaque, message: BroadcastMessage) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        // Emit to room (channel)
        if (self.subscriptions.get(message.channel)) |callback| {
            callback(message.event, message.data);
        }
    }

    fn getSubscribers(ptr: *anyopaque, channel: []const u8) []const []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.rooms.get(channel)) |members| {
            return members.items;
        }
        return &[_][]const u8{};
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var sub_it = self.subscriptions.iterator();
        while (sub_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit();

        var room_it = self.rooms.iterator();
        while (room_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.rooms.deinit();

        self.allocator.destroy(self);
    }
};

/// Memory driver for testing
pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    config: RealtimeConfig,
    state: ConnectionState,
    subscriptions: std.StringHashMap(SubscriptionCallback),
    messages: std.ArrayList(BroadcastMessage),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: RealtimeConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .state = .disconnected,
            .subscriptions = std.StringHashMap(SubscriptionCallback).init(allocator),
            .messages = .empty,
            .mutex = .{},
        };
        return self;
    }

    pub fn driver(self: *Self) RealtimeDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .connect = connect,
                .disconnect = disconnect,
                .isConnected = isConnected,
                .subscribe = subscribe,
                .unsubscribe = unsubscribe,
                .broadcast = broadcast,
                .getSubscribers = getSubscribers,
                .deinit = deinit,
            },
        };
    }

    fn connect(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.state = .connected;
    }

    fn disconnect(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.state = .disconnected;
    }

    fn isConnected(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.state == .connected;
    }

    fn subscribe(ptr: *anyopaque, channel: []const u8, callback: SubscriptionCallback) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const channel_copy = try self.allocator.dupe(u8, channel);
        try self.subscriptions.put(channel_copy, callback);
    }

    fn unsubscribe(ptr: *anyopaque, channel: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.subscriptions.fetchRemove(channel)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn broadcast(ptr: *anyopaque, message: BroadcastMessage) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.messages.append(self.allocator, message);

        // Deliver to subscribers
        if (self.subscriptions.get(message.channel)) |callback| {
            callback(message.event, message.data);
        }
    }

    fn getSubscribers(ptr: *anyopaque, channel: []const u8) []const []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = channel;
        // Return channel names as "subscribers" for testing
        var result: std.ArrayList([]const u8) = .empty;
        var it = self.subscriptions.keyIterator();
        while (it.next()) |key| {
            result.append(self.allocator, key.*) catch continue;
        }
        return result.toOwnedSlice(self.allocator) catch &[_][]const u8{};
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit();
        self.messages.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Get all broadcast messages (for testing)
    pub fn getMessages(self: *Self) []const BroadcastMessage {
        return self.messages.items;
    }

    /// Clear messages (for testing)
    pub fn clearMessages(self: *Self) void {
        self.messages.clearRetainingCapacity();
    }
};

/// Broadcast manager - high-level API
pub const Broadcast = struct {
    allocator: std.mem.Allocator,
    config: RealtimeConfig,
    driver: RealtimeDriver,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: RealtimeConfig) !Self {
        const driver_instance = switch (config.driver_type) {
            .pusher => blk: {
                const pusher = try PusherDriver.init(allocator, config);
                break :blk pusher.driver();
            },
            .socket_io => blk: {
                const socket_io = try SocketIODriver.init(allocator, config);
                break :blk socket_io.driver();
            },
            .websocket => blk: {
                // Use Socket.IO driver as base for native WebSocket
                const ws = try SocketIODriver.init(allocator, config);
                break :blk ws.driver();
            },
            .memory => blk: {
                const mem = try MemoryDriver.init(allocator, config);
                break :blk mem.driver();
            },
        };

        return .{
            .allocator = allocator,
            .config = config,
            .driver = driver_instance,
        };
    }

    pub fn deinit(self: *Self) void {
        self.driver.deinit();
    }

    /// Connect to the realtime server
    pub fn connect(self: *Self) !void {
        return self.driver.connect();
    }

    /// Disconnect from the server
    pub fn disconnect(self: *Self) void {
        self.driver.disconnect();
    }

    /// Check if connected
    pub fn isConnected(self: *Self) bool {
        return self.driver.isConnected();
    }

    /// Subscribe to a channel
    pub fn subscribe(self: *Self, channel: []const u8, callback: SubscriptionCallback) !void {
        return self.driver.subscribe(channel, callback);
    }

    /// Unsubscribe from a channel
    pub fn unsubscribe(self: *Self, channel: []const u8) void {
        self.driver.unsubscribe(channel);
    }

    /// Broadcast to a public channel
    pub fn toChannel(self: *Self, channel: []const u8, event: []const u8, data: []const u8) !void {
        const message = BroadcastMessage.init(channel, event, data);
        return self.driver.broadcast(message);
    }

    /// Broadcast to a private channel
    pub fn toPrivateChannel(self: *Self, channel: []const u8, event: []const u8, data: []const u8) !void {
        const message = BroadcastMessage.init(channel, event, data).toPrivate();
        return self.driver.broadcast(message);
    }

    /// Broadcast to a presence channel
    pub fn toPresenceChannel(self: *Self, channel: []const u8, event: []const u8, data: []const u8) !void {
        const message = BroadcastMessage.init(channel, event, data).toPresence();
        return self.driver.broadcast(message);
    }

    /// Broadcast to multiple channels
    pub fn toChannels(self: *Self, channels: []const []const u8, event: []const u8, data: []const u8) !void {
        for (channels) |channel| {
            try self.toChannel(channel, event, data);
        }
    }

    /// Broadcast to all except specific socket
    pub fn toOthers(self: *Self, channel: []const u8, event: []const u8, data: []const u8, socket_id: []const u8) !void {
        const message = BroadcastMessage.init(channel, event, data).excludeSocket(socket_id);
        return self.driver.broadcast(message);
    }

    /// Get channel subscribers
    pub fn getSubscribers(self: *Self, channel: []const u8) []const []const u8 {
        return self.driver.getSubscribers(channel);
    }
};

/// Channel builder for fluent API
pub const Channel = struct {
    broadcast: *Broadcast,
    name: []const u8,
    channel_type: ChannelType,

    const Self = @This();

    pub fn init(b: *Broadcast, name: []const u8) Self {
        return .{
            .broadcast = b,
            .name = name,
            .channel_type = .public,
        };
    }

    pub fn asPrivate(self: *Self) *Self {
        self.channel_type = .private;
        return self;
    }

    pub fn asPresence(self: *Self) *Self {
        self.channel_type = .presence;
        return self;
    }

    pub fn emit(self: *Self, event: []const u8, data: []const u8) !void {
        const message = BroadcastMessage{
            .channel = self.name,
            .event = event,
            .data = data,
            .channel_type = self.channel_type,
            .except_socket_id = null,
            .timestamp = getTimestamp(),
        };
        return self.broadcast.driver.broadcast(message);
    }

    pub fn listen(self: *Self, callback: SubscriptionCallback) !void {
        return self.broadcast.driver.subscribe(self.name, callback);
    }

    pub fn stopListening(self: *Self) void {
        self.broadcast.driver.unsubscribe(self.name);
    }
};

// Tests
test "broadcast basic operations" {
    const allocator = std.testing.allocator;
    var broadcast = try Broadcast.init(allocator, RealtimeConfig.memory());
    defer broadcast.deinit();

    try broadcast.connect();
    try std.testing.expect(broadcast.isConnected());

    var received_event: []const u8 = "";
    var received_data: []const u8 = "";

    const callback = struct {
        fn cb(event: []const u8, data: []const u8) void {
            _ = event;
            _ = data;
            // In real test, we'd capture these
        }
    }.cb;

    try broadcast.subscribe("test-channel", callback);
    try broadcast.toChannel("test-channel", "message", "{\"text\": \"hello\"}");

    _ = received_event;
    _ = received_data;

    broadcast.unsubscribe("test-channel");
    broadcast.disconnect();
    try std.testing.expect(!broadcast.isConnected());
}

test "channel types" {
    const msg = BroadcastMessage.init("channel", "event", "data");
    try std.testing.expect(msg.channel_type == .public);

    const private = msg.toPrivate();
    try std.testing.expect(private.channel_type == .private);

    const presence = msg.toPresence();
    try std.testing.expect(presence.channel_type == .presence);
}

test "broadcast config" {
    const pusher_config = RealtimeConfig.pusher("app123", "key123", "secret123", "us2");
    try std.testing.expect(pusher_config.driver_type == .pusher);
    try std.testing.expectEqualStrings("app123", pusher_config.pusher_app_id.?);

    const socket_io_config = RealtimeConfig.socketIo(3000);
    try std.testing.expect(socket_io_config.driver_type == .socket_io);
    try std.testing.expectEqual(@as(u16, 3000), socket_io_config.socket_io_port);
}
