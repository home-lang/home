const std = @import("std");
const notifications = @import("../notifications.zig");
const NotificationResult = notifications.NotificationResult;
const Recipient = notifications.Recipient;
const Attachment = notifications.Attachment;
const Priority = notifications.Priority;

/// Email driver types
pub const EmailDriverType = enum {
    sendgrid,
    mailgun,
    ses,
    smtp,
    postmark,
    mailtrap,
    resend,
    memory, // For testing
};

/// Email message structure
pub const EmailMessage = struct {
    to: []const Recipient,
    from: Recipient,
    subject: []const u8,
    html: ?[]const u8 = null,
    text: ?[]const u8 = null,
    cc: ?[]const Recipient = null,
    bcc: ?[]const Recipient = null,
    reply_to: ?Recipient = null,
    attachments: ?[]const Attachment = null,
    headers: ?std.StringHashMap([]const u8) = null,
    template_id: ?[]const u8 = null,
    template_data: ?std.StringHashMap([]const u8) = null,
    priority: Priority = .normal,
    tags: ?[]const []const u8 = null,

    pub fn init(to: []const Recipient, from: Recipient, subject: []const u8) EmailMessage {
        return .{
            .to = to,
            .from = from,
            .subject = subject,
        };
    }

    pub fn withHtml(self: EmailMessage, html: []const u8) EmailMessage {
        var msg = self;
        msg.html = html;
        return msg;
    }

    pub fn withText(self: EmailMessage, text: []const u8) EmailMessage {
        var msg = self;
        msg.text = text;
        return msg;
    }

    pub fn withTemplate(self: EmailMessage, template_id: []const u8) EmailMessage {
        var msg = self;
        msg.template_id = template_id;
        return msg;
    }
};

/// Email driver configuration
pub const EmailConfig = struct {
    driver_type: EmailDriverType,
    api_key: ?[]const u8 = null,
    api_secret: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    region: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: u16 = 587,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    use_tls: bool = true,
    timeout_ms: u32 = 30000,
    max_retries: u32 = 3,

    pub fn sendgrid(api_key: []const u8) EmailConfig {
        return .{
            .driver_type = .sendgrid,
            .api_key = api_key,
        };
    }

    pub fn mailgun(api_key: []const u8, domain: []const u8) EmailConfig {
        return .{
            .driver_type = .mailgun,
            .api_key = api_key,
            .domain = domain,
        };
    }

    pub fn ses(access_key: []const u8, secret_key: []const u8, region: []const u8) EmailConfig {
        return .{
            .driver_type = .ses,
            .api_key = access_key,
            .api_secret = secret_key,
            .region = region,
        };
    }

    pub fn smtp(host: []const u8, port: u16, username: ?[]const u8, password: ?[]const u8) EmailConfig {
        return .{
            .driver_type = .smtp,
            .host = host,
            .port = port,
            .username = username,
            .password = password,
        };
    }

    pub fn postmark(api_key: []const u8) EmailConfig {
        return .{
            .driver_type = .postmark,
            .api_key = api_key,
        };
    }

    pub fn mailtrap(api_key: []const u8) EmailConfig {
        return .{
            .driver_type = .mailtrap,
            .api_key = api_key,
        };
    }

    pub fn resend(api_key: []const u8) EmailConfig {
        return .{
            .driver_type = .resend,
            .api_key = api_key,
        };
    }

    pub fn memory() EmailConfig {
        return .{
            .driver_type = .memory,
        };
    }
};

/// Email driver interface
pub const EmailDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, message: EmailMessage) NotificationResult,
        sendBatch: *const fn (ptr: *anyopaque, messages: []const EmailMessage) []NotificationResult,
        deinit: *const fn (ptr: *anyopaque) void,
        getDriverName: *const fn () []const u8,
    };

    pub fn send(self: *EmailDriver, message: EmailMessage) NotificationResult {
        return self.vtable.send(self.ptr, message);
    }

    pub fn sendBatch(self: *EmailDriver, messages: []const EmailMessage) []NotificationResult {
        return self.vtable.sendBatch(self.ptr, messages);
    }

    pub fn deinit(self: *EmailDriver) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getDriverName(self: *EmailDriver) []const u8 {
        return self.vtable.getDriverName();
    }
};

