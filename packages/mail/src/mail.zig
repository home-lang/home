const std = @import("std");
const net = std.net;
const posix = std.posix;

/// Email address with optional display name
pub const Address = struct {
    email: []const u8,
    name: ?[]const u8 = null,

    pub fn format(self: Address, allocator: std.mem.Allocator) ![]const u8 {
        if (self.name) |n| {
            return std.fmt.allocPrint(allocator, "\"{s}\" <{s}>", .{ n, self.email });
        }
        return allocator.dupe(u8, self.email);
    }

    pub fn parse(input: []const u8) Address {
        // Simple parser: "Name" <email> or just email
        if (std.mem.indexOf(u8, input, "<")) |start| {
            if (std.mem.indexOf(u8, input, ">")) |end| {
                const email = input[start + 1 .. end];
                const name_part = std.mem.trim(u8, input[0..start], " \"");
                return .{
                    .email = email,
                    .name = if (name_part.len > 0) name_part else null,
                };
            }
        }
        return .{ .email = std.mem.trim(u8, input, " ") };
    }
};

/// Email attachment
pub const Attachment = struct {
    filename: []const u8,
    content: []const u8,
    mime_type: []const u8 = "application/octet-stream",
    content_id: ?[]const u8 = null, // For inline attachments
};

/// Email message
pub const Message = struct {
    allocator: std.mem.Allocator,
    from: ?Address = null,
    to: std.ArrayListUnmanaged(Address),
    cc: std.ArrayListUnmanaged(Address),
    bcc: std.ArrayListUnmanaged(Address),
    reply_to: ?Address = null,
    subject: ?[]const u8 = null,
    text_body: ?[]const u8 = null,
    html_body: ?[]const u8 = null,
    attachments: std.ArrayListUnmanaged(Attachment),
    headers: std.StringHashMapUnmanaged([]const u8),
    priority: Priority = .normal,

    pub const Priority = enum { low, normal, high };

    pub fn init(allocator: std.mem.Allocator) Message {
        return .{
            .allocator = allocator,
            .to = .empty,
            .cc = .empty,
            .bcc = .empty,
            .attachments = .empty,
            .headers = .empty,
        };
    }

    pub fn deinit(self: *Message) void {
        self.to.deinit(self.allocator);
        self.cc.deinit(self.allocator);
        self.bcc.deinit(self.allocator);
        self.attachments.deinit(self.allocator);
        self.headers.deinit(self.allocator);
    }

    pub fn setFrom(self: *Message, email: []const u8, name: ?[]const u8) *Message {
        self.from = .{ .email = email, .name = name };
        return self;
    }

    pub fn addTo(self: *Message, email: []const u8, name: ?[]const u8) !*Message {
        try self.to.append(self.allocator, .{ .email = email, .name = name });
        return self;
    }

    pub fn addCc(self: *Message, email: []const u8, name: ?[]const u8) !*Message {
        try self.cc.append(self.allocator, .{ .email = email, .name = name });
        return self;
    }

    pub fn addBcc(self: *Message, email: []const u8, name: ?[]const u8) !*Message {
        try self.bcc.append(self.allocator, .{ .email = email, .name = name });
        return self;
    }

    pub fn setReplyTo(self: *Message, email: []const u8, name: ?[]const u8) *Message {
        self.reply_to = .{ .email = email, .name = name };
        return self;
    }

    pub fn setSubject(self: *Message, subject: []const u8) *Message {
        self.subject = subject;
        return self;
    }

    pub fn setText(self: *Message, body: []const u8) *Message {
        self.text_body = body;
        return self;
    }

    pub fn setHtml(self: *Message, body: []const u8) *Message {
        self.html_body = body;
        return self;
    }

    pub fn addAttachment(self: *Message, filename: []const u8, content: []const u8, mime_type: []const u8) !*Message {
        try self.attachments.append(self.allocator, .{
            .filename = filename,
            .content = content,
            .mime_type = mime_type,
        });
        return self;
    }

    pub fn addHeader(self: *Message, name: []const u8, value: []const u8) !*Message {
        try self.headers.put(self.allocator, name, value);
        return self;
    }

    pub fn setPriority(self: *Message, priority: Priority) *Message {
        self.priority = priority;
        return self;
    }
};

/// SMTP configuration
pub const SmtpConfig = struct {
    host: []const u8,
    port: u16 = 587,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    encryption: Encryption = .starttls,
    timeout_ms: u32 = 30000,

    pub const Encryption = enum { none, ssl, starttls };

    pub fn gmail(username: []const u8, password: []const u8) SmtpConfig {
        return .{
            .host = "smtp.gmail.com",
            .port = 587,
            .username = username,
            .password = password,
            .encryption = .starttls,
        };
    }

    pub fn outlook(username: []const u8, password: []const u8) SmtpConfig {
        return .{
            .host = "smtp-mail.outlook.com",
            .port = 587,
            .username = username,
            .password = password,
            .encryption = .starttls,
        };
    }

    pub fn mailgun(domain: []const u8, api_key: []const u8) SmtpConfig {
        _ = domain;
        return .{
            .host = "smtp.mailgun.org",
            .port = 587,
            .username = "postmaster",
            .password = api_key,
            .encryption = .starttls,
        };
    }

    pub fn sendgrid(api_key: []const u8) SmtpConfig {
        return .{
            .host = "smtp.sendgrid.net",
            .port = 587,
            .username = "apikey",
            .password = api_key,
            .encryption = .starttls,
        };
    }
};

