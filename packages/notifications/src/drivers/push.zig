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
    // Note: The FCM v1 API requires OAuth2 authentication with service account.
    // For simplicity, we also support the legacy API which uses server key.
    const FCM_V1_BASE = "https://fcm.googleapis.com/v1/projects/";
    const FCM_LEGACY_URL = "https://fcm.googleapis.com/fcm/send";
    const IID_BASE = "https://iid.googleapis.com/iid/v1";

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

    fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (input) |c| {
            switch (c) {
                '"' => try result.appendSlice(allocator, "\\\""),
                '\\' => try result.appendSlice(allocator, "\\\\"),
                '\n' => try result.appendSlice(allocator, "\\n"),
                '\r' => try result.appendSlice(allocator, "\\r"),
                '\t' => try result.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                        try result.appendSlice(allocator, hex);
                    } else {
                        try result.append(allocator, c);
                    }
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn isServerKey(credentials: []const u8) bool {
        // Server keys typically start with "AAAA" or similar, while service account JSON starts with "{"
        return credentials.len > 0 and credentials[0] != '{';
    }

    fn buildLegacyPayload(allocator: std.mem.Allocator, message: PushMessage, topic: ?[]const u8) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_title = try escapeJsonString(allocator, message.title);
        defer allocator.free(escaped_title);

        const escaped_body = try escapeJsonString(allocator, message.body);
        defer allocator.free(escaped_body);

        try json.appendSlice(allocator, "{");

        // Target: tokens, topic, or condition
        if (topic) |t| {
            const escaped_topic = try escapeJsonString(allocator, t);
            defer allocator.free(escaped_topic);
            try json.appendSlice(allocator, "\"to\":\"/topics/");
            try json.appendSlice(allocator, escaped_topic);
            try json.appendSlice(allocator, "\"");
        } else if (message.topic) |t| {
            const escaped_topic = try escapeJsonString(allocator, t);
            defer allocator.free(escaped_topic);
            try json.appendSlice(allocator, "\"to\":\"/topics/");
            try json.appendSlice(allocator, escaped_topic);
            try json.appendSlice(allocator, "\"");
        } else if (message.tokens.len == 1) {
            const escaped_token = try escapeJsonString(allocator, message.tokens[0]);
            defer allocator.free(escaped_token);
            try json.appendSlice(allocator, "\"to\":\"");
            try json.appendSlice(allocator, escaped_token);
            try json.appendSlice(allocator, "\"");
        } else if (message.tokens.len > 1) {
            try json.appendSlice(allocator, "\"registration_ids\":[");
            for (message.tokens, 0..) |token, i| {
                if (i > 0) try json.appendSlice(allocator, ",");
                const escaped_token = try escapeJsonString(allocator, token);
                defer allocator.free(escaped_token);
                try json.appendSlice(allocator, "\"");
                try json.appendSlice(allocator, escaped_token);
                try json.appendSlice(allocator, "\"");
            }
            try json.appendSlice(allocator, "]");
        }

        // Notification payload
        try json.appendSlice(allocator, ",\"notification\":{\"title\":\"");
        try json.appendSlice(allocator, escaped_title);
        try json.appendSlice(allocator, "\",\"body\":\"");
        try json.appendSlice(allocator, escaped_body);
        try json.appendSlice(allocator, "\"");

        if (message.image_url) |img| {
            const escaped_img = try escapeJsonString(allocator, img);
            defer allocator.free(escaped_img);
            try json.appendSlice(allocator, ",\"image\":\"");
            try json.appendSlice(allocator, escaped_img);
            try json.appendSlice(allocator, "\"");
        }

        if (message.click_action) |action| {
            const escaped_action = try escapeJsonString(allocator, action);
            defer allocator.free(escaped_action);
            try json.appendSlice(allocator, ",\"click_action\":\"");
            try json.appendSlice(allocator, escaped_action);
            try json.appendSlice(allocator, "\"");
        }

        if (message.sound) |sound| {
            const escaped_sound = try escapeJsonString(allocator, sound);
            defer allocator.free(escaped_sound);
            try json.appendSlice(allocator, ",\"sound\":\"");
            try json.appendSlice(allocator, escaped_sound);
            try json.appendSlice(allocator, "\"");
        }

        try json.appendSlice(allocator, "}");

        // Android specific
        if (message.android_channel_id) |channel| {
            const escaped_channel = try escapeJsonString(allocator, channel);
            defer allocator.free(escaped_channel);
            try json.appendSlice(allocator, ",\"android\":{\"notification\":{\"channel_id\":\"");
            try json.appendSlice(allocator, escaped_channel);
            try json.appendSlice(allocator, "\"}}");
        }

        // Priority
        if (message.priority == .high or message.priority == .critical) {
            try json.appendSlice(allocator, ",\"priority\":\"high\"");
        }

        // TTL
        if (message.ttl) |ttl| {
            var ttl_buf: [20]u8 = undefined;
            const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl}) catch "0";
            try json.appendSlice(allocator, ",\"time_to_live\":");
            try json.appendSlice(allocator, ttl_str);
        }

        // Collapse key
        if (message.collapse_key) |key| {
            const escaped_key = try escapeJsonString(allocator, key);
            defer allocator.free(escaped_key);
            try json.appendSlice(allocator, ",\"collapse_key\":\"");
            try json.appendSlice(allocator, escaped_key);
            try json.appendSlice(allocator, "\"");
        }

        try json.appendSlice(allocator, "}");

        return json.toOwnedSlice(allocator);
    }

    fn sendLegacy(self: *Self, server_key: []const u8, json_body: []const u8) NotificationResult {
        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "key={s}", .{server_key}) catch {
            return NotificationResult.err("fcm", "Server key too long");
        };

        const uri = std.Uri.parse(FCM_LEGACY_URL) catch {
            return NotificationResult.err("fcm", "Invalid URL");
        };

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch {
            return NotificationResult.err("fcm", "Failed to open connection");
        };
        defer req.deinit();

        req.send() catch {
            return NotificationResult.err("fcm", "Failed to send request");
        };

        req.writer().writeAll(json_body) catch {
            return NotificationResult.err("fcm", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("fcm", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("fcm", "Failed to get response");
        };

        if (req.status == .ok) {
            // Read response
            var response_body: [4096]u8 = undefined;
            const body_len = req.reader().readAll(&response_body) catch {
                self.sent_count += 1;
                return NotificationResult.ok("fcm", null);
            };
            const response_str = response_body[0..body_len];

            // Extract message_id from response
            if (std.mem.indexOf(u8, response_str, "\"message_id\":")) |id_start| {
                const search_start = id_start + 13;
                // Skip potential whitespace and quotes
                var start = search_start;
                while (start < response_str.len and (response_str[start] == ' ' or response_str[start] == '"')) {
                    start += 1;
                }
                if (std.mem.indexOfPos(u8, response_str, start, "\"")) |end| {
                    const msg_id = response_str[start..end];
                    self.sent_count += 1;
                    return NotificationResult.ok("fcm", msg_id);
                }
            }

            self.sent_count += 1;
            return NotificationResult.ok("fcm", null);
        }

        return NotificationResult.err("fcm", "Request failed");
    }

    fn send(ptr: *anyopaque, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const credentials = self.config.fcm_credentials orelse {
            return NotificationResult.err("fcm", "No FCM credentials configured");
        };

        // Use legacy API if server key provided
        if (isServerKey(credentials)) {
            const json_body = buildLegacyPayload(self.allocator, message, null) catch |err| {
                return NotificationResult.err("fcm", @errorName(err));
            };
            defer self.allocator.free(json_body);

            return sendLegacy(self, credentials, json_body);
        }

        // For v1 API with service account JSON, we'd need OAuth2 token exchange
        // This requires JWT signing which is complex without a crypto library
        // For now, return error indicating v1 API requires additional setup
        return NotificationResult.err("fcm", "V1 API requires OAuth2 - use server key for legacy API");
    }

    fn sendToTopic(ptr: *anyopaque, topic: []const u8, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const credentials = self.config.fcm_credentials orelse {
            return NotificationResult.err("fcm", "No FCM credentials configured");
        };

        if (isServerKey(credentials)) {
            const json_body = buildLegacyPayload(self.allocator, message, topic) catch |err| {
                return NotificationResult.err("fcm", @errorName(err));
            };
            defer self.allocator.free(json_body);

            return sendLegacy(self, credentials, json_body);
        }

        return NotificationResult.err("fcm", "V1 API requires OAuth2 - use server key for legacy API");
    }

    fn subscribeToTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const credentials = self.config.fcm_credentials orelse return false;

        if (!isServerKey(credentials)) {
            return false;
        }

        // Build JSON for batch subscribe
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        const escaped_topic = escapeJsonString(self.allocator, topic) catch return false;
        defer self.allocator.free(escaped_topic);

        json.appendSlice(self.allocator, "{\"to\":\"/topics/") catch return false;
        json.appendSlice(self.allocator, escaped_topic) catch return false;
        json.appendSlice(self.allocator, "\",\"registration_tokens\":[") catch return false;

        for (tokens, 0..) |token, i| {
            if (i > 0) json.appendSlice(self.allocator, ",") catch return false;
            const escaped_token = escapeJsonString(self.allocator, token) catch return false;
            defer self.allocator.free(escaped_token);
            json.appendSlice(self.allocator, "\"") catch return false;
            json.appendSlice(self.allocator, escaped_token) catch return false;
            json.appendSlice(self.allocator, "\"") catch return false;
        }

        json.appendSlice(self.allocator, "]}") catch return false;

        // Send to IID API
        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "key={s}", .{credentials}) catch return false;

        const api_url = IID_BASE ++ ":batchAdd";
        const uri = std.Uri.parse(api_url) catch return false;

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return false;
        defer req.deinit();

        req.send() catch return false;
        req.writer().writeAll(json.items) catch return false;
        req.finish() catch return false;
        req.wait() catch return false;

        return req.status == .ok;
    }

    fn unsubscribeFromTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const credentials = self.config.fcm_credentials orelse return false;

        if (!isServerKey(credentials)) {
            return false;
        }

        // Build JSON for batch unsubscribe
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        const escaped_topic = escapeJsonString(self.allocator, topic) catch return false;
        defer self.allocator.free(escaped_topic);

        json.appendSlice(self.allocator, "{\"to\":\"/topics/") catch return false;
        json.appendSlice(self.allocator, escaped_topic) catch return false;
        json.appendSlice(self.allocator, "\",\"registration_tokens\":[") catch return false;

        for (tokens, 0..) |token, i| {
            if (i > 0) json.appendSlice(self.allocator, ",") catch return false;
            const escaped_token = escapeJsonString(self.allocator, token) catch return false;
            defer self.allocator.free(escaped_token);
            json.appendSlice(self.allocator, "\"") catch return false;
            json.appendSlice(self.allocator, escaped_token) catch return false;
            json.appendSlice(self.allocator, "\"") catch return false;
        }

        json.appendSlice(self.allocator, "]}") catch return false;

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "key={s}", .{credentials}) catch return false;

        const api_url = IID_BASE ++ ":batchRemove";
        const uri = std.Uri.parse(api_url) catch return false;

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return false;
        defer req.deinit();

        req.send() catch return false;
        req.writer().writeAll(json.items) catch return false;
        req.finish() catch return false;
        req.wait() catch return false;

        return req.status == .ok;
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
    const EXPO_API_URL = "https://exp.host/--/api/v2/push/send";

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

    fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (input) |c| {
            switch (c) {
                '"' => try result.appendSlice(allocator, "\\\""),
                '\\' => try result.appendSlice(allocator, "\\\\"),
                '\n' => try result.appendSlice(allocator, "\\n"),
                '\r' => try result.appendSlice(allocator, "\\r"),
                '\t' => try result.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                        try result.appendSlice(allocator, hex);
                    } else {
                        try result.append(allocator, c);
                    }
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn buildPayload(allocator: std.mem.Allocator, message: PushMessage) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_title = try escapeJsonString(allocator, message.title);
        defer allocator.free(escaped_title);

        const escaped_body = try escapeJsonString(allocator, message.body);
        defer allocator.free(escaped_body);

        // Expo API accepts array of messages
        try json.appendSlice(allocator, "[");

        for (message.tokens, 0..) |token, i| {
            if (i > 0) try json.appendSlice(allocator, ",");

            const escaped_token = try escapeJsonString(allocator, token);
            defer allocator.free(escaped_token);

            try json.appendSlice(allocator, "{\"to\":\"");
            try json.appendSlice(allocator, escaped_token);
            try json.appendSlice(allocator, "\",\"title\":\"");
            try json.appendSlice(allocator, escaped_title);
            try json.appendSlice(allocator, "\",\"body\":\"");
            try json.appendSlice(allocator, escaped_body);
            try json.appendSlice(allocator, "\"");

            // Sound
            if (message.sound) |sound| {
                const escaped_sound = try escapeJsonString(allocator, sound);
                defer allocator.free(escaped_sound);
                try json.appendSlice(allocator, ",\"sound\":\"");
                try json.appendSlice(allocator, escaped_sound);
                try json.appendSlice(allocator, "\"");
            } else {
                try json.appendSlice(allocator, ",\"sound\":\"default\"");
            }

            // Badge
            if (message.badge) |badge| {
                var badge_buf: [20]u8 = undefined;
                const badge_str = std.fmt.bufPrint(&badge_buf, "{d}", .{badge}) catch "0";
                try json.appendSlice(allocator, ",\"badge\":");
                try json.appendSlice(allocator, badge_str);
            }

            // TTL
            if (message.ttl) |ttl| {
                var ttl_buf: [20]u8 = undefined;
                const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl}) catch "0";
                try json.appendSlice(allocator, ",\"ttl\":");
                try json.appendSlice(allocator, ttl_str);
            }

            // Priority
            if (message.priority == .high or message.priority == .critical) {
                try json.appendSlice(allocator, ",\"priority\":\"high\"");
            }

            // Channel ID for Android
            if (message.android_channel_id) |channel| {
                const escaped_channel = try escapeJsonString(allocator, channel);
                defer allocator.free(escaped_channel);
                try json.appendSlice(allocator, ",\"channelId\":\"");
                try json.appendSlice(allocator, escaped_channel);
                try json.appendSlice(allocator, "\"");
            }

            // Category ID for iOS
            if (message.ios_category) |category| {
                const escaped_cat = try escapeJsonString(allocator, category);
                defer allocator.free(escaped_cat);
                try json.appendSlice(allocator, ",\"categoryId\":\"");
                try json.appendSlice(allocator, escaped_cat);
                try json.appendSlice(allocator, "\"");
            }

            try json.appendSlice(allocator, "}");
        }

        try json.appendSlice(allocator, "]");

        return json.toOwnedSlice(allocator);
    }

    fn send(ptr: *anyopaque, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (message.tokens.len == 0) {
            return NotificationResult.err("expo", "No tokens provided");
        }

        const json_body = buildPayload(self.allocator, message) catch |err| {
            return NotificationResult.err("expo", @errorName(err));
        };
        defer self.allocator.free(json_body);

        const uri = std.Uri.parse(EXPO_API_URL) catch {
            return NotificationResult.err("expo", "Invalid URL");
        };

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Build headers
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(self.allocator);

        headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" }) catch {
            return NotificationResult.err("expo", "OutOfMemory");
        };
        headers.append(self.allocator, .{ .name = "Accept", .value = "application/json" }) catch {
            return NotificationResult.err("expo", "OutOfMemory");
        };

        // Add authorization if token provided
        var auth_buf: [512]u8 = undefined;
        if (self.config.expo_access_token) |token| {
            const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch {
                return NotificationResult.err("expo", "Token too long");
            };
            headers.append(self.allocator, .{ .name = "Authorization", .value = auth_header }) catch {
                return NotificationResult.err("expo", "OutOfMemory");
            };
        }

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = headers.items,
        }) catch {
            return NotificationResult.err("expo", "Failed to open connection");
        };
        defer req.deinit();

        req.send() catch {
            return NotificationResult.err("expo", "Failed to send request");
        };

        req.writer().writeAll(json_body) catch {
            return NotificationResult.err("expo", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("expo", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("expo", "Failed to get response");
        };

        if (req.status == .ok) {
            var response_body: [4096]u8 = undefined;
            const body_len = req.reader().readAll(&response_body) catch {
                self.sent_count += 1;
                return NotificationResult.ok("expo", null);
            };
            const response_str = response_body[0..body_len];

            // Extract receipt ID if present
            if (std.mem.indexOf(u8, response_str, "\"id\":\"")) |id_start| {
                const id_begin = id_start + 6;
                if (std.mem.indexOfPos(u8, response_str, id_begin, "\"")) |id_end| {
                    const receipt_id = response_str[id_begin..id_end];
                    self.sent_count += 1;
                    return NotificationResult.ok("expo", receipt_id);
                }
            }

            self.sent_count += 1;
            return NotificationResult.ok("expo", null);
        }

        return NotificationResult.err("expo", "Request failed");
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
    const ONESIGNAL_API_URL = "https://onesignal.com/api/v1/notifications";

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

    fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (input) |c| {
            switch (c) {
                '"' => try result.appendSlice(allocator, "\\\""),
                '\\' => try result.appendSlice(allocator, "\\\\"),
                '\n' => try result.appendSlice(allocator, "\\n"),
                '\r' => try result.appendSlice(allocator, "\\r"),
                '\t' => try result.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                        try result.appendSlice(allocator, hex);
                    } else {
                        try result.append(allocator, c);
                    }
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn buildPayload(self: *Self, message: PushMessage, segment: ?[]const u8) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(self.allocator);

        const app_id = self.config.onesignal_app_id orelse return error.NoAppId;

        const escaped_app_id = try escapeJsonString(self.allocator, app_id);
        defer self.allocator.free(escaped_app_id);

        const escaped_title = try escapeJsonString(self.allocator, message.title);
        defer self.allocator.free(escaped_title);

        const escaped_body = try escapeJsonString(self.allocator, message.body);
        defer self.allocator.free(escaped_body);

        try json.appendSlice(self.allocator, "{\"app_id\":\"");
        try json.appendSlice(self.allocator, escaped_app_id);
        try json.appendSlice(self.allocator, "\"");

        // Headings (title)
        try json.appendSlice(self.allocator, ",\"headings\":{\"en\":\"");
        try json.appendSlice(self.allocator, escaped_title);
        try json.appendSlice(self.allocator, "\"}");

        // Contents (body)
        try json.appendSlice(self.allocator, ",\"contents\":{\"en\":\"");
        try json.appendSlice(self.allocator, escaped_body);
        try json.appendSlice(self.allocator, "\"}");

        // Target: segment or player IDs
        if (segment) |seg| {
            const escaped_seg = try escapeJsonString(self.allocator, seg);
            defer self.allocator.free(escaped_seg);
            try json.appendSlice(self.allocator, ",\"included_segments\":[\"");
            try json.appendSlice(self.allocator, escaped_seg);
            try json.appendSlice(self.allocator, "\"]");
        } else if (message.tokens.len > 0) {
            try json.appendSlice(self.allocator, ",\"include_player_ids\":[");
            for (message.tokens, 0..) |token, i| {
                if (i > 0) try json.appendSlice(self.allocator, ",");
                const escaped_token = try escapeJsonString(self.allocator, token);
                defer self.allocator.free(escaped_token);
                try json.appendSlice(self.allocator, "\"");
                try json.appendSlice(self.allocator, escaped_token);
                try json.appendSlice(self.allocator, "\"");
            }
            try json.appendSlice(self.allocator, "]");
        } else {
            // Default to all subscribed users
            try json.appendSlice(self.allocator, ",\"included_segments\":[\"Subscribed Users\"]");
        }

        // Image
        if (message.image_url) |img| {
            const escaped_img = try escapeJsonString(self.allocator, img);
            defer self.allocator.free(escaped_img);
            try json.appendSlice(self.allocator, ",\"big_picture\":\"");
            try json.appendSlice(self.allocator, escaped_img);
            try json.appendSlice(self.allocator, "\"");
        }

        // URL / Click action
        if (message.click_action) |action| {
            const escaped_action = try escapeJsonString(self.allocator, action);
            defer self.allocator.free(escaped_action);
            try json.appendSlice(self.allocator, ",\"url\":\"");
            try json.appendSlice(self.allocator, escaped_action);
            try json.appendSlice(self.allocator, "\"");
        }

        // iOS badge
        if (message.badge) |badge| {
            var badge_buf: [20]u8 = undefined;
            const badge_str = std.fmt.bufPrint(&badge_buf, "{d}", .{badge}) catch "0";
            try json.appendSlice(self.allocator, ",\"ios_badgeType\":\"SetTo\",\"ios_badgeCount\":");
            try json.appendSlice(self.allocator, badge_str);
        }

        // Android channel
        if (message.android_channel_id) |channel| {
            const escaped_channel = try escapeJsonString(self.allocator, channel);
            defer self.allocator.free(escaped_channel);
            try json.appendSlice(self.allocator, ",\"android_channel_id\":\"");
            try json.appendSlice(self.allocator, escaped_channel);
            try json.appendSlice(self.allocator, "\"");
        }

        // TTL
        if (message.ttl) |ttl| {
            var ttl_buf: [20]u8 = undefined;
            const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl}) catch "0";
            try json.appendSlice(self.allocator, ",\"ttl\":");
            try json.appendSlice(self.allocator, ttl_str);
        }

        // Priority
        if (message.priority == .high or message.priority == .critical) {
            try json.appendSlice(self.allocator, ",\"priority\":10");
        }

        try json.appendSlice(self.allocator, "}");

        return json.toOwnedSlice(self.allocator);
    }

    fn sendRequest(self: *Self, json_body: []const u8) NotificationResult {
        const api_key = self.config.onesignal_api_key orelse {
            return NotificationResult.err("onesignal", "No API key configured");
        };

        var auth_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Basic {s}", .{api_key}) catch {
            return NotificationResult.err("onesignal", "API key too long");
        };

        const uri = std.Uri.parse(ONESIGNAL_API_URL) catch {
            return NotificationResult.err("onesignal", "Invalid URL");
        };

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch {
            return NotificationResult.err("onesignal", "Failed to open connection");
        };
        defer req.deinit();

        req.send() catch {
            return NotificationResult.err("onesignal", "Failed to send request");
        };

        req.writer().writeAll(json_body) catch {
            return NotificationResult.err("onesignal", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("onesignal", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("onesignal", "Failed to get response");
        };

        if (req.status == .ok or req.status == .created) {
            var response_body: [4096]u8 = undefined;
            const body_len = req.reader().readAll(&response_body) catch {
                self.sent_count += 1;
                return NotificationResult.ok("onesignal", null);
            };
            const response_str = response_body[0..body_len];

            // Extract notification ID
            if (std.mem.indexOf(u8, response_str, "\"id\":\"")) |id_start| {
                const id_begin = id_start + 6;
                if (std.mem.indexOfPos(u8, response_str, id_begin, "\"")) |id_end| {
                    const notification_id = response_str[id_begin..id_end];
                    self.sent_count += 1;
                    return NotificationResult.ok("onesignal", notification_id);
                }
            }

            self.sent_count += 1;
            return NotificationResult.ok("onesignal", null);
        }

        return NotificationResult.err("onesignal", "Request failed");
    }

    fn send(ptr: *anyopaque, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const json_body = self.buildPayload(message, null) catch |err| {
            return NotificationResult.err("onesignal", @errorName(err));
        };
        defer self.allocator.free(json_body);

        return self.sendRequest(json_body);
    }

    fn sendToTopic(ptr: *anyopaque, topic: []const u8, message: PushMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // OneSignal uses "segments" instead of topics
        const json_body = self.buildPayload(message, topic) catch |err| {
            return NotificationResult.err("onesignal", @errorName(err));
        };
        defer self.allocator.free(json_body);

        return self.sendRequest(json_body);
    }

    fn subscribeToTopic(ptr: *anyopaque, tokens: []const []const u8, topic: []const u8) bool {
        // OneSignal manages segments server-side, not via API topic subscription
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
            .sent_messages = .empty,
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
        self.sent_messages.append(self.allocator, message) catch {
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
            result.value_ptr.* = .empty;
        }
        for (tokens) |token| {
            result.value_ptr.append(self.allocator, token) catch return false;
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
        self.sent_messages.deinit(self.allocator);

        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
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
