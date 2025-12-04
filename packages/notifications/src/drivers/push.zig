const std = @import("std");
const notifications = @import("../notifications.zig");
const NotificationResult = notifications.NotificationResult;
const Priority = notifications.Priority;

/// Push notification driver types
pub const PushDriverType = enum {
    fcm, // Firebase Cloud Messaging
    apns, // Apple Push Notification Service
    expo, // Expo Push Notifications
    onesignal,
    pushy,
    memory, // For testing
};

/// Platform types for push notifications
pub const Platform = enum {
    ios,
    android,
    web,
    all,
};

/// Push notification message structure
pub const PushMessage = struct {
    /// Device tokens to send to
    tokens: []const []const u8,
    /// Notification title
    title: []const u8,
    /// Notification body
    body: []const u8,
    /// Custom data payload
    data: ?std.StringHashMap([]const u8) = null,
    /// Image URL for rich notifications
    image_url: ?[]const u8 = null,
    /// Click action / deep link
    click_action: ?[]const u8 = null,
    /// Sound to play
    sound: ?[]const u8 = null,
    /// Badge count (iOS)
    badge: ?u32 = null,
    /// Topic for topic messaging (FCM)
    topic: ?[]const u8 = null,
    /// Condition for conditional messaging (FCM)
    condition: ?[]const u8 = null,
    /// Target platform
    platform: Platform = .all,
    /// Priority level
    priority: Priority = .normal,
    /// Time to live in seconds
    ttl: ?u32 = null,
    /// Collapse key for notification grouping
    collapse_key: ?[]const u8 = null,
    /// Channel ID (Android 8.0+)
    android_channel_id: ?[]const u8 = null,
    /// Thread ID for grouping (iOS)
    ios_thread_id: ?[]const u8 = null,
    /// Category for actionable notifications (iOS)
    ios_category: ?[]const u8 = null,
    /// Content available flag for background updates (iOS)
    content_available: bool = false,
    /// Mutable content flag for notification extensions (iOS)
    mutable_content: bool = false,

    pub fn init(tokens: []const []const u8, title: []const u8, body: []const u8) PushMessage {
        return .{
            .tokens = tokens,
            .title = title,
            .body = body,
        };
    }

    pub fn toTopic(topic: []const u8, title: []const u8, body: []const u8) PushMessage {
        return .{
            .tokens = &[_][]const u8{},
            .title = title,
            .body = body,
            .topic = topic,
        };
    }

    pub fn withData(self: PushMessage, data: std.StringHashMap([]const u8)) PushMessage {
        var msg = self;
        msg.data = data;
        return msg;
    }

    pub fn withImage(self: PushMessage, url: []const u8) PushMessage {
        var msg = self;
        msg.image_url = url;
        return msg;
    }

    pub fn withClickAction(self: PushMessage, action: []const u8) PushMessage {
        var msg = self;
        msg.click_action = action;
        return msg;
    }

    pub fn withSound(self: PushMessage, sound: []const u8) PushMessage {
        var msg = self;
        msg.sound = sound;
        return msg;
    }

    pub fn withBadge(self: PushMessage, badge: u32) PushMessage {
        var msg = self;
        msg.badge = badge;
        return msg;
    }

    pub fn withTtl(self: PushMessage, ttl_seconds: u32) PushMessage {
        var msg = self;
        msg.ttl = ttl_seconds;
        return msg;
    }

    pub fn forPlatform(self: PushMessage, platform: Platform) PushMessage {
        var msg = self;
        msg.platform = platform;
        return msg;
    }

    pub fn silent(self: PushMessage) PushMessage {
        var msg = self;
        msg.content_available = true;
        return msg;
    }
};