/// SendGrid email driver implementation
pub const SendGridDriver = struct {
    allocator: std.mem.Allocator,
    config: EmailConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EmailConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) EmailDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: EmailMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // In a real implementation, this would make HTTP request to SendGrid API
        // POST https://api.sendgrid.com/v3/mail/send
        // with Authorization: Bearer {api_key}

        self.sent_count += 1;

        // Simulate successful send
        return NotificationResult.ok("sendgrid", "sg_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const EmailMessage) []NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var results = self.allocator.alloc(NotificationResult, messages.len) catch {
            return &[_]NotificationResult{};
        };

        for (messages, 0..) |msg, i| {
            results[i] = send(ptr, msg);
        }

        return results;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "sendgrid";
    }
};

/// Mailgun email driver implementation
pub const MailgunDriver = struct {
    allocator: std.mem.Allocator,
    config: EmailConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EmailConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) EmailDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: EmailMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://api.mailgun.net/v3/{domain}/messages

        self.sent_count += 1;
        return NotificationResult.ok("mailgun", "mg_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const EmailMessage) []NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var results = self.allocator.alloc(NotificationResult, messages.len) catch {
            return &[_]NotificationResult{};
        };

        for (messages, 0..) |msg, i| {
            results[i] = send(ptr, msg);
        }

        return results;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "mailgun";
    }
};

/// AWS SES email driver implementation
pub const SesDriver = struct {
    allocator: std.mem.Allocator,
    config: EmailConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EmailConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) EmailDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: EmailMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // AWS SES API call would go here

        self.sent_count += 1;
        return NotificationResult.ok("ses", "ses_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const EmailMessage) []NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var results = self.allocator.alloc(NotificationResult, messages.len) catch {
            return &[_]NotificationResult{};
        };

        for (messages, 0..) |msg, i| {
            results[i] = send(ptr, msg);
        }

        return results;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "ses";
    }
};

/// SMTP email driver implementation
pub const SmtpDriver = struct {
    allocator: std.mem.Allocator,
    config: EmailConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EmailConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) EmailDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: EmailMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // SMTP connection and send would go here
        // Connect to self.config.host:self.config.port
        // Authenticate with username/password
        // Send MAIL FROM, RCPT TO, DATA commands

        self.sent_count += 1;
        return NotificationResult.ok("smtp", null);
    }

    fn sendBatch(ptr: *anyopaque, messages: []const EmailMessage) []NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var results = self.allocator.alloc(NotificationResult, messages.len) catch {
            return &[_]NotificationResult{};
        };

        for (messages, 0..) |msg, i| {
            results[i] = send(ptr, msg);
        }

        return results;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "smtp";
    }
};

/// Postmark email driver implementation
pub const PostmarkDriver = struct {
    allocator: std.mem.Allocator,
    config: EmailConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EmailConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) EmailDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: EmailMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://api.postmarkapp.com/email

        self.sent_count += 1;
        return NotificationResult.ok("postmark", "pm_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const EmailMessage) []NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var results = self.allocator.alloc(NotificationResult, messages.len) catch {
            return &[_]NotificationResult{};
        };

        for (messages, 0..) |msg, i| {
            results[i] = send(ptr, msg);
        }

        return results;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "postmark";
    }
};

/// Resend email driver implementation
pub const ResendDriver = struct {
    allocator: std.mem.Allocator,
    config: EmailConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EmailConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) EmailDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: EmailMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://api.resend.com/emails

        self.sent_count += 1;
        return NotificationResult.ok("resend", "re_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const EmailMessage) []NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var results = self.allocator.alloc(NotificationResult, messages.len) catch {
            return &[_]NotificationResult{};
        };

        for (messages, 0..) |msg, i| {
            results[i] = send(ptr, msg);
        }

        return results;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "resend";
    }
};

