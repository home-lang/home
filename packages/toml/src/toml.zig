/// Home TOML Parser
///
/// A complete TOML v1.0.0 parser and serializer.
/// Supports all TOML types including inline tables, arrays of tables, and datetime.
///
/// Example usage:
/// ```home
/// const toml = try Toml.parse(
///     \\[server]
///     \\host = "localhost"
///     \\port = 8080
/// );
/// defer toml.deinit();
///
/// const host = toml.get("server.host").?.string;
/// const port = toml.get("server.port").?.integer;
/// ```
const std = @import("std");

/// TOML value types
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: DateTime,
    array: []Value,
    table: Table,

    pub fn format(self: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .boolean => |b| try writer.print("{}", .{b}),
            .datetime => |dt| try dt.format(writer),
            .array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeAll("]");
            },
            .table => |t| {
                try writer.writeAll("{ ");
                var it = t.entries.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try writer.writeAll(", ");
                    first = false;
                    try writer.print("{s} = ", .{entry.key_ptr.*});
                    try entry.value_ptr.format("", .{}, writer);
                }
                try writer.writeAll(" }");
            },
        }
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |*item| {
                    var mut_item = item.*;
                    mut_item.deinit(allocator);
                }
                allocator.free(arr);
            },
            .table => |*t| t.deinit(),
            else => {},
        }
    }

    /// Get nested value using dot notation
    pub fn get(self: *const Value, path: []const u8) ?*const Value {
        if (self.* != .table) return null;
        return self.table.get(path);
    }

    /// Convert to string
    pub fn asString(self: *const Value) ?[]const u8 {
        return switch (self.*) {
            .string => |s| s,
            else => null,
        };
    }

    /// Convert to integer
    pub fn asInteger(self: *const Value) ?i64 {
        return switch (self.*) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Convert to float
    pub fn asFloat(self: *const Value) ?f64 {
        return switch (self.*) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Convert to boolean
    pub fn asBoolean(self: *const Value) ?bool {
        return switch (self.*) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// Convert to array
    pub fn asArray(self: *const Value) ?[]const Value {
        return switch (self.*) {
            .array => |a| a,
            else => null,
        };
    }

    /// Convert to table
    pub fn asTable(self: *const Value) ?*const Table {
        return switch (self.*) {
            .table => |*t| t,
            else => null,
        };
    }
};

/// TOML table (ordered map)
pub const Table = struct {
    allocator: std.mem.Allocator,
    entries: std.StringArrayHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .allocator = allocator,
            .entries = std.StringArrayHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Table) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var val = entry.value_ptr.*;
            val.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn put(self: *Table, key: []const u8, value: Value) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.entries.put(owned_key, value);
    }

    pub fn get(self: *const Table, path: []const u8) ?*const Value {
        // Support dot notation
        var current: ?*const Value = null;
        var path_iter = std.mem.splitSequence(u8, path, ".");
        var first = true;

        while (path_iter.next()) |segment| {
            if (first) {
                current = self.entries.getPtr(segment);
                first = false;
            } else if (current) |c| {
                if (c.* == .table) {
                    current = c.table.entries.getPtr(segment);
                } else {
                    return null;
                }
            } else {
                return null;
            }
        }

        return current;
    }

    pub fn contains(self: *const Table, key: []const u8) bool {
        return self.entries.contains(key);
    }

    pub fn keys(self: *const Table) []const []const u8 {
        return self.entries.keys();
    }
};

/// TOML datetime
pub const DateTime = struct {
    year: ?u16 = null,
    month: ?u8 = null,
    day: ?u8 = null,
    hour: ?u8 = null,
    minute: ?u8 = null,
    second: ?u8 = null,
    nanosecond: ?u32 = null,
    offset_hours: ?i8 = null,
    offset_minutes: ?u8 = null,
    is_local: bool = true,

    pub fn format(self: DateTime, writer: anytype) !void {
        if (self.year) |y| {
            try writer.print("{d:0>4}", .{y});
            if (self.month) |m| {
                try writer.print("-{d:0>2}", .{m});
                if (self.day) |d| {
                    try writer.print("-{d:0>2}", .{d});
                }
            }
        }

        if (self.hour) |h| {
            if (self.year != null) try writer.writeAll("T");
            try writer.print("{d:0>2}", .{h});
            if (self.minute) |min| {
                try writer.print(":{d:0>2}", .{min});
                if (self.second) |s| {
                    try writer.print(":{d:0>2}", .{s});
                    if (self.nanosecond) |ns| {
                        if (ns > 0) {
                            try writer.print(".{d:0>9}", .{ns});
                        }
                    }
                }
            }
        }

        if (!self.is_local) {
            if (self.offset_hours) |oh| {
                if (oh == 0 and (self.offset_minutes orelse 0) == 0) {
                    try writer.writeAll("Z");
                } else {
                    const sign: u8 = if (oh >= 0) '+' else '-';
                    const abs_hours: u8 = @intCast(@abs(oh));
                    try writer.print("{c}{d:0>2}:{d:0>2}", .{ sign, abs_hours, self.offset_minutes orelse 0 });
                }
            }
        }
    }
};

