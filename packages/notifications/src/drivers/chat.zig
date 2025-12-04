const std = @import("std");
const notifications = @import("../notifications.zig");
const NotificationResult = notifications.NotificationResult;
const Attachment = notifications.Attachment;
const Priority = notifications.Priority;

/// Chat notification driver types
pub const ChatDriverType = enum {
    slack,
    discord,
    teams,
    telegram,
    memory, // For testing
};

/// Message format types
pub const MessageFormat = enum {
    plain,
    markdown,
    blocks, // Slack blocks
    embeds, // Discord embeds
};

/// Chat message structure
pub const ChatMessage = struct {
    /// Channel/Room ID or webhook URL
    channel: []const u8,
    /// Message text
    text: []const u8,
    /// Username to display as sender (if supported)
    username: ?[]const u8 = null,
    /// Avatar URL for the sender
    avatar_url: ?[]const u8 = null,
    /// Thread ID for threaded messages
    thread_id: ?[]const u8 = null,
    /// Message format
    format: MessageFormat = .plain,
    /// Slack blocks or Discord embeds (JSON)
    blocks: ?[]const u8 = null,
    /// Attachments
    attachments: ?[]const ChatAttachment = null,
    /// Mention users
    mentions: ?[]const []const u8 = null,
    /// Mention everyone (@here, @channel, @everyone)
    mention_all: bool = false,
    /// Reply to message ID
    reply_to: ?[]const u8 = null,
    /// Priority (affects notification behavior)
    priority: Priority = .normal,
    /// Unfurl links (preview URLs)
    unfurl_links: bool = true,
    /// Unfurl media
    unfurl_media: bool = true,
    /// Parse mode for Telegram (HTML, Markdown, MarkdownV2)
    parse_mode: ?[]const u8 = null,

    pub fn init(channel: []const u8, text: []const u8) ChatMessage {
        return .{
            .channel = channel,
            .text = text,
        };
    }

    pub fn asUser(self: ChatMessage, username: []const u8, avatar_url: ?[]const u8) ChatMessage {
        var msg = self;
        msg.username = username;
        msg.avatar_url = avatar_url;
        return msg;
    }

    pub fn inThread(self: ChatMessage, thread_id: []const u8) ChatMessage {
        var msg = self;
        msg.thread_id = thread_id;
        return msg;
    }

    pub fn withBlocks(self: ChatMessage, blocks_json: []const u8) ChatMessage {
        var msg = self;
        msg.blocks = blocks_json;
        msg.format = .blocks;
        return msg;
    }

    pub fn withMentions(self: ChatMessage, users: []const []const u8) ChatMessage {
        var msg = self;
        msg.mentions = users;
        return msg;
    }

    pub fn mentionAll(self: ChatMessage) ChatMessage {
        var msg = self;
        msg.mention_all = true;
        return msg;
    }

    pub fn replyTo(self: ChatMessage, message_id: []const u8) ChatMessage {
        var msg = self;
        msg.reply_to = message_id;
        return msg;
    }
};

/// Chat attachment
pub const ChatAttachment = struct {
    /// Fallback text
    fallback: []const u8,
    /// Color (hex without #, e.g., "36a64f")
    color: ?[]const u8 = null,
    /// Author name
    author_name: ?[]const u8 = null,
    /// Author URL
    author_link: ?[]const u8 = null,
    /// Author icon URL
    author_icon: ?[]const u8 = null,
    /// Title
    title: ?[]const u8 = null,
    /// Title URL
    title_link: ?[]const u8 = null,
    /// Text content
    text: ?[]const u8 = null,
    /// Image URL
    image_url: ?[]const u8 = null,
    /// Thumbnail URL
    thumb_url: ?[]const u8 = null,
    /// Footer text
    footer: ?[]const u8 = null,
    /// Footer icon
    footer_icon: ?[]const u8 = null,
    /// Timestamp
    timestamp: ?i64 = null,
    /// Fields (for structured data)
    fields: ?[]const AttachmentField = null,
};

/// Attachment field
pub const AttachmentField = struct {
    title: []const u8,
    value: []const u8,
    short: bool = false,
};

/// Discord embed for rich messages
pub const DiscordEmbed = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    color: ?u32 = null,
    timestamp: ?[]const u8 = null, // ISO8601
    footer: ?EmbedFooter = null,
    image: ?EmbedMedia = null,
    thumbnail: ?EmbedMedia = null,
    author: ?EmbedAuthor = null,
    fields: ?[]const EmbedField = null,

    pub const EmbedFooter = struct {
        text: []const u8,
        icon_url: ?[]const u8 = null,
    };

    pub const EmbedMedia = struct {
        url: []const u8,
    };

    pub const EmbedAuthor = struct {
        name: []const u8,
        url: ?[]const u8 = null,
        icon_url: ?[]const u8 = null,
    };

    pub const EmbedField = struct {
        name: []const u8,
        value: []const u8,
        inline_field: bool = false,
    };
};

/// Chat driver configuration
pub const ChatConfig = struct {
    driver_type: ChatDriverType,
    /// Slack bot token or webhook URL
    slack_token: ?[]const u8 = null,
    /// Discord webhook URL or bot token
    discord_token: ?[]const u8 = null,
    /// Microsoft Teams webhook URL
    teams_webhook: ?[]const u8 = null,
    /// Telegram bot token
    telegram_token: ?[]const u8 = null,
    /// Default channel/chat ID
    default_channel: ?[]const u8 = null,
    /// Timeout for requests
    timeout_ms: u32 = 30000,
    /// Max retries
    max_retries: u32 = 3,

    pub fn slack(token: []const u8) ChatConfig {
        return .{
            .driver_type = .slack,
            .slack_token = token,
        };
    }

    pub fn slackWebhook(webhook_url: []const u8) ChatConfig {
        return .{
            .driver_type = .slack,
            .slack_token = webhook_url,
        };
    }

    pub fn discord(token: []const u8) ChatConfig {
        return .{
            .driver_type = .discord,
            .discord_token = token,
        };
    }

    pub fn discordWebhook(webhook_url: []const u8) ChatConfig {
        return .{
            .driver_type = .discord,
            .discord_token = webhook_url,
        };
    }

    pub fn teams(webhook_url: []const u8) ChatConfig {
        return .{
            .driver_type = .teams,
            .teams_webhook = webhook_url,
        };
    }

    pub fn telegram(bot_token: []const u8) ChatConfig {
        return .{
            .driver_type = .telegram,
            .telegram_token = bot_token,
        };
    }

    pub fn memory() ChatConfig {
        return .{
            .driver_type = .memory,
        };
    }
};

