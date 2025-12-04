const std = @import("std");

// Re-export drivers
pub const email = @import("drivers/email.zig");
pub const sms = @import("drivers/sms.zig");
pub const push = @import("drivers/push.zig");
pub const chat = @import("drivers/chat.zig");

/// Notification types supported by the system
pub const NotificationType = enum {
    email,
    sms,
    push,
    chat,
};

/// Notification status
pub const NotificationStatus = enum {
    pending,
    sending,
    sent,
    delivered,
    failed,
    bounced,
};

/// Notification priority levels
pub const Priority = enum {
    low,
    normal,
    high,
    urgent,
};

/// Base notification result
pub const NotificationResult = struct {
    success: bool,
    message_id: ?[]const u8,
    error_message: ?[]const u8,
    status: NotificationStatus,
    provider: []const u8,
    timestamp: i64,

    pub fn ok(provider: []const u8, message_id: ?[]const u8) NotificationResult {
        return .{
            .success = true,
            .message_id = message_id,
            .error_message = null,
            .status = .sent,
            .provider = provider,
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn err(provider: []const u8, error_message: []const u8) NotificationResult {
        return .{
            .success = false,
            .message_id = null,
            .error_message = error_message,
            .status = .failed,
            .provider = provider,
            .timestamp = std.time.timestamp(),
        };
    }
};

/// Attachment for notifications (email, chat)
pub const Attachment = struct {
    filename: []const u8,
    content: []const u8,
    content_type: []const u8,
    size: usize,
};

/// Recipient address (can be email, phone, device token, etc.)
pub const Recipient = struct {
    address: []const u8,
    name: ?[]const u8 = null,

    pub fn init(address: []const u8) Recipient {
        return .{ .address = address, .name = null };
    }

    pub fn withName(address: []const u8, name: []const u8) Recipient {
        return .{ .address = address, .name = name };
    }
};

/// Notification channel configuration
pub const ChannelConfig = struct {
    channel_type: NotificationType,
    driver: []const u8,
    enabled: bool = true,
    retry_attempts: u32 = 3,
    retry_delay_ms: u64 = 1000,
};

/// Notification manager - central point for sending notifications
pub const NotificationManager = struct {
    allocator: std.mem.Allocator,
    email_driver: ?*email.EmailDriver = null,
    sms_driver: ?*sms.SmsDriver = null,
    push_driver: ?*push.PushDriver = null,
    chat_driver: ?*chat.ChatDriver = null,
    default_from_email: ?[]const u8 = null,
    default_from_name: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.email_driver) |driver| {
            driver.deinit();
        }
        if (self.sms_driver) |driver| {
            driver.deinit();
        }
        if (self.push_driver) |driver| {
            driver.deinit();
        }
        if (self.chat_driver) |driver| {
            driver.deinit();
        }
    }

    /// Set the email driver
    pub fn useEmail(self: *Self, driver: *email.EmailDriver) *Self {
        self.email_driver = driver;
        return self;
    }

    /// Set the SMS driver
    pub fn useSms(self: *Self, driver: *sms.SmsDriver) *Self {
        self.sms_driver = driver;
        return self;
    }

    /// Set the push notification driver
    pub fn usePush(self: *Self, driver: *push.PushDriver) *Self {
        self.push_driver = driver;
        return self;
    }

    /// Set the chat driver
    pub fn useChat(self: *Self, driver: *chat.ChatDriver) *Self {
        self.chat_driver = driver;
        return self;
    }

    /// Set default from email
    pub fn setDefaultFrom(self: *Self, email_addr: []const u8, name: ?[]const u8) *Self {
        self.default_from_email = email_addr;
        self.default_from_name = name;
        return self;
    }

    /// Send an email notification
    pub fn sendEmail(self: *Self, message: email.EmailMessage) !NotificationResult {
        if (self.email_driver) |driver| {
            return driver.send(message);
        }
        return NotificationResult.err("none", "No email driver configured");
    }

    /// Send an SMS notification
    pub fn sendSms(self: *Self, message: sms.SmsMessage) !NotificationResult {
        if (self.sms_driver) |driver| {
            return driver.send(message);
        }
        return NotificationResult.err("none", "No SMS driver configured");
    }

    /// Send a push notification
    pub fn sendPush(self: *Self, message: push.PushMessage) !NotificationResult {
        if (self.push_driver) |driver| {
            return driver.send(message);
        }
        return NotificationResult.err("none", "No push driver configured");
    }

    /// Send a chat notification
    pub fn sendChat(self: *Self, message: chat.ChatMessage) !NotificationResult {
        if (self.chat_driver) |driver| {
            return driver.send(message);
        }
        return NotificationResult.err("none", "No chat driver configured");
    }

    /// Send notification to multiple channels
    pub fn broadcast(
        self: *Self,
        channels: []const NotificationType,
        content: BroadcastContent,
    ) ![]NotificationResult {
        var results = std.ArrayList(NotificationResult).init(self.allocator);
        errdefer results.deinit();

        for (channels) |channel| {
            const result = switch (channel) {
                .email => if (content.email_message) |msg| try self.sendEmail(msg) else continue,
                .sms => if (content.sms_message) |msg| try self.sendSms(msg) else continue,
                .push => if (content.push_message) |msg| try self.sendPush(msg) else continue,
                .chat => if (content.chat_message) |msg| try self.sendChat(msg) else continue,
            };
            try results.append(result);
        }

        return results.toOwnedSlice();
    }
};

