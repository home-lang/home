// JSON Parser and Stringifier for Home Language
// Simple, ergonomic API for JSON manipulation

const std = @import("std");
const Allocator = std.mem.Allocator;

/// JSON Value type - represents any JSON value
pub const Value = union(enum) {
    null_value,
    bool_value: bool,
    number_value: f64,
    string_value: []const u8,
    array_value: []Value,
    object_value: Object,

    /// JSON Object type
    pub const Object = struct {
        allocator: Allocator,
        map: std.StringHashMap(Value),

        pub fn init(allocator: Allocator) Object {
            return .{
                .allocator = allocator,
                .map = std.StringHashMap(Value).init(allocator),
            };
        }

        pub fn deinit(self: *Object) void {
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            self.map.deinit();
        }

        pub fn put(self: *Object, key: []const u8, value: Value) !void {
            const owned_key = try self.allocator.dupe(u8, key);
            try self.map.put(owned_key, value);
        }

        pub fn get(self: *const Object, key: []const u8) ?Value {
            return self.map.get(key);
        }
    };

    pub fn deinit(self: Value, allocator: Allocator) void {
        switch (self) {
            .string_value => |s| allocator.free(s),
            .array_value => |arr| {
                for (arr) |item| {
                    item.deinit(allocator);
                }
                allocator.free(arr);
            },
            .object_value => |*obj| {
                var obj_mut = obj.*;
                obj_mut.deinit();
            },
            else => {},
        }
    }
};

/// JSON Parse Errors
pub const ParseError = error{
    UnexpectedEndOfInput,
    InvalidNull,
    InvalidBoolean,
    ExpectedQuote,
    UnterminatedString,
    ExpectedOpenBracket,
    ExpectedComma,
    ExpectedOpenBrace,
    ExpectedColon,
    UnexpectedCharacter,
} || Allocator.Error || std.fmt.ParseFloatError;

/// JSON Parser
pub const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .pos = 0,
        };
    }

    pub fn parse(self: *Parser) ParseError!Value {
        self.skipWhitespace();
        return try self.parseValue();
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();

        if (self.pos >= self.source.len) {
            return error.UnexpectedEndOfInput;
        }

        const char = self.source[self.pos];

        return switch (char) {
            'n' => try self.parseNull(),
            't', 'f' => try self.parseBool(),
            '"' => try self.parseString(),
            '[' => try self.parseArray(),
            '{' => try self.parseObject(),
            '-', '0'...'9' => try self.parseNumber(),
            else => error.UnexpectedCharacter,
        };
    }

    fn parseNull(self: *Parser) ParseError!Value {
        if (self.pos + 4 > self.source.len) return error.UnexpectedEndOfInput;
        if (!std.mem.eql(u8, self.source[self.pos..][0..4], "null")) {
            return error.InvalidNull;
        }
        self.pos += 4;
        return .null_value;
    }

    fn parseBool(self: *Parser) ParseError!Value {
        if (self.source[self.pos] == 't') {
            if (self.pos + 4 > self.source.len) return error.UnexpectedEndOfInput;
            if (!std.mem.eql(u8, self.source[self.pos..][0..4], "true")) {
                return error.InvalidBoolean;
            }
            self.pos += 4;
            return .{ .bool_value = true };
        } else {
            if (self.pos + 5 > self.source.len) return error.UnexpectedEndOfInput;
            if (!std.mem.eql(u8, self.source[self.pos..][0..5], "false")) {
                return error.InvalidBoolean;
            }
            self.pos += 5;
            return .{ .bool_value = false };
        }
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;

        // Handle negative sign
        if (self.source[self.pos] == '-') {
            self.pos += 1;
        }

        // Parse digits
        while (self.pos < self.source.len) : (self.pos += 1) {
            const c = self.source[self.pos];
            if (c != '.' and c != 'e' and c != 'E' and c != '+' and c != '-' and !std.ascii.isDigit(c)) {
                break;
            }
        }

        const num_str = self.source[start..self.pos];
        const value = try std.fmt.parseFloat(f64, num_str);
        return .{ .number_value = value };
    }

    fn parseString(self: *Parser) ParseError!Value {
        if (self.source[self.pos] != '"') return error.ExpectedQuote;
        self.pos += 1;

        const start = self.pos;
        while (self.pos < self.source.len) : (self.pos += 1) {
            if (self.source[self.pos] == '"') {
                const str = try self.allocator.dupe(u8, self.source[start..self.pos]);
                self.pos += 1;
                return .{ .string_value = str };
            }
            // Skip escaped characters
            if (self.source[self.pos] == '\\') {
                self.pos += 1;
            }
        }

        return error.UnterminatedString;
    }

    fn parseArray(self: *Parser) ParseError!Value {
        if (self.source[self.pos] != '[') return error.ExpectedOpenBracket;
        self.pos += 1;

        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |item| {
                item.deinit(self.allocator);
            }
            items.deinit(self.allocator);
        }

        self.skipWhitespace();

        // Empty array
        if (self.pos < self.source.len and self.source[self.pos] == ']') {
            self.pos += 1;
            return .{ .array_value = try items.toOwnedSlice(self.allocator) };
        }

        while (true) {
            const value = try self.parseValue();
            try items.append(self.allocator, value);

            self.skipWhitespace();
            if (self.pos >= self.source.len) return error.UnexpectedEndOfInput;

            if (self.source[self.pos] == ']') {
                self.pos += 1;
                return .{ .array_value = try items.toOwnedSlice(self.allocator) };
            }

            if (self.source[self.pos] != ',') return error.ExpectedComma;
            self.pos += 1;
            self.skipWhitespace();
        }
    }

    fn parseObject(self: *Parser) ParseError!Value {
        if (self.source[self.pos] != '{') return error.ExpectedOpenBrace;
        self.pos += 1;

        var obj = Value.Object.init(self.allocator);
        errdefer obj.deinit();

        self.skipWhitespace();

        // Empty object
        if (self.pos < self.source.len and self.source[self.pos] == '}') {
            self.pos += 1;
            return .{ .object_value = obj };
        }

        while (true) {
            // Parse key
            self.skipWhitespace();
            if (self.source[self.pos] != '"') return error.ExpectedQuote;

            const key_value = try self.parseString();
            defer key_value.deinit(self.allocator);

            const key = key_value.string_value;

            self.skipWhitespace();
            if (self.pos >= self.source.len or self.source[self.pos] != ':') {
                return error.ExpectedColon;
            }
            self.pos += 1;

            // Parse value
            const value = try self.parseValue();
            try obj.put(key, value);

            self.skipWhitespace();
            if (self.pos >= self.source.len) return error.UnexpectedEndOfInput;

            if (self.source[self.pos] == '}') {
                self.pos += 1;
                return .{ .object_value = obj };
            }

            if (self.source[self.pos] != ',') return error.ExpectedComma;
            self.pos += 1;
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            self.pos += 1;
        }
    }
};

