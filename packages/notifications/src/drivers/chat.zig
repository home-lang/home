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

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // For webhooks: POST {webhook_url}
        // For API: POST https://slack.com/api/chat.postMessage
        // Authorization: Bearer {token}

        self.sent_count += 1;
        return NotificationResult.ok("slack", "1234567890.123456");
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
        // POST https://slack.com/api/chat.update
        return NotificationResult.ok("slack", null);
    }

    fn deleteMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        // POST https://slack.com/api/chat.delete
        return true;
    }

    fn addReaction(ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        _ = emoji;
        // POST https://slack.com/api/reactions.add
        return true;
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

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // For webhooks: POST {webhook_url}
        // For API: POST https://discord.com/api/v10/channels/{channel_id}/messages
        // Authorization: Bot {token}

        self.sent_count += 1;
        return NotificationResult.ok("discord", "1234567890123456789");
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
        // PATCH https://discord.com/api/v10/channels/{channel_id}/messages/{message_id}
        return NotificationResult.ok("discord", null);
    }

    fn deleteMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        // DELETE https://discord.com/api/v10/channels/{channel_id}/messages/{message_id}
        return true;
    }

    fn addReaction(ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        _ = emoji;
        // PUT https://discord.com/api/v10/channels/{channel_id}/messages/{message_id}/reactions/{emoji}/@me
        return true;
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

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST {webhook_url}
        // Teams uses Adaptive Cards format

        self.sent_count += 1;
        return NotificationResult.ok("teams", "teams_msg_12345");
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

    fn send(ptr: *anyopaque, message: ChatMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://api.telegram.org/bot{token}/sendMessage

        self.sent_count += 1;
        return NotificationResult.ok("telegram", "12345");
    }

    fn sendToThread(ptr: *anyopaque, channel: []const u8, thread_id: []const u8, message: ChatMessage) NotificationResult {
        _ = channel;
        _ = thread_id;
        // Telegram uses reply_to_message_id for threading
        return send(ptr, message);
    }

    fn updateMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8, new_text: []const u8) NotificationResult {
        _ = ptr;
        _ = channel;
        _ = message_id;
        _ = new_text;
        // POST https://api.telegram.org/bot{token}/editMessageText
        return NotificationResult.ok("telegram", null);
    }

    fn deleteMessage(ptr: *anyopaque, channel: []const u8, message_id: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        // POST https://api.telegram.org/bot{token}/deleteMessage
        return true;
    }

    fn addReaction(ptr: *anyopaque, channel: []const u8, message_id: []const u8, emoji: []const u8) bool {
        _ = ptr;
        _ = channel;
        _ = message_id;
        _ = emoji;
        // POST https://api.telegram.org/bot{token}/setMessageReaction
        return true;
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