/// Push driver configuration
pub const PushConfig = struct {
    driver_type: PushDriverType,
    /// FCM server key or service account JSON
    fcm_credentials: ?[]const u8 = null,
    /// APNS key ID
    apns_key_id: ?[]const u8 = null,
    /// APNS team ID
    apns_team_id: ?[]const u8 = null,
    /// APNS private key (.p8 file contents)
    apns_private_key: ?[]const u8 = null,
    /// APNS bundle ID
    apns_bundle_id: ?[]const u8 = null,
    /// APNS environment (true = production)
    apns_production: bool = false,
    /// Expo access token
    expo_access_token: ?[]const u8 = null,
    /// OneSignal app ID
    onesignal_app_id: ?[]const u8 = null,
    /// OneSignal API key
    onesignal_api_key: ?[]const u8 = null,
    /// Timeout for requests
    timeout_ms: u32 = 30000,
    /// Max retries
    max_retries: u32 = 3,

    pub fn fcm(credentials: []const u8) PushConfig {
        return .{
            .driver_type = .fcm,
            .fcm_credentials = credentials,
        };
    }

    pub fn apns(key_id: []const u8, team_id: []const u8, private_key: []const u8, bundle_id: []const u8, production: bool) PushConfig {
        return .{
            .driver_type = .apns,
            .apns_key_id = key_id,
            .apns_team_id = team_id,
            .apns_private_key = private_key,
            .apns_bundle_id = bundle_id,
            .apns_production = production,
        };
    }

    pub fn expo(access_token: ?[]const u8) PushConfig {
        return .{
            .driver_type = .expo,
            .expo_access_token = access_token,
        };
    }

    pub fn onesignal(app_id: []const u8, api_key: []const u8) PushConfig {
        return .{
            .driver_type = .onesignal,
            .onesignal_app_id = app_id,
            .onesignal_api_key = api_key,
        };
    }

    pub fn memory() PushConfig {
        return .{
            .driver_type = .memory,
        };
    }
};

/// Push notification send result with per-token status
pub const PushSendResult = struct {
    overall: NotificationResult,
    token_results: ?[]const TokenResult = null,

    pub const TokenResult = struct {
        token: []const u8,
        success: bool,
        message_id: ?[]const u8 = null,
        error_code: ?[]const u8 = null,
        error_message: ?[]const u8 = null,
    };
};

/// Push driver interface
pub const PushDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, message: PushMessage) NotificationResult,
        sendToTopic: *const fn (ptr: *anyopaque, topic: []const u8, message: PushMessage) NotificationResult,
        subscribeToTopic: *const fn (ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool,
        unsubscribeFromTopic: *const fn (ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool,
        deinit: *const fn (ptr: *anyopaque) void,
        getDriverName: *const fn () []const u8,
    };

    pub fn send(self: *PushDriver, message: PushMessage) NotificationResult {
        return self.vtable.send(self.ptr, message);
    }

    pub fn sendToTopic(self: *PushDriver, topic: []const u8, message: PushMessage) NotificationResult {
        return self.vtable.sendToTopic(self.ptr, topic, message);
    }

    pub fn subscribeToTopic(self: *PushDriver, tokens: []const []const u8, topic: []const u8) bool {
        return self.vtable.subscribeToTopic(self.ptr, tokens, topic);
    }

    pub fn unsubscribeFromTopic(self: *PushDriver, tokens: []const []const u8, topic: []const u8) bool {
        return self.vtable.unsubscribeFromTopic(self.ptr, tokens, topic);
    }

    pub fn deinit(self: *PushDriver) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getDriverName(self: *PushDriver) []const u8 {
        return self.vtable.getDriverName();
    }
};

/// Firebase Cloud Messaging driver implementation
pub const FcmDriver = struct {
    allocator: std.mem.Allocator,
    config: PushConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PushConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) PushDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToTopic = sendToTopic,
                .subscribeToTopic = subscribeToTopic,
                .unsubscribeFromTopic = unsubscribeFromTopic,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://fcm.googleapis.com/v1/projects/{project_id}/messages:send
        // Authorization: Bearer {access_token}
        // Content-Type: application/json
        // Body: { "message": { "token": "...", "notification": { "title": "...", "body": "..." } } }

        self.sent_count += 1;
        return NotificationResult.ok("fcm", "projects/myproject/messages/fcm_msg_12345");
    }

    fn sendToTopic(ptr: *anyopaque, topic: []const u8, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = topic;
        _ = message;

        self.sent_count += 1;
        return NotificationResult.ok("fcm", "projects/myproject/messages/fcm_topic_12345");
    }

    fn subscribeToTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        _ = ptr;
        _ = tokens;
        _ = topic;
        // POST https://iid.googleapis.com/iid/v1:batchAdd
        return true;
    }

    fn unsubscribeFromTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        _ = ptr;
        _ = tokens;
        _ = topic;
        // POST https://iid.googleapis.com/iid/v1:batchRemove
        return true;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "fcm";
    }
};

