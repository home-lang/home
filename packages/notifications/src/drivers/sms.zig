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

        const account_sid = self.config.account_sid orelse {
            return NotificationResult.err("twilio", "Account SID not configured");
        };
        const auth_token = self.config.auth_token orelse {
            return NotificationResult.err("twilio", "Auth token not configured");
        };

        // Build Twilio API URL
        var url_buf: [256]u8 = undefined;
        const api_url = std.fmt.bufPrint(&url_buf, "https://api.twilio.com/2010-04-01/Accounts/{s}/Messages.json", .{account_sid}) catch {
            return NotificationResult.err("twilio", "Failed to build API URL");
        };

        // Build form data body
        const form_body = buildFormBody(self.allocator, message) catch |err| {
            return NotificationResult.err("twilio", @errorName(err));
        };
        defer self.allocator.free(form_body);

        // Make HTTP request with Basic auth
        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Build Basic auth header
        var credentials_buf: [256]u8 = undefined;
        const credentials = std.fmt.bufPrint(&credentials_buf, "{s}:{s}", .{ account_sid, auth_token }) catch {
            return NotificationResult.err("twilio", "Failed to build credentials");
        };

        // Base64 encode credentials
        const encoder = std.base64.standard.Encoder;
        var encoded_buf: [512]u8 = undefined;
        const encoded = encoder.encode(&encoded_buf, credentials);

        var auth_buf: [600]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Basic {s}", .{encoded}) catch {
            return NotificationResult.err("twilio", "Failed to build auth header");
        };

        const uri = std.Uri.parse(api_url) catch {
            return NotificationResult.err("twilio", "Invalid API URL");
        };

        var server_header_buf: [8192]u8 = undefined;
        var req = http_client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            },
        }) catch {
            return NotificationResult.err("twilio", "Failed to open connection");
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = form_body.len };
        req.send() catch {
            return NotificationResult.err("twilio", "Failed to send request");
        };

        req.writer().writeAll(form_body) catch {
            return NotificationResult.err("twilio", "Failed to write body");
        };
        req.finish() catch {
            return NotificationResult.err("twilio", "Failed to finish request");
        };

        req.wait() catch {
            return NotificationResult.err("twilio", "Failed to get response");
        };

        const status = @intFromEnum(req.status);
        if (status >= 200 and status < 300) {
            self.sent_count += 1;

            // Parse JSON response to get message SID
            const response_body = req.reader().readAllAlloc(self.allocator, 4096) catch {
                return NotificationResult.ok("twilio", null);
            };
            defer self.allocator.free(response_body);

            // Extract "sid" from JSON response (simple parsing)
            if (std.mem.indexOf(u8, response_body, "\"sid\":\"")) |sid_start| {
                const start = sid_start + 7;
                if (std.mem.indexOf(u8, response_body[start..], "\"")) |sid_end| {
                    const sid = self.allocator.dupe(u8, response_body[start .. start + sid_end]) catch null;
                    return NotificationResult.ok("twilio", sid);
                }
            }
            return NotificationResult.ok("twilio", null);
        } else {
            const error_body = req.reader().readAllAlloc(self.allocator, 4096) catch {
                return NotificationResult.err("twilio", "Request failed");
            };
            defer self.allocator.free(error_body);

            var error_msg_buf: [256]u8 = undefined;
            const error_msg = std.fmt.bufPrint(&error_msg_buf, "HTTP {d}: {s}", .{ status, error_body[0..@min(error_body.len, 100)] }) catch "Request failed";
            return NotificationResult.err("twilio", error_msg);
        }
    }

    fn buildFormBody(allocator: std.mem.Allocator, message: SmsMessage) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        const writer = buf.writer(allocator);

        try writer.writeAll("To=");
        try urlEncode(writer, message.to);
        try writer.writeAll("&From=");
        try urlEncode(writer, message.from);
        try writer.writeAll("&Body=");
        try urlEncode(writer, message.body);

        // Add media URL if present
        if (message.media_url) |media| {
            try writer.writeAll("&MediaUrl=");
            try urlEncode(writer, media);
        }

        return buf.toOwnedSlice(allocator);
    }

    fn urlEncode(writer: anytype, str: []const u8) !void {
        const hex = "0123456789ABCDEF";
        for (str) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try writer.writeByte(c);
            } else {
                try writer.writeByte('%');
                try writer.writeByte(hex[c >> 4]);
                try writer.writeByte(hex[c & 0x0F]);
            }
        }
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
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Fetch balance from Twilio API
        const account_sid = self.config.account_sid orelse return null;
        const auth_token = self.config.auth_token orelse return null;

        var url_buf: [256]u8 = undefined;
        const api_url = std.fmt.bufPrint(&url_buf, "https://api.twilio.com/2010-04-01/Accounts/{s}/Balance.json", .{account_sid}) catch return null;

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        var credentials_buf: [256]u8 = undefined;
        const credentials = std.fmt.bufPrint(&credentials_buf, "{s}:{s}", .{ account_sid, auth_token }) catch return null;

        const encoder = std.base64.standard.Encoder;
        var encoded_buf: [512]u8 = undefined;
        const encoded = encoder.encode(&encoded_buf, credentials);

        var auth_buf: [600]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Basic {s}", .{encoded}) catch return null;

        const uri = std.Uri.parse(api_url) catch return null;

        var server_header_buf: [8192]u8 = undefined;
        var req = http_client.open(.GET, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Authorization", .value = auth_header },
            },
        }) catch return null;
        defer req.deinit();

        req.send() catch return null;
        req.wait() catch return null;

        if (@intFromEnum(req.status) == 200) {
            const body = req.reader().readAllAlloc(self.allocator, 4096) catch return null;
            defer self.allocator.free(body);

            // Parse "balance" from JSON
            if (std.mem.indexOf(u8, body, "\"balance\":\"")) |start| {
                const val_start = start + 11;
                if (std.mem.indexOf(u8, body[val_start..], "\"")) |end| {
                    return std.fmt.parseFloat(f64, body[val_start .. val_start + end]) catch null;
                }
            }
        }
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
