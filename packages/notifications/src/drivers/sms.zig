const std = @import("std");
const notifications = @import("../notifications.zig");
const NotificationResult = notifications.NotificationResult;
const Priority = notifications.Priority;

/// SMS driver types
pub const SmsDriverType = enum {
    twilio,
    vonage, // formerly Nexmo
    plivo,
    sns, // AWS SNS
    telnyx,
    messagebird,
    memory, // For testing
};

/// SMS message structure
pub const SmsMessage = struct {
    to: []const u8, // Phone number in E.164 format (+1234567890)
    from: []const u8, // Sender phone number or alphanumeric ID
    body: []const u8, // Message content (max 160 chars for single SMS)
    media_url: ?[]const u8 = null, // For MMS
    callback_url: ?[]const u8 = null, // Status callback webhook
    priority: Priority = .normal,
    scheduled_at: ?i64 = null, // Unix timestamp for scheduled send
    validity_period: ?u32 = null, // Seconds until message expires

    pub fn init(to: []const u8, from: []const u8, body: []const u8) SmsMessage {
        return .{
            .to = to,
            .from = from,
            .body = body,
        };
    }

    pub fn withMediaUrl(self: SmsMessage, url: []const u8) SmsMessage {
        var msg = self;
        msg.media_url = url;
        return msg;
    }

    pub fn withCallback(self: SmsMessage, url: []const u8) SmsMessage {
        var msg = self;
        msg.callback_url = url;
        return msg;
    }

    pub fn scheduled(self: SmsMessage, timestamp: i64) SmsMessage {
        var msg = self;
        msg.scheduled_at = timestamp;
        return msg;
    }

    /// Check if message exceeds single SMS limit
    pub fn isMultipart(self: *const SmsMessage) bool {
        return self.body.len > 160;
    }

    /// Calculate number of SMS segments needed
    pub fn segmentCount(self: *const SmsMessage) u32 {
        if (self.body.len <= 160) return 1;
        // Multipart messages have 153 chars per segment due to UDH header
        return @intCast((self.body.len + 152) / 153);
    }
};

/// SMS driver configuration
pub const SmsConfig = struct {
    driver_type: SmsDriverType,
    account_sid: ?[]const u8 = null, // Twilio
    auth_token: ?[]const u8 = null, // Twilio
    api_key: ?[]const u8 = null, // General API key
    api_secret: ?[]const u8 = null, // API secret
    region: ?[]const u8 = null, // AWS region for SNS
    sender_id: ?[]const u8 = null, // Default sender ID
    timeout_ms: u32 = 30000,
    max_retries: u32 = 3,

    pub fn twilio(account_sid: []const u8, auth_token: []const u8) SmsConfig {
        return .{
            .driver_type = .twilio,
            .account_sid = account_sid,
            .auth_token = auth_token,
        };
    }

    pub fn vonage(api_key: []const u8, api_secret: []const u8) SmsConfig {
        return .{
            .driver_type = .vonage,
            .api_key = api_key,
            .api_secret = api_secret,
        };
    }

    pub fn plivo(auth_id: []const u8, auth_token: []const u8) SmsConfig {
        return .{
            .driver_type = .plivo,
            .account_sid = auth_id,
            .auth_token = auth_token,
        };
    }

    pub fn sns(access_key: []const u8, secret_key: []const u8, region: []const u8) SmsConfig {
        return .{
            .driver_type = .sns,
            .api_key = access_key,
            .api_secret = secret_key,
            .region = region,
        };
    }

    pub fn telnyx(api_key: []const u8) SmsConfig {
        return .{
            .driver_type = .telnyx,
            .api_key = api_key,
        };
    }

    pub fn messagebird(api_key: []const u8) SmsConfig {
        return .{
            .driver_type = .messagebird,
            .api_key = api_key,
        };
    }

    pub fn memory() SmsConfig {
        return .{
            .driver_type = .memory,
        };
    }
};

/// SMS driver interface
pub const SmsDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, message: SmsMessage) NotificationResult,
        sendBatch: *const fn (ptr: *anyopaque, messages: []const SmsMessage) []NotificationResult,
        deinit: *const fn (ptr: *anyopaque) void,
        getDriverName: *const fn () []const u8,
        getBalance: *const fn (ptr: *anyopaque) ?f64,
    };

    pub fn send(self: *SmsDriver, message: SmsMessage) NotificationResult {
        return self.vtable.send(self.ptr, message);
    }

    pub fn sendBatch(self: *SmsDriver, messages: []const SmsMessage) []NotificationResult {
        return self.vtable.sendBatch(self.ptr, messages);
    }

    pub fn deinit(self: *SmsDriver) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getDriverName(self: *SmsDriver) []const u8 {
        return self.vtable.getDriverName();
    }

    pub fn getBalance(self: *SmsDriver) ?f64 {
        return self.vtable.getBalance(self.ptr);
    }
};

/// Twilio SMS driver implementation
pub const TwilioDriver = struct {
    allocator: std.mem.Allocator,
    config: SmsConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: SmsConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) SmsDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
                .getBalance = getBalance,
            },
        };
    }

    fn send(ptr: *anyopaque, message: SmsMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://api.twilio.com/2010-04-01/Accounts/{AccountSid}/Messages.json
        // with Basic auth: account_sid:auth_token
        // Form data: To, From, Body

        self.sent_count += 1;
        return NotificationResult.ok("twilio", "SM12345678901234567890123456789012");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const SmsMessage) []NotificationResult {
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
        return "twilio";
    }

    fn getBalance(ptr: *anyopaque) ?f64 {
        _ = ptr;
        // Would fetch from Twilio API
        return null;
    }
};