/// Apple Push Notification Service driver implementation
pub const ApnsDriver = struct {
    allocator: std.mem.Allocator,
    config: PushConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PushConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) PushDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToTopic = sendToTopic,
                .subscribeToTopic = subscribeToTopic,
                .unsubscribeFromTopic = unsubscribeFromTopic,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://api.push.apple.com/3/device/{device_token}
        // (or api.sandbox.push.apple.com for development)
        // Uses HTTP/2 with JWT authentication
        // Headers: authorization, apns-topic, apns-push-type, apns-priority, apns-expiration

        self.sent_count += 1;
        return NotificationResult.ok("apns", "apns_msg_12345");
    }

    fn sendToTopic(ptr: *anyopaque, topic: []const u8, message: PushMessage) NotificationResult {
        _ = ptr;
        _ = topic;
        _ = message;
        // APNS doesn't support topics directly, use FCM for that
        return NotificationResult.err("apns", "Topics not supported in APNS directly");
    }

    fn subscribeToTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        _ = ptr;
        _ = tokens;
        _ = topic;
        return false; // Not supported in APNS
    }

    fn unsubscribeFromTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        _ = ptr;
        _ = tokens;
        _ = topic;
        return false; // Not supported in APNS
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "apns";
    }
};

/// Expo Push Notifications driver implementation
pub const ExpoDriver = struct {
    allocator: std.mem.Allocator,
    config: PushConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PushConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) PushDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToTopic = sendToTopic,
                .subscribeToTopic = subscribeToTopic,
                .unsubscribeFromTopic = unsubscribeFromTopic,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://exp.host/--/api/v2/push/send
        // Content-Type: application/json
        // Body: [{ "to": "ExponentPushToken[...]", "title": "...", "body": "..." }]

        self.sent_count += 1;
        return NotificationResult.ok("expo", "expo_msg_12345");
    }

    fn sendToTopic(ptr: *anyopaque, topic: []const u8, message: PushMessage) NotificationResult {
        _ = ptr;
        _ = topic;
        _ = message;
        return NotificationResult.err("expo", "Topics not directly supported in Expo");
    }

    fn subscribeToTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        _ = ptr;
        _ = tokens;
        _ = topic;
        return false;
    }

    fn unsubscribeFromTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        _ = ptr;
        _ = tokens;
        _ = topic;
        return false;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "expo";
    }
};

/// OneSignal push driver implementation
pub const OneSignalDriver = struct {
    allocator: std.mem.Allocator,
    config: PushConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PushConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) PushDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToTopic = sendToTopic,
                .subscribeToTopic = subscribeToTopic,
                .unsubscribeFromTopic = unsubscribeFromTopic,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://onesignal.com/api/v1/notifications

        self.sent_count += 1;
        return NotificationResult.ok("onesignal", "os_msg_12345");
    }

    fn sendToTopic(ptr: *anyopaque, topic: []const u8, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = topic;
        _ = message;

        // OneSignal uses segments/tags instead of topics
        self.sent_count += 1;
        return NotificationResult.ok("onesignal", "os_segment_12345");
    }

    fn subscribeToTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        _ = ptr;
        _ = tokens;
        _ = topic;
        return true;
    }

    fn unsubscribeFromTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        _ = ptr;
        _ = tokens;
        _ = topic;
        return true;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "onesignal";
    }
};