/// TOML parser error types
pub const ParseError = error{
    UnexpectedCharacter,
    UnexpectedEndOfInput,
    InvalidEscapeSequence,
    InvalidNumber,
    InvalidDateTime,
    InvalidKey,
    DuplicateKey,
    InvalidTable,
    InvalidArray,
    InvalidValue,
    InvalidUnicode,
    InvalidNewlineInString,
    MixedArrayTypes,
    OutOfMemory,
};

/// TOML document
pub const Toml = struct {
    allocator: std.mem.Allocator,
    root: Table,

    pub fn init(allocator: std.mem.Allocator) Toml {
        return .{
            .allocator = allocator,
            .root = Table.init(allocator),
        };
    }

    pub fn deinit(self: *Toml) void {
        self.root.deinit();
    }

    /// Parse TOML from string
    pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Toml {
        var parser = Parser.init(allocator, input);
        return parser.parse();
    }

    /// Parse TOML from file
    pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Toml {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(content);

        return parse(allocator, content);
    }

    /// Get a value by path (dot notation)
    pub fn get(self: *const Toml, path: []const u8) ?*const Value {
        return self.root.get(path);
    }

    /// Get string value
    pub fn getString(self: *const Toml, path: []const u8) ?[]const u8 {
        const val = self.get(path) orelse return null;
        return val.asString();
    }

    /// Get integer value
    pub fn getInteger(self: *const Toml, path: []const u8) ?i64 {
        const val = self.get(path) orelse return null;
        return val.asInteger();
    }

    /// Get float value
    pub fn getFloat(self: *const Toml, path: []const u8) ?f64 {
        const val = self.get(path) orelse return null;
        return val.asFloat();
    }

    /// Get boolean value
    pub fn getBoolean(self: *const Toml, path: []const u8) ?bool {
        const val = self.get(path) orelse return null;
        return val.asBoolean();
    }

    /// Get array value
    pub fn getArray(self: *const Toml, path: []const u8) ?[]const Value {
        const val = self.get(path) orelse return null;
        return val.asArray();
    }

    /// Get table value
    pub fn getTable(self: *const Toml, path: []const u8) ?*const Table {
        const val = self.get(path) orelse return null;
        return val.asTable();
    }

    /// Serialize to TOML string
    pub fn serialize(self: *const Toml, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();

        try serializeTable(&list, &self.root, &.{});

        return list.toOwnedSlice();
    }

    fn serializeTable(list: *std.ArrayList(u8), table: *const Table, prefix: []const []const u8) !void {
        // First, write simple key-value pairs
        var it = table.entries.iterator();
        while (it.next()) |entry| {
            const val = entry.value_ptr;
            if (val.* != .table and val.* != .array) {
                try serializeValue(list, entry.key_ptr.*, val);
            } else if (val.* == .array) {
                const arr = val.array;
                if (arr.len > 0 and arr[0] != .table) {
                    try serializeValue(list, entry.key_ptr.*, val);
                }
            }
        }

        // Then write sub-tables
        it = table.entries.iterator();
        while (it.next()) |entry| {
            const val = entry.value_ptr;
            if (val.* == .table) {
                // Build full path
                var full_path = std.ArrayList([]const u8).init(list.allocator);
                defer full_path.deinit();
                for (prefix) |p| try full_path.append(p);
                try full_path.append(entry.key_ptr.*);

                try list.appendSlice("\n[");
                for (full_path.items, 0..) |p, i| {
                    if (i > 0) try list.append('.');
                    try list.appendSlice(p);
                }
                try list.appendSlice("]\n");

                try serializeTable(list, &val.table, full_path.items);
            } else if (val.* == .array) {
                const arr = val.array;
                if (arr.len > 0 and arr[0] == .table) {
                    // Array of tables
                    for (arr) |item| {
                        try list.appendSlice("\n[[");
                        for (prefix) |p| {
                            try list.appendSlice(p);
                            try list.append('.');
                        }
                        try list.appendSlice(entry.key_ptr.*);
                        try list.appendSlice("]]\n");

                        var empty_prefix: []const []const u8 = &.{};
                        try serializeTable(list, &item.table, empty_prefix);
                    }
                }
            }
        }
    }

    fn serializeValue(list: *std.ArrayList(u8), key: []const u8, value: *const Value) !void {
        try list.appendSlice(key);
        try list.appendSlice(" = ");

        switch (value.*) {
            .string => |s| {
                try list.append('"');
                for (s) |c| {
                    switch (c) {
                        '\n' => try list.appendSlice("\\n"),
                        '\r' => try list.appendSlice("\\r"),
                        '\t' => try list.appendSlice("\\t"),
                        '\\' => try list.appendSlice("\\\\"),
                        '"' => try list.appendSlice("\\\""),
                        else => try list.append(c),
                    }
                }
                try list.append('"');
            },
            .integer => |i| {
                var buf: [32]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                try list.appendSlice(slice);
            },
            .float => |f| {
                if (std.math.isNan(f)) {
                    try list.appendSlice("nan");
                } else if (std.math.isInf(f)) {
                    if (f < 0) try list.append('-');
                    try list.appendSlice("inf");
                } else {
                    var buf: [64]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
                    try list.appendSlice(slice);
                }
            },
            .boolean => |b| {
                try list.appendSlice(if (b) "true" else "false");
            },
            .datetime => |dt| {
                try dt.format(list.writer());
            },
            .array => |arr| {
                try list.append('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try list.appendSlice(", ");
                    var dummy_key: []const u8 = "";
                    _ = dummy_key;
                    switch (item) {
                        .string => |s| {
                            try list.append('"');
                            try list.appendSlice(s);
                            try list.append('"');
                        },
                        .integer => |i| {
                            var buf: [32]u8 = undefined;
                            const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                            try list.appendSlice(slice);
                        },
                        .float => |f| {
                            var buf: [64]u8 = undefined;
                            const slice = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
                            try list.appendSlice(slice);
                        },
                        .boolean => |b| {
                            try list.appendSlice(if (b) "true" else "false");
                        },
                        else => {},
                    }
                }
                try list.append(']');
            },
            .table => {
                try list.appendSlice("{ }");
            },
        }

        try list.append('\n');
    }
};