/// Chat driver interface
pub const ChatDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, message: ChatMessage) NotificationResult,
        sendToThread: *const fn (ptr: *anyopaque, channel: []const u8, thread_id: []const u8, message: ChatMessage) NotificationResult,
        updateMessage: *const fn (ptr: *anyopaque, channel: []const u8, message_id: []const u8, new_text: []const u8) NotificationResult,
        deleteMessage: *const fn (ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool,
        addReaction: *const fn (ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool,
        deinit: *const fn (ptr: *anyopaque) void,
        getDriverName: *const fn () []const u8,
    };

    pub fn send(self: *ChatDriver, message: ChatMessage) NotificationResult {
        return self.vtable.send(self.ptr, message);
    }

    pub fn sendToThread(self: *ChatDriver, channel: []const u8, thread_id: []const u8, message: ChatMessage) NotificationResult {
        return self.vtable.sendToThread(self.ptr, channel, thread_id, message);
    }

    pub fn updateMessage(self: *ChatDriver, channel: []const u8, message_id: []const u8, new_text: []const u8) NotificationResult {
        return self.vtable.updateMessage(self.ptr, channel, message_id, new_text);
    }

    pub fn deleteMessage(self: *ChatDriver, channel: []const u8, message_id: []const u8) bool {
        return self.vtable.deleteMessage(self.ptr, channel, message_id);
    }

    pub fn addReaction(self: *ChatDriver, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        return self.vtable.addReaction(self.ptr, channel, message_id, emoji);
    }

    pub fn deinit(self: *ChatDriver) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getDriverName(self: *ChatDriver) []const u8 {
        return self.vtable.getDriverName();
    }
};