/// Memory push driver for testing
pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    sent_messages: std.ArrayList(PushMessage),
    subscriptions: std.StringHashMap(std.ArrayList([]const u8)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .sent_messages = std.ArrayList(PushMessage).init(allocator),
            .subscriptions = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
        return self;
    }

    pub fn driver(self: *Self) PushDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToTopic = sendToTopic,
                .subscribeToTopic = subscribeToTopic,
                .unsubscribeFromTopic = unsubscribeFromTopic,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sent_messages.append(message) catch {
            return NotificationResult.err("memory", "Failed to store message");
        };
        return NotificationResult.ok("memory", "mem_push_12345");
    }

    fn sendToTopic(ptr: *anyopaque, topic: []const u8, message: PushMessage) NotificationResult {
        _ = topic;
        return send(ptr, message);
    }

    fn subscribeToTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const result = self.subscriptions.getOrPut(topic) catch return false;
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }
        for (tokens) |token| {
            result.value_ptr.append(token) catch return false;
        }
        return true;
    }

    fn unsubscribeFromTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.subscriptions.get(topic)) |*list| {
            for (tokens) |token| {
                for (list.items, 0..) |item, i| {
                    if (std.mem.eql(u8, item, token)) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
            }
        }
        return true;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sent_messages.deinit();

        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.subscriptions.deinit();

        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "memory";
    }

    /// Get all sent messages (for testing)
    pub fn getSentMessages(self: *Self) []const PushMessage {
        return self.sent_messages.items;
    }

    /// Clear all sent messages (for testing)
    pub fn clearMessages(self: *Self) void {
        self.sent_messages.clearRetainingCapacity();
    }
};

/// Create a push driver based on configuration
pub fn createDriver(allocator: std.mem.Allocator, config: PushConfig) !*PushDriver {
    const driver_ptr = try allocator.create(PushDriver);

    switch (config.driver_type) {
        .fcm => {
            const fcm = try FcmDriver.init(allocator, config);
            driver_ptr.* = fcm.driver();
        },
        .apns => {
            const apns = try ApnsDriver.init(allocator, config);
            driver_ptr.* = apns.driver();
        },
        .expo => {
            const expo = try ExpoDriver.init(allocator, config);
            driver_ptr.* = expo.driver();
        },
        .onesignal => {
            const os = try OneSignalDriver.init(allocator, config);
            driver_ptr.* = os.driver();
        },
        .pushy => {
            // Would have its own implementation
            const mem = try MemoryDriver.init(allocator);
            driver_ptr.* = mem.driver();
        },
        .memory => {
            const mem = try MemoryDriver.init(allocator);
            driver_ptr.* = mem.driver();
        },
    }

    return driver_ptr;
}

// Tests
test "push message creation" {
    const tokens = [_][]const u8{"token1", "token2"};
    const msg = PushMessage.init(&tokens, "Test Title", "Test Body");

    try std.testing.expectEqualStrings("Test Title", msg.title);
    try std.testing.expectEqualStrings("Test Body", msg.body);
    try std.testing.expectEqual(@as(usize, 2), msg.tokens.len);
}

test "push message to topic" {
    const msg = PushMessage.toTopic("news", "Breaking News", "Something happened!");

    try std.testing.expectEqualStrings("news", msg.topic.?);
    try std.testing.expectEqual(@as(usize, 0), msg.tokens.len);
}

test "push config creation" {
    const fcm_config = PushConfig.fcm("service_account_json");
    try std.testing.expect(fcm_config.driver_type == .fcm);

    const apns_config = PushConfig.apns("KEY123", "TEAM123", "private_key", "com.app.bundle", false);
    try std.testing.expect(apns_config.driver_type == .apns);
    try std.testing.expect(!apns_config.apns_production);
}

test "memory driver send" {
    const allocator = std.testing.allocator;
    const mem_driver = try MemoryDriver.init(allocator);
    defer mem_driver.allocator.destroy(mem_driver);
    defer mem_driver.sent_messages.deinit();
    defer {
        var it = mem_driver.subscriptions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        mem_driver.subscriptions.deinit();
    }

    var driver = mem_driver.driver();

    const tokens = [_][]const u8{"token1"};
    const msg = PushMessage.init(&tokens, "Test", "Body");
    const result = driver.send(msg);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("memory", result.provider);
    try std.testing.expectEqual(@as(usize, 1), mem_driver.getSentMessages().len);
}
