const std = @import("std");

/// Shared configuration loader for Home language
/// Supports: home.jsonc, home.json, package.jsonc, package.json, home.toml, couch.toml
pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,

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
            std.fs.cwd().access(path, .{}) catch {
                self.allocator.free(path);
                continue;
            };

            return path;
        }

        return error.NoConfigFile;
    }

    /// Load and parse config file content
    pub fn loadConfigFile(self: *ConfigLoader, path: []const u8) ![]const u8 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        return try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
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
        errdefer result.deinit();

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

        return result.toOwnedSlice();
    }

    /// Parse TOML content (simplified parser)
    pub fn parseToml(self: *ConfigLoader, content: []const u8) !std.StringHashMap(TomlValue) {
        var result = std.StringHashMap(TomlValue).init(self.allocator);
        errdefer result.deinit();

        var current_section: ?[]const u8 = null;
        var lines = std.mem.split(u8, content, "\n");

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
            var parts = std.mem.split(u8, trimmed, "=");
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