/// Slack driver implementation
pub const SlackDriver = struct {
    allocator: std.mem.Allocator,
    config: ChatConfig,
    sent_count: usize = 0,

    const Self = @This();
    const SLACK_API_BASE = "https://slack.com/api";

    pub fn init(allocator: std.mem.Allocator, config: ChatConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) ChatDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToThread = sendToThread,
                .updateMessage = updateMessage,
                .deleteMessage = deleteMessage,
                .addReaction = addReaction,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn isWebhookUrl(token: []const u8) bool {
        return std.mem.startsWith(u8, token, "https://hooks.slack.com/");
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

    fn buildWebhookPayload(allocator: std.mem.Allocator, message: ChatMessage) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_text = try escapeJsonString(allocator, message.text);
        defer allocator.free(escaped_text);

        try json.appendSlice(allocator, "{\"text\":\"");
        try json.appendSlice(allocator, escaped_text);
        try json.appendSlice(allocator, "\"");

        if (message.username) |username| {
            const escaped_username = try escapeJsonString(allocator, username);
            defer allocator.free(escaped_username);
            try json.appendSlice(allocator, ",\"username\":\"");
            try json.appendSlice(allocator, escaped_username);
            try json.appendSlice(allocator, "\"");
        }

        if (message.avatar_url) |icon| {
            const escaped_icon = try escapeJsonString(allocator, icon);
            defer allocator.free(escaped_icon);
            try json.appendSlice(allocator, ",\"icon_url\":\"");
            try json.appendSlice(allocator, escaped_icon);
            try json.appendSlice(allocator, "\"");
        }

        // Add blocks if provided
        if (message.blocks) |blocks| {
            try json.appendSlice(allocator, ",\"blocks\":");
            try json.appendSlice(allocator, blocks);
        }

        try json.appendSlice(allocator, "}");

        return json.toOwnedSlice(allocator);
    }

    fn buildApiPayload(allocator: std.mem.Allocator, message: ChatMessage, thread_ts: ?[]const u8) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_text = try escapeJsonString(allocator, message.text);
        defer allocator.free(escaped_text);

        const escaped_channel = try escapeJsonString(allocator, message.channel);
        defer allocator.free(escaped_channel);

        try json.appendSlice(allocator, "{\"channel\":\"");
        try json.appendSlice(allocator, escaped_channel);
        try json.appendSlice(allocator, "\",\"text\":\"");
        try json.appendSlice(allocator, escaped_text);
        try json.appendSlice(allocator, "\"");

        if (message.username) |username| {
            const escaped_username = try escapeJsonString(allocator, username);
            defer allocator.free(escaped_username);
            try json.appendSlice(allocator, ",\"username\":\"");
            try json.appendSlice(allocator, escaped_username);
            try json.appendSlice(allocator, "\"");
        }

        if (message.avatar_url) |icon| {
            const escaped_icon = try escapeJsonString(allocator, icon);
            defer allocator.free(escaped_icon);
            try json.appendSlice(allocator, ",\"icon_url\":\"");
            try json.appendSlice(allocator, escaped_icon);
            try json.appendSlice(allocator, "\"");
        }

        // Thread support
        const thread_id = thread_ts orelse message.thread_id;
        if (thread_id) |tid| {
            const escaped_tid = try escapeJsonString(allocator, tid);
            defer allocator.free(escaped_tid);
            try json.appendSlice(allocator, ",\"thread_ts\":\"");
            try json.appendSlice(allocator, escaped_tid);
            try json.appendSlice(allocator, "\"");
        }

        // Add blocks if provided
        if (message.blocks) |blocks| {
            try json.appendSlice(allocator, ",\"blocks\":");
            try json.appendSlice(allocator, blocks);
        }

        // Link unfurling options
        if (!message.unfurl_links) {
            try json.appendSlice(allocator, ",\"unfurl_links\":false");
        }
        if (!message.unfurl_media) {
            try json.appendSlice(allocator, ",\"unfurl_media\":false");
        }

        try json.appendSlice(allocator, "}");

        return json.toOwnedSlice(allocator);
    }

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.slack_token orelse {
            return NotificationResult.err("slack", "No Slack token configured");
        };

        // Determine if using webhook or API
        if (isWebhookUrl(token)) {
            return sendViaWebhook(self, token, message);
        } else {
            return sendViaApi(self, token, message, null);
        }
    }

    fn sendViaWebhook(self: *Self, webhook_url: []const u8, message: ChatMessage) NotificationResult {
        const json_body = buildWebhookPayload(self.allocator, message) catch |err| {
            return NotificationResult.err("slack", @errorName(err));
        };
        defer self.allocator.free(json_body);

        // Parse webhook URL
        const uri = std.Uri.parse(webhook_url) catch {
            return NotificationResult.err("slack", "Invalid webhook URL");
        };

        // Create HTTP client
        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Setup request
        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch {
            return NotificationResult.err("slack", "Failed to open connection");
        };
        defer req.deinit();

        // Send request
        req.send() catch {
            return NotificationResult.err("slack", "Failed to send request");
        };

        // Write body
        req.writer().writeAll(json_body) catch {
            return NotificationResult.err("slack", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("slack", "Failed to finish request");
        };

        // Wait for response
        req.wait() catch {
            return NotificationResult.err("slack", "Failed to get response");
        };

        // Check response status
        if (req.status != .ok) {
            return NotificationResult.err("slack", "Webhook request failed");
        }

        self.sent_count += 1;
        return NotificationResult.ok("slack", "webhook_sent");
    }

    fn sendViaApi(self: *Self, token: []const u8, message: ChatMessage, thread_ts: ?[]const u8) NotificationResult {
        const json_body = buildApiPayload(self.allocator, message, thread_ts) catch |err| {
            return NotificationResult.err("slack", @errorName(err));
        };
        defer self.allocator.free(json_body);

        // Build auth header
        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch {
            return NotificationResult.err("slack", "Token too long");
        };

        // Parse API URL
        const api_url = SLACK_API_BASE ++ "/chat.postMessage";
        const uri = std.Uri.parse(api_url) catch {
            return NotificationResult.err("slack", "Invalid API URL");
        };

        // Create HTTP client
        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Setup request
        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch {
            return NotificationResult.err("slack", "Failed to open connection");
        };
        defer req.deinit();

        // Send request
        req.send() catch {
            return NotificationResult.err("slack", "Failed to send request");
        };

        // Write body
        req.writer().writeAll(json_body) catch {
            return NotificationResult.err("slack", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("slack", "Failed to finish request");
        };

        // Wait for response
        req.wait() catch {
            return NotificationResult.err("slack", "Failed to get response");
        };

        // Read response body
        var response_body: [4096]u8 = undefined;
        const body_len = req.reader().readAll(&response_body) catch {
            return NotificationResult.err("slack", "Failed to read response");
        };
        const response_str = response_body[0..body_len];

        // Check for API success (Slack returns {"ok":true,...})
        if (std.mem.indexOf(u8, response_str, "\"ok\":true")) |_| {
            // Try to extract message timestamp (ts) as message ID
            if (std.mem.indexOf(u8, response_str, "\"ts\":\"")) |ts_start| {
                const ts_begin = ts_start + 6;
                if (std.mem.indexOfPos(u8, response_str, ts_begin, "\"")) |ts_end| {
                    const message_ts = response_str[ts_begin..ts_end];
                    self.sent_count += 1;
                    return NotificationResult.ok("slack", message_ts);
                }
            }
            self.sent_count += 1;
            return NotificationResult.ok("slack", null);
        } else {
            // Extract error message if present
            if (std.mem.indexOf(u8, response_str, "\"error\":\"")) |err_start| {
                const err_begin = err_start + 9;
                if (std.mem.indexOfPos(u8, response_str, err_begin, "\"")) |err_end| {
                    _ = response_str[err_begin..err_end];
                }
            }
            return NotificationResult.err("slack", "API request failed");
        }
    }

    fn sendToThread(ptr: *anyopaque, channel: []const u8, thread_id: []const u8, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.slack_token orelse {
            return NotificationResult.err("slack", "No Slack token configured");
        };

        if (isWebhookUrl(token)) {
            // Webhooks don't support threading directly
            return sendViaWebhook(self, token, message);
        }

        // Create modified message with channel
        var thread_msg = message;
        thread_msg.channel = channel;
        return sendViaApi(self, token, thread_msg, thread_id);
    }

    fn updateMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8, new_text: []const u8) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.slack_token orelse {
            return NotificationResult.err("slack", "No Slack token configured");
        };

        if (isWebhookUrl(token)) {
            return NotificationResult.err("slack", "Update not supported via webhook");
        }

        // Build JSON payload for chat.update
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        const escaped_channel = escapeJsonString(self.allocator, channel) catch |err| {
            return NotificationResult.err("slack", @errorName(err));
        };
        defer self.allocator.free(escaped_channel);

        const escaped_ts = escapeJsonString(self.allocator, message_id) catch |err| {
            return NotificationResult.err("slack", @errorName(err));
        };
        defer self.allocator.free(escaped_ts);

        const escaped_text = escapeJsonString(self.allocator, new_text) catch |err| {
            return NotificationResult.err("slack", @errorName(err));
        };
        defer self.allocator.free(escaped_text);

        json.appendSlice(self.allocator, "{\"channel\":\"") catch {
            return NotificationResult.err("slack", "OutOfMemory");
        };
        json.appendSlice(self.allocator, escaped_channel) catch {
            return NotificationResult.err("slack", "OutOfMemory");
        };
        json.appendSlice(self.allocator, "\",\"ts\":\"") catch {
            return NotificationResult.err("slack", "OutOfMemory");
        };
        json.appendSlice(self.allocator, escaped_ts) catch {
            return NotificationResult.err("slack", "OutOfMemory");
        };
        json.appendSlice(self.allocator, "\",\"text\":\"") catch {
            return NotificationResult.err("slack", "OutOfMemory");
        };
        json.appendSlice(self.allocator, escaped_text) catch {
            return NotificationResult.err("slack", "OutOfMemory");
        };
        json.appendSlice(self.allocator, "\"}") catch {
            return NotificationResult.err("slack", "OutOfMemory");
        };

        // Build auth header
        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch {
            return NotificationResult.err("slack", "Token too long");
        };

        const api_url = SLACK_API_BASE ++ "/chat.update";
        const uri = std.Uri.parse(api_url) catch {
            return NotificationResult.err("slack", "Invalid API URL");
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
            return NotificationResult.err("slack", "Failed to open connection");
        };
        defer req.deinit();

        req.send() catch {
            return NotificationResult.err("slack", "Failed to send request");
        };

        req.writer().writeAll(json.items) catch {
            return NotificationResult.err("slack", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("slack", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("slack", "Failed to get response");
        };

        var response_body: [4096]u8 = undefined;
        const body_len = req.reader().readAll(&response_body) catch {
            return NotificationResult.err("slack", "Failed to read response");
        };
        const response_str = response_body[0..body_len];

        if (std.mem.indexOf(u8, response_str, "\"ok\":true")) |_| {
            return NotificationResult.ok("slack", message_id);
        }
        return NotificationResult.err("slack", "Update failed");
    }

    fn deleteMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.slack_token orelse return false;

        if (isWebhookUrl(token)) {
            return false; // Delete not supported via webhook
        }

        // Build JSON payload for chat.delete
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        const escaped_channel = escapeJsonString(self.allocator, channel) catch return false;
        defer self.allocator.free(escaped_channel);

        const escaped_ts = escapeJsonString(self.allocator, message_id) catch return false;
        defer self.allocator.free(escaped_ts);

        json.appendSlice(self.allocator, "{\"channel\":\"") catch return false;
        json.appendSlice(self.allocator, escaped_channel) catch return false;
        json.appendSlice(self.allocator, "\",\"ts\":\"") catch return false;
        json.appendSlice(self.allocator, escaped_ts) catch return false;
        json.appendSlice(self.allocator, "\"}") catch return false;

        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return false;

        const api_url = SLACK_API_BASE ++ "/chat.delete";
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

        var response_body: [4096]u8 = undefined;
        const body_len = req.reader().readAll(&response_body) catch return false;
        const response_str = response_body[0..body_len];

        return std.mem.indexOf(u8, response_str, "\"ok\":true") != null;
    }

    fn addReaction(ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.slack_token orelse return false;

        if (isWebhookUrl(token)) {
            return false; // Reactions not supported via webhook
        }

        // Build JSON payload for reactions.add
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        const escaped_channel = escapeJsonString(self.allocator, channel) catch return false;
        defer self.allocator.free(escaped_channel);

        const escaped_ts = escapeJsonString(self.allocator, message_id) catch return false;
        defer self.allocator.free(escaped_ts);

        const escaped_emoji = escapeJsonString(self.allocator, emoji) catch return false;
        defer self.allocator.free(escaped_emoji);

        json.appendSlice(self.allocator, "{\"channel\":\"") catch return false;
        json.appendSlice(self.allocator, escaped_channel) catch return false;
        json.appendSlice(self.allocator, "\",\"timestamp\":\"") catch return false;
        json.appendSlice(self.allocator, escaped_ts) catch return false;
        json.appendSlice(self.allocator, "\",\"name\":\"") catch return false;
        json.appendSlice(self.allocator, escaped_emoji) catch return false;
        json.appendSlice(self.allocator, "\"}") catch return false;

        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch return false;

        const api_url = SLACK_API_BASE ++ "/reactions.add";
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

        var response_body: [4096]u8 = undefined;
        const body_len = req.reader().readAll(&response_body) catch return false;
        const response_str = response_body[0..body_len];

        return std.mem.indexOf(u8, response_str, "\"ok\":true") != null;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "slack";
    }
};