/// Internal parser
const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize,
    line: usize,
    column: usize,

    fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .line = 1,
            .column = 1,
        };
    }

    fn parse(self: *Parser) ParseError!Toml {
        var toml = Toml.init(self.allocator);
        errdefer toml.deinit();

        var current_table: *Table = &toml.root;

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.input.len) break;

            const c = self.input[self.pos];

            if (c == '[') {
                // Table header
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '[') {
                    // Array of tables [[name]]
                    self.pos += 2;
                    const path = try self.parseTablePath();
                    defer self.allocator.free(path);

                    if (self.pos < self.input.len and self.input[self.pos] == ']') self.pos += 1;
                    if (self.pos < self.input.len and self.input[self.pos] == ']') self.pos += 1;

                    current_table = try self.getOrCreateArrayTable(&toml.root, path);
                } else {
                    // Regular table [name]
                    self.pos += 1;
                    const path = try self.parseTablePath();
                    defer self.allocator.free(path);

                    if (self.pos < self.input.len and self.input[self.pos] == ']') self.pos += 1;

                    current_table = try self.getOrCreateTable(&toml.root, path);
                }
            } else if (c == '\n' or c == '\r') {
                self.advance();
            } else {
                // Key-value pair
                const key = try self.parseKey();
                errdefer self.allocator.free(key);

                self.skipWhitespace();

                if (self.pos >= self.input.len or self.input[self.pos] != '=') {
                    self.allocator.free(key);
                    return ParseError.UnexpectedCharacter;
                }
                self.pos += 1;

                self.skipWhitespace();

                const value = try self.parseValue();
                errdefer {
                    var mut_val = value;
                    mut_val.deinit(self.allocator);
                }

                if (current_table.entries.contains(key)) {
                    self.allocator.free(key);
                    return ParseError.DuplicateKey;
                }

                try current_table.entries.put(key, value);
            }
        }

        return toml;
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.advance();
            } else if (c == '#') {
                // Skip comment
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn parseTablePath(self: *Parser) ParseError![]u8 {
        var path = std.ArrayList(u8).init(self.allocator);
        errdefer path.deinit();

        self.skipWhitespace();

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ']') break;

            if (c == '"') {
                // Quoted key
                const str = try self.parseBasicString();
                try path.appendSlice(str);
                self.allocator.free(str);
            } else if (c == '\'') {
                // Literal key
                const str = try self.parseLiteralString();
                try path.appendSlice(str);
                self.allocator.free(str);
            } else if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                // Bare key
                const start = self.pos;
                while (self.pos < self.input.len) {
                    const ch = self.input[self.pos];
                    if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
                        self.advance();
                    } else {
                        break;
                    }
                }
                try path.appendSlice(self.input[start..self.pos]);
            } else if (c == '.') {
                try path.append('.');
                self.advance();
                self.skipWhitespace();
            } else if (c == ' ' or c == '\t') {
                self.skipWhitespace();
            } else {
                break;
            }
        }

        return path.toOwnedSlice();
    }

    fn parseKey(self: *Parser) ParseError![]u8 {
        self.skipWhitespace();

        if (self.pos >= self.input.len) return ParseError.UnexpectedEndOfInput;

        const c = self.input[self.pos];

        if (c == '"') {
            return self.parseBasicString();
        } else if (c == '\'') {
            return self.parseLiteralString();
        } else if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            // Bare key
            const start = self.pos;
            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
                    self.advance();
                } else {
                    break;
                }
            }
            return self.allocator.dupe(u8, self.input[start..self.pos]);
        } else {
            return ParseError.InvalidKey;
        }
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespace();

        if (self.pos >= self.input.len) return ParseError.UnexpectedEndOfInput;

        const c = self.input[self.pos];

        // String
        if (c == '"') {
            if (self.pos + 2 < self.input.len and
                self.input[self.pos + 1] == '"' and
                self.input[self.pos + 2] == '"')
            {
                return .{ .string = try self.parseMultilineBasicString() };
            }
            return .{ .string = try self.parseBasicString() };
        }

        if (c == '\'') {
            if (self.pos + 2 < self.input.len and
                self.input[self.pos + 1] == '\'' and
                self.input[self.pos + 2] == '\'')
            {
                return .{ .string = try self.parseMultilineLiteralString() };
            }
            return .{ .string = try self.parseLiteralString() };
        }

        // Array
        if (c == '[') {
            return .{ .array = try self.parseArray() };
        }

        // Inline table
        if (c == '{') {
            return .{ .table = try self.parseInlineTable() };
        }

        // Boolean
        if (self.startsWith("true")) {
            self.pos += 4;
            return .{ .boolean = true };
        }
        if (self.startsWith("false")) {
            self.pos += 5;
            return .{ .boolean = false };
        }

        // Special float values
        if (self.startsWith("nan") or self.startsWith("+nan")) {
            self.pos += if (self.input[self.pos] == '+') @as(usize, 4) else @as(usize, 3);
            return .{ .float = std.math.nan(f64) };
        }
        if (self.startsWith("-nan")) {
            self.pos += 4;
            return .{ .float = -std.math.nan(f64) };
        }
        if (self.startsWith("inf") or self.startsWith("+inf")) {
            self.pos += if (self.input[self.pos] == '+') @as(usize, 4) else @as(usize, 3);
            return .{ .float = std.math.inf(f64) };
        }
        if (self.startsWith("-inf")) {
            self.pos += 4;
            return .{ .float = -std.math.inf(f64) };
        }

        // Number or datetime
        return self.parseNumberOrDateTime();
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos .. self.pos + prefix.len], prefix);
    }

    fn parseBasicString(self: *Parser) ParseError![]u8 {
        self.pos += 1; // Skip opening quote

        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            if (c == '"') {
                self.pos += 1;
                return result.toOwnedSlice();
            }

            if (c == '\n' or c == '\r') {
                return ParseError.InvalidNewlineInString;
            }

            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.input.len) return ParseError.InvalidEscapeSequence;

                const escaped = self.input[self.pos];
                self.pos += 1;

                switch (escaped) {
                    'b' => try result.append(0x08),
                    't' => try result.append('\t'),
                    'n' => try result.append('\n'),
                    'f' => try result.append(0x0C),
                    'r' => try result.append('\r'),
                    '"' => try result.append('"'),
                    '\\' => try result.append('\\'),
                    'u' => {
                        const codepoint = try self.parseUnicodeEscape(4);
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch return ParseError.InvalidUnicode;
                        try result.appendSlice(buf[0..len]);
                    },
                    'U' => {
                        const codepoint = try self.parseUnicodeEscape(8);
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch return ParseError.InvalidUnicode;
                        try result.appendSlice(buf[0..len]);
                    },
                    else => return ParseError.InvalidEscapeSequence,
                }
            } else {
                try result.append(c);
                self.pos += 1;
            }
        }

        return ParseError.UnexpectedEndOfInput;
    }

    fn parseMultilineBasicString(self: *Parser) ParseError![]u8 {
        self.pos += 3; // Skip """

        // Skip newline immediately after opening quotes
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
        } else if (self.pos + 1 < self.input.len and
            self.input[self.pos] == '\r' and self.input[self.pos + 1] == '\n')
        {
            self.pos += 2;
        }

        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        while (self.pos < self.input.len) {
            if (self.pos + 2 < self.input.len and
                self.input[self.pos] == '"' and
                self.input[self.pos + 1] == '"' and
                self.input[self.pos + 2] == '"')
            {
                self.pos += 3;
                return result.toOwnedSlice();
            }

            const c = self.input[self.pos];

            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.input.len) return ParseError.InvalidEscapeSequence;

                const escaped = self.input[self.pos];

                // Line-ending backslash
                if (escaped == '\n' or escaped == '\r' or escaped == ' ' or escaped == '\t') {
                    // Skip whitespace and newlines
                    while (self.pos < self.input.len) {
                        const ch = self.input[self.pos];
                        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                            self.pos += 1;
                        } else {
                            break;
                        }
                    }
                    continue;
                }

                self.pos += 1;

                switch (escaped) {
                    'b' => try result.append(0x08),
                    't' => try result.append('\t'),
                    'n' => try result.append('\n'),
                    'f' => try result.append(0x0C),
                    'r' => try result.append('\r'),
                    '"' => try result.append('"'),
                    '\\' => try result.append('\\'),
                    'u' => {
                        const codepoint = try self.parseUnicodeEscape(4);
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch return ParseError.InvalidUnicode;
                        try result.appendSlice(buf[0..len]);
                    },
                    'U' => {
                        const codepoint = try self.parseUnicodeEscape(8);
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch return ParseError.InvalidUnicode;
                        try result.appendSlice(buf[0..len]);
                    },
                    else => return ParseError.InvalidEscapeSequence,
                }
            } else {
                try result.append(c);
                self.pos += 1;
            }
        }

        return ParseError.UnexpectedEndOfInput;
    }

    fn parseLiteralString(self: *Parser) ParseError![]u8 {
        self.pos += 1; // Skip opening quote

        const start = self.pos;

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            if (c == '\'') {
                const result = try self.allocator.dupe(u8, self.input[start..self.pos]);
                self.pos += 1;
                return result;
            }

            if (c == '\n' or c == '\r') {
                return ParseError.InvalidNewlineInString;
            }

            self.pos += 1;
        }

        return ParseError.UnexpectedEndOfInput;
    }

    fn parseMultilineLiteralString(self: *Parser) ParseError![]u8 {
        self.pos += 3; // Skip '''

        // Skip newline immediately after opening quotes
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
        } else if (self.pos + 1 < self.input.len and
            self.input[self.pos] == '\r' and self.input[self.pos + 1] == '\n')
        {
            self.pos += 2;
        }

        const start = self.pos;

        while (self.pos < self.input.len) {
            if (self.pos + 2 < self.input.len and
                self.input[self.pos] == '\'' and
                self.input[self.pos + 1] == '\'' and
                self.input[self.pos + 2] == '\'')
            {
                const result = try self.allocator.dupe(u8, self.input[start..self.pos]);
                self.pos += 3;
                return result;
            }

            self.pos += 1;
        }

        return ParseError.UnexpectedEndOfInput;
    }

    fn parseUnicodeEscape(self: *Parser, digits: usize) ParseError!u21 {
        if (self.pos + digits > self.input.len) return ParseError.InvalidUnicode;

        var value: u21 = 0;
        for (0..digits) |_| {
            const c = self.input[self.pos];
            const digit = std.fmt.charToDigit(c, 16) catch return ParseError.InvalidUnicode;
            value = value * 16 + digit;
            self.pos += 1;
        }

        return value;
    }

    fn parseArray(self: *Parser) ParseError![]Value {
        self.pos += 1; // Skip [

        var items = std.ArrayList(Value).init(self.allocator);
        errdefer {
            for (items.items) |*item| {
                var mut_item = item.*;
                mut_item.deinit(self.allocator);
            }
            items.deinit();
        }

        self.skipWhitespaceAndComments();

        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            const value = try self.parseValue();
            try items.append(value);

            self.skipWhitespaceAndComments();

            if (self.pos < self.input.len and self.input[self.pos] == ',') {
                self.pos += 1;
                self.skipWhitespaceAndComments();
            }
        }

        if (self.pos < self.input.len) self.pos += 1; // Skip ]

        return items.toOwnedSlice();
    }

    fn parseInlineTable(self: *Parser) ParseError!Table {
        self.pos += 1; // Skip {

        var table = Table.init(self.allocator);
        errdefer table.deinit();

        self.skipWhitespace();

        while (self.pos < self.input.len and self.input[self.pos] != '}') {
            const key = try self.parseKey();
            errdefer self.allocator.free(key);

            self.skipWhitespace();

            if (self.pos >= self.input.len or self.input[self.pos] != '=') {
                self.allocator.free(key);
                return ParseError.UnexpectedCharacter;
            }
            self.pos += 1;

            self.skipWhitespace();

            const value = try self.parseValue();
            errdefer {
                var mut_val = value;
                mut_val.deinit(self.allocator);
            }

            try table.entries.put(key, value);

            self.skipWhitespace();

            if (self.pos < self.input.len and self.input[self.pos] == ',') {
                self.pos += 1;
                self.skipWhitespace();
            }
        }

        if (self.pos < self.input.len) self.pos += 1; // Skip }

        return table;
    }

    fn parseNumberOrDateTime(self: *Parser) ParseError!Value {
        const start = self.pos;

        // Collect the token
        var has_dot = false;
        var has_exp = false;
        var has_colon = false;
        var has_dash = false;
        var has_t = false;

        // Handle sign
        if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
            self.pos += 1;
        }

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];

            if (c == '.') {
                has_dot = true;
                self.pos += 1;
            } else if (c == 'e' or c == 'E') {
                has_exp = true;
                self.pos += 1;
                // Handle exponent sign
                if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
                    self.pos += 1;
                }
            } else if (c == ':') {
                has_colon = true;
                self.pos += 1;
            } else if (c == '-') {
                has_dash = true;
                self.pos += 1;
            } else if (c == 'T' or c == 't' or c == ' ') {
                if (has_dash and self.pos + 1 < self.input.len and std.ascii.isDigit(self.input[self.pos + 1])) {
                    has_t = true;
                    self.pos += 1;
                } else {
                    break;
                }
            } else if (c == 'Z' or c == '+') {
                self.pos += 1;
            } else if (std.ascii.isDigit(c) or c == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }

        const token = self.input[start..self.pos];

        // Determine if datetime or number
        if (has_colon or (has_dash and has_t)) {
            return .{ .datetime = try self.parseDateTime(token) };
        }

        // Remove underscores for parsing
        var clean = std.ArrayList(u8).init(self.allocator);
        defer clean.deinit();

        for (token) |c| {
            if (c != '_') try clean.append(c);
        }

        const clean_token = clean.items;

        // Check for hex, octal, binary
        if (clean_token.len > 2) {
            if (clean_token[0] == '0') {
                if (clean_token[1] == 'x' or clean_token[1] == 'X') {
                    const val = std.fmt.parseInt(i64, clean_token[2..], 16) catch return ParseError.InvalidNumber;
                    return .{ .integer = val };
                }
                if (clean_token[1] == 'o' or clean_token[1] == 'O') {
                    const val = std.fmt.parseInt(i64, clean_token[2..], 8) catch return ParseError.InvalidNumber;
                    return .{ .integer = val };
                }
                if (clean_token[1] == 'b' or clean_token[1] == 'B') {
                    const val = std.fmt.parseInt(i64, clean_token[2..], 2) catch return ParseError.InvalidNumber;
                    return .{ .integer = val };
                }
            }
        }

        // Float or integer
        if (has_dot or has_exp) {
            const val = std.fmt.parseFloat(f64, clean_token) catch return ParseError.InvalidNumber;
            return .{ .float = val };
        } else {
            const val = std.fmt.parseInt(i64, clean_token, 10) catch return ParseError.InvalidNumber;
            return .{ .integer = val };
        }
    }

    fn parseDateTime(self: *Parser, token: []const u8) ParseError!DateTime {
        _ = self;
        var dt = DateTime{};

        var pos: usize = 0;

        // Parse date part (YYYY-MM-DD)
        if (token.len >= 10 and token[4] == '-' and token[7] == '-') {
            dt.year = std.fmt.parseInt(u16, token[0..4], 10) catch return ParseError.InvalidDateTime;
            dt.month = std.fmt.parseInt(u8, token[5..7], 10) catch return ParseError.InvalidDateTime;
            dt.day = std.fmt.parseInt(u8, token[8..10], 10) catch return ParseError.InvalidDateTime;
            pos = 10;

            // Skip 'T' or ' '
            if (pos < token.len and (token[pos] == 'T' or token[pos] == 't' or token[pos] == ' ')) {
                pos += 1;
            }
        }

        // Parse time part (HH:MM:SS)
        if (pos + 5 <= token.len and token[pos + 2] == ':') {
            dt.hour = std.fmt.parseInt(u8, token[pos .. pos + 2], 10) catch return ParseError.InvalidDateTime;
            dt.minute = std.fmt.parseInt(u8, token[pos + 3 .. pos + 5], 10) catch return ParseError.InvalidDateTime;
            pos += 5;

            if (pos + 3 <= token.len and token[pos] == ':') {
                dt.second = std.fmt.parseInt(u8, token[pos + 1 .. pos + 3], 10) catch return ParseError.InvalidDateTime;
                pos += 3;

                // Fractional seconds
                if (pos < token.len and token[pos] == '.') {
                    pos += 1;
                    const frac_start = pos;
                    while (pos < token.len and std.ascii.isDigit(token[pos])) {
                        pos += 1;
                    }
                    const frac = token[frac_start..pos];
                    var ns: u32 = 0;
                    for (frac, 0..) |c, i| {
                        if (i >= 9) break;
                        ns = ns * 10 + (c - '0');
                    }
                    // Pad to nanoseconds
                    for (0..9 - @min(frac.len, 9)) |_| {
                        ns *= 10;
                    }
                    dt.nanosecond = ns;
                }
            }
        }

        // Parse timezone
        if (pos < token.len) {
            if (token[pos] == 'Z') {
                dt.is_local = false;
                dt.offset_hours = 0;
                dt.offset_minutes = 0;
            } else if (token[pos] == '+' or token[pos] == '-') {
                dt.is_local = false;
                const sign: i8 = if (token[pos] == '-') -1 else 1;
                pos += 1;
                if (pos + 5 <= token.len and token[pos + 2] == ':') {
                    const hours = std.fmt.parseInt(i8, token[pos .. pos + 2], 10) catch return ParseError.InvalidDateTime;
                    const mins = std.fmt.parseInt(u8, token[pos + 3 .. pos + 5], 10) catch return ParseError.InvalidDateTime;
                    dt.offset_hours = sign * hours;
                    dt.offset_minutes = mins;
                }
            }
        }

        return dt;
    }

    fn getOrCreateTable(self: *Parser, root: *Table, path: []const u8) ParseError!*Table {
        var current = root;
        var path_iter = std.mem.splitSequence(u8, path, ".");

        while (path_iter.next()) |segment| {
            if (current.entries.getPtr(segment)) |existing| {
                if (existing.* == .table) {
                    current = &existing.table;
                } else {
                    return ParseError.InvalidTable;
                }
            } else {
                var new_table = Table.init(self.allocator);
                const key = self.allocator.dupe(u8, segment) catch return ParseError.OutOfMemory;
                current.entries.put(key, .{ .table = new_table }) catch return ParseError.OutOfMemory;
                current = &current.entries.getPtr(segment).?.table;
            }
        }

        return current;
    }

    fn getOrCreateArrayTable(self: *Parser, root: *Table, path: []const u8) ParseError!*Table {
        var current = root;
        var path_iter = std.mem.splitSequence(u8, path, ".");
        var segments = std.ArrayList([]const u8).init(self.allocator);
        defer segments.deinit();

        while (path_iter.next()) |segment| {
            segments.append(segment) catch return ParseError.OutOfMemory;
        }

        // Navigate to parent
        for (segments.items[0 .. segments.items.len - 1]) |segment| {
            if (current.entries.getPtr(segment)) |existing| {
                if (existing.* == .table) {
                    current = &existing.table;
                } else if (existing.* == .array) {
                    // Get last table in array
                    if (existing.array.len > 0 and existing.array[existing.array.len - 1] == .table) {
                        current = &existing.array[existing.array.len - 1].table;
                    } else {
                        return ParseError.InvalidTable;
                    }
                } else {
                    return ParseError.InvalidTable;
                }
            } else {
                var new_table = Table.init(self.allocator);
                const key = self.allocator.dupe(u8, segment) catch return ParseError.OutOfMemory;
                current.entries.put(key, .{ .table = new_table }) catch return ParseError.OutOfMemory;
                current = &current.entries.getPtr(segment).?.table;
            }
        }

        // Handle last segment as array
        const last_segment = segments.items[segments.items.len - 1];
        if (current.entries.getPtr(last_segment)) |existing| {
            if (existing.* == .array) {
                // Add new table to array
                var new_array = self.allocator.alloc(Value, existing.array.len + 1) catch return ParseError.OutOfMemory;
                @memcpy(new_array[0..existing.array.len], existing.array);
                new_array[existing.array.len] = .{ .table = Table.init(self.allocator) };
                self.allocator.free(existing.array);
                existing.array = new_array;
                return &new_array[new_array.len - 1].table;
            } else {
                return ParseError.InvalidTable;
            }
        } else {
            // Create new array with one table
            var arr = self.allocator.alloc(Value, 1) catch return ParseError.OutOfMemory;
            arr[0] = .{ .table = Table.init(self.allocator) };
            const key = self.allocator.dupe(u8, last_segment) catch return ParseError.OutOfMemory;
            current.entries.put(key, .{ .array = arr }) catch return ParseError.OutOfMemory;
            return &current.entries.getPtr(last_segment).?.array[0].table;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parse basic string" {
    var toml = try Toml.parse(std.testing.allocator,
        \\name = "Tom"
    );
    defer toml.deinit();

    try std.testing.expectEqualStrings("Tom", toml.getString("name").?);
}

test "parse integer" {
    var toml = try Toml.parse(std.testing.allocator,
        \\port = 8080
    );
    defer toml.deinit();

    try std.testing.expectEqual(@as(i64, 8080), toml.getInteger("port").?);
}

test "parse float" {
    var toml = try Toml.parse(std.testing.allocator,
        \\pi = 3.14159
    );
    defer toml.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), toml.getFloat("pi").?, 0.00001);
}

