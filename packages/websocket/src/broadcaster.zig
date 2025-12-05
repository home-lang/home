const std = @import("std");
const server = @import("server.zig");

/// Event broadcaster (like Laravel Echo/Pusher)
pub const Broadcaster = struct {
    allocator: std.mem.Allocator,
    ws_server: *server.Server,
    private_channel_auth: ?*const fn (*server.Client, []const u8) bool,
    presence_channel_auth: ?*const fn (*server.Client, []const u8) ?PresenceInfo,

    const Self = @This();

    pub const PresenceInfo = struct {
        user_id: u64,
        user_info: ?[]const u8, // JSON string with user info
    };

    pub fn init(allocator: std.mem.Allocator, ws_server: *server.Server) *Self {
        const self = allocator.create(Self) catch unreachable;
        self.* = .{
            .allocator = allocator,
            .ws_server = ws_server,
            .private_channel_auth = null,
            .presence_channel_auth = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Set authorization callback for private channels
    pub fn setPrivateChannelAuth(self: *Self, auth_fn: *const fn (*server.Client, []const u8) bool) void {
        self.private_channel_auth = auth_fn;
    }

    /// Set authorization callback for presence channels
    pub fn setPresenceChannelAuth(self: *Self, auth_fn: *const fn (*server.Client, []const u8) ?PresenceInfo) void {
        self.presence_channel_auth = auth_fn;
    }

    /// Broadcast an event to a public channel
    pub fn broadcast(self: *Self, channel_name: []const u8, event_name: []const u8, data: []const u8) !void {
        var msg_buf: [8192]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf,
            \\{{"event":"{s}","channel":"{s}","data":{s}}}
        , .{ event_name, channel_name, data });

        try self.ws_server.broadcastToChannel(channel_name, msg, false);
    }

    /// Broadcast to a private channel (requires auth)
    pub fn broadcastToPrivate(self: *Self, channel_name: []const u8, event_name: []const u8, data: []const u8) !void {
        // Private channels are prefixed with "private-"
        var private_name_buf: [256]u8 = undefined;
        const private_name = try std.fmt.bufPrint(&private_name_buf, "private-{s}", .{channel_name});

        var msg_buf: [8192]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf,
            \\{{"event":"{s}","channel":"{s}","data":{s}}}
        , .{ event_name, private_name, data });

        try self.ws_server.broadcastToChannel(private_name, msg, false);
    }

    /// Broadcast to a presence channel
    pub fn broadcastToPresence(self: *Self, channel_name: []const u8, event_name: []const u8, data: []const u8) !void {
        // Presence channels are prefixed with "presence-"
        var presence_name_buf: [256]u8 = undefined;
        const presence_name = try std.fmt.bufPrint(&presence_name_buf, "presence-{s}", .{channel_name});

        var msg_buf: [8192]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf,
            \\{{"event":"{s}","channel":"{s}","data":{s}}}
        , .{ event_name, presence_name, data });

        try self.ws_server.broadcastToChannel(presence_name, msg, false);
    }

    /// Broadcast to specific users (by user_data pointer containing user IDs)
    pub fn broadcastToUsers(self: *Self, user_ids: []const u64, event_name: []const u8, data: []const u8) !void {
        var msg_buf: [8192]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf,
            \\{{"event":"{s}","data":{s}}}
        , .{ event_name, data });

        var client_iter = self.ws_server.clients.iterator();
        while (client_iter.next()) |entry| {
            const client = entry.value_ptr.*;
            if (client.user_data) |user_data| {
                const user_id_ptr: *const u64 = @ptrCast(@alignCast(user_data));
                for (user_ids) |target_id| {
                    if (user_id_ptr.* == target_id) {
                        client.send(msg) catch continue;
                        break;
                    }
                }
            }
        }
    }

    /// Handle client message (for subscribing to channels, etc.)
    pub fn handleClientMessage(self: *Self, client: *server.Client, message: server.Server.Message) !void {
        if (message.is_binary) return; // Only handle text messages

        // Try to parse as JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, message.data, .{}) catch return;
        defer parsed.deinit();

        const event = parsed.value.object.get("event") orelse return;
        if (event != .string) return;

        if (std.mem.eql(u8, event.string, "pusher:subscribe")) {
            try self.handleSubscribe(client, parsed.value);
        } else if (std.mem.eql(u8, event.string, "pusher:unsubscribe")) {
            try self.handleUnsubscribe(client, parsed.value);
        } else if (std.mem.eql(u8, event.string, "client-")) {
            // Client events (whispers)
            try self.handleClientEvent(client, parsed.value);
        }
    }

    fn handleSubscribe(self: *Self, client: *server.Client, msg: std.json.Value) !void {
        const data = msg.object.get("data") orelse return;
        if (data != .object) return;

        const channel_name_val = data.object.get("channel") orelse return;
        if (channel_name_val != .string) return;
        const channel_name = channel_name_val.string;

        // Check if private channel
        if (std.mem.startsWith(u8, channel_name, "private-")) {
            if (self.private_channel_auth) |auth_fn| {
                if (!auth_fn(client, channel_name)) {
                    try self.sendError(client, "Subscription failed: unauthorized");
                    return;
                }
            }
        }

        // Check if presence channel
        if (std.mem.startsWith(u8, channel_name, "presence-")) {
            if (self.presence_channel_auth) |auth_fn| {
                if (auth_fn(client, channel_name)) |presence_info| {
                    // Store user info
                    const user_id = try self.allocator.create(u64);
                    user_id.* = presence_info.user_id;
                    client.setUserData(user_id);

                    // Create presence channel
                    const ch = try self.ws_server.presenceChannel(channel_name);
                    try ch.addMember(client);

                    // Mark in client's channel list
                    const name_copy = try self.allocator.dupe(u8, channel_name);
                    try client.channels.put(name_copy, {});
                } else {
                    try self.sendError(client, "Subscription failed: unauthorized");
                    return;
                }
            }
        } else {
            // Regular channel
            try client.join(channel_name);
        }

        // Send subscription confirmation
        var confirm_buf: [512]u8 = undefined;
        const confirm = try std.fmt.bufPrint(&confirm_buf,
            \\{{"event":"pusher_internal:subscription_succeeded","channel":"{s}"}}
        , .{channel_name});
        try client.send(confirm);
    }

    fn handleUnsubscribe(self: *Self, client: *server.Client, msg: std.json.Value) !void {
        _ = self;
        const data = msg.object.get("data") orelse return;
        if (data != .object) return;

        const channel_name_val = data.object.get("channel") orelse return;
        if (channel_name_val != .string) return;

        client.leave(channel_name_val.string);
    }

    fn handleClientEvent(self: *Self, client: *server.Client, msg: std.json.Value) !void {
        const event = msg.object.get("event") orelse return;
        if (event != .string) return;

        // Client events must start with "client-"
        if (!std.mem.startsWith(u8, event.string, "client-")) return;

        const channel_val = msg.object.get("channel") orelse return;
        if (channel_val != .string) return;
        const channel_name = channel_val.string;

        // Client can only send to channels they're subscribed to
        if (!client.channels.contains(channel_name)) return;

        // Get the channel and broadcast to others
        if (self.ws_server.channels.get(channel_name)) |ch| {
            const data = msg.object.get("data");
            var data_str: []const u8 = "{}";
            if (data) |d| {
                // Stringify the data
                var data_buf: [4096]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&data_buf);
                std.json.stringify(d, .{}, fbs.writer()) catch {};
                data_str = fbs.getWritten();
            }

            var msg_buf: [8192]u8 = undefined;
            const full_msg = try std.fmt.bufPrint(&msg_buf,
                \\{{"event":"{s}","channel":"{s}","data":{s}}}
            , .{ event.string, channel_name, data_str });

            try ch.broadcastExcept(full_msg, false, client);
        }
    }

    fn sendError(self: *Self, client: *server.Client, message: []const u8) !void {
        _ = self;
        var buf: [512]u8 = undefined;
        const err_msg = try std.fmt.bufPrint(&buf,
            \\{{"event":"pusher:error","data":{{"message":"{s}"}}}}
        , .{message});
        try client.send(err_msg);
    }
};

/// Event helper for creating broadcast events
pub const Event = struct {
    name: []const u8,
    data: []const u8,

    pub fn init(name: []const u8, data: []const u8) Event {
        return .{ .name = name, .data = data };
    }

    /// Create JSON payload from struct
    pub fn fromStruct(allocator: std.mem.Allocator, name: []const u8, value: anytype) !Event {
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try std.json.stringify(value, .{}, fbs.writer());

        return Event{
            .name = name,
            .data = try allocator.dupe(u8, fbs.getWritten()),
        };
    }
};

// Tests
test "broadcaster event creation" {
    const allocator = std.testing.allocator;

    const TestData = struct {
        message: []const u8,
        count: u32,
    };

    const event = try Event.fromStruct(allocator, "test-event", TestData{
        .message = "Hello",
        .count = 42,
    });
    defer allocator.free(event.data);

    try std.testing.expectEqualStrings("test-event", event.name);
    try std.testing.expect(event.data.len > 0);
}