/// Discord driver implementation
pub const DiscordDriver = struct {
    allocator: std.mem.Allocator,
    config: ChatConfig,
    sent_count: usize = 0,

    const Self = @This();
    const DISCORD_API_BASE = "https://discord.com/api/v10";

    pub fn init(allocator: std.mem.Allocator, config: ChatConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) ChatDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToThread = sendToThread,
                .updateMessage = updateMessage,
                .deleteMessage = deleteMessage,
                .addReaction = addReaction,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn isWebhookUrl(token: []const u8) bool {
        return std.mem.startsWith(u8, token, "https://discord.com/api/webhooks/") or
            std.mem.startsWith(u8, token, "https://discordapp.com/api/webhooks/");
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

    fn buildWebhookPayload(allocator: std.mem.Allocator, message: ChatMessage) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_text = try escapeJsonString(allocator, message.text);
        defer allocator.free(escaped_text);

        try json.appendSlice(allocator, "{\"content\":\"");
        try json.appendSlice(allocator, escaped_text);
        try json.appendSlice(allocator, "\"");

        if (message.username) |username| {
            const escaped_username = try escapeJsonString(allocator, username);
            defer allocator.free(escaped_username);
            try json.appendSlice(allocator, ",\"username\":\"");
            try json.appendSlice(allocator, escaped_username);
            try json.appendSlice(allocator, "\"");
        }

        if (message.avatar_url) |avatar| {
            const escaped_avatar = try escapeJsonString(allocator, avatar);
            defer allocator.free(escaped_avatar);
            try json.appendSlice(allocator, ",\"avatar_url\":\"");
            try json.appendSlice(allocator, escaped_avatar);
            try json.appendSlice(allocator, "\"");
        }

        // Add embeds if blocks are provided (Discord uses embeds)
        if (message.blocks) |embeds| {
            try json.appendSlice(allocator, ",\"embeds\":");
            try json.appendSlice(allocator, embeds);
        }

        try json.appendSlice(allocator, "}");

        return json.toOwnedSlice(allocator);
    }

    fn buildApiPayload(allocator: std.mem.Allocator, message: ChatMessage) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_text = try escapeJsonString(allocator, message.text);
        defer allocator.free(escaped_text);

        try json.appendSlice(allocator, "{\"content\":\"");
        try json.appendSlice(allocator, escaped_text);
        try json.appendSlice(allocator, "\"");

        // Add embeds if blocks are provided
        if (message.blocks) |embeds| {
            try json.appendSlice(allocator, ",\"embeds\":");
            try json.appendSlice(allocator, embeds);
        }

        // Reply support
        if (message.reply_to) |reply_id| {
            const escaped_reply = try escapeJsonString(allocator, reply_id);
            defer allocator.free(escaped_reply);
            try json.appendSlice(allocator, ",\"message_reference\":{\"message_id\":\"");
            try json.appendSlice(allocator, escaped_reply);
            try json.appendSlice(allocator, "\"}");
        }

        try json.appendSlice(allocator, "}");

        return json.toOwnedSlice(allocator);
    }

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.discord_token orelse {
            return NotificationResult.err("discord", "No Discord token configured");
        };

        if (isWebhookUrl(token)) {
            return sendViaWebhook(self, token, message);
        } else {
            return sendViaApi(self, token, message);
        }
    }

    fn sendViaWebhook(self: *Self, webhook_url: []const u8, message: ChatMessage) NotificationResult {
        const json_body = buildWebhookPayload(self.allocator, message) catch |err| {
            return NotificationResult.err("discord", @errorName(err));
        };
        defer self.allocator.free(json_body);

        const uri = std.Uri.parse(webhook_url) catch {
            return NotificationResult.err("discord", "Invalid webhook URL");
        };

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch {
            return NotificationResult.err("discord", "Failed to open connection");
        };
        defer req.deinit();

        req.send() catch {
            return NotificationResult.err("discord", "Failed to send request");
        };

        req.writer().writeAll(json_body) catch {
            return NotificationResult.err("discord", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("discord", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("discord", "Failed to get response");
        };

        // Discord webhooks return 204 No Content on success
        if (req.status == .no_content or req.status == .ok) {
            self.sent_count += 1;
            return NotificationResult.ok("discord", "webhook_sent");
        }

        return NotificationResult.err("discord", "Webhook request failed");
    }

    fn sendViaApi(self: *Self, token: []const u8, message: ChatMessage) NotificationResult {
        const json_body = buildApiPayload(self.allocator, message) catch |err| {
            return NotificationResult.err("discord", @errorName(err));
        };
        defer self.allocator.free(json_body);

        // Build auth header
        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bot {s}", .{token}) catch {
            return NotificationResult.err("discord", "Token too long");
        };

        // Build API URL with channel ID
        var url_buf: [512]u8 = undefined;
        const api_url = std.fmt.bufPrint(&url_buf, "{s}/channels/{s}/messages", .{ DISCORD_API_BASE, message.channel }) catch {
            return NotificationResult.err("discord", "Channel ID too long");
        };

        const uri = std.Uri.parse(api_url) catch {
            return NotificationResult.err("discord", "Invalid API URL");
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
            return NotificationResult.err("discord", "Failed to open connection");
        };
        defer req.deinit();

        req.send() catch {
            return NotificationResult.err("discord", "Failed to send request");
        };

        req.writer().writeAll(json_body) catch {
            return NotificationResult.err("discord", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("discord", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("discord", "Failed to get response");
        };

        if (req.status == .ok or req.status == .created) {
            // Read response to get message ID
            var response_body: [4096]u8 = undefined;
            const body_len = req.reader().readAll(&response_body) catch {
                self.sent_count += 1;
                return NotificationResult.ok("discord", null);
            };
            const response_str = response_body[0..body_len];

            // Extract message ID from response
            if (std.mem.indexOf(u8, response_str, "\"id\":\"")) |id_start| {
                const id_begin = id_start + 6;
                if (std.mem.indexOfPos(u8, response_str, id_begin, "\"")) |id_end| {
                    const message_id = response_str[id_begin..id_end];
                    self.sent_count += 1;
                    return NotificationResult.ok("discord", message_id);
                }
            }

            self.sent_count += 1;
            return NotificationResult.ok("discord", null);
        }

        return NotificationResult.err("discord", "API request failed");
    }

    fn sendToThread(ptr: *anyopaque, channel: []const u8, thread_id: []const u8, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = channel;

        const token = self.config.discord_token orelse {
            return NotificationResult.err("discord", "No Discord token configured");
        };

        if (isWebhookUrl(token)) {
            return sendViaWebhook(self, token, message);
        }

        // For Discord, thread_id is the channel ID of the thread
        var thread_msg = message;
        thread_msg.channel = thread_id;
        return sendViaApi(self, token, thread_msg);
    }

    fn updateMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8, new_text: []const u8) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.discord_token orelse {
            return NotificationResult.err("discord", "No Discord token configured");
        };

        if (isWebhookUrl(token)) {
            return NotificationResult.err("discord", "Update not supported via webhook");
        }

        // Build JSON payload
        const escaped_text = escapeJsonString(self.allocator, new_text) catch |err| {
            return NotificationResult.err("discord", @errorName(err));
        };
        defer self.allocator.free(escaped_text);

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        json.appendSlice(self.allocator, "{\"content\":\"") catch {
            return NotificationResult.err("discord", "OutOfMemory");
        };
        json.appendSlice(self.allocator, escaped_text) catch {
            return NotificationResult.err("discord", "OutOfMemory");
        };
        json.appendSlice(self.allocator, "\"}") catch {
            return NotificationResult.err("discord", "OutOfMemory");
        };

        // Build auth header
        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bot {s}", .{token}) catch {
            return NotificationResult.err("discord", "Token too long");
        };

        // Build API URL
        var url_buf: [512]u8 = undefined;
        const api_url = std.fmt.bufPrint(&url_buf, "{s}/channels/{s}/messages/{s}", .{ DISCORD_API_BASE, channel, message_id }) catch {
            return NotificationResult.err("discord", "URL too long");
        };

        const uri = std.Uri.parse(api_url) catch {
            return NotificationResult.err("discord", "Invalid API URL");
        };

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.PATCH, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch {
            return NotificationResult.err("discord", "Failed to open connection");
        };
        defer req.deinit();

        req.send() catch {
            return NotificationResult.err("discord", "Failed to send request");
        };

        req.writer().writeAll(json.items) catch {
            return NotificationResult.err("discord", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("discord", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("discord", "Failed to get response");
        };

        if (req.status == .ok) {
            return NotificationResult.ok("discord", message_id);
        }
        return NotificationResult.err("discord", "Update failed");
    }

    fn deleteMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.discord_token orelse return false;

        if (isWebhookUrl(token)) {
            return false;
        }

        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bot {s}", .{token}) catch return false;

        var url_buf: [512]u8 = undefined;
        const api_url = std.fmt.bufPrint(&url_buf, "{s}/channels/{s}/messages/{s}", .{ DISCORD_API_BASE, channel, message_id }) catch return false;

        const uri = std.Uri.parse(api_url) catch return false;

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.DELETE, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
            },
        }) catch return false;
        defer req.deinit();

        req.send() catch return false;
        req.finish() catch return false;
        req.wait() catch return false;

        return req.status == .no_content or req.status == .ok;
    }

    fn addReaction(ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const token = self.config.discord_token orelse return false;

        if (isWebhookUrl(token)) {
            return false;
        }

        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bot {s}", .{token}) catch return false;

        // URL encode the emoji
        var emoji_encoded: std.ArrayList(u8) = .empty;
        defer emoji_encoded.deinit(self.allocator);

        for (emoji) |c| {
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.') {
                emoji_encoded.append(self.allocator, c) catch return false;
            } else {
                var buf: [3]u8 = undefined;
                const encoded = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch return false;
                emoji_encoded.appendSlice(self.allocator, encoded) catch return false;
            }
        }

        var url_buf: [512]u8 = undefined;
        const api_url = std.fmt.bufPrint(&url_buf, "{s}/channels/{s}/messages/{s}/reactions/{s}/@me", .{
            DISCORD_API_BASE,
            channel,
            message_id,
            emoji_encoded.items,
        }) catch return false;

        const uri = std.Uri.parse(api_url) catch return false;

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.PUT, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
            },
        }) catch return false;
        defer req.deinit();

        req.send() catch return false;
        req.finish() catch return false;
        req.wait() catch return false;

        return req.status == .no_content or req.status == .ok;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "discord";
    }
};