test "parse boolean" {
    var toml = try Toml.parse(std.testing.allocator,
        \\enabled = true
        \\disabled = false
    );
    defer toml.deinit();

    try std.testing.expect(toml.getBoolean("enabled").?);
    try std.testing.expect(!toml.getBoolean("disabled").?);
}

test "parse array" {
    var toml = try Toml.parse(std.testing.allocator,
        \\numbers = [1, 2, 3]
    );
    defer toml.deinit();

    const arr = toml.getArray("numbers").?;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
    try std.testing.expectEqual(@as(i64, 2), arr[1].integer);
    try std.testing.expectEqual(@as(i64, 3), arr[2].integer);
}

test "parse table" {
    var toml = try Toml.parse(std.testing.allocator,
        \\[server]
        \\host = "localhost"
        \\port = 3000
    );
    defer toml.deinit();

    try std.testing.expectEqualStrings("localhost", toml.getString("server.host").?);
    try std.testing.expectEqual(@as(i64, 3000), toml.getInteger("server.port").?);
}

test "parse nested tables" {
    var toml = try Toml.parse(std.testing.allocator,
        \\[database.connection]
        \\host = "127.0.0.1"
        \\port = 5432
    );
    defer toml.deinit();

    try std.testing.expectEqualStrings("127.0.0.1", toml.getString("database.connection.host").?);
    try std.testing.expectEqual(@as(i64, 5432), toml.getInteger("database.connection.port").?);
}