/// Mail transport interface
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, message: *const Message) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn send(self: Transport, message: *const Message) !void {
        return self.vtable.send(self.ptr, message);
    }

    pub fn deinit(self: Transport) void {
        self.vtable.deinit(self.ptr);
    }
};

/// SMTP Transport
pub const SmtpTransport = struct {
    allocator: std.mem.Allocator,
    config: SmtpConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: SmtpConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn transport(self: *Self) Transport {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn send(ptr: *anyopaque, message: *const Message) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        // In a real implementation, this would:
        // 1. Connect to SMTP server
        // 2. Perform EHLO handshake
        // 3. Authenticate if credentials provided
        // 4. Send MAIL FROM, RCPT TO, DATA commands
        // 5. Send message content
        // For now, this is a stub that validates the message

        // Validate message has required fields
        if (message.from == null) return error.NoFromAddress;
        if (message.to.items.len == 0) return error.NoRecipients;
        if (message.subject == null) return error.NoSubject;
        if (message.text_body == null and message.html_body == null) {
            return error.NoBody;
        }
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = Transport.VTable{
        .send = send,
        .deinit = deinitFn,
    };
};

/// Memory transport for testing
pub const MemoryTransport = struct {
    allocator: std.mem.Allocator,
    sent_messages: std.ArrayListUnmanaged(SentMessage),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub const SentMessage = struct {
        from: []const u8,
        to: []const []const u8,
        subject: []const u8,
        body: []const u8,
        sent_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .sent_messages = .empty,
            .mutex = .{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.sent_messages.items) |msg| {
            self.allocator.free(msg.from);
            for (msg.to) |t| {
                self.allocator.free(t);
            }
            self.allocator.free(msg.to);
            self.allocator.free(msg.subject);
            self.allocator.free(msg.body);
        }
        self.sent_messages.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn transport(self: *Self) Transport {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn getSentMessages(self: *Self) []const SentMessage {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sent_messages.items;
    }

    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.sent_messages.items) |msg| {
            self.allocator.free(msg.from);
            for (msg.to) |t| {
                self.allocator.free(t);
            }
            self.allocator.free(msg.to);
            self.allocator.free(msg.subject);
            self.allocator.free(msg.body);
        }
        self.sent_messages.clearRetainingCapacity();
    }

    fn getTimestamp() i64 {
        const ts = posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec;
    }

    fn send(ptr: *anyopaque, message: *const Message) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Validate
        if (message.from == null) return error.NoFromAddress;
        if (message.to.items.len == 0) return error.NoRecipients;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Copy recipients
        var to_list = try self.allocator.alloc([]const u8, message.to.items.len);
        for (message.to.items, 0..) |addr, i| {
            to_list[i] = try self.allocator.dupe(u8, addr.email);
        }

        try self.sent_messages.append(self.allocator, .{
            .from = try self.allocator.dupe(u8, message.from.?.email),
            .to = to_list,
            .subject = try self.allocator.dupe(u8, message.subject orelse ""),
            .body = try self.allocator.dupe(u8, message.text_body orelse message.html_body orelse ""),
            .sent_at = getTimestamp(),
        });
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = Transport.VTable{
        .send = send,
        .deinit = deinitFn,
    };
};

/// Simple template engine for emails
pub const Template = struct {
    allocator: std.mem.Allocator,
    content: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, content: []const u8) Self {
        return .{
            .allocator = allocator,
            .content = content,
        };
    }

    /// Render template with variables
    /// Variables are replaced using {{ variable_name }} syntax
    pub fn render(self: Self, variables: std.StringHashMap([]const u8)) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < self.content.len) {
            if (i + 1 < self.content.len and
                self.content[i] == '{' and self.content[i + 1] == '{')
            {
                // Find closing }}
                const start = i + 2;
                var end = start;
                while (end + 1 < self.content.len) {
                    if (self.content[end] == '}' and self.content[end + 1] == '}') {
                        break;
                    }
                    end += 1;
                }

                if (end + 1 < self.content.len) {
                    const var_name = std.mem.trim(u8, self.content[start..end], " ");
                    if (variables.get(var_name)) |value| {
                        try result.appendSlice(self.allocator, value);
                    } else {
                        // Keep original if variable not found
                        try result.appendSlice(self.allocator, self.content[i .. end + 2]);
                    }
                    i = end + 2;
                    continue;
                }
            }

            try result.append(self.allocator, self.content[i]);
            i += 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Render with a struct (field names become variable names)
    pub fn renderStruct(self: Self, data: anytype) ![]const u8 {
        var variables = std.StringHashMap([]const u8).init(self.allocator);
        defer variables.deinit();

        const T = @TypeOf(data);
        const fields = @typeInfo(T).@"struct".fields;

        inline for (fields) |field| {
            const value = @field(data, field.name);
            if (@TypeOf(value) == []const u8) {
                try variables.put(field.name, value);
            }
        }

        return self.render(variables);
    }
};