/// Microsoft Teams driver implementation
pub const TeamsDriver = struct {
    allocator: std.mem.Allocator,
    config: ChatConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ChatConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) ChatDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToThread = sendToThread,
                .updateMessage = updateMessage,
                .deleteMessage = deleteMessage,
                .addReaction = addReaction,
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

    fn buildAdaptiveCardPayload(allocator: std.mem.Allocator, message: ChatMessage) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_text = try escapeJsonString(allocator, message.text);
        defer allocator.free(escaped_text);

        // Build Adaptive Card format for Teams
        try json.appendSlice(allocator,
            \\{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{
        );
        try json.appendSlice(allocator,
            \\"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","version":"1.4","body":[
        );

        // Add text block
        try json.appendSlice(allocator, "{\"type\":\"TextBlock\",\"text\":\"");
        try json.appendSlice(allocator, escaped_text);
        try json.appendSlice(allocator, "\",\"wrap\":true}");

        try json.appendSlice(allocator, "]}}]}");

        return json.toOwnedSlice(allocator);
    }

    fn buildSimplePayload(allocator: std.mem.Allocator, message: ChatMessage) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_text = try escapeJsonString(allocator, message.text);
        defer allocator.free(escaped_text);

        // Simple message card format (legacy but widely supported)
        try json.appendSlice(allocator, "{\"@type\":\"MessageCard\",\"@context\":\"http://schema.org/extensions\",");
        try json.appendSlice(allocator, "\"text\":\"");
        try json.appendSlice(allocator, escaped_text);
        try json.appendSlice(allocator, "\"}");

        return json.toOwnedSlice(allocator);
    }

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const webhook_url = self.config.teams_webhook orelse {
            return NotificationResult.err("teams", "No Teams webhook configured");
        };

        // Build payload - use Adaptive Card if blocks provided, otherwise simple card
        const json_body = if (message.blocks != null)
            buildAdaptiveCardPayload(self.allocator, message) catch |err| {
                return NotificationResult.err("teams", @errorName(err));
            }
        else
            buildSimplePayload(self.allocator, message) catch |err| {
                return NotificationResult.err("teams", @errorName(err));
            };
        defer self.allocator.free(json_body);

        const uri = std.Uri.parse(webhook_url) catch {
            return NotificationResult.err("teams", "Invalid webhook URL");
        };

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch {
            return NotificationResult.err("teams", "Failed to open connection");
        };
        defer req.deinit();

        req.send() catch {
            return NotificationResult.err("teams", "Failed to send request");
        };

        req.writer().writeAll(json_body) catch {
            return NotificationResult.err("teams", "Failed to write body");
        };

        req.finish() catch {
            return NotificationResult.err("teams", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("teams", "Failed to get response");
        };

        // Teams returns 200 OK with "1" on success
        if (req.status == .ok) {
            self.sent_count += 1;
            return NotificationResult.ok("teams", "webhook_sent");
        }

        return NotificationResult.err("teams", "Webhook request failed");
    }

    fn sendToThread(ptr: *anyopaque, channel: []const u8, thread_id: []const u8, message: ChatMessage) NotificationResult {
        _ = channel;
        _ = thread_id;
        // Teams webhooks don't support threading
        return send(ptr, message);
    }

    fn updateMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8, new_text: []const u8) NotificationResult {
        _ = ptr;
        _ = channel;
        _ = message_id;
        _ = new_text;
        return NotificationResult.err("teams", "Update not supported via webhook");
    }

    fn deleteMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        return false; // Not supported via webhook
    }

    fn addReaction(ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        _ = emoji;
        return false; // Not supported via webhook
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "teams";
    }
};