test "parse inline table" {
    var toml = try Toml.parse(std.testing.allocator,
        \\point = { x = 10, y = 20 }
    );
    defer toml.deinit();

    try std.testing.expectEqual(@as(i64, 10), toml.getInteger("point.x").?);
    try std.testing.expectEqual(@as(i64, 20), toml.getInteger("point.y").?);
}

test "parse datetime" {
    var toml = try Toml.parse(std.testing.allocator,
        \\date = 2023-12-25T10:30:00Z
    );
    defer toml.deinit();

    const val = toml.get("date").?;
    try std.testing.expect(val.* == .datetime);
    const dt = val.datetime;
    try std.testing.expectEqual(@as(u16, 2023), dt.year.?);
    try std.testing.expectEqual(@as(u8, 12), dt.month.?);
    try std.testing.expectEqual(@as(u8, 25), dt.day.?);
}

test "parse hex octal binary" {
    var toml = try Toml.parse(std.testing.allocator,
        \\hex = 0xDEADBEEF
        \\oct = 0o755
        \\bin = 0b11010110
    );
    defer toml.deinit();

    try std.testing.expectEqual(@as(i64, 0xDEADBEEF), toml.getInteger("hex").?);
    try std.testing.expectEqual(@as(i64, 0o755), toml.getInteger("oct").?);
    try std.testing.expectEqual(@as(i64, 0b11010110), toml.getInteger("bin").?);
}

test "parse comments" {
    var toml = try Toml.parse(std.testing.allocator,
        \\# This is a comment
        \\key = "value" # inline comment
    );
    defer toml.deinit();

    try std.testing.expectEqualStrings("value", toml.getString("key").?);
}
