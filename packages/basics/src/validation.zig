const std = @import("std");

/// Validation Library for Home
/// Declarative input validation similar to Yup/Joi/Laravel

pub const ValidationError = error{
    ValidationFailed,
    InvalidRule,
    InvalidValue,
};

/// Validation result
pub const ValidationResult = struct {
    allocator: std.mem.Allocator,
    valid: bool,
    errors: std.StringHashMap([]const []const u8),

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{
            .allocator = allocator,
            .valid = true,
            .errors = std.StringHashMap([]const []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ValidationResult) void {
        var iter = self.errors.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.errors.deinit();
    }

    pub fn addError(self: *ValidationResult, field: []const u8, message: []const u8) !void {
        self.valid = false;

        var errors = std.ArrayList([]const u8).init(self.allocator);

        if (self.errors.get(field)) |existing| {
            try errors.appendSlice(existing);
        }

        try errors.append(message);
        try self.errors.put(field, try errors.toOwnedSlice());
    }

    pub fn hasError(self: *ValidationResult, field: []const u8) bool {
        return self.errors.contains(field);
    }

    pub fn getErrors(self: *ValidationResult, field: []const u8) ?[]const []const u8 {
        return self.errors.get(field);
    }

    pub fn toJSON(self: *ValidationResult) ![]const u8 {
        var json = std.ArrayList(u8).init(self.allocator);
        const writer = json.writer();

        try writer.writeAll("{\"valid\": ");
        try writer.print("{}", .{self.valid});
        try writer.writeAll(", \"errors\": {");

        var iter = self.errors.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(", ");
            first = false;

            try writer.print("\"{s}\": [", .{entry.key_ptr.*});
            for (entry.value_ptr.*, 0..) |err_msg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{err_msg});
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("}}");
        return try json.toOwnedSlice();
    }
};

/// Rule interface
pub const Rule = struct {
    vtable: *const VTable,
    ptr: *anyopaque,

    pub const VTable = struct {
        validate: *const fn (ptr: *anyopaque, value: ?[]const u8) bool,
        message: *const fn (ptr: *anyopaque, field: []const u8) []const u8,
    };

    pub fn validate(self: *const Rule, value: ?[]const u8) bool {
        return self.vtable.validate(self.ptr, value);
    }

    pub fn message(self: *const Rule, field: []const u8) []const u8 {
        return self.vtable.message(self.ptr, field);
    }
};

/// Field validator
pub const FieldValidator = struct {
    allocator: std.mem.Allocator,
    field_name: []const u8,
    rules: std.ArrayList(Rule),
    custom_messages: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, field_name: []const u8) FieldValidator {
        return .{
            .allocator = allocator,
            .field_name = field_name,
            .rules = std.ArrayList(Rule).init(allocator),
            .custom_messages = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FieldValidator) void {
        self.rules.deinit();
        self.custom_messages.deinit();
    }

    pub fn addRule(self: *FieldValidator, rule: Rule) !*FieldValidator {
        try self.rules.append(rule);
        return self;
    }

    pub fn validate(self: *FieldValidator, value: ?[]const u8, result: *ValidationResult) !void {
        for (self.rules.items) |*rule| {
            if (!rule.validate(value)) {
                const msg = rule.message(self.field_name);
                try result.addError(self.field_name, msg);
            }
        }
    }
};

/// Validator builder
pub const Validator = struct {
    allocator: std.mem.Allocator,
    fields: std.StringHashMap(FieldValidator),

    pub fn init(allocator: std.mem.Allocator) Validator {
        return .{
            .allocator = allocator,
            .fields = std.StringHashMap(FieldValidator).init(allocator),
        };
    }

    pub fn deinit(self: *Validator) void {
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            var validator = entry.value_ptr.*;
            validator.deinit();
        }
        self.fields.deinit();
    }

    pub fn field(self: *Validator, field_name: []const u8) !*FieldValidator {
        var validator = FieldValidator.init(self.allocator, field_name);
        try self.fields.put(field_name, validator);
        return self.fields.getPtr(field_name).?;
    }

    pub fn validate(self: *Validator, data: std.StringHashMap([]const u8)) !ValidationResult {
        var result = ValidationResult.init(self.allocator);

        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            const field_name = entry.key_ptr.*;
            var field_validator = entry.value_ptr;

            const value = data.get(field_name);
            try field_validator.validate(value, &result);
        }

        return result;
    }
};

// Built-in validation rules

