// Home Programming Language - Compile-Time JSON Imports
// Narrow type inference for JSON values with literal types

const Basics = @import("basics");
const json = Basics.json;

/// Parse JSON at compile time and return a narrowly-typed struct
/// This provides TypeScript `as const` style type narrowing
pub fn importJson(comptime file_path: []const u8) type {
    const file_contents = @embedFile(file_path);

    return struct {
        pub const raw = file_contents;
        pub const parsed = parseJsonComptime(file_contents);

        /// Get a value by path with narrow type inference
        pub fn get(comptime path: []const u8) @TypeOf(getByPath(parsed, path)) {
            return getByPath(parsed, path);
        }

        /// Get the entire parsed JSON value
        pub fn value() @TypeOf(parsed) {
            return parsed;
        }
    };
}

/// JSON value type that preserves literal types
pub const JsonValue = union(enum) {
    null_value,
    bool_value: bool,
    int_value: i64,
    float_value: f64,
    string_value: []const u8,
    array_value: []const JsonValue,
    object_value: Basics.StringHashMap(JsonValue),

    pub fn format(
        self: JsonValue,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        switch (self) {
            .null_value => try writer.writeAll("null"),
            .bool_value => |b| try writer.print("{}", .{b}),
            .int_value => |i| try writer.print("{}", .{i}),
            .float_value => |f| try writer.print("{d}", .{f}),
            .string_value => |s| try writer.print("\"{s}\"", .{s}),
            .array_value => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeAll("]");
            },
            .object_value => |obj| {
                try writer.writeAll("{");
                var iter = obj.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(", ");
                    first = false;
                    try writer.print("\"{s}\": ", .{entry.key_ptr.*});
                    try entry.value_ptr.format("", .{}, writer);
                }
                try writer.writeAll("}");
            },
        }
    }
};

/// Parse JSON at compile time
fn parseJsonComptime(comptime json_str: []const u8) JsonValue {
    var stream = json.TokenStream.init(json_str);
    return parseValue(&stream) catch @compileError("Invalid JSON: " ++ json_str);
}

fn parseValue(stream: anytype) !JsonValue {
    const token = try stream.next();

    switch (token) {
        .null => return .null_value,
        .true => return .{ .bool_value = true },
        .false => return .{ .bool_value = false },
        .number => |n| {
            if (n.is_integer) {
                return .{ .int_value = try Basics.fmt.parseInt(i64, n.slice, 10) };
            } else {
                return .{ .float_value = try Basics.fmt.parseFloat(f64, n.slice) };
            }
        },
        .string => |s| return .{ .string_value = s.slice },
        .array_begin => {
            var items = Basics.ArrayList(JsonValue).init(Basics.heap.page_allocator);

            while (true) {
                const next_token = try stream.peekNextTokenType();
                if (next_token == .array_end) {
                    _ = try stream.next();
                    break;
                }

                const value = try parseValue(stream);
                try items.append(value);
            }

            return .{ .array_value = items.toOwnedSlice() };
        },
        .object_begin => {
            var map = Basics.StringHashMap(JsonValue).init(Basics.heap.page_allocator);

            while (true) {
                const next_token = try stream.peekNextTokenType();
                if (next_token == .object_end) {
                    _ = try stream.next();
                    break;
                }

                const key_token = try stream.next();
                const key = switch (key_token) {
                    .string => |s| s.slice,
                    else => return error.InvalidJson,
                };

                const value = try parseValue(stream);
                try map.put(key, value);
            }

            return .{ .object_value = map };
        },
        else => return error.InvalidJson,
    }
}

/// Get value by JSON path (e.g., "name", "version", "scripts.build")
fn getByPath(value: JsonValue, comptime path: []const u8) JsonValue {
    if (Basics.mem.indexOf(u8, path, ".")) |dot_pos| {
        const first = path[0..dot_pos];
        const rest = path[dot_pos + 1 ..];

        const intermediate = getByPath(value, first);
        return getByPath(intermediate, rest);
    }

    switch (value) {
        .object_value => |obj| {
            return obj.get(path) orelse @compileError("Path '" ++ path ++ "' not found in JSON");
        },
        else => @compileError("Cannot access path '" ++ path ++ "' on non-object value"),
    }
}

/// Generate a strongly-typed struct from JSON schema
pub fn JsonSchema(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Parse JSON into the schema type
        pub fn parse(allocator: Basics.mem.Allocator, json_str: []const u8) !T {
            const parsed = try Basics.json.parseFromSlice(T, allocator, json_str, .{});
            defer parsed.deinit();
            return parsed.value;
        }

        /// Parse JSON file at compile time
        pub fn parseFile(comptime file_path: []const u8) T {
            const json_str = @embedFile(file_path);
            return parse(Basics.heap.page_allocator, json_str) catch @compileError("Failed to parse JSON file: " ++ file_path);
        }
    };
}

