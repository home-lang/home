// Secure remote logging (TLS)

const std = @import("std");
const syslog = @import("syslog.zig");
const auth = @import("auth.zig");

/// Remote syslog server configuration
pub const RemoteConfig = struct {
    host: []const u8,
    port: u16 = 6514, // RFC 5425 (syslog over TLS)
    use_tls: bool = true,
    verify_cert: bool = true,
    timeout_ms: u32 = 5000,
};

/// Remote connection status
pub const ConnectionStatus = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

/// Remote syslog client
pub const RemoteClient = struct {
    config: RemoteConfig,
    status: std.atomic.Value(ConnectionStatus),
    auth_key: ?auth.AuthKey,
    sequence: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: RemoteConfig) RemoteClient {
        return .{
            .config = config,
            .status = std.atomic.Value(ConnectionStatus).init(.disconnected),
            .auth_key = null,
            .sequence = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    pub fn setAuthKey(self: *RemoteClient, key: auth.AuthKey) void {
        self.auth_key = key;
    }

    pub fn connect(self: *RemoteClient) !void {
        self.status.store(.connecting, .release);

        // In production, would establish TLS connection
        // For now, simulate connection
        std.time.sleep(100 * std.time.ns_per_ms);

        self.status.store(.connected, .release);
    }

    pub fn disconnect(self: *RemoteClient) void {
        self.status.store(.disconnected, .release);
    }

    pub fn getStatus(self: *const RemoteClient) ConnectionStatus {
        return self.status.load(.acquire);
    }

    pub fn sendLog(self: *RemoteClient, message: *const syslog.LogMessage) !void {
        if (self.getStatus() != .connected) {
            return error.NotConnected;
        }

        // Format message
        const formatted = try message.formatRFC5424(self.allocator);
        defer self.allocator.free(formatted);

        // If authentication enabled, add HMAC
        if (self.auth_key) |*key| {
            const seq = self.sequence.fetchAdd(1, .monotonic);
            const auth_log = try auth.authenticateLog(message, key, seq);

            // In production, would send authenticated log over TLS
            _ = auth_log;
        }
        // In production, would send formatted message over TLS
    }

    pub fn sendBatch(self: *RemoteClient, messages: []const syslog.LogMessage) !void {
        for (messages) |*msg| {
            try self.sendLog(msg);
        }
    }
};

/// Remote server (receiver)
pub const RemoteServer = struct {
    config: RemoteConfig,
    auth_key: ?auth.AuthKey,
    received_count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: RemoteConfig) RemoteServer {
        return .{
            .config = config,
            .auth_key = null,
            .received_count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    pub fn setAuthKey(self: *RemoteServer, key: auth.AuthKey) void {
        self.auth_key = key;
    }

    pub fn start(self: *RemoteServer) !void {
        // In production, would start TLS server
        _ = self;
    }

    pub fn stop(self: *RemoteServer) void {
        // In production, would stop server
        _ = self;
    }

    pub fn getReceivedCount(self: *const RemoteServer) u64 {
        return self.received_count.load(.acquire);
    }
};

/// Log forwarding with retry
pub const LogForwarder = struct {
    client: RemoteClient,
    retry_queue: std.ArrayList(syslog.LogMessage),
    max_queue_size: usize,
    retry_attempts: u32,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: RemoteConfig, max_queue: usize) LogForwarder {
        return .{
            .client = RemoteClient.init(allocator, config),
            .retry_queue = std.ArrayList(syslog.LogMessage){},
            .max_queue_size = max_queue,
            .retry_attempts = 3,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *LogForwarder) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.retry_queue.items) |*msg| {
            msg.deinit();
        }
        self.retry_queue.deinit(self.allocator);
    }

    pub fn forwardLog(self: *LogForwarder, message: *const syslog.LogMessage) !void {
        var attempts: u32 = 0;
        while (attempts < self.retry_attempts) : (attempts += 1) {
            self.client.sendLog(message) catch |err| {
                if (attempts + 1 >= self.retry_attempts) {
                    // Queue for later retry
                    try self.queueMessage(message);
                    return err;
                }
                // Retry after delay
                std.time.sleep(100 * std.time.ns_per_ms * (attempts + 1));
                continue;
            };
            return;
        }
    }

    fn queueMessage(self: *LogForwarder, message: *const syslog.LogMessage) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.retry_queue.items.len >= self.max_queue_size) {
            // Drop oldest message
            var oldest = self.retry_queue.orderedRemove(0);
            oldest.deinit();
        }

        // Duplicate message for queue
        const msg_copy = try syslog.LogMessage.init(
            self.allocator,
            message.facility,
            message.severity,
            message.getHostname(),
            message.getAppName(),
            message.process_id,
            message.message,
        );

        try self.retry_queue.append(self.allocator, msg_copy);
    }

    pub fn retryQueued(self: *LogForwarder) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var sent: usize = 0;
        var i: usize = 0;

        while (i < self.retry_queue.items.len) {
            const msg = &self.retry_queue.items[i];

            self.client.sendLog(msg) catch {
                // Keep in queue
                i += 1;
                continue;
            };

            // Successfully sent
            var removed = self.retry_queue.orderedRemove(i);
            removed.deinit();
            sent += 1;
        }

        return sent;
    }

    pub fn getQueueSize(self: *LogForwarder) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.retry_queue.items.len;
    }
};

test "remote client connection" {
    const testing = std.testing;

    var client = RemoteClient.init(testing.allocator, .{
        .host = "log.example.com",
        .port = 6514,
    });

    try testing.expectEqual(ConnectionStatus.disconnected, client.getStatus());

    try client.connect();
    try testing.expectEqual(ConnectionStatus.connected, client.getStatus());

    client.disconnect();
    try testing.expectEqual(ConnectionStatus.disconnected, client.getStatus());
}

test "log forwarding" {
    const testing = std.testing;

    var forwarder = LogForwarder.init(testing.allocator, .{
        .host = "log.example.com",
    }, 100);
    defer forwarder.deinit();

    try forwarder.client.connect();

    var msg = try syslog.LogMessage.init(
        testing.allocator,
        .user,
        .info,
        "localhost",
        "test",
        1,
        "Test message",
    );
    defer msg.deinit();

    // Should succeed when connected
    try forwarder.forwardLog(&msg);
}