/// Telegram driver implementation
pub const TelegramDriver = struct {
    allocator: std.mem.Allocator,
    config: ChatConfig,
    sent_count: usize = 0,

    const Self = @This();
    const TELEGRAM_API_BASE = "https://api.telegram.org/bot";

    pub fn init(allocator: std.mem.Allocator, config: ChatConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) ChatDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToThread = sendToThread,
                .updateMessage = updateMessage,
                .deleteMessage = deleteMessage,
                .addReaction = addReaction,
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

    fn buildSendMessagePayload(allocator: std.mem.Allocator, message: ChatMessage, reply_to: ?[]const u8) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);

        const escaped_text = try escapeJsonString(allocator, message.text);
        defer allocator.free(escaped_text);

        const escaped_chat = try escapeJsonString(allocator, message.channel);
        defer allocator.free(escaped_chat);

        try json.appendSlice(allocator, "{\"chat_id\":\"");
        try json.appendSlice(allocator, escaped_chat);
        try json.appendSlice(allocator, "\",\"text\":\"");
        try json.appendSlice(allocator, escaped_text);
        try json.appendSlice(allocator, "\"");

        // Parse mode (HTML, Markdown, MarkdownV2)
        if (message.parse_mode) |mode| {
            const escaped_mode = try escapeJsonString(allocator, mode);
            defer allocator.free(escaped_mode);
            try json.appendSlice(allocator, ",\"parse_mode\":\"");
            try json.appendSlice(allocator, escaped_mode);
            try json.appendSlice(allocator, "\"");
        } else if (message.format == .markdown) {
            try json.appendSlice(allocator, ",\"parse_mode\":\"MarkdownV2\"");
        }

        // Reply to message
        const reply_id = reply_to orelse message.reply_to;
        if (reply_id) |rid| {
            try json.appendSlice(allocator, ",\"reply_to_message_id\":");
            try json.appendSlice(allocator, rid);
        }

        // Disable link preview if unfurl is disabled
        if (!message.unfurl_links) {
            try json.appendSlice(allocator, ",\"disable_web_page_preview\":true");
        }

        // Silent notification for low priority
        if (message.priority == .low) {
            try json.appendSlice(allocator, ",\"disable_notification\":true");
        }

        try json.appendSlice(allocator, "}");

        return json.toOwnedSlice(allocator);
    }

    fn makeApiRequest(self: *Self, method: []const u8, json_body: []const u8) ![]u8 {
        const token = self.config.telegram_token orelse return error.NoToken;

        // Build API URL
        var url_buf: [512]u8 = undefined;
        const api_url = std.fmt.bufPrint(&url_buf, "{s}{s}/{s}", .{ TELEGRAM_API_BASE, token, method }) catch return error.UrlTooLong;

        const uri = std.Uri.parse(api_url) catch return error.InvalidUrl;

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var server_header_buf: [16384]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.send() catch return error.SendFailed;
        req.writer().writeAll(json_body) catch return error.WriteFailed;
        req.finish() catch return error.FinishFailed;
        req.wait() catch return error.ResponseFailed;

        if (req.status != .ok) {
            return error.RequestFailed;
        }

        // Read response
        var response_body: [4096]u8 = undefined;
        const body_len = req.reader().readAll(&response_body) catch return error.ReadFailed;

        const result = try self.allocator.alloc(u8, body_len);
        @memcpy(result, response_body[0..body_len]);
        return result;
    }

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.config.telegram_token == null) {
            return NotificationResult.err("telegram", "No Telegram token configured");
        }

        const json_body = buildSendMessagePayload(self.allocator, message, null) catch |err| {
            return NotificationResult.err("telegram", @errorName(err));
        };
        defer self.allocator.free(json_body);

        const response = self.makeApiRequest("sendMessage", json_body) catch |err| {
            return NotificationResult.err("telegram", @errorName(err));
        };
        defer self.allocator.free(response);

        // Check for success and extract message_id
        if (std.mem.indexOf(u8, response, "\"ok\":true")) |_| {
            if (std.mem.indexOf(u8, response, "\"message_id\":")) |id_start| {
                const id_begin = id_start + 13;
                var id_end = id_begin;
                while (id_end < response.len and response[id_end] >= '0' and response[id_end] <= '9') {
                    id_end += 1;
                }
                if (id_end > id_begin) {
                    const message_id = response[id_begin..id_end];
                    self.sent_count += 1;
                    return NotificationResult.ok("telegram", message_id);
                }
            }
            self.sent_count += 1;
            return NotificationResult.ok("telegram", null);
        }

        return NotificationResult.err("telegram", "API request failed");
    }

    fn sendToThread(ptr: *anyopaque, channel: []const u8, thread_id: []const u8, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = channel;

        if (self.config.telegram_token == null) {
            return NotificationResult.err("telegram", "No Telegram token configured");
        }

        // Telegram uses reply_to_message_id for threading
        const json_body = buildSendMessagePayload(self.allocator, message, thread_id) catch |err| {
            return NotificationResult.err("telegram", @errorName(err));
        };
        defer self.allocator.free(json_body);

        const response = self.makeApiRequest("sendMessage", json_body) catch |err| {
            return NotificationResult.err("telegram", @errorName(err));
        };
        defer self.allocator.free(response);

        if (std.mem.indexOf(u8, response, "\"ok\":true")) |_| {
            self.sent_count += 1;
            return NotificationResult.ok("telegram", null);
        }

        return NotificationResult.err("telegram", "API request failed");
    }

    fn updateMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8, new_text: []const u8) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.config.telegram_token == null) {
            return NotificationResult.err("telegram", "No Telegram token configured");
        }

        // Build editMessageText payload
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        const escaped_chat = escapeJsonString(self.allocator, channel) catch |err| {
            return NotificationResult.err("telegram", @errorName(err));
        };
        defer self.allocator.free(escaped_chat);

        const escaped_text = escapeJsonString(self.allocator, new_text) catch |err| {
            return NotificationResult.err("telegram", @errorName(err));
        };
        defer self.allocator.free(escaped_text);

        json.appendSlice(self.allocator, "{\"chat_id\":\"") catch {
            return NotificationResult.err("telegram", "OutOfMemory");
        };
        json.appendSlice(self.allocator, escaped_chat) catch {
            return NotificationResult.err("telegram", "OutOfMemory");
        };
        json.appendSlice(self.allocator, "\",\"message_id\":") catch {
            return NotificationResult.err("telegram", "OutOfMemory");
        };
        json.appendSlice(self.allocator, message_id) catch {
            return NotificationResult.err("telegram", "OutOfMemory");
        };
        json.appendSlice(self.allocator, ",\"text\":\"") catch {
            return NotificationResult.err("telegram", "OutOfMemory");
        };
        json.appendSlice(self.allocator, escaped_text) catch {
            return NotificationResult.err("telegram", "OutOfMemory");
        };
        json.appendSlice(self.allocator, "\"}") catch {
            return NotificationResult.err("telegram", "OutOfMemory");
        };

        const response = self.makeApiRequest("editMessageText", json.items) catch |err| {
            return NotificationResult.err("telegram", @errorName(err));
        };
        defer self.allocator.free(response);

        if (std.mem.indexOf(u8, response, "\"ok\":true")) |_| {
            return NotificationResult.ok("telegram", message_id);
        }

        return NotificationResult.err("telegram", "Update failed");
    }

    fn deleteMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.config.telegram_token == null) {
            return false;
        }

        // Build deleteMessage payload
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        const escaped_chat = escapeJsonString(self.allocator, channel) catch return false;
        defer self.allocator.free(escaped_chat);

        json.appendSlice(self.allocator, "{\"chat_id\":\"") catch return false;
        json.appendSlice(self.allocator, escaped_chat) catch return false;
        json.appendSlice(self.allocator, "\",\"message_id\":") catch return false;
        json.appendSlice(self.allocator, message_id) catch return false;
        json.appendSlice(self.allocator, "}") catch return false;

        const response = self.makeApiRequest("deleteMessage", json.items) catch return false;
        defer self.allocator.free(response);

        return std.mem.indexOf(u8, response, "\"ok\":true") != null;
    }

    fn addReaction(ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.config.telegram_token == null) {
            return false;
        }

        // Build setMessageReaction payload
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);

        const escaped_chat = escapeJsonString(self.allocator, channel) catch return false;
        defer self.allocator.free(escaped_chat);

        const escaped_emoji = escapeJsonString(self.allocator, emoji) catch return false;
        defer self.allocator.free(escaped_emoji);

        json.appendSlice(self.allocator, "{\"chat_id\":\"") catch return false;
        json.appendSlice(self.allocator, escaped_chat) catch return false;
        json.appendSlice(self.allocator, "\",\"message_id\":") catch return false;
        json.appendSlice(self.allocator, message_id) catch return false;
        json.appendSlice(self.allocator, ",\"reaction\":[{\"type\":\"emoji\",\"emoji\":\"") catch return false;
        json.appendSlice(self.allocator, escaped_emoji) catch return false;
        json.appendSlice(self.allocator, "\"}]}") catch return false;

        const response = self.makeApiRequest("setMessageReaction", json.items) catch return false;
        defer self.allocator.free(response);

        return std.mem.indexOf(u8, response, "\"ok\":true") != null;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "telegram";
    }
};

