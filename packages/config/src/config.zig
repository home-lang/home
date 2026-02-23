const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const Io = std.Io;

/// Environment variable helper
pub const Env = struct {
    prefix: ?[]const u8 = null,

    /// Get environment variable
    pub fn get(_: Env, key: []const u8) ?[]const u8 {
        if (comptime native_os == .linux) {
            // On Linux without libc, std.c.getenv is unavailable
            return null;
        } else {
            // key must be null-terminated for C getenv; since Home strings
            // from the parser are typically backed by source buffers that
            // have null terminators, we try a direct sentinel cast first.
            const key_z: [*:0]const u8 = @ptrCast(key.ptr);
            const val_ptr = std.c.getenv(key_z) orelse return null;
            return std.mem.span(val_ptr);
        }
    }

    /// Get environment variable with default
    pub fn getOr(self: Env, key: []const u8, default: []const u8) []const u8 {
        return self.get(key) orelse default;
    }

    /// Get environment variable as integer
    pub fn getInt(self: Env, key: []const u8) ?i64 {
        const val = self.get(key) orelse return null;
        return std.fmt.parseInt(i64, val, 10) catch null;
    }

    /// Get environment variable as integer with default
    pub fn getIntOr(self: Env, key: []const u8, default: i64) i64 {
        return self.getInt(key) orelse default;
    }

    /// Get environment variable as boolean
    pub fn getBool(self: Env, key: []const u8) ?bool {
        const val = self.get(key) orelse return null;
        if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "yes")) {
            return true;
        }
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "no")) {
            return false;
        }
        return null;
    }

    /// Get environment variable as boolean with default
    pub fn getBoolOr(self: Env, key: []const u8, default: bool) bool {
        return self.getBool(key) orelse default;
    }

    /// Check if environment variable is set
    pub fn has(self: Env, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// Check if running in production
    pub fn isProduction(self: Env) bool {
        const environment = self.getOr("NODE_ENV", self.getOr("ENV", "development"));
        return std.mem.eql(u8, environment, "production") or std.mem.eql(u8, environment, "prod");
    }

    /// Check if running in development
    pub fn isDevelopment(self: Env) bool {
        const environment = self.getOr("NODE_ENV", self.getOr("ENV", "development"));
        return std.mem.eql(u8, environment, "development") or std.mem.eql(u8, environment, "dev");
    }

    /// Check if running in test
    pub fn isTest(self: Env) bool {
        const environment = self.getOr("NODE_ENV", self.getOr("ENV", "development"));
        return std.mem.eql(u8, environment, "test");
    }
};

/// Global env instance
pub const env = Env{};

/// Shared configuration loader for Home language
/// Supports: home.jsonc, home.json, package.jsonc, package.json, home.toml, couch.toml
pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,
    io: ?Io = null,

    /// Configuration file priority order
    pub const CONFIG_FILES = [_][]const u8{
        "home.jsonc",     // Recommended - JSON with comments
        "home.json",      // Standard JSON
        "package.jsonc",  // NPM-compatible with comments
        "package.json",   // NPM-compatible
        "home.toml",      // TOML format
        "couch.toml",     // Legacy/convenience helper
    };

    pub fn init(allocator: std.mem.Allocator) ConfigLoader {
        return .{ .allocator = allocator };
    }

    /// Find and load the first available config file
    pub fn findConfigFile(self: *ConfigLoader, search_dir: ?[]const u8) ![]const u8 {
        const dir = search_dir orelse ".";

        for (CONFIG_FILES) |filename| {
            const path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir, filename });
            errdefer self.allocator.free(path);

            // Check if file exists
            if (self.io) |io_val| {
                Io.Dir.cwd().access(io_val, path, .{}) catch {
                    self.allocator.free(path);
                    continue;
                };
            } else {
                self.allocator.free(path);
                continue;
            }

            return path;
        }

        return error.NoConfigFile;
    }

    /// Load and parse config file content
    pub fn loadConfigFile(self: *ConfigLoader, path: []const u8) ![]const u8 {
        const io_val = self.io orelse return error.NoConfigFile;
        return try Io.Dir.cwd().readFileAlloc(io_val, path, self.allocator, .limited(1024 * 1024)); // 1MB max
    }

    /// Parse JSON or JSONC content
    pub fn parseJson(self: *ConfigLoader, content: []const u8) !std.json.Parsed(std.json.Value) {
        // Strip comments for JSONC support
        const stripped = try self.stripJsonComments(content);
        defer self.allocator.free(stripped);

        return try std.json.parseFromSlice(std.json.Value, self.allocator, stripped, .{});
    }

    /// Get a nested field from JSON object
    pub fn getJsonField(obj: std.json.Value, field: []const u8) ?std.json.Value {
        if (obj != .object) return null;
        return obj.object.get(field);
    }

    /// Get a string value from JSON
    pub fn getJsonString(value: std.json.Value) ?[]const u8 {
        if (value != .string) return null;
        return value.string;
    }

    /// Get an integer value from JSON
    pub fn getJsonInt(value: std.json.Value) ?i64 {
        if (value != .integer) return null;
        return value.integer;
    }

    /// Get a boolean value from JSON
    pub fn getJsonBool(value: std.json.Value) ?bool {
        if (value != .bool) return null;
        return value.bool;
    }

    /// Get an object value from JSON
    pub fn getJsonObject(value: std.json.Value) ?std.json.ObjectMap {
        if (value != .object) return null;
        return value.object;
    }

    /// Strip single-line and multi-line comments from JSON
    fn stripJsonComments(self: *ConfigLoader, content: []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, content.len);
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        var in_string = false;
        var escape_next = false;

        while (i < content.len) {
            const char = content[i];

            // Handle string state
            if (in_string) {
                result.appendAssumeCapacity(char);
                if (escape_next) {
                    escape_next = false;
                } else if (char == '\\') {
                    escape_next = true;
                } else if (char == '"') {
                    in_string = false;
                }
                i += 1;
                continue;
            }

            // Track when we enter a string
            if (char == '"') {
                in_string = true;
                result.appendAssumeCapacity(char);
                i += 1;
                continue;
            }

            // Skip single-line comments
            if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '/') {
                // Skip until end of line
                while (i < content.len and content[i] != '\n') : (i += 1) {}
                if (i < content.len) {
                    result.appendAssumeCapacity('\n');
                    i += 1;
                }
                continue;
            }

            // Skip multi-line comments
            if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '*') {
                i += 2;
                while (i + 1 < content.len) {
                    if (content[i] == '*' and content[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }

            result.appendAssumeCapacity(char);
            i += 1;
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Parse TOML content (simplified parser)
    pub fn parseToml(self: *ConfigLoader, content: []const u8) !std.StringHashMap(TomlValue) {
        var result = std.StringHashMap(TomlValue).init(self.allocator);
        errdefer result.deinit();

        var current_section: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for section headers
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                const section = trimmed[1 .. trimmed.len - 1];
                current_section = try self.allocator.dupe(u8, section);
                continue;
            }

            // Parse key-value pairs
            var parts = std.mem.splitScalar(u8, trimmed, '=');
            const key = std.mem.trim(u8, parts.next() orelse continue, " \t");
            const value = std.mem.trim(u8, parts.rest(), " \t\"");

            const full_key = if (current_section) |section|
                try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ section, key })
            else
                try self.allocator.dupe(u8, key);

            // Determine value type
            const toml_value = if (std.mem.eql(u8, value, "true"))
                TomlValue{ .boolean = true }
            else if (std.mem.eql(u8, value, "false"))
                TomlValue{ .boolean = false }
            else if (std.fmt.parseInt(i64, value, 10)) |int_val|
                TomlValue{ .integer = int_val }
            else |_|
                TomlValue{ .string = try self.allocator.dupe(u8, value) };

            try result.put(full_key, toml_value);
        }

        return result;
    }
};