/// JSON Stringifier
pub const Stringifier = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    indent_level: usize,
    pretty: bool,

    pub fn init(allocator: Allocator, pretty: bool) Stringifier {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .indent_level = 0,
            .pretty = pretty,
        };
    }

    pub fn deinit(self: *Stringifier) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn stringify(self: *Stringifier, value: Value) ![]u8 {
        try self.stringifyValue(value);
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn stringifyValue(self: *Stringifier, value: Value) Allocator.Error!void {
        switch (value) {
            .null_value => try self.buffer.appendSlice(self.allocator, "null"),
            .bool_value => |b| try self.buffer.appendSlice(self.allocator, if (b) "true" else "false"),
            .number_value => |n| {
                const str = try std.fmt.allocPrint(self.allocator, "{d}", .{n});
                defer self.allocator.free(str);
                try self.buffer.appendSlice(self.allocator, str);
            },
            .string_value => |s| {
                try self.buffer.append(self.allocator, '"');
                try self.buffer.appendSlice(self.allocator, s);
                try self.buffer.append(self.allocator, '"');
            },
            .array_value => |arr| try self.stringifyArray(arr),
            .object_value => |obj| try self.stringifyObject(obj),
        }
    }

    fn stringifyArray(self: *Stringifier, arr: []const Value) Allocator.Error!void {
        try self.buffer.append(self.allocator, '[');

        if (self.pretty and arr.len > 0) {
            self.indent_level += 1;
        }

        for (arr, 0..) |item, i| {
            if (i > 0) try self.buffer.append(self.allocator, ',');

            if (self.pretty) {
                try self.buffer.append(self.allocator, '\n');
                try self.writeIndent();
            }

            try self.stringifyValue(item);
        }

        if (self.pretty and arr.len > 0) {
            self.indent_level -= 1;
            try self.buffer.append(self.allocator, '\n');
            try self.writeIndent();
        }

        try self.buffer.append(self.allocator, ']');
    }

    fn stringifyObject(self: *Stringifier, obj: Value.Object) Allocator.Error!void {
        try self.buffer.append(self.allocator, '{');

        if (self.pretty) {
            self.indent_level += 1;
        }

        var iter = obj.map.iterator();
        var first = true;

        while (iter.next()) |entry| {
            if (!first) try self.buffer.append(self.allocator, ',');
            first = false;

            if (self.pretty) {
                try self.buffer.append(self.allocator, '\n');
                try self.writeIndent();
            }

            try self.buffer.append(self.allocator, '"');
            try self.buffer.appendSlice(self.allocator, entry.key_ptr.*);
            try self.buffer.append(self.allocator, '"');
            try self.buffer.append(self.allocator, ':');

            if (self.pretty) try self.buffer.append(self.allocator, ' ');

            try self.stringifyValue(entry.value_ptr.*);
        }

        if (self.pretty and obj.map.count() > 0) {
            self.indent_level -= 1;
            try self.buffer.append(self.allocator, '\n');
            try self.writeIndent();
        }

        try self.buffer.append(self.allocator, '}');
    }

    fn writeIndent(self: *Stringifier) Allocator.Error!void {
        var i: usize = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.buffer.appendSlice(self.allocator, "  ");
        }
    }
};