/// Memory chat driver for testing
pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    sent_messages: std.ArrayList(ChatMessage),
    reactions: std.StringHashMap(std.ArrayList([]const u8)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .sent_messages = .empty,
            .reactions = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
        return self;
    }

    pub fn driver(self: *Self) ChatDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendToThread = sendToThread,
                .updateMessage = updateMessage,
                .deleteMessage = deleteMessage,
                .addReaction = addReaction,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sent_messages.append(self.allocator, message) catch {
            return NotificationResult.err("memory", "Failed to store message");
        };
        return NotificationResult.ok("memory", "mem_chat_12345");
    }

    fn sendToThread(ptr: *anyopaque, channel: []const u8, thread_id: []const u8, message: ChatMessage) NotificationResult {
        _ = channel;
        _ = thread_id;
        return send(ptr, message);
    }

    fn updateMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8, new_text: []const u8) NotificationResult {
        _ = ptr;
        _ = channel;
        _ = message_id;
        _ = new_text;
        return NotificationResult.ok("memory", null);
    }

    fn deleteMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        return true;
    }

    fn addReaction(ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = channel;
        const key = message_id;
        const result = self.reactions.getOrPut(key) catch return false;
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        result.value_ptr.append(self.allocator, emoji) catch return false;
        return true;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sent_messages.deinit(self.allocator);

        var it = self.reactions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.reactions.deinit();

        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "memory";
    }

    /// Get all sent messages (for testing)
    pub fn getSentMessages(self: *Self) []const ChatMessage {
        return self.sent_messages.items;
    }

    /// Clear all sent messages (for testing)
    pub fn clearMessages(self: *Self) void {
        self.sent_messages.clearRetainingCapacity();
    }
};

