const std = @import("std");

/// JSON parser and serializer
pub const Json = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Json {
        return .{ .allocator = allocator };
    }

    /// Parse JSON string into Value
    pub fn parse(self: *Json, source: []const u8) !Value {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            source,
            .{},
        );
        defer parsed.deinit();

        return try self.convertValue(parsed.value);
    }

    /// Serialize Value to JSON string
    pub fn stringify(self: *Json, value: Value) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        try self.writeValue(&buffer.writer(), value, 0);
        return buffer.toOwnedSlice();
    }

    /// Serialize with pretty printing
    pub fn stringifyPretty(self: *Json, value: Value) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        try self.writeValuePretty(&buffer.writer(), value, 0);
        return buffer.toOwnedSlice();
    }

    fn convertValue(self: *Json, value: std.json.Value) !Value {
        return switch (value) {
            .null => Value.Null,
            .bool => |b| Value{ .Bool = b },
            .integer => |i| Value{ .Number = @floatFromInt(i) },
            .float => |f| Value{ .Number = f },
            .number_string => |s| Value{ .Number = try std.fmt.parseFloat(f64, s) },
            .string => |s| Value{ .String = try self.allocator.dupe(u8, s) },
            .array => |arr| {
                var values = try self.allocator.alloc(Value, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    values[i] = try self.convertValue(item);
                }
                return Value{ .Array = values };
            },
            .object => |obj| {
                var map = std.StringHashMap(Value).init(self.allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const val = try self.convertValue(entry.value_ptr.*);
                    try map.put(key, val);
                }
                return Value{ .Object = map };
            },
        };
    }

    fn writeValue(self: *Json, writer: anytype, value: Value, indent: usize) !void {
        _ = indent;
        switch (value) {
            .Null => try writer.writeAll("null"),
            .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .Number => |n| try writer.print("{d}", .{n}),
            .String => |s| {
                try writer.writeByte('"');
                for (s) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeByte('"');
            },
            .Array => |arr| {
                try writer.writeByte('[');
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try self.writeValue(writer, item, indent + 2);
                }
                try writer.writeByte(']');
            },
            .Object => |obj| {
                try writer.writeByte('{');
                var iter = obj.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeByte(',');
                    first = false;

                    try writer.writeByte('"');
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll("\":");
                    try self.writeValue(writer, entry.value_ptr.*, indent + 2);
                }
                try writer.writeByte('}');
            },
        }
    }

    fn writeValuePretty(self: *Json, writer: anytype, value: Value, indent: usize) !void {
        const indent_str = "  " ** 10; // Max 10 levels

        switch (value) {
            .Null => try writer.writeAll("null"),
            .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .Number => |n| try writer.print("{d}", .{n}),
            .String => |s| {
                try writer.writeByte('"');
                for (s) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeByte('"');
            },
            .Array => |arr| {
                if (arr.len == 0) {
                    try writer.writeAll("[]");
                    return;
                }

                try writer.writeAll("[\n");
                for (arr, 0..) |item, i| {
                    try writer.writeAll(indent_str[0 .. (indent + 1) * 2]);
                    try self.writeValuePretty(writer, item, indent + 1);
                    if (i < arr.len - 1) {
                        try writer.writeByte(',');
                    }
                    try writer.writeByte('\n');
                }
                try writer.writeAll(indent_str[0 .. indent * 2]);
                try writer.writeByte(']');
            },
            .Object => |obj| {
                if (obj.count() == 0) {
                    try writer.writeAll("{}");
                    return;
                }

                try writer.writeAll("{\n");
                var iter = obj.iterator();
                var i: usize = 0;
                const count = obj.count();
                while (iter.next()) |entry| {
                    try writer.writeAll(indent_str[0 .. (indent + 1) * 2]);
                    try writer.writeByte('"');
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll("\": ");
                    try self.writeValuePretty(writer, entry.value_ptr.*, indent + 1);
                    if (i < count - 1) {
                        try writer.writeByte(',');
                    }
                    try writer.writeByte('\n');
                    i += 1;
                }
                try writer.writeAll(indent_str[0 .. indent * 2]);
                try writer.writeByte('}');
            },
        }
    }
};

/// JSON value types
pub const Value = union(enum) {
    Null: void,
    Bool: bool,
    Number: f64,
    String: []const u8,
    Array: []Value,
    Object: std.StringHashMap(Value),

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .String => |s| allocator.free(s),
            .Array => |arr| {
                for (arr) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(arr);
            },
            .Object => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
            else => {},
        }
    }

    /// Get value as bool
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .Bool => |b| b,
            else => null,
        };
    }

    /// Get value as number
    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .Number => |n| n,
            else => null,
        };
    }

    /// Get value as string
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .String => |s| s,
            else => null,
        };
    }

    /// Get value as array
    pub fn asArray(self: Value) ?[]Value {
        return switch (self) {
            .Array => |a| a,
            else => null,
        };
    }

    /// Get value as object
    pub fn asObject(self: Value) ?std.StringHashMap(Value) {
        return switch (self) {
            .Object => |o| o,
            else => null,
        };
    }

    /// Get object field
    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .Object => |obj| obj.get(key),
            else => null,
        };
    }

    /// Get array element
    pub fn at(self: Value, index: usize) ?Value {
        return switch (self) {
            .Array => |arr| if (index < arr.len) arr[index] else null,
            else => null,
        };
    }
};

/// JSON Builder for constructing values
pub const Builder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn null_(self: *Builder) Value {
        _ = self;
        return Value.Null;
    }

    pub fn bool_(self: *Builder, b: bool) Value {
        _ = self;
        return Value{ .Bool = b };
    }

    pub fn number(self: *Builder, n: f64) Value {
        _ = self;
        return Value{ .Number = n };
    }

    pub fn string(self: *Builder, s: []const u8) !Value {
        return Value{ .String = try self.allocator.dupe(u8, s) };
    }

    pub fn array(self: *Builder) !ArrayBuilder {
        return ArrayBuilder{
            .allocator = self.allocator,
            .values = std.ArrayList(Value).init(self.allocator),
        };
    }

    pub fn object(self: *Builder) !ObjectBuilder {
        return ObjectBuilder{
            .allocator = self.allocator,
            .map = std.StringHashMap(Value).init(self.allocator),
        };
    }
};

pub const ArrayBuilder = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(Value),

    pub fn push(self: *ArrayBuilder, value: Value) !void {
        try self.values.append(value);
    }

    pub fn build(self: *ArrayBuilder) !Value {
        return Value{ .Array = try self.values.toOwnedSlice() };
    }
};

pub const ObjectBuilder = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(Value),

    pub fn put(self: *ObjectBuilder, key: []const u8, value: Value) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        try self.map.put(owned_key, value);
    }

    pub fn build(self: *ObjectBuilder) Value {
        return Value{ .Object = self.map };
    }
};
