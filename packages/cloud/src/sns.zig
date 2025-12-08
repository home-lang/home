const std = @import("std");
const aws = @import("aws.zig");

/// SNS message attributes
pub const MessageAttribute = struct {
    data_type: []const u8, // String, Number, Binary
    string_value: ?[]const u8 = null,
    binary_value: ?[]const u8 = null,
};

/// Publish result
pub const PublishResult = struct {
    message_id: []const u8,
    sequence_number: ?[]const u8 = null, // For FIFO topics
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PublishResult) void {
        self.allocator.free(self.message_id);
        if (self.sequence_number) |sn| self.allocator.free(sn);
    }
};

/// Topic attributes
pub const TopicAttributes = struct {
    topic_arn: []const u8,
    display_name: ?[]const u8 = null,
    delivery_policy: ?[]const u8 = null,
    effective_delivery_policy: ?[]const u8 = null,
    subscriptions_confirmed: u32 = 0,
    subscriptions_pending: u32 = 0,
    subscriptions_deleted: u32 = 0,
};

/// Subscription
pub const Subscription = struct {
    subscription_arn: []const u8,
    owner: []const u8,
    protocol: []const u8,
    endpoint: []const u8,
    topic_arn: []const u8,
};

/// SNS protocols
pub const Protocol = enum {
    http,
    https,
    email,
    email_json,
    sms,
    sqs,
    application,
    lambda,
    firehose,

    pub fn toString(self: Protocol) []const u8 {
        return switch (self) {
            .http => "http",
            .https => "https",
            .email => "email",
            .email_json => "email-json",
            .sms => "sms",
            .sqs => "sqs",
            .application => "application",
            .lambda => "lambda",
            .firehose => "firehose",
        };
    }
};