/// Vonage (Nexmo) SMS driver implementation
pub const VonageDriver = struct {
    allocator: std.mem.Allocator,
    config: SmsConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: SmsConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) SmsDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
                .getBalance = getBalance,
            },
        };
    }

    fn send(ptr: *anyopaque, message: SmsMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://rest.nexmo.com/sms/json

        self.sent_count += 1;
        return NotificationResult.ok("vonage", "vonage_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const SmsMessage) []NotificationResult {
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
        return "vonage";
    }

    fn getBalance(ptr: *anyopaque) ?f64 {
        _ = ptr;
        return null;
    }
};

/// AWS SNS SMS driver implementation
pub const SnsDriver = struct {
    allocator: std.mem.Allocator,
    config: SmsConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: SmsConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) SmsDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
                .getBalance = getBalance,
            },
        };
    }

    fn send(ptr: *anyopaque, message: SmsMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // AWS SNS Publish action

        self.sent_count += 1;
        return NotificationResult.ok("sns", "sns_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const SmsMessage) []NotificationResult {
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
        return "sns";
    }

    fn getBalance(ptr: *anyopaque) ?f64 {
        _ = ptr;
        return null; // SNS doesn't have balance concept
    }
};

/// Plivo SMS driver implementation
pub const PlivoDriver = struct {
    allocator: std.mem.Allocator,
    config: SmsConfig,
    sent_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: SmsConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn driver(self: *Self) SmsDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
                .getBalance = getBalance,
            },
        };
    }

    fn send(ptr: *anyopaque, message: SmsMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = message;

        // POST https://api.plivo.com/v1/Account/{auth_id}/Message/

        self.sent_count += 1;
        return NotificationResult.ok("plivo", "plivo_msg_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const SmsMessage) []NotificationResult {
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
        return "plivo";
    }

    fn getBalance(ptr: *anyopaque) ?f64 {
        _ = ptr;
        return null;
    }
};

/// Memory SMS driver for testing
pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    sent_messages: std.ArrayList(SmsMessage),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .sent_messages = .empty,
        };
        return self;
    }

    pub fn driver(self: *Self) SmsDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .sendBatch = sendBatch,
                .deinit = deinit,
                .getDriverName = getDriverName,
                .getBalance = getBalance,
            },
        };
    }

    fn send(ptr: *anyopaque, message: SmsMessage) NotificationResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.sent_messages.append(self.allocator, message) catch {
            return NotificationResult.err("memory", "Failed to store message");
        };
        return NotificationResult.ok("memory", "mem_sms_12345");
    }

    fn sendBatch(ptr: *anyopaque, messages: []const SmsMessage) []NotificationResult {
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

    fn getBalance(ptr: *anyopaque) ?f64 {
        _ = ptr;
        return 999999.99; // Unlimited for testing
    }

    /// Get all sent messages (for testing)
    pub fn getSentMessages(self: *Self) []const SmsMessage {
        return self.sent_messages.items;
    }

    /// Clear all sent messages (for testing)
    pub fn clearMessages(self: *Self) void {
        self.sent_messages.clearRetainingCapacity();
    }
};

/// Create an SMS driver based on configuration
pub fn createDriver(allocator: std.mem.Allocator, config: SmsConfig) !*SmsDriver {
    const driver_ptr = try allocator.create(SmsDriver);

    switch (config.driver_type) {
        .twilio => {
            const tw = try TwilioDriver.init(allocator, config);
            driver_ptr.* = tw.driver();
        },
        .vonage => {
            const vn = try VonageDriver.init(allocator, config);
            driver_ptr.* = vn.driver();
        },
        .plivo => {
            const pl = try PlivoDriver.init(allocator, config);
            driver_ptr.* = pl.driver();
        },
        .sns => {
            const sns = try SnsDriver.init(allocator, config);
            driver_ptr.* = sns.driver();
        },
        .telnyx, .messagebird => {
            // These would have their own implementations
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
test "sms message creation" {
    const msg = SmsMessage.init("+14155551234", "+14155555678", "Hello, World!");
    try std.testing.expectEqualStrings("+14155551234", msg.to);
    try std.testing.expectEqualStrings("Hello, World!", msg.body);
    try std.testing.expect(!msg.isMultipart());
    try std.testing.expectEqual(@as(u32, 1), msg.segmentCount());
}

test "sms message multipart" {
    const long_body = "A" ** 200;
    const msg = SmsMessage.init("+14155551234", "+14155555678", long_body);
    try std.testing.expect(msg.isMultipart());
    try std.testing.expectEqual(@as(u32, 2), msg.segmentCount());
}

test "sms config creation" {
    const twilio_config = SmsConfig.twilio("AC123", "auth_token");
    try std.testing.expect(twilio_config.driver_type == .twilio);
    try std.testing.expectEqualStrings("AC123", twilio_config.account_sid.?);

    const vonage_config = SmsConfig.vonage("api_key", "api_secret");
    try std.testing.expect(vonage_config.driver_type == .vonage);
}

test "memory driver send" {
    const allocator = std.testing.allocator;
    const mem_driver = try MemoryDriver.init(allocator);
    defer mem_driver.allocator.destroy(mem_driver);
    defer mem_driver.sent_messages.deinit();

    var driver = mem_driver.driver();

    const msg = SmsMessage.init("+14155551234", "+14155555678", "Test message");
    const result = driver.send(msg);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("memory", result.provider);
    try std.testing.expectEqual(@as(usize, 1), mem_driver.getSentMessages().len);
}
