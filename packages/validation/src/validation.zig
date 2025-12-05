const std = @import("std");

// Re-export modules
pub const rules = @import("rules.zig");
pub const messages = @import("messages.zig");

/// Validation error
pub const ValidationError = struct {
    field: []const u8,
    rule: []const u8,
    message: []const u8,
};

/// Stored rules for a field
const FieldRules = struct {
    rules: []Rule,
};

/// Validation result
pub const ValidationResult = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayListUnmanaged(ValidationError),
    validated_data: std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .errors = .empty,
            .validated_data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.field);
            self.allocator.free(err.rule);
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);

        var iter = self.validated_data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.validated_data.deinit();
    }

    pub fn passes(self: *Self) bool {
        return self.errors.items.len == 0;
    }

    pub fn fails(self: *Self) bool {
        return self.errors.items.len > 0;
    }

    pub fn addError(self: *Self, field: []const u8, rule: []const u8, message: []const u8) !void {
        try self.errors.append(self.allocator, .{
            .field = try self.allocator.dupe(u8, field),
            .rule = try self.allocator.dupe(u8, rule),
            .message = try self.allocator.dupe(u8, message),
        });
    }

    pub fn getErrors(self: *Self, field: []const u8) []const ValidationError {
        var count: usize = 0;
        for (self.errors.items) |err| {
            if (std.mem.eql(u8, err.field, field)) {
                count += 1;
            }
        }

        if (count == 0) return &[_]ValidationError{};

        // Return all errors for field
        const result = self.allocator.alloc(ValidationError, count) catch return &[_]ValidationError{};
        var idx: usize = 0;
        for (self.errors.items) |err| {
            if (std.mem.eql(u8, err.field, field)) {
                result[idx] = err;
                idx += 1;
            }
        }
        return result;
    }

    pub fn firstError(self: *Self, field: []const u8) ?[]const u8 {
        for (self.errors.items) |err| {
            if (std.mem.eql(u8, err.field, field)) {
                return err.message;
            }
        }
        return null;
    }

    pub fn allErrors(self: *Self) []const ValidationError {
        return self.errors.items;
    }
};

/// Rule type union
pub const Rule = union(enum) {
    required: void,
    nullable: void,
    string: void,
    integer: void,
    float: void,
    boolean: void,
    email: void,
    url: void,
    alpha: void,
    alphanumeric: void,
    numeric: void,
    min: usize,
    max: usize,
    between: struct { min: usize, max: usize },
    min_length: usize,
    max_length: usize,
    length: usize,
    in_list: []const []const u8,
    not_in: []const []const u8,
    regex: []const u8,
    confirmed: []const u8, // field name of confirmation
    same: []const u8, // field name to compare
    different: []const u8, // field name to differ from
    uuid: void,
    date: void,
    ip: void,
    ipv4: void,
    ipv6: void,
    json: void,
    accepted: void, // true, "true", "yes", "on", "1"
    digits: usize,
    starts_with: []const u8,
    ends_with: []const u8,
    contains: []const u8,
    custom: *const fn (value: ?[]const u8, data: std.StringHashMap([]const u8)) bool,
};

