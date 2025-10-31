// Home Programming Language - .env File Support
// Load and manage .env files

const std = @import("std");
const parser = @import("parser.zig");

pub const LoadError = error{
    FileNotFound,
    AccessDenied,
    InvalidFormat,
} || parser.ParseError || std.fs.File.OpenError || std.fs.File.ReadError;

pub const DotEnv = struct {
    allocator: std.mem.Allocator,
    vars: std.StringHashMap([]const u8),
    loaded_files: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .vars = std.StringHashMap([]const u8).init(allocator),
            .loaded_files = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.vars.deinit();

        for (self.loaded_files.items) |file| {
            self.allocator.free(file);
        }
        self.loaded_files.deinit(self.allocator);
    }

    // Load .env file
    pub fn load(self: *Self, path: []const u8) LoadError!void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.AccessDenied => error.AccessDenied,
                else => err,
            };
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        const parsed = try parser.parseContent(self.allocator, content);
        defer parsed.deinit();

        // Merge into existing vars
        var iter = parsed.iterator();
        while (iter.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value = try self.allocator.dupe(u8, entry.value_ptr.*);

            // If key exists, free old value
            if (self.vars.get(key)) |old_value| {
                self.allocator.free(old_value);
            }

            try self.vars.put(key, value);
        }

        try self.loaded_files.append(self.allocator, try self.allocator.dupe(u8, path));
    }

    // Load .env file or silently fail if not found
    pub fn loadOptional(self: *Self, path: []const u8) !void {
        self.load(path) catch |err| {
            if (err == error.FileNotFound) {
                return;
            }
            return err;
        };
    }

    // Load multiple .env files in order
    pub fn loadMultiple(self: *Self, paths: []const []const u8) LoadError!void {
        for (paths) |path| {
            try self.load(path);
        }
    }

    // Load with priority (last file takes precedence)
    pub fn loadWithPriority(self: *Self, paths: []const []const u8) LoadError!void {
        for (paths) |path| {
            try self.loadOptional(path);
        }
    }

    // Load standard .env files (.env, .env.local, .env.{mode})
    pub fn loadStandard(self: *Self, mode: ?[]const u8) LoadError!void {
        // Load in order of precedence (later files override earlier ones)
        try self.loadOptional(".env");

        if (mode) |m| {
            const env_mode = try std.fmt.allocPrint(self.allocator, ".env.{s}", .{m});
            defer self.allocator.free(env_mode);
            try self.loadOptional(env_mode);
        }

        try self.loadOptional(".env.local");
    }

    // Get variable
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        return self.vars.get(key);
    }

    // Set variable
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const value_owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_owned);

        // Check if key exists - if so, reuse it
        const gop = try self.vars.getOrPut(key);
        if (gop.found_existing) {
            // Free old value
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = value_owned;
        } else {
            // New key - need to duplicate it
            const key_owned = try self.allocator.dupe(u8, key);
            gop.key_ptr.* = key_owned;
            gop.value_ptr.* = value_owned;
        }
    }

    // Apply to process environment
    pub fn applyToEnv(self: *Self) !void {
        if (@import("builtin").os.tag == .windows) {
            return error.NotImplemented;
        }

        const c = struct {
            extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
        };

        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            const key_z = try self.allocator.dupeZ(u8, entry.key_ptr.*);
            defer self.allocator.free(key_z);

            const value_z = try self.allocator.dupeZ(u8, entry.value_ptr.*);
            defer self.allocator.free(value_z);

            const result = c.setenv(key_z.ptr, value_z.ptr, 0); // Don't overwrite existing
            if (result != 0) {
                return error.SetEnvironmentVariableFailed;
            }
        }
    }

    // Apply to process environment (overwrite existing)
    pub fn applyToEnvOverwrite(self: *Self) !void {
        if (@import("builtin").os.tag == .windows) {
            return error.NotImplemented;
        }

        const c = struct {
            extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
        };

        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            const key_z = try self.allocator.dupeZ(u8, entry.key_ptr.*);
            defer self.allocator.free(key_z);

            const value_z = try self.allocator.dupeZ(u8, entry.value_ptr.*);
            defer self.allocator.free(value_z);

            const result = c.setenv(key_z.ptr, value_z.ptr, 1); // Overwrite existing
            if (result != 0) {
                return error.SetEnvironmentVariableFailed;
            }
        }
    }

    // Get all variables as a map
    pub fn getAll(self: *Self) std.StringHashMap([]const u8) {
        return self.vars;
    }

    // Write to file
    pub fn save(self: *Self, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            // Quote values that contain spaces or special characters
            const needs_quotes = blk: {
                for (entry.value_ptr.*) |c| {
                    if (c == ' ' or c == '\t' or c == '"' or c == '\'' or c == '#') {
                        break :blk true;
                    }
                }
                break :blk false;
            };

            if (needs_quotes) {
                // Escape special characters
                try writer.print("{s}=\"", .{entry.key_ptr.*});
                for (entry.value_ptr.*) |c| {
                    switch (c) {
                        '\n' => try writer.writeAll("\\n"),
                        '\t' => try writer.writeAll("\\t"),
                        '\r' => try writer.writeAll("\\r"),
                        '\\' => try writer.writeAll("\\\\"),
                        '"' => try writer.writeAll("\\\""),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeAll("\"\n");
            } else {
                try writer.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
    }

    // Merge with another DotEnv instance
    pub fn merge(self: *Self, other: *const Self) !void {
        var iter = other.vars.iterator();
        while (iter.next()) |entry| {
            try self.set(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // Get variable count
    pub fn count(self: *Self) usize {
        return self.vars.count();
    }

    // Check if variable exists
    pub fn has(self: *Self, key: []const u8) bool {
        return self.vars.contains(key);
    }

    // Remove variable
    pub fn remove(self: *Self, key: []const u8) void {
        if (self.vars.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    // Clear all variables
    pub fn clear(self: *Self) void {
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.vars.clearRetainingCapacity();
    }
};

// Convenience function to load and apply .env file
pub fn load(allocator: std.mem.Allocator, path: []const u8) !void {
    var dotenv = DotEnv.init(allocator);
    defer dotenv.deinit();

    try dotenv.load(path);
    try dotenv.applyToEnv();
}

// Load standard .env files
pub fn loadStandard(allocator: std.mem.Allocator, mode: ?[]const u8) !void {
    var dotenv = DotEnv.init(allocator);
    defer dotenv.deinit();

    try dotenv.loadStandard(mode);
    try dotenv.applyToEnv();
}

test "dotenv init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var dotenv = DotEnv.init(allocator);
    defer dotenv.deinit();

    try testing.expectEqual(@as(usize, 0), dotenv.count());
}

test "dotenv set and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var dotenv = DotEnv.init(allocator);
    defer dotenv.deinit();

    try dotenv.set("TEST_KEY", "test_value");
    try testing.expectEqual(@as(usize, 1), dotenv.count());

    const value = dotenv.get("TEST_KEY");
    try testing.expect(value != null);
    try testing.expectEqualStrings("test_value", value.?);
}

test "dotenv has and remove" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var dotenv = DotEnv.init(allocator);
    defer dotenv.deinit();

    try dotenv.set("TEST_KEY", "test_value");
    try testing.expect(dotenv.has("TEST_KEY"));

    dotenv.remove("TEST_KEY");
    try testing.expect(!dotenv.has("TEST_KEY"));
    try testing.expectEqual(@as(usize, 0), dotenv.count());
}

test "dotenv clear" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var dotenv = DotEnv.init(allocator);
    defer dotenv.deinit();

    try dotenv.set("KEY1", "value1");
    try dotenv.set("KEY2", "value2");
    try testing.expectEqual(@as(usize, 2), dotenv.count());

    dotenv.clear();
    try testing.expectEqual(@as(usize, 0), dotenv.count());
}

test "dotenv overwrite" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var dotenv = DotEnv.init(allocator);
    defer dotenv.deinit();

    try dotenv.set("TEST_KEY", "value1");
    try testing.expectEqualStrings("value1", dotenv.get("TEST_KEY").?);

    try dotenv.set("TEST_KEY", "value2");
    try testing.expectEqualStrings("value2", dotenv.get("TEST_KEY").?);
    try testing.expectEqual(@as(usize, 1), dotenv.count());
}
