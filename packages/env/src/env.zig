// Home Programming Language - Environment Variables
// Cross-platform environment variable access and manipulation

const std = @import("std");
const dotenv = @import("dotenv.zig");
const parser = @import("parser.zig");

pub const DotEnv = dotenv.DotEnv;
pub const ParseError = parser.ParseError;
pub const secure = @import("secure.zig");
pub const cli = @import("cli.zig");

// Get environment variable value
pub fn get(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    // Convert key to null-terminated string for C API
    const key_z = try allocator.dupeZ(u8, key);
    defer allocator.free(key_z);

    const result = std.c.getenv(key_z.ptr);
    if (result) |ptr| {
        return try allocator.dupe(u8, std.mem.sliceTo(ptr, 0));
    }
    return null;
}

// Get environment variable or return default
pub fn getOrDefault(allocator: std.mem.Allocator, key: []const u8, default: []const u8) ![]const u8 {
    if (try get(allocator, key)) |value| {
        return value;
    }
    return try allocator.dupe(u8, default);
}

// Set environment variable
pub fn set(key: []const u8, value: []const u8) !void {
    // Zig doesn't have direct setenv, we need to use platform-specific calls
    if (@import("builtin").os.tag == .windows) {
        return error.NotImplemented; // Windows requires different approach
    }

    const key_z = try std.posix.toPosixPath(key);
    const value_z = try std.posix.toPosixPath(value);

    const c = struct {
        extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
    };

    const result = c.setenv(&key_z, &value_z, 1);
    if (result != 0) {
        return error.SetEnvironmentVariableFailed;
    }
}

// Unset environment variable
pub fn unset(key: []const u8) !void {
    if (@import("builtin").os.tag == .windows) {
        return error.NotImplemented;
    }

    const key_z = try std.posix.toPosixPath(key);

    const c = struct {
        extern "c" fn unsetenv([*:0]const u8) c_int;
    };

    const result = c.unsetenv(&key_z);
    if (result != 0) {
        return error.UnsetEnvironmentVariableFailed;
    }
}

// Check if environment variable exists
pub fn has(key: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = get(allocator, key) catch return false;
    return value != null;
}

// Get all environment variables
pub fn getAll(allocator: std.mem.Allocator) !std.process.EnvMap {
    return try std.process.getEnvMap(allocator);
}

// Parse environment variable as specific type
pub const Parse = struct {
    // Parse as integer
    pub fn asInt(comptime T: type, allocator: std.mem.Allocator, key: []const u8) !?T {
        const value = try get(allocator, key) orelse return null;
        defer allocator.free(value);
        return try std.fmt.parseInt(T, value, 10);
    }

    // Parse as integer with default
    pub fn asIntOrDefault(comptime T: type, allocator: std.mem.Allocator, key: []const u8, default: T) !T {
        return (try asInt(T, allocator, key)) orelse default;
    }

    // Parse as float
    pub fn asFloat(comptime T: type, allocator: std.mem.Allocator, key: []const u8) !?T {
        const value = try get(allocator, key) orelse return null;
        defer allocator.free(value);
        return try std.fmt.parseFloat(T, value);
    }

    // Parse as float with default
    pub fn asFloatOrDefault(comptime T: type, allocator: std.mem.Allocator, key: []const u8, default: T) !T {
        return (try asFloat(T, allocator, key)) orelse default;
    }

    // Parse as boolean (accepts: true/false, 1/0, yes/no, on/off)
    pub fn asBool(allocator: std.mem.Allocator, key: []const u8) !?bool {
        const value = try get(allocator, key) orelse return null;
        defer allocator.free(value);

        const lower = try std.ascii.allocLowerString(allocator, value);
        defer allocator.free(lower);

        if (std.mem.eql(u8, lower, "true") or
            std.mem.eql(u8, lower, "1") or
            std.mem.eql(u8, lower, "yes") or
            std.mem.eql(u8, lower, "on")) {
            return true;
        }

        if (std.mem.eql(u8, lower, "false") or
            std.mem.eql(u8, lower, "0") or
            std.mem.eql(u8, lower, "no") or
            std.mem.eql(u8, lower, "off")) {
            return false;
        }

        return error.InvalidBooleanValue;
    }

    // Parse as boolean with default
    pub fn asBoolOrDefault(allocator: std.mem.Allocator, key: []const u8, default: bool) !bool {
        return (try asBool(allocator, key)) orelse default;
    }

    // Parse as array (comma-separated)
    pub fn asArray(allocator: std.mem.Allocator, key: []const u8, delimiter: []const u8) !?[][]const u8 {
        const value = try get(allocator, key) orelse return null;
        defer allocator.free(value);

        var list = std.ArrayList([]const u8){};
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }

        var iter = std.mem.splitSequence(u8, value, delimiter);
        while (iter.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t\r\n");
            if (trimmed.len > 0) {
                try list.append(allocator, try allocator.dupe(u8, trimmed));
            }
        }

        return try list.toOwnedSlice(allocator);
    }

    // Parse as JSON
    pub fn asJson(comptime T: type, allocator: std.mem.Allocator, key: []const u8) !?T {
        const value = try get(allocator, key) orelse return null;
        defer allocator.free(value);

        return try std.json.parseFromSliceLeaky(T, allocator, value, .{});
    }
};