/// Validator for request data
pub const Validator = struct {
    allocator: std.mem.Allocator,
    rules_map: std.StringHashMap([]Rule),
    custom_messages: std.StringHashMap([]const u8),
    message_provider: messages.MessageProvider,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .rules_map = std.StringHashMap([]Rule).init(allocator),
            .custom_messages = std.StringHashMap([]const u8).init(allocator),
            .message_provider = messages.MessageProvider.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.rules_map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.rules_map.deinit();

        var msg_iter = self.custom_messages.iterator();
        while (msg_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.custom_messages.deinit();

        self.message_provider.deinit();
    }

    /// Add rules for a field
    pub fn addRules(self: *Self, field: []const u8, field_rules: []const Rule) !void {
        const key = try self.allocator.dupe(u8, field);
        errdefer self.allocator.free(key);

        const rules_copy = try self.allocator.alloc(Rule, field_rules.len);
        @memcpy(rules_copy, field_rules);

        try self.rules_map.put(key, rules_copy);
    }

    /// Add custom error message for field.rule
    pub fn setMessage(self: *Self, key: []const u8, message: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);

        const v = try self.allocator.dupe(u8, message);
        try self.custom_messages.put(k, v);
    }

    /// Validate data against rules
    pub fn validate(self: *Self, data: std.StringHashMap([]const u8)) !ValidationResult {
        var result = ValidationResult.init(self.allocator);
        errdefer result.deinit();

        var iter = self.rules_map.iterator();
        while (iter.next()) |entry| {
            const field = entry.key_ptr.*;
            const field_rules = entry.value_ptr.*;
            const value = data.get(field);

            // Check if field is nullable
            var is_nullable = false;
            for (field_rules) |rule| {
                if (rule == .nullable) {
                    is_nullable = true;
                    break;
                }
            }

            // Skip validation if nullable and value is null/empty
            if (is_nullable and (value == null or value.?.len == 0)) {
                continue;
            }

            // Validate each rule
            for (field_rules) |rule| {
                const passed = self.validateRule(field, rule, value, data);
                if (!passed) {
                    const message = self.getMessage(field, rule);
                    try result.addError(field, getRuleName(rule), message);
                }
            }

            // Store validated value
            if (value) |v| {
                const key_copy = try self.allocator.dupe(u8, field);
                const val_copy = try self.allocator.dupe(u8, v);
                try result.validated_data.put(key_copy, val_copy);
            }
        }

        return result;
    }

    fn validateRule(self: *Self, field: []const u8, rule: Rule, value: ?[]const u8, data: std.StringHashMap([]const u8)) bool {
        _ = self;
        _ = field;

        return switch (rule) {
            .required => value != null and value.?.len > 0,
            .nullable => true,
            .string => value != null,
            .integer => if (value) |v| rules.isInteger(v) else true,
            .float => if (value) |v| rules.isFloat(v) else true,
            .boolean => if (value) |v| rules.isBoolean(v) else true,
            .email => if (value) |v| rules.isEmail(v) else true,
            .url => if (value) |v| rules.isUrl(v) else true,
            .alpha => if (value) |v| rules.isAlpha(v) else true,
            .alphanumeric => if (value) |v| rules.isAlphanumeric(v) else true,
            .numeric => if (value) |v| rules.isNumeric(v) else true,
            .min => |min| if (value) |v| rules.minValue(v, min) else true,
            .max => |max| if (value) |v| rules.maxValue(v, max) else true,
            .between => |b| if (value) |v| rules.between(v, b.min, b.max) else true,
            .min_length => |min| if (value) |v| v.len >= min else true,
            .max_length => |max| if (value) |v| v.len <= max else true,
            .length => |len| if (value) |v| v.len == len else true,
            .in_list => |list| if (value) |v| rules.inList(v, list) else true,
            .not_in => |list| if (value) |v| !rules.inList(v, list) else true,
            .regex => |pattern| if (value) |v| rules.matchesRegex(v, pattern) else true,
            .confirmed => |confirm_field| blk: {
                const confirm_value = data.get(confirm_field);
                if (value == null and confirm_value == null) break :blk true;
                if (value == null or confirm_value == null) break :blk false;
                break :blk std.mem.eql(u8, value.?, confirm_value.?);
            },
            .same => |other_field| blk: {
                const other_value = data.get(other_field);
                if (value == null and other_value == null) break :blk true;
                if (value == null or other_value == null) break :blk false;
                break :blk std.mem.eql(u8, value.?, other_value.?);
            },
            .different => |other_field| blk: {
                const other_value = data.get(other_field);
                if (value == null or other_value == null) break :blk true;
                break :blk !std.mem.eql(u8, value.?, other_value.?);
            },
            .uuid => if (value) |v| rules.isUuid(v) else true,
            .date => if (value) |v| rules.isDate(v) else true,
            .ip => if (value) |v| rules.isIp(v) else true,
            .ipv4 => if (value) |v| rules.isIpv4(v) else true,
            .ipv6 => if (value) |v| rules.isIpv6(v) else true,
            .json => if (value) |v| rules.isJson(v) else true,
            .accepted => if (value) |v| rules.isAccepted(v) else false,
            .digits => |count| if (value) |v| rules.hasDigits(v, count) else true,
            .starts_with => |prefix| if (value) |v| std.mem.startsWith(u8, v, prefix) else true,
            .ends_with => |suffix| if (value) |v| std.mem.endsWith(u8, v, suffix) else true,
            .contains => |substr| if (value) |v| std.mem.indexOf(u8, v, substr) != null else true,
            .custom => |func| func(value, data),
        };
    }

    fn getMessage(self: *Self, field: []const u8, rule: Rule) []const u8 {
        const rule_name = getRuleName(rule);

        // Check for custom message: field.rule
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ field, rule_name }) catch return "Validation failed";

        if (self.custom_messages.get(key)) |custom| {
            return custom;
        }

        // Fall back to default message
        return self.message_provider.getMessage(rule_name);
    }
};