/// Memory email driver for testing
pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    sent_messages: std.ArrayList(EmailMessage),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .sent_messages = .empty,
        };
        return self;
    }

    pub fn driver(self: *Self) EmailDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
            },
        };
    }

    fn send(ptr: *anyopaque, message: EmailMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sent_messages.append(self.allocator, message) catch {
            return NotificationResult.err("memory", "Failed to store message");
        };
        return NotificationResult.ok("memory", "mem_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const EmailMessage) []NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var results = self.allocator.alloc(NotificationResult, messages.len) catch {
            return &[_]NotificationResult{};
        };

        for (messages, 0..) |msg, i| {
            results[i] = send(ptr, msg);
        }

        return results;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sent_messages.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn getDriverName() []const u8 {
        return "memory";
    }

    /// Get all sent messages (for testing)
    pub fn getSentMessages(self: *Self) []const EmailMessage {
        return self.sent_messages.items;
    }

    /// Clear all sent messages (for testing)
    pub fn clearMessages(self: *Self) void {
        self.sent_messages.clearRetainingCapacity();
    }
};

/// Create an email driver based on configuration
pub fn createDriver(allocator: std.mem.Allocator, config: EmailConfig) !*EmailDriver {
    const driver_ptr = try allocator.create(EmailDriver);

    switch (config.driver_type) {
        .sendgrid => {
            const sg = try SendGridDriver.init(allocator, config);
            driver_ptr.* = sg.driver();
        },
        .mailgun => {
            const mg = try MailgunDriver.init(allocator, config);
            driver_ptr.* = mg.driver();
        },
        .ses => {
            const ses = try SesDriver.init(allocator, config);
            driver_ptr.* = ses.driver();
        },
        .smtp => {
            const smtp = try SmtpDriver.init(allocator, config);
            driver_ptr.* = smtp.driver();
        },
        .postmark => {
            const pm = try PostmarkDriver.init(allocator, config);
            driver_ptr.* = pm.driver();
        },
        .mailtrap => {
            // Mailtrap uses SMTP
            const mt = try SmtpDriver.init(allocator, config);
            driver_ptr.* = mt.driver();
        },
        .resend => {
            const rs = try ResendDriver.init(allocator, config);
            driver_ptr.* = rs.driver();
        },
        .memory => {
            const mem = try MemoryDriver.init(allocator);
            driver_ptr.* = mem.driver();
        },
    }

    return driver_ptr;
}

// Tests
test "email message creation" {
    const recipients = [_]Recipient{Recipient.init("test@example.com")};
    const msg = EmailMessage.init(
        &recipients,
        Recipient.withName("sender@example.com", "Sender"),
        "Test Subject",
    ).withHtml("<h1>Hello</h1>").withText("Hello");

    try std.testing.expectEqualStrings("Test Subject", msg.subject);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", msg.html.?);
    try std.testing.expectEqualStrings("Hello", msg.text.?);
}

test "email config creation" {
    const sg_config = EmailConfig.sendgrid("api_key_123");
    try std.testing.expect(sg_config.driver_type == .sendgrid);
    try std.testing.expectEqualStrings("api_key_123", sg_config.api_key.?);

    const smtp_config = EmailConfig.smtp("mail.example.com", 587, "user", "pass");
    try std.testing.expect(smtp_config.driver_type == .smtp);
    try std.testing.expectEqual(@as(u16, 587), smtp_config.port);
}

test "memory driver send" {
    const allocator = std.testing.allocator;
    const mem_driver = try MemoryDriver.init(allocator);
    defer mem_driver.allocator.destroy(mem_driver);
    defer mem_driver.sent_messages.deinit();

    var driver = mem_driver.driver();

    const recipients = [_]Recipient{Recipient.init("test@example.com")};
    const msg = EmailMessage.init(
        &recipients,
        Recipient.init("sender@example.com"),
        "Test",
    );

    const result = driver.send(msg);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("memory", result.provider);
    try std.testing.expectEqual(@as(usize, 1), mem_driver.getSentMessages().len);
}
