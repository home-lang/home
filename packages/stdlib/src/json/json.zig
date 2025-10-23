const std = @import("std");

/// JSON parser and serializer
/// Supports all JSON types: object, array, string, number, boolean, null
pub const Json = struct {
    allocator: std.mem.Allocator,

    pub const Value = union(enum) {
        object: std.StringHashMap(Value),
        array: std.ArrayList(Value),
        string: []const u8,
        number: f64,
        boolean: bool,
        null: void,

        pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .object => |*obj| {
                    var it = obj.valueIterator();
                    while (it.next()) |val| {
                        var v = val.*;
                        v.deinit(allocator);
                    }
                    obj.deinit();
                },
                .array => |*arr| {
                    for (arr.items) |*item| {
                        item.deinit(allocator);
                    }
                    arr.deinit();
                },
                .string => |s| allocator.free(s),
                else => {},
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) Json {
        return .{ .allocator = allocator };
    }

    /// Parse JSON string into Value
    pub fn parse(self: *Json, input: []const u8) !Value {
        var parser = Parser{
            .allocator = self.allocator,
            .input = input,
            .pos = 0,
        };
        return try parser.parseValue();
    }

    /// Stringify Value into JSON string
    pub fn stringify(self: *Json, value: Value, writer: anytype) !void {
        _ = self;
        try stringifyValue(value, writer, 0);
    }

    fn stringifyValue(value: Value, writer: anytype, indent: usize) !void {
        switch (value) {
            .object => |obj| {
                try writer.writeAll("{");
                if (obj.count() > 0) {
                    try writer.writeAll("\n");

                    var it = obj.iterator();
                    var first = true;
                    while (it.next()) |entry| {
                        if (!first) {
                            try writer.writeAll(",\n");
                        }
                        first = false;

                        try writeIndent(writer, indent + 1);
                        try writer.print("\"{s}\": ", .{entry.key_ptr.*});
                        try stringifyValue(entry.value_ptr.*, writer, indent + 1);
                    }

                    try writer.writeAll("\n");
                    try writeIndent(writer, indent);
                }
                try writer.writeAll("}");
            },
            .array => |arr| {
                try writer.writeAll("[");
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try stringifyValue(item, writer, indent);
                }
                try writer.writeAll("]");
            },
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .number => |n| try writer.print("{d}", .{n}),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .null => try writer.writeAll("null"),
        }
    }

    fn writeIndent(writer: anytype, indent: usize) !void {
        var i: usize = 0;
        while (i < indent * 2) : (i += 1) {
            try writer.writeAll(" ");
        }
    }

    const Parser = struct {
        allocator: std.mem.Allocator,
        input: []const u8,
        pos: usize,

        fn parseValue(self: *Parser) !Value {
            self.skipWhitespace();

            if (self.pos >= self.input.len) return error.UnexpectedEof;

            const c = self.input[self.pos];
            return switch (c) {
                '{' => try self.parseObject(),
                '[' => try self.parseArray(),
                '"' => try self.parseString(),
                't', 'f' => try self.parseBoolean(),
                'n' => try self.parseNull(),
                '-', '0'...'9' => try self.parseNumber(),
                else => error.UnexpectedCharacter,
            };
        }

        fn parseObject(self: *Parser) !Value {
            self.pos += 1; // consume '{'

            var obj = std.StringHashMap(Value).init(self.allocator);
            errdefer obj.deinit();

            self.skipWhitespace();

            if (self.pos < self.input.len and self.input[self.pos] == '}') {
                self.pos += 1;
                return Value{ .object = obj };
            }

            while (true) {
                self.skipWhitespace();

                // Parse key
                if (self.pos >= self.input.len or self.input[self.pos] != '"') {
                    return error.ExpectedString;
                }
                const key_value = try self.parseString();
                const key = key_value.string;

                self.skipWhitespace();

                // Expect colon
                if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                    return error.ExpectedColon;
                }
                self.pos += 1;

                // Parse value
                const value = try self.parseValue();
                try obj.put(key, value);

                self.skipWhitespace();

                if (self.pos >= self.input.len) return error.UnexpectedEof;

                if (self.input[self.pos] == '}') {
                    self.pos += 1;
                    break;
                }

                if (self.input[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                }

                return error.UnexpectedCharacter;
            }

            return Value{ .object = obj };
        }

        fn parseArray(self: *Parser) !Value {
            self.pos += 1; // consume '['

            var arr = std.ArrayList(Value).init(self.allocator);
            errdefer arr.deinit();

            self.skipWhitespace();

            if (self.pos < self.input.len and self.input[self.pos] == ']') {
                self.pos += 1;
                return Value{ .array = arr };
            }

            while (true) {
                const value = try self.parseValue();
                try arr.append(value);

                self.skipWhitespace();

                if (self.pos >= self.input.len) return error.UnexpectedEof;

                if (self.input[self.pos] == ']') {
                    self.pos += 1;
                    break;
                }

                if (self.input[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                }

                return error.UnexpectedCharacter;
            }

            return Value{ .array = arr };
        }

        fn parseString(self: *Parser) !Value {
            self.pos += 1; // consume opening quote

            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != '"') {
                if (self.input[self.pos] == '\\') {
                    self.pos += 1; // skip escaped character
                }
                self.pos += 1;
            }

            if (self.pos >= self.input.len) return error.UnexpectedEof;

            const str = try self.allocator.dupe(u8, self.input[start..self.pos]);
            self.pos += 1; // consume closing quote

            return Value{ .string = str };
        }

        fn parseNumber(self: *Parser) !Value {
            const start = self.pos;

            if (self.input[self.pos] == '-') {
                self.pos += 1;
            }

            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.pos += 1;
            }

            if (self.pos < self.input.len and self.input[self.pos] == '.') {
                self.pos += 1;
                while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                    self.pos += 1;
                }
            }

            if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                    self.pos += 1;
                }
            }

            const num_str = self.input[start..self.pos];
            const num = try std.fmt.parseFloat(f64, num_str);

            return Value{ .number = num };
        }

        fn parseBoolean(self: *Parser) !Value {
            if (self.pos + 4 <= self.input.len and std.mem.eql(u8, self.input[self.pos .. self.pos + 4], "true")) {
                self.pos += 4;
                return Value{ .boolean = true };
            }

            if (self.pos + 5 <= self.input.len and std.mem.eql(u8, self.input[self.pos .. self.pos + 5], "false")) {
                self.pos += 5;
                return Value{ .boolean = false };
            }

            return error.InvalidBoolean;
        }

        fn parseNull(self: *Parser) !Value {
            if (self.pos + 4 <= self.input.len and std.mem.eql(u8, self.input[self.pos .. self.pos + 4], "null")) {
                self.pos += 4;
                return Value{ .null = {} };
            }

            return error.InvalidNull;
        }

        fn skipWhitespace(self: *Parser) void {
            while (self.pos < self.input.len) {
                switch (self.input[self.pos]) {
                    ' ', '\t', '\n', '\r' => self.pos += 1,
                    else => break,
                }
            }
        }
    };
};