/// SNS client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: aws.Config,
    signer: aws.Signer,

    const Self = @This();
    const SERVICE = "sns";

    pub fn init(allocator: std.mem.Allocator, config: aws.Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .signer = aws.Signer.init(allocator, config.credentials, config.region.toString(), SERVICE),
        };
    }

    /// Publish a message to a topic
    pub fn publish(self: *Self, topic_arn: []const u8, message: []const u8) !PublishResult {
        return self.publishWithOptions(topic_arn, message, .{});
    }

    pub const PublishOptions = struct {
        subject: ?[]const u8 = null,
        message_structure: ?[]const u8 = null, // "json" for per-protocol messages
        message_attributes: ?std.StringHashMap(MessageAttribute) = null,
        message_group_id: ?[]const u8 = null, // For FIFO topics
        message_deduplication_id: ?[]const u8 = null,
    };

    pub fn publishWithOptions(
        self: *Self,
        topic_arn: []const u8,
        message: []const u8,
        options: PublishOptions,
    ) !PublishResult {
        _ = options;
        _ = message;
        _ = topic_arn;

        const timestamp = std.time.timestamp();

        var signed = try self.signer.sign(
            "POST",
            "/",
            "",
            &[_][2][]const u8{
                .{ "Content-Type", "application/x-www-form-urlencoded" },
                .{ "Host", self.getHost() },
            },
            "",
            timestamp,
        );
        defer signed.deinit();

        return PublishResult{
            .message_id = try self.allocator.dupe(u8, "sns-mock-message-id-12345"),
            .allocator = self.allocator,
        };
    }

    /// Publish to a phone number (SMS)
    pub fn publishSms(self: *Self, phone_number: []const u8, message: []const u8) !PublishResult {
        _ = phone_number;
        _ = message;

        return PublishResult{
            .message_id = try self.allocator.dupe(u8, "sns-sms-mock-message-id"),
            .allocator = self.allocator,
        };
    }

    /// Create a new topic
    pub fn createTopic(self: *Self, name: []const u8) ![]const u8 {
        var arn: std.ArrayList(u8) = .empty;
        const writer = arn.writer(self.allocator);

        try writer.print("arn:aws:sns:{s}:123456789012:{s}", .{
            self.config.region.toString(),
            name,
        });

        return arn.toOwnedSlice(self.allocator);
    }

    /// Delete a topic
    pub fn deleteTopic(self: *Self, topic_arn: []const u8) !void {
        _ = self;
        _ = topic_arn;
    }

    /// List all topics
    pub fn listTopics(self: *Self) ![][]const u8 {
        return &[_][]const u8{};
    }

    /// Subscribe to a topic
    pub fn subscribe(
        self: *Self,
        topic_arn: []const u8,
        protocol: Protocol,
        endpoint: []const u8,
    ) ![]const u8 {
        _ = endpoint;
        _ = protocol;
        _ = topic_arn;

        return try self.allocator.dupe(u8, "arn:aws:sns:us-east-1:123456789012:mock-subscription");
    }

    /// Confirm a subscription
    pub fn confirmSubscription(
        self: *Self,
        topic_arn: []const u8,
        token: []const u8,
    ) ![]const u8 {
        _ = token;
        _ = topic_arn;

        return try self.allocator.dupe(u8, "arn:aws:sns:us-east-1:123456789012:confirmed-subscription");
    }

    /// Unsubscribe from a topic
    pub fn unsubscribe(self: *Self, subscription_arn: []const u8) !void {
        _ = self;
        _ = subscription_arn;
    }

    /// List subscriptions for a topic
    pub fn listSubscriptionsByTopic(self: *Self, topic_arn: []const u8) ![]Subscription {
        _ = topic_arn;
        return &[_]Subscription{};
    }

    /// Get topic attributes
    pub fn getTopicAttributes(self: *Self, topic_arn: []const u8) !TopicAttributes {
        return TopicAttributes{
            .topic_arn = try self.allocator.dupe(u8, topic_arn),
        };
    }

    /// Set topic attributes
    pub fn setTopicAttributes(
        self: *Self,
        topic_arn: []const u8,
        attribute_name: []const u8,
        attribute_value: []const u8,
    ) !void {
        _ = self;
        _ = topic_arn;
        _ = attribute_name;
        _ = attribute_value;
    }

    /// Create a platform endpoint for push notifications
    pub fn createPlatformEndpoint(
        self: *Self,
        platform_application_arn: []const u8,
        token: []const u8,
    ) ![]const u8 {
        _ = token;
        _ = platform_application_arn;

        return try self.allocator.dupe(u8, "arn:aws:sns:us-east-1:123456789012:endpoint/mock");
    }

    /// Delete a platform endpoint
    pub fn deleteEndpoint(self: *Self, endpoint_arn: []const u8) !void {
        _ = self;
        _ = endpoint_arn;
    }

    /// Publish to an endpoint (push notification)
    pub fn publishToEndpoint(
        self: *Self,
        endpoint_arn: []const u8,
        message: []const u8,
    ) !PublishResult {
        _ = endpoint_arn;
        _ = message;

        return PublishResult{
            .message_id = try self.allocator.dupe(u8, "sns-push-mock-message-id"),
            .allocator = self.allocator,
        };
    }

    fn getHost(self: *Self) []const u8 {
        _ = self;
        return "sns.us-east-1.amazonaws.com";
    }
};

// Tests
test "sns client init" {
    const creds = aws.Credentials.init("key", "secret");
    const config = aws.Config.init(creds, .us_east_1);
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, config);
    _ = &client;
}

test "sns publish" {
    const creds = aws.Credentials.init("key", "secret");
    const config = aws.Config.init(creds, .us_east_1);
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, config);
    var result = try client.publish("arn:aws:sns:us-east-1:123:test", "Hello");
    defer result.deinit();

    try std.testing.expect(result.message_id.len > 0);
}

test "sns create topic" {
    const creds = aws.Credentials.init("key", "secret");
    const config = aws.Config.init(creds, .us_east_1);
    const allocator = std.testing.allocator;

    var client = Client.init(allocator, config);
    const arn = try client.createTopic("my-topic");
    defer allocator.free(arn);

    try std.testing.expect(std.mem.indexOf(u8, arn, "my-topic") != null);
}