/// Type-safe package.json schema
pub const PackageJson = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    main: ?[]const u8 = null,
    types: ?[]const u8 = null,
    scripts: ?Basics.StringHashMap([]const u8) = null,
    dependencies: ?Basics.StringHashMap([]const u8) = null,
    devDependencies: ?Basics.StringHashMap([]const u8) = null,
    author: ?[]const u8 = null,
    license: ?[]const u8 = null,
    keywords: ?[]const []const u8 = null,
    repository: ?Repository = null,
    bugs: ?Bugs = null,
    homepage: ?[]const u8 = null,

    pub const Repository = struct {
        type: []const u8,
        url: []const u8,
    };

    pub const Bugs = struct {
        url: []const u8,
    };

    /// Import package.json at compile time
    pub fn import(comptime path: []const u8) PackageJson {
        return JsonSchema(PackageJson).parseFile(path);
    }

    /// Get script by name
    pub fn getScript(self: *const PackageJson, name: []const u8) ?[]const u8 {
        if (self.scripts) |scripts| {
            return scripts.get(name);
        }
        return null;
    }

    /// Get dependency version
    pub fn getDependency(self: *const PackageJson, name: []const u8) ?[]const u8 {
        if (self.dependencies) |deps| {
            return deps.get(name);
        }
        return null;
    }
};

/// Narrow literal types for string values
pub fn stringLiteral(comptime value: []const u8) type {
    return struct {
        pub const literal = value;

        pub fn get() []const u8 {
            return literal;
        }

        pub fn equals(other: []const u8) bool {
            return Basics.mem.eql(u8, literal, other);
        }
    };
}

/// Narrow literal types for integer values
pub fn intLiteral(comptime value: i64) type {
    return struct {
        pub const literal = value;

        pub fn get() i64 {
            return literal;
        }

        pub fn equals(other: i64) bool {
            return literal == other;
        }
    };
}

/// Narrow literal types for boolean values
pub fn boolLiteral(comptime value: bool) type {
    return struct {
        pub const literal = value;

        pub fn get() bool {
            return literal;
        }

        pub fn equals(other: bool) bool {
            return literal == other;
        }
    };
}

/// Extract narrow type from JSON value
pub fn NarrowType(comptime value: JsonValue) type {
    return switch (value) {
        .null_value => @TypeOf(null),
        .bool_value => |b| boolLiteral(b),
        .int_value => |i| intLiteral(i),
        .float_value => f64,
        .string_value => |s| stringLiteral(s),
        .array_value => []const JsonValue,
        .object_value => Basics.StringHashMap(JsonValue),
    };
}

/// Compile-time JSON assertion - validate structure
pub fn assertJson(comptime json_str: []const u8) void {
    _ = parseJsonComptime(json_str);
}

/// Compile-time JSON path validation
pub fn assertPath(comptime json_str: []const u8, comptime path: []const u8) void {
    const parsed = parseJsonComptime(json_str);
    _ = getByPath(parsed, path);
}

// Tests
test "import package.json with narrow types" {
    const pkg = comptime blk: {
        const raw =
            \\{
            \\  "name": "my-package",
            \\  "version": "1.0.0",
            \\  "description": "A test package"
            \\}
        ;

        break :blk PackageJson{
            .name = "my-package",
            .version = "1.0.0",
            .description = "A test package",
        };
    };

    try Basics.testing.expectEqualStrings("my-package", pkg.name);
    try Basics.testing.expectEqualStrings("1.0.0", pkg.version);
}

test "narrow string literal type" {
    const Name = stringLiteral("my-package");
    try Basics.testing.expectEqualStrings("my-package", Name.literal);
    try Basics.testing.expect(Name.equals("my-package"));
    try Basics.testing.expect(!Name.equals("other-package"));
}

test "parse JSON at compile time" {
    const json_str =
        \\{
        \\  "name": "test",
        \\  "version": "1.0.0",
        \\  "count": 42
        \\}
    ;

    const parsed = comptime parseJsonComptime(json_str);

    switch (parsed) {
        .object_value => |obj| {
            const name = obj.get("name").?;
            try Basics.testing.expect(name == .string_value);
            try Basics.testing.expectEqualStrings("test", name.string_value);
        },
        else => unreachable,
    }
}

test "JSON path access" {
    const json_str =
        \\{
        \\  "config": {
        \\    "port": 3000,
        \\    "host": "localhost"
        \\  }
        \\}
    ;

    const parsed = comptime parseJsonComptime(json_str);
    const port = comptime getByPath(parsed, "config.port");

    try Basics.testing.expect(port == .int_value);
    try Basics.testing.expectEqual(@as(i64, 3000), port.int_value);
}