/// Content for broadcasting to multiple channels
pub const BroadcastContent = struct {
    email_message: ?email.EmailMessage = null,
    sms_message: ?sms.SmsMessage = null,
    push_message: ?push.PushMessage = null,
    chat_message: ?chat.ChatMessage = null,
};

/// Notification builder for fluent API
pub fn NotificationBuilder(comptime MessageType: type) type {
    return struct {
        message: MessageType,
        retry_count: u32 = 3,
        delay_ms: u64 = 0,
        priority: Priority = .normal,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, message: MessageType) Self {
            return .{
                .allocator = allocator,
                .message = message,
            };
        }

        pub fn withRetries(self: *Self, count: u32) *Self {
            self.retry_count = count;
            return self;
        }

        pub fn withDelay(self: *Self, delay_ms: u64) *Self {
            self.delay_ms = delay_ms;
            return self;
        }

        pub fn withPriority(self: *Self, priority: Priority) *Self {
            self.priority = priority;
            return self;
        }

        pub fn build(self: *Self) MessageType {
            return self.message;
        }
    };
}

// Convenience functions for creating notifications
pub fn createEmailBuilder(allocator: std.mem.Allocator, message: email.EmailMessage) NotificationBuilder(email.EmailMessage) {
    return NotificationBuilder(email.EmailMessage).init(allocator, message);
}

pub fn createSmsBuilder(allocator: std.mem.Allocator, message: sms.SmsMessage) NotificationBuilder(sms.SmsMessage) {
    return NotificationBuilder(sms.SmsMessage).init(allocator, message);
}

pub fn createPushBuilder(allocator: std.mem.Allocator, message: push.PushMessage) NotificationBuilder(push.PushMessage) {
    return NotificationBuilder(push.PushMessage).init(allocator, message);
}

pub fn createChatBuilder(allocator: std.mem.Allocator, message: chat.ChatMessage) NotificationBuilder(chat.ChatMessage) {
    return NotificationBuilder(chat.ChatMessage).init(allocator, message);
}

// Tests
test "notification result ok" {
    const result = NotificationResult.ok("sendgrid", "msg_123");
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("sendgrid", result.provider);
    try std.testing.expectEqualStrings("msg_123", result.message_id.?);
}

test "notification result error" {
    const result = NotificationResult.err("sendgrid", "Connection failed");
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Connection failed", result.error_message.?);
}

test "recipient creation" {
    const r1 = Recipient.init("test@example.com");
    try std.testing.expectEqualStrings("test@example.com", r1.address);
    try std.testing.expect(r1.name == null);

    const r2 = Recipient.withName("test@example.com", "John Doe");
    try std.testing.expectEqualStrings("John Doe", r2.name.?);
}