/// Required rule
pub const Required = struct {
    pub fn rule() Rule {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(_: *anyopaque, value: ?[]const u8) bool {
        if (value) |v| {
            return v.len > 0;
        }
        return false;
    }

    fn message(_: *anyopaque, field: []const u8) []const u8 {
        _ = field;
        return "This field is required";
    }
};

/// Email rule
pub const Email = struct {
    pub fn rule() Rule {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(_: *anyopaque, value: ?[]const u8) bool {
        const v = value orelse return true; // Optional
        return std.mem.indexOf(u8, v, "@") != null and std.mem.indexOf(u8, v, ".") != null;
    }

    fn message(_: *anyopaque, field: []const u8) []const u8 {
        _ = field;
        return "Must be a valid email address";
    }
};

/// Min length rule
pub const MinLength = struct {
    min: usize,

    pub fn rule(min: usize) MinLength {
        return .{ .min = min };
    }

    pub fn toRule(self: *MinLength) Rule {
        return .{
            .ptr = self,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(ptr: *anyopaque, value: ?[]const u8) bool {
        const self: *MinLength = @ptrCast(@alignCast(ptr));
        const v = value orelse return true;
        return v.len >= self.min;
    }

    fn message(ptr: *anyopaque, field: []const u8) []const u8 {
        const self: *MinLength = @ptrCast(@alignCast(ptr));
        _ = field;
        _ = self;
        return "Must be at least specified length";
    }
};

/// Max length rule
pub const MaxLength = struct {
    max: usize,

    pub fn rule(max: usize) MaxLength {
        return .{ .max = max };
    }

    pub fn toRule(self: *MaxLength) Rule {
        return .{
            .ptr = self,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(ptr: *anyopaque, value: ?[]const u8) bool {
        const self: *MaxLength = @ptrCast(@alignCast(ptr));
        const v = value orelse return true;
        return v.len <= self.max;
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must not exceed maximum length";
    }
};

/// Integer rule
pub const Integer = struct {
    pub fn rule() Rule {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(_: *anyopaque, value: ?[]const u8) bool {
        const v = value orelse return true;
        _ = std.fmt.parseInt(i64, v, 10) catch return false;
        return true;
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must be an integer";
    }
};

/// Min value rule
pub const Min = struct {
    min: i64,

    pub fn rule(min: i64) Min {
        return .{ .min = min };
    }

    pub fn toRule(self: *Min) Rule {
        return .{
            .ptr = self,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(ptr: *anyopaque, value: ?[]const u8) bool {
        const self: *Min = @ptrCast(@alignCast(ptr));
        const v = value orelse return true;
        const num = std.fmt.parseInt(i64, v, 10) catch return false;
        return num >= self.min;
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must be at least minimum value";
    }
};

/// Max value rule
pub const Max = struct {
    max: i64,

    pub fn rule(max: i64) Max {
        return .{ .max = max };
    }

    pub fn toRule(self: *Max) Rule {
        return .{
            .ptr = self,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(ptr: *anyopaque, value: ?[]const u8) bool {
        const self: *Max = @ptrCast(@alignCast(ptr));
        const v = value orelse return true;
        const num = std.fmt.parseInt(i64, v, 10) catch return false;
        return num <= self.max;
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must not exceed maximum value";
    }
};

/// URL rule
pub const Url = struct {
    pub fn rule() Rule {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(_: *anyopaque, value: ?[]const u8) bool {
        const v = value orelse return true;
        return std.mem.startsWith(u8, v, "http://") or std.mem.startsWith(u8, v, "https://");
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must be a valid URL";
    }
};

/// Alpha rule (letters only)
pub const Alpha = struct {
    pub fn rule() Rule {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(_: *anyopaque, value: ?[]const u8) bool {
        const v = value orelse return true;
        for (v) |c| {
            if (!std.ascii.isAlphabetic(c)) return false;
        }
        return true;
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must contain only letters";
    }
};

/// Alphanumeric rule
pub const Alphanumeric = struct {
    pub fn rule() Rule {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(_: *anyopaque, value: ?[]const u8) bool {
        const v = value orelse return true;
        for (v) |c| {
            if (!std.ascii.isAlphanumeric(c)) return false;
        }
        return true;
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must contain only letters and numbers";
    }
};

/// Regex rule
pub const Regex = struct {
    pattern: []const u8,

    pub fn rule(pattern: []const u8) Regex {
        return .{ .pattern = pattern };
    }

    pub fn toRule(self: *Regex) Rule {
        return .{
            .ptr = self,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(ptr: *anyopaque, value: ?[]const u8) bool {
        const self: *Regex = @ptrCast(@alignCast(ptr));
        _ = self;
        const v = value orelse return true;
        // Would integrate with regex module
        _ = v;
        return true;
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must match the required pattern";
    }
};

/// In rule (value must be in list)
pub const In = struct {
    allocator: std.mem.Allocator,
    values: []const []const u8,

    pub fn rule(allocator: std.mem.Allocator, values: []const []const u8) In {
        return .{
            .allocator = allocator,
            .values = values,
        };
    }

    pub fn toRule(self: *In) Rule {
        return .{
            .ptr = self,
            .vtable = &.{
                .validate = validate,
                .message = message,
            },
        };
    }

    fn validate(ptr: *anyopaque, value: ?[]const u8) bool {
        const self: *In = @ptrCast(@alignCast(ptr));
        const v = value orelse return true;

        for (self.values) |allowed| {
            if (std.mem.eql(u8, v, allowed)) {
                return true;
            }
        }
        return false;
    }

    fn message(_: *anyopaque, _: []const u8) []const u8 {
        return "Must be one of the allowed values";
    }
};