/// Convenience function to parse JSON string
pub fn parse(allocator: Allocator, source: []const u8) !Value {
    var parser = Parser.init(allocator, source);
    return try parser.parse();
}

/// Convenience function to stringify JSON value
pub fn stringify(allocator: Allocator, value: Value) ![]u8 {
    var stringifier = Stringifier.init(allocator, false);
    defer stringifier.deinit();
    return try stringifier.stringify(value);
}

/// Convenience function to stringify JSON value with pretty formatting
pub fn stringifyPretty(allocator: Allocator, value: Value) ![]u8 {
    var stringifier = Stringifier.init(allocator, true);
    defer stringifier.deinit();
    return try stringifier.stringify(value);
}

// ==================== Tests ====================

test "JSON - parse null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const value = try parse(allocator, "null");
    defer value.deinit(allocator);

    try testing.expect(value == .null_value);
}

test "JSON - parse bool" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const value_true = try parse(allocator, "true");
    defer value_true.deinit(allocator);
    try testing.expect(value_true.bool_value == true);

    const value_false = try parse(allocator, "false");
    defer value_false.deinit(allocator);
    try testing.expect(value_false.bool_value == false);
}

test "JSON - parse number" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const value = try parse(allocator, "42.5");
    defer value.deinit(allocator);

    try testing.expectEqual(@as(f64, 42.5), value.number_value);
}

test "JSON - parse string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const value = try parse(allocator, "\"hello world\"");
    defer value.deinit(allocator);

    try testing.expectEqualStrings("hello world", value.string_value);
}

test "JSON - parse array" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const value = try parse(allocator, "[1, 2, 3]");
    defer value.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), value.array_value.len);
    try testing.expectEqual(@as(f64, 1), value.array_value[0].number_value);
    try testing.expectEqual(@as(f64, 2), value.array_value[1].number_value);
    try testing.expectEqual(@as(f64, 3), value.array_value[2].number_value);
}

test "JSON - parse object" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const value = try parse(allocator, "{\"name\": \"test\", \"age\": 30}");
    defer value.deinit(allocator);

    try testing.expect(value == .object_value);

    const name = value.object_value.get("name").?;
    try testing.expectEqualStrings("test", name.string_value);

    const age = value.object_value.get("age").?;
    try testing.expectEqual(@as(f64, 30), age.number_value);
}

test "JSON - stringify null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try stringify(allocator, .null_value);
    defer allocator.free(result);

    try testing.expectEqualStrings("null", result);
}

test "JSON - stringify bool" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result_true = try stringify(allocator, .{ .bool_value = true });
    defer allocator.free(result_true);
    try testing.expectEqualStrings("true", result_true);

    const result_false = try stringify(allocator, .{ .bool_value = false });
    defer allocator.free(result_false);
    try testing.expectEqualStrings("false", result_false);
}

test "JSON - stringify number" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try stringify(allocator, .{ .number_value = 42.5 });
    defer allocator.free(result);

    try testing.expectEqualStrings("42.5", result);
}

test "JSON - parse and stringify round-trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original = "{\"name\":\"test\",\"value\":123}";
    const value = try parse(allocator, original);
    defer value.deinit(allocator);

    const result = try stringify(allocator, value);
    defer allocator.free(result);

    // Parse again to verify structure
    const reparsed = try parse(allocator, result);
    defer reparsed.deinit(allocator);

    try testing.expect(reparsed == .object_value);
}
