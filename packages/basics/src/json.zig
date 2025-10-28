const std = @import("std");

/// JSON parser and serializer for Home's standard library.
///
/// Provides parsing from JSON strings to Home Value objects and serialization
/// back to JSON. Supports both compact and pretty-printed output.
///
/// Features:
/// - Full JSON parsing (null, bool, number, string, array, object)
/// - Compact and pretty-printed serialization
/// - Builder API for constructing JSON values programmatically
/// - Type-safe accessor methods (asBool, asNumber, etc.)
///
/// Example:
/// ```zig
/// var json = Json.init(allocator);
/// const value = try json.parse("{\"name\":\"Home\",\"version\":1}");
/// defer value.deinit(allocator);
/// const pretty = try json.stringifyPretty(value);
/// defer allocator.free(pretty);
/// ```
pub const Json = struct {
    /// Memory allocator for parsing and building JSON values
    allocator: std.mem.Allocator,

    /// Create a new JSON parser/serializer.
    ///
    /// Parameters:
    ///   - allocator: Allocator for JSON values and output strings
    ///
    /// Returns: Initialized Json instance
    pub fn init(allocator: std.mem.Allocator) Json {
        return .{ .allocator = allocator };
    }

    /// Parse a JSON string into a Value.
    ///
    /// Parses the input string as JSON and converts it to Home's JSON Value
    /// representation. The returned Value must be freed with deinit().
    ///
    /// Parameters:
    ///   - source: JSON string to parse
    ///
    /// Returns: Parsed JSON value
    /// Errors: SyntaxError if JSON is malformed, OutOfMemory on allocation failure
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

    /// Serialize a Value to a compact JSON string.
    ///
    /// Converts the value to JSON with no whitespace or formatting.
    /// The returned string is owned by the caller and must be freed.
    ///
    /// Parameters:
    ///   - value: Value to serialize
    ///
    /// Returns: Compact JSON string (caller must free)
    /// Errors: OutOfMemory on allocation failure
    pub fn stringify(self: *Json, value: Value) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        try self.writeValue(&buffer.writer(), value, 0);
        return buffer.toOwnedSlice();
    }

    /// Serialize a Value to a formatted, indented JSON string.
    ///
    /// Converts the value to JSON with newlines and 2-space indentation
    /// for readability. The returned string is owned by the caller.
    ///
    /// Parameters:
    ///   - value: Value to serialize
    ///
    /// Returns: Pretty-printed JSON string (caller must free)
    /// Errors: OutOfMemory on allocation failure
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

/// JSON value types supporting all JSON data types.
///
/// A tagged union representing any JSON value. Values can be:
/// - Null: JSON null
/// - Bool: true or false
/// - Number: IEEE 754 double-precision float
/// - String: UTF-8 encoded text
/// - Array: Ordered list of values
/// - Object: Unordered map of string keys to values
///
/// Memory Management:
/// Values allocated with parse() or Builder methods must be freed
/// with deinit() to prevent memory leaks. This recursively frees
/// nested arrays and objects.
pub const Value = union(enum) {
    /// JSON null value
    Null: void,
    /// JSON boolean (true/false)
    Bool: bool,
    /// JSON number (stored as f64)
    Number: f64,
    /// JSON string (UTF-8)
    String: []const u8,
    /// JSON array (ordered values)
    Array: []Value,
    /// JSON object (key-value pairs)
    Object: std.StringHashMap(Value),

    /// Recursively free all memory used by this value.
    ///
    /// Deallocates strings, arrays, objects, and all nested values.
    /// After calling deinit(), the value must not be used.
    ///
    /// Parameters:
    ///   - allocator: The allocator used to create this value
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

    /// Try to extract a boolean value.
    ///
    /// Returns: The boolean if this is a Bool value, null otherwise
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .Bool => |b| b,
            else => null,
        };
    }

    /// Try to extract a numeric value.
    ///
    /// Returns: The number if this is a Number value, null otherwise
    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .Number => |n| n,
            else => null,
        };
    }

    /// Try to extract a string value.
    ///
    /// Returns: The string if this is a String value, null otherwise
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .String => |s| s,
            else => null,
        };
    }

    /// Try to extract an array value.
    ///
    /// Returns: The array slice if this is an Array value, null otherwise
    pub fn asArray(self: Value) ?[]Value {
        return switch (self) {
            .Array => |a| a,
            else => null,
        };
    }

    /// Try to extract an object value.
    ///
    /// Returns: The object hash map if this is an Object value, null otherwise
    pub fn asObject(self: Value) ?std.StringHashMap(Value) {
        return switch (self) {
            .Object => |o| o,
            else => null,
        };
    }

    /// Get a field from a JSON object by key.
    ///
    /// Parameters:
    ///   - key: Field name to look up
    ///
    /// Returns: The field value if this is an Object and key exists, null otherwise
    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .Object => |obj| obj.get(key),
            else => null,
        };
    }

    /// Get an element from a JSON array by index.
    ///
    /// Parameters:
    ///   - index: Zero-based array index
    ///
    /// Returns: The element if this is an Array and index is in bounds, null otherwise
    pub fn at(self: Value, index: usize) ?Value {
        return switch (self) {
            .Array => |arr| if (index < arr.len) arr[index] else null,
            else => null,
        };
    }
};

/// Builder API for programmatically constructing JSON values.
///
/// Provides a fluent interface for creating JSON values without parsing.
/// Useful for generating JSON output or building values dynamically.
///
/// Example:
/// ```zig
/// var builder = Builder.init(allocator);
/// var obj = try builder.object();
/// try obj.put("name", try builder.string("Home"));
/// try obj.put("count", builder.number(42));
/// const value = obj.build();
/// ```
pub const Builder = struct {
    /// Allocator for creating values
    allocator: std.mem.Allocator,

    /// Create a new JSON builder.
    ///
    /// Parameters:
    ///   - allocator: Allocator for JSON values
    ///
    /// Returns: Initialized Builder
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

/// Builder for JSON arrays.
///
/// Allows incrementally building a JSON array by pushing values.
pub const ArrayBuilder = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(Value),

    /// Add a value to the end of the array.
    ///
    /// Parameters:
    ///   - value: Value to append
    ///
    /// Errors: OutOfMemory on allocation failure
    pub fn push(self: *ArrayBuilder, value: Value) !void {
        try self.values.append(value);
    }

    /// Finalize the array and return it as a Value.
    ///
    /// After calling build(), the builder should not be used again.
    ///
    /// Returns: JSON array Value
    /// Errors: OutOfMemory on allocation failure
    pub fn build(self: *ArrayBuilder) !Value {
        return Value{ .Array = try self.values.toOwnedSlice() };
    }
};

/// Builder for JSON objects.
///
/// Allows incrementally building a JSON object by adding key-value pairs.
pub const ObjectBuilder = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(Value),

    /// Add a key-value pair to the object.
    ///
    /// Parameters:
    ///   - key: Field name (will be duplicated)
    ///   - value: Field value
    ///
    /// Errors: OutOfMemory on allocation failure
    pub fn put(self: *ObjectBuilder, key: []const u8, value: Value) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        try self.map.put(owned_key, value);
    }

    /// Finalize the object and return it as a Value.
    ///
    /// After calling build(), the builder should not be used again.
    ///
    /// Returns: JSON object Value
    pub fn build(self: *ObjectBuilder) Value {
        return Value{ .Object = self.map };
    }
};