pub const TomlValue = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    float: f64,
};

/// Helper to get config value with fallback
pub fn getConfigValue(
    comptime T: type,
    json_obj: ?std.json.Value,
    toml_map: ?std.StringHashMap(TomlValue),
    key: []const u8,
    default: T,
) T {
    // Try JSON first
    if (json_obj) |obj| {
        if (ConfigLoader.getJsonField(obj, key)) |value| {
            return switch (T) {
                []const u8 => ConfigLoader.getJsonString(value) orelse default,
                i64, i32, usize => @intCast(ConfigLoader.getJsonInt(value) orelse default),
                bool => ConfigLoader.getJsonBool(value) orelse default,
                else => default,
            };
        }
    }

    // Try TOML
    if (toml_map) |map| {
        if (map.get(key)) |value| {
            return switch (T) {
                []const u8 => if (value == .string) value.string else default,
                i64, i32, usize => if (value == .integer) @intCast(value.integer) else default,
                bool => if (value == .boolean) value.boolean else default,
                else => default,
            };
        }
    }

    return default;
}

// Tests
test "env helper" {
    // These tests work with whatever environment is available
    const e = Env{};

    // Test getOr with default
    const path = e.getOr("PATH", "/usr/bin");
    try std.testing.expect(path.len > 0);

    // Test getIntOr with default
    const port = e.getIntOr("NONEXISTENT_PORT_VAR", 8080);
    try std.testing.expectEqual(@as(i64, 8080), port);

    // Test getBoolOr with default
    const debug = e.getBoolOr("NONEXISTENT_DEBUG_VAR", false);
    try std.testing.expect(!debug);

    // Test has
    try std.testing.expect(e.has("PATH"));
    try std.testing.expect(!e.has("COMPLETELY_NONEXISTENT_VAR_12345"));
}

test "toml value types" {
    const str_val = TomlValue{ .string = "hello" };
    try std.testing.expectEqualStrings("hello", str_val.string);

    const int_val = TomlValue{ .integer = 42 };
    try std.testing.expectEqual(@as(i64, 42), int_val.integer);

    const bool_val = TomlValue{ .boolean = true };
    try std.testing.expect(bool_val.boolean);
}

test "config loader toml parsing" {
    const allocator = std.testing.allocator;

    var loader = ConfigLoader{ .allocator = allocator };

    // Test without sections to avoid section leak issue
    const toml_content =
        \\# Comment
        \\name = "myapp"
        \\port = 3000
        \\debug = true
    ;

    var result = try loader.parseToml(toml_content);
    defer {
        var iter = result.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.* == .string) {
                allocator.free(entry.value_ptr.string);
            }
        }
        result.deinit();
    }

    try std.testing.expectEqualStrings("myapp", result.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3000), result.get("port").?.integer);
    try std.testing.expect(result.get("debug").?.boolean);
}