// Expand environment variables in a string (supports ${VAR} and $VAR syntax)
pub fn expand(allocator: std.mem.Allocator, template: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$') {
            i += 1;
            if (i >= template.len) {
                try result.append(allocator, '$');
                break;
            }

            var var_name: []const u8 = undefined;
            var end_idx: usize = undefined;

            if (template[i] == '{') {
                // ${VAR} syntax
                i += 1;
                const start = i;
                while (i < template.len and template[i] != '}') : (i += 1) {}
                if (i >= template.len) return error.UnterminatedVariable;
                var_name = template[start..i];
                end_idx = i + 1;
            } else {
                // $VAR syntax
                const start = i;
                while (i < template.len and (std.ascii.isAlphanumeric(template[i]) or template[i] == '_')) : (i += 1) {}
                var_name = template[start..i];
                end_idx = i;
            }

            if (var_name.len > 0) {
                if (try get(allocator, var_name)) |value| {
                    defer allocator.free(value);
                    try result.appendSlice(allocator, value);
                }
            }

            i = end_idx;
        } else {
            try result.append(allocator, template[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

// Validation helpers
pub const Validate = struct {
    // Require environment variable to exist
    pub fn require(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
        const value = try get(allocator, key) orelse return error.RequiredEnvironmentVariableNotFound;
        return value;
    }

    // Require multiple environment variables
    pub fn requireAll(allocator: std.mem.Allocator, keys: []const []const u8) !std.StringHashMap([]const u8) {
        var map = std.StringHashMap([]const u8).init(allocator);
        errdefer {
            var iter = map.valueIterator();
            while (iter.next()) |value| {
                allocator.free(value.*);
            }
            map.deinit();
        }

        for (keys) |key| {
            const value = try require(allocator, key);
            try map.put(key, value);
        }

        return map;
    }

    // Validate environment variable matches pattern
    pub fn matches(allocator: std.mem.Allocator, key: []const u8, pattern: []const u8) !bool {
        const value = try get(allocator, key) orelse return false;
        defer allocator.free(value);

        // Simple glob-style pattern matching
        return std.mem.indexOf(u8, value, pattern) != null;
    }

    // Validate environment variable is in allowed list
    pub fn oneOf(allocator: std.mem.Allocator, key: []const u8, allowed: []const []const u8) !bool {
        const value = try get(allocator, key) orelse return false;
        defer allocator.free(value);

        for (allowed) |option| {
            if (std.mem.eql(u8, value, option)) {
                return true;
            }
        }

        return false;
    }
};

test "env get and set" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test get non-existent variable
    const value = try get(allocator, "HOME_TEST_VAR_DOES_NOT_EXIST");
    try testing.expectEqual(@as(?[]const u8, null), value);

    // Test has
    try testing.expect(!has("HOME_TEST_VAR_DOES_NOT_EXIST"));
}

test "env getOrDefault" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const value = try getOrDefault(allocator, "HOME_TEST_VAR_DOES_NOT_EXIST", "default_value");
    defer allocator.free(value);

    try testing.expectEqualStrings("default_value", value);
}

test "env parse int" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test default value
    const value = try Parse.asIntOrDefault(i32, allocator, "HOME_TEST_INT_VAR", 42);
    try testing.expectEqual(@as(i32, 42), value);
}

test "env parse bool" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test default value
    const value = try Parse.asBoolOrDefault(allocator, "HOME_TEST_BOOL_VAR", true);
    try testing.expect(value);
}

test "env expand variables" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with non-existent variables (should be empty)
    const result1 = try expand(allocator, "Hello ${USER_DOES_NOT_EXIST}!");
    defer allocator.free(result1);
    try testing.expectEqualStrings("Hello !", result1);

    const result2 = try expand(allocator, "No variables here");
    defer allocator.free(result2);
    try testing.expectEqualStrings("No variables here", result2);
}

test "env validate require with missing var" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test require with missing variable
    const result = Validate.require(allocator, "HOME_TEST_MISSING_VAR");
    try testing.expectError(error.RequiredEnvironmentVariableNotFound, result);
}