/// Mailer - high-level interface
pub const Mailer = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    default_from: ?Address = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, transport_impl: Transport) Self {
        return .{
            .allocator = allocator,
            .transport = transport_impl,
        };
    }

    pub fn deinit(self: *Self) void {
        self.transport.deinit();
    }

    pub fn setDefaultFrom(self: *Self, email: []const u8, name: ?[]const u8) void {
        self.default_from = .{ .email = email, .name = name };
    }

    pub fn createMessage(self: *Self) Message {
        var msg = Message.init(self.allocator);
        if (self.default_from) |from| {
            msg.from = from;
        }
        return msg;
    }

    pub fn send(self: *Self, message: *const Message) !void {
        try self.transport.send(message);
    }

    /// Quick send helper
    pub fn sendMail(
        self: *Self,
        to: []const u8,
        subject: []const u8,
        body: []const u8,
    ) !void {
        var msg = self.createMessage();
        defer msg.deinit();

        _ = try msg.addTo(to, null);
        _ = msg.setSubject(subject);
        _ = msg.setText(body);

        try self.send(&msg);
    }
};

// Base64 encoding for attachments
pub const Base64 = struct {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        const out_len = ((data.len + 2) / 3) * 4;
        var result = try allocator.alloc(u8, out_len);

        var i: usize = 0;
        var j: usize = 0;
        while (i < data.len) {
            const b0 = data[i];
            const b1 = if (i + 1 < data.len) data[i + 1] else 0;
            const b2 = if (i + 2 < data.len) data[i + 2] else 0;

            result[j] = alphabet[b0 >> 2];
            result[j + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            result[j + 2] = if (i + 1 < data.len) alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)] else '=';
            result[j + 3] = if (i + 2 < data.len) alphabet[b2 & 0x3f] else '=';

            i += 3;
            j += 4;
        }

        return result;
    }
};

// Tests
test "address parsing" {
    const addr1 = Address.parse("test@example.com");
    try std.testing.expectEqualStrings("test@example.com", addr1.email);
    try std.testing.expect(addr1.name == null);

    const addr2 = Address.parse("\"John Doe\" <john@example.com>");
    try std.testing.expectEqualStrings("john@example.com", addr2.email);
    try std.testing.expectEqualStrings("John Doe", addr2.name.?);
}

test "message builder" {
    const allocator = std.testing.allocator;

    var msg = Message.init(allocator);
    defer msg.deinit();

    _ = msg.setFrom("sender@example.com", "Sender");
    _ = try msg.addTo("recipient@example.com", "Recipient");
    _ = msg.setSubject("Test Subject");
    _ = msg.setText("Hello, World!");

    try std.testing.expectEqualStrings("sender@example.com", msg.from.?.email);
    try std.testing.expectEqual(@as(usize, 1), msg.to.items.len);
    try std.testing.expectEqualStrings("Test Subject", msg.subject.?);
}

test "memory transport" {
    const allocator = std.testing.allocator;

    const mem_transport = try MemoryTransport.init(allocator);
    var mailer = Mailer.init(allocator, mem_transport.transport());
    defer mailer.deinit();

    mailer.setDefaultFrom("noreply@example.com", "Test App");

    var msg = mailer.createMessage();
    defer msg.deinit();

    _ = try msg.addTo("user@example.com", null);
    _ = msg.setSubject("Welcome!");
    _ = msg.setText("Thanks for signing up.");

    try mailer.send(&msg);

    const sent = mem_transport.getSentMessages();
    try std.testing.expectEqual(@as(usize, 1), sent.len);
    try std.testing.expectEqualStrings("noreply@example.com", sent[0].from);
    try std.testing.expectEqualStrings("Welcome!", sent[0].subject);
}

test "template rendering" {
    const allocator = std.testing.allocator;

    const template = Template.init(allocator, "Hello, {{ name }}! Your code is {{ code }}.");

    var vars = std.StringHashMap([]const u8).init(allocator);
    defer vars.deinit();
    try vars.put("name", "John");
    try vars.put("code", "ABC123");

    const result = try template.render(vars);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, John! Your code is ABC123.", result);
}

test "base64 encoding" {
    const allocator = std.testing.allocator;

    const encoded = try Base64.encode(allocator, "Hello");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("SGVsbG8=", encoded);
}

test "smtp config presets" {
    const gmail = SmtpConfig.gmail("user@gmail.com", "password");
    try std.testing.expectEqualStrings("smtp.gmail.com", gmail.host);
    try std.testing.expectEqual(@as(u16, 587), gmail.port);

    const sendgrid = SmtpConfig.sendgrid("api-key");
    try std.testing.expectEqualStrings("smtp.sendgrid.net", sendgrid.host);
    try std.testing.expectEqualStrings("apikey", sendgrid.username.?);
}