fn getRuleName(rule: Rule) []const u8 {
    return switch (rule) {
        .required => "required",
        .nullable => "nullable",
        .string => "string",
        .integer => "integer",
        .float => "float",
        .boolean => "boolean",
        .email => "email",
        .url => "url",
        .alpha => "alpha",
        .alphanumeric => "alphanumeric",
        .numeric => "numeric",
        .min => "min",
        .max => "max",
        .between => "between",
        .min_length => "min_length",
        .max_length => "max_length",
        .length => "length",
        .in_list => "in_list",
        .not_in => "not_in",
        .regex => "regex",
        .confirmed => "confirmed",
        .same => "same",
        .different => "different",
        .uuid => "uuid",
        .date => "date",
        .ip => "ip",
        .ipv4 => "ipv4",
        .ipv6 => "ipv6",
        .json => "json",
        .accepted => "accepted",
        .digits => "digits",
        .starts_with => "starts_with",
        .ends_with => "ends_with",
        .contains => "contains",
        .custom => "custom",
    };
}

/// Quick validation helper
pub fn make(allocator: std.mem.Allocator, data: std.StringHashMap([]const u8), field_rules: anytype) !ValidationResult {
    var validator = Validator.init(allocator);
    defer validator.deinit();

    // Add rules from tuple
    inline for (field_rules) |fr| {
        try validator.addRules(fr[0], fr[1]);
    }

    return validator.validate(data);
}

// Tests
test "validator basic" {
    const allocator = std.testing.allocator;

    var validator = Validator.init(allocator);
    defer validator.deinit();

    try validator.addRules("name", &[_]Rule{ .required, .{ .min_length = 3 } });
    try validator.addRules("email", &[_]Rule{ .required, .email });

    // Test with valid data
    var data = std.StringHashMap([]const u8).init(allocator);
    defer data.deinit();
    try data.put("name", "John");
    try data.put("email", "john@example.com");

    var result = try validator.validate(data);
    defer result.deinit();

    try std.testing.expect(result.passes());
}

test "validator fails" {
    const allocator = std.testing.allocator;

    var validator = Validator.init(allocator);
    defer validator.deinit();

    try validator.addRules("name", &[_]Rule{.required});
    try validator.addRules("email", &[_]Rule{.email});

    // Test with invalid data
    var data = std.StringHashMap([]const u8).init(allocator);
    defer data.deinit();
    try data.put("name", "");
    try data.put("email", "not-an-email");

    var result = try validator.validate(data);
    defer result.deinit();

    try std.testing.expect(result.fails());
    try std.testing.expect(result.errors.items.len == 2);
}

test "validator nullable" {
    const allocator = std.testing.allocator;

    var validator = Validator.init(allocator);
    defer validator.deinit();

    try validator.addRules("nickname", &[_]Rule{ .nullable, .{ .min_length = 3 } });

    // Test with empty data (should pass because nullable)
    var data = std.StringHashMap([]const u8).init(allocator);
    defer data.deinit();

    var result = try validator.validate(data);
    defer result.deinit();

    try std.testing.expect(result.passes());
}
