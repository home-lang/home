const std = @import("std");

/// Message provider for validation error messages
pub const MessageProvider = struct {
    allocator: std.mem.Allocator,
    messages: std.StringHashMap([]const u8),
    locale: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var provider = Self{
            .allocator = allocator,
            .messages = std.StringHashMap([]const u8).init(allocator),
            .locale = "en",
        };

        // Initialize with default messages
        provider.loadDefaults() catch {};

        return provider;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.messages.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.messages.deinit();
    }

    fn loadDefaults(self: *Self) !void {
        try self.setMessage("required", "This field is required.");
        try self.setMessage("nullable", "This field may be empty.");
        try self.setMessage("string", "This field must be a string.");
        try self.setMessage("integer", "This field must be an integer.");
        try self.setMessage("float", "This field must be a number.");
        try self.setMessage("boolean", "This field must be true or false.");
        try self.setMessage("email", "This field must be a valid email address.");
        try self.setMessage("url", "This field must be a valid URL.");
        try self.setMessage("alpha", "This field must only contain letters.");
        try self.setMessage("alphanumeric", "This field must only contain letters and numbers.");
        try self.setMessage("numeric", "This field must only contain numbers.");
        try self.setMessage("min", "This field must be at least the minimum value.");
        try self.setMessage("max", "This field must not exceed the maximum value.");
        try self.setMessage("between", "This field must be between the minimum and maximum values.");
        try self.setMessage("min_length", "This field must be at least the minimum length.");
        try self.setMessage("max_length", "This field must not exceed the maximum length.");
        try self.setMessage("length", "This field must be exactly the specified length.");
        try self.setMessage("in_list", "The selected value is invalid.");
        try self.setMessage("not_in", "The selected value is invalid.");
        try self.setMessage("regex", "This field format is invalid.");
        try self.setMessage("confirmed", "The confirmation does not match.");
        try self.setMessage("same", "This field must match the specified field.");
        try self.setMessage("different", "This field must be different from the specified field.");
        try self.setMessage("uuid", "This field must be a valid UUID.");
        try self.setMessage("date", "This field must be a valid date.");
        try self.setMessage("ip", "This field must be a valid IP address.");
        try self.setMessage("ipv4", "This field must be a valid IPv4 address.");
        try self.setMessage("ipv6", "This field must be a valid IPv6 address.");
        try self.setMessage("json", "This field must be valid JSON.");
        try self.setMessage("accepted", "This field must be accepted.");
        try self.setMessage("digits", "This field must have the exact number of digits.");
        try self.setMessage("starts_with", "This field must start with the specified value.");
        try self.setMessage("ends_with", "This field must end with the specified value.");
        try self.setMessage("contains", "This field must contain the specified value.");
        try self.setMessage("custom", "This field is invalid.");
    }

    pub fn setMessage(self: *Self, key: []const u8, message: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);

        const v = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(v);

        // Remove old value if exists
        if (self.messages.fetchRemove(k)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }

        try self.messages.put(k, v);
    }

    pub fn getMessage(self: *Self, key: []const u8) []const u8 {
        return self.messages.get(key) orelse "Validation failed.";
    }

    /// Set locale (for future i18n support)
    pub fn setLocale(self: *Self, locale: []const u8) void {
        self.locale = locale;
    }

    /// Get current locale
    pub fn getLocale(self: *Self) []const u8 {
        return self.locale;
    }
};

/// Error message builder with placeholders
pub const MessageBuilder = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Build message with attribute placeholder
    pub fn withAttribute(self: *Self, template: []const u8, attribute: []const u8) ![]const u8 {
        return self.replace(template, ":attribute", attribute);
    }

    /// Build message with value placeholder
    pub fn withValue(self: *Self, template: []const u8, comptime key: []const u8, value: []const u8) ![]const u8 {
        return self.replace(template, ":" ++ key, value);
    }

    fn replace(self: *Self, template: []const u8, placeholder: []const u8, value: []const u8) ![]const u8 {
        const pos = std.mem.indexOf(u8, template, placeholder) orelse {
            return try self.allocator.dupe(u8, template);
        };

        const result_len = template.len - placeholder.len + value.len;
        const result = try self.allocator.alloc(u8, result_len);

        @memcpy(result[0..pos], template[0..pos]);
        @memcpy(result[pos .. pos + value.len], value);
        @memcpy(result[pos + value.len ..], template[pos + placeholder.len ..]);

        return result;
    }
};

// Tests
test "message provider defaults" {
    const allocator = std.testing.allocator;

    var provider = MessageProvider.init(allocator);
    defer provider.deinit();

    try std.testing.expectEqualStrings("This field is required.", provider.getMessage("required"));
    try std.testing.expectEqualStrings("This field must be a valid email address.", provider.getMessage("email"));
    try std.testing.expectEqualStrings("Validation failed.", provider.getMessage("nonexistent"));
}

test "message provider custom" {
    const allocator = std.testing.allocator;

    var provider = MessageProvider.init(allocator);
    defer provider.deinit();

    try provider.setMessage("required", "Please fill in this field.");
    try std.testing.expectEqualStrings("Please fill in this field.", provider.getMessage("required"));
}

test "message builder" {
    const allocator = std.testing.allocator;

    var builder = MessageBuilder.init(allocator);

    const msg = try builder.withAttribute("The :attribute field is required.", "name");
    defer allocator.free(msg);

    try std.testing.expectEqualStrings("The name field is required.", msg);
}
