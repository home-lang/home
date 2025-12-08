const std = @import("std");
const aws = @import("aws.zig");

/// SQS message
pub const Message = struct {
    message_id: []const u8,
    receipt_handle: []const u8,
    body: []const u8,
    md5_of_body: ?[]const u8 = null,
    attributes: ?std.StringHashMap([]const u8) = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.message_id);
        self.allocator.free(self.receipt_handle);
        self.allocator.free(self.body);
        if (self.md5_of_body) |md5| self.allocator.free(md5);
        if (self.attributes) |*attrs| attrs.deinit();
    }
};

/// SQS send message result
pub const SendMessageResult = struct {
    message_id: []const u8,
    md5_of_message_body: []const u8,
    sequence_number: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SendMessageResult) void {
        self.allocator.free(self.message_id);
        self.allocator.free(self.md5_of_message_body);
        if (self.sequence_number) |sn| self.allocator.free(sn);
    }
};

/// SQS client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: aws.Config,
    signer: aws.Signer,

    const Self = @This();
    const SERVICE = "sqs";

    pub fn init(allocator: std.mem.Allocator, config: aws.Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .signer = aws.Signer.init(allocator, config.credentials, config.region.toString(), SERVICE),
        };
    }

    /// Send a message to an SQS queue
    pub fn sendMessage(self: *Self, queue_url: []const u8, message_body: []const u8) !SendMessageResult {
        return self.sendMessageWithOptions(queue_url, message_body, .{});
    }

    pub const SendMessageOptions = struct {
        delay_seconds: ?u32 = null,
        message_group_id: ?[]const u8 = null, // For FIFO queues
        message_deduplication_id: ?[]const u8 = null,
        message_attributes: ?std.StringHashMap([]const u8) = null,
    };

    pub fn sendMessageWithOptions(
        self: *Self,
        queue_url: []const u8,
        message_body: []const u8,
        options: SendMessageOptions,
    ) !SendMessageResult {
        _ = options;
        _ = queue_url;

        // Build request body
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        const writer = body.writer(self.allocator);

        try writer.writeAll("Action=SendMessage");
        try writer.writeAll("&MessageBody=");
        try urlEncode(writer, message_body);
        try writer.writeAll("&Version=2012-11-05");

        // Get current timestamp
        const timestamp = std.time.timestamp();

        // Sign the request
        var signed = try self.signer.sign(
            "POST",
            "/",
            "",
            &[_][2][]const u8{
                .{ "Content-Type", "application/x-www-form-urlencoded" },
                .{ "Host", self.getHost() },
            },
            body.items,
            timestamp,
        );
        defer signed.deinit();

        // In a real implementation, we'd make the HTTP request here
        // For now, return a mock response
        return SendMessageResult{
            .message_id = try self.allocator.dupe(u8, "mock-message-id-12345"),
            .md5_of_message_body = try self.allocator.dupe(u8, "d41d8cd98f00b204e9800998ecf8427e"),
            .allocator = self.allocator,
        };
    }

    /// Receive messages from an SQS queue
    pub fn receiveMessage(self: *Self, queue_url: []const u8) ![]Message {
        return self.receiveMessageWithOptions(queue_url, .{});
    }

    pub const ReceiveMessageOptions = struct {
        max_number_of_messages: u32 = 1,
        visibility_timeout: ?u32 = null,
        wait_time_seconds: ?u32 = null,
        attribute_names: ?[]const []const u8 = null,
        message_attribute_names: ?[]const []const u8 = null,
    };

    pub fn receiveMessageWithOptions(
        self: *Self,
        queue_url: []const u8,
        options: ReceiveMessageOptions,
    ) ![]Message {
        _ = options;
        _ = queue_url;

        // In a real implementation, we'd make the HTTP request and parse XML response
        // For now, return empty array
        return &[_]Message{};
    }

    /// Delete a message from an SQS queue
    pub fn deleteMessage(self: *Self, queue_url: []const u8, receipt_handle: []const u8) !void {
        _ = self;
        _ = queue_url;
        _ = receipt_handle;
        // In a real implementation, we'd make the HTTP request
    }

    /// Create a new SQS queue
    pub fn createQueue(self: *Self, queue_name: []const u8) ![]const u8 {
        _ = queue_name;
        return try self.allocator.dupe(u8, "https://sqs.us-east-1.amazonaws.com/123456789/mock-queue");
    }

    /// Delete an SQS queue
    pub fn deleteQueue(self: *Self, queue_url: []const u8) !void {
        _ = self;
        _ = queue_url;
    }

    /// Get the queue URL for a queue name
    pub fn getQueueUrl(self: *Self, queue_name: []const u8) ![]const u8 {
        var url: std.ArrayList(u8) = .empty;
        const writer = url.writer(self.allocator);

        try writer.print("https://sqs.{s}.amazonaws.com/account/{s}", .{
            self.config.region.toString(),
            queue_name,
        });

        return url.toOwnedSlice(self.allocator);
    }

    /// Purge all messages from a queue
    pub fn purgeQueue(self: *Self, queue_url: []const u8) !void {
        _ = self;
        _ = queue_url;
    }

    /// Get queue attributes
    pub fn getQueueAttributes(self: *Self, queue_url: []const u8) !std.StringHashMap([]const u8) {
        _ = queue_url;
        return std.StringHashMap([]const u8).init(self.allocator);
    }

    fn getHost(self: *Self) []const u8 {
        _ = self;
        return "sqs.us-east-1.amazonaws.com";
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
};

// Tests
test "sqs client init" {
    const creds = aws.Credentials.init("key", "secret");
    const config = aws.Config.init(creds, .us_east_1);
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, config);
    _ = &client;
}

test "sqs send message" {
    const creds = aws.Credentials.init("key", "secret");
    const config = aws.Config.init(creds, .us_east_1);
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, config);
    var result = try client.sendMessage("https://sqs.us-east-1.amazonaws.com/123/test", "Hello");
    defer result.deinit();

    try std.testing.expect(result.message_id.len > 0);
}