/// Create a chat driver based on configuration
pub fn createDriver(allocator: std.mem.Allocator, config: ChatConfig) !*ChatDriver {
    const driver_ptr = try allocator.create(ChatDriver);

    switch (config.driver_type) {
        .slack => {
            const slack = try SlackDriver.init(allocator, config);
            driver_ptr.* = slack.driver();
        },
        .discord => {
            const discord = try DiscordDriver.init(allocator, config);
            driver_ptr.* = discord.driver();
        },
        .teams => {
            const teams = try TeamsDriver.init(allocator, config);
            driver_ptr.* = teams.driver();
        },
        .telegram => {
            const telegram = try TelegramDriver.init(allocator, config);
            driver_ptr.* = telegram.driver();
        },
        .memory => {
            const mem = try MemoryDriver.init(allocator);
            driver_ptr.* = mem.driver();
        },
    }

    return driver_ptr;
}

// Tests
test "chat message creation" {
    const msg = ChatMessage.init("#general", "Hello, World!");
    try std.testing.expectEqualStrings("#general", msg.channel);
    try std.testing.expectEqualStrings("Hello, World!", msg.text);
}

test "chat message with user" {
    const msg = ChatMessage.init("#general", "Hello!")
        .asUser("Bot", "https://example.com/avatar.png");
    try std.testing.expectEqualStrings("Bot", msg.username.?);
    try std.testing.expectEqualStrings("https://example.com/avatar.png", msg.avatar_url.?);
}

test "chat config creation" {
    const slack_config = ChatConfig.slack("xoxb-token");
    try std.testing.expect(slack_config.driver_type == .slack);

    const discord_config = ChatConfig.discord("bot_token");
    try std.testing.expect(discord_config.driver_type == .discord);

    const telegram_config = ChatConfig.telegram("123456:ABC-DEF");
    try std.testing.expect(telegram_config.driver_type == .telegram);
}

test "memory driver send" {
    const allocator = std.testing.allocator;
    const mem_driver = try MemoryDriver.init(allocator);
    defer mem_driver.allocator.destroy(mem_driver);
    defer mem_driver.sent_messages.deinit();
    defer {
        var it = mem_driver.reactions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        mem_driver.reactions.deinit();
    }

    var driver = mem_driver.driver();

    const msg = ChatMessage.init("#test", "Test message");
    const result = driver.send(msg);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("memory", result.provider);
    try std.testing.expectEqual(@as(usize, 1), mem_driver.getSentMessages().len);
}
