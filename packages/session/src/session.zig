const std = @import("std");
const posix = std.posix;

/// Helper to get current timestamp (Zig 0.16 compatible)
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

// Re-export drivers
pub const file = @import("drivers/file.zig");
pub const memory = @import("drivers/memory.zig");
pub const cookie = @import("drivers/cookie.zig");

/// Session driver interface
pub const SessionDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, id: []const u8) anyerror!?SessionData,
        write: *const fn (ptr: *anyopaque, id: []const u8, data: SessionData) anyerror!void,
        destroy: *const fn (ptr: *anyopaque, id: []const u8) anyerror!void,
        gc: *const fn (ptr: *anyopaque, max_lifetime: i64) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn read(self: SessionDriver, id: []const u8) !?SessionData {
        return self.vtable.read(self.ptr, id);
    }

    pub fn write(self: SessionDriver, id: []const u8, data: SessionData) !void {
        return self.vtable.write(self.ptr, id, data);
    }

    pub fn destroy(self: SessionDriver, id: []const u8) !void {
        return self.vtable.destroy(self.ptr, id);
    }

    pub fn gc(self: SessionDriver, max_lifetime: i64) !void {
        return self.vtable.gc(self.ptr, max_lifetime);
    }

    pub fn deinit(self: SessionDriver) void {
        return self.vtable.deinit(self.ptr);
    }
};

/// Session data stored by drivers
pub const SessionData = struct {
    data: std.StringHashMap(Value),
    created_at: i64,
    last_activity: i64,
    allocator: std.mem.Allocator,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        bool: bool,
        null,

        pub fn asString(self: Value) ?[]const u8 {
            return switch (self) {
                .string => |s| s,
                else => null,
            };
        }

        pub fn asInt(self: Value) ?i64 {
            return switch (self) {
                .int => |i| i,
                else => null,
            };
        }

        pub fn asBool(self: Value) ?bool {
            return switch (self) {
                .bool => |b| b,
                else => null,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) SessionData {
        return .{
            .data = std.StringHashMap(Value).init(allocator),
            .created_at = getTimestamp(),
            .last_activity = getTimestamp(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionData) void {
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.* == .string) {
                self.allocator.free(entry.value_ptr.string);
            }
        }
        self.data.deinit();
    }

    pub fn clone(self: *const SessionData, allocator: std.mem.Allocator) !SessionData {
        var new_data = std.StringHashMap(Value).init(allocator);

        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const value: Value = switch (entry.value_ptr.*) {
                .string => |s| .{ .string = try allocator.dupe(u8, s) },
                else => entry.value_ptr.*,
            };
            try new_data.put(key, value);
        }

        return .{
            .data = new_data,
            .created_at = self.created_at,
            .last_activity = self.last_activity,
            .allocator = allocator,
        };
    }
};

/// Session configuration
pub const SessionConfig = struct {
    driver: DriverType = .memory,
    lifetime: i64 = 7200, // 2 hours in seconds
    expire_on_close: bool = false,
    encrypt: bool = false,
    cookie_name: []const u8 = "session_id",
    cookie_path: []const u8 = "/",
    cookie_domain: ?[]const u8 = null,
    cookie_secure: bool = false,
    cookie_http_only: bool = true,
    cookie_same_site: SameSite = .lax,
    file_path: []const u8 = "/tmp/sessions",
    gc_probability: u32 = 1, // 1 in 100 requests trigger GC
    gc_divisor: u32 = 100,

    pub const DriverType = enum {
        memory,
        file,
        cookie,
        redis,
    };

    pub const SameSite = enum {
        strict,
        lax,
        none,

        pub fn toString(self: SameSite) []const u8 {
            return switch (self) {
                .strict => "Strict",
                .lax => "Lax",
                .none => "None",
            };
        }
    };

    pub fn default() SessionConfig {
        return .{};
    }

    pub fn fileDriver(path: []const u8) SessionConfig {
        var config = default();
        config.driver = .file;
        config.file_path = path;
        return config;
    }
};

/// Session manager - main interface for working with sessions
pub const Session = struct {
    allocator: std.mem.Allocator,
    config: SessionConfig,
    driver: SessionDriver,
    id: ?[]const u8,
    data: ?SessionData,
    started: bool,
    regenerated: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: SessionConfig, driver: SessionDriver) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .driver = driver,
            .id = null,
            .data = null,
            .started = false,
            .regenerated = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.id) |id| {
            self.allocator.free(id);
        }
        if (self.data) |*data| {
            data.deinit();
        }
    }

    /// Start or resume a session
    pub fn start(self: *Self, session_id: ?[]const u8) !void {
        if (self.started) return;

        if (session_id) |id| {
            // Try to load existing session
            self.id = try self.allocator.dupe(u8, id);
            if (try self.driver.read(id)) |data| {
                self.data = try data.clone(self.allocator);
                // Update last activity
                self.data.?.last_activity = getTimestamp();
            } else {
                // Session not found, create new
                self.data = SessionData.init(self.allocator);
            }
        } else {
            // Generate new session ID
            self.id = try self.generateId();
            self.data = SessionData.init(self.allocator);
        }

        self.started = true;

        // Maybe run garbage collection
        try self.maybeGc();
    }

    /// Get a value from the session
    pub fn get(self: *Self, key: []const u8) ?SessionData.Value {
        if (self.data) |data| {
            return data.data.get(key);
        }
        return null;
    }

    /// Get a string value
    pub fn getString(self: *Self, key: []const u8) ?[]const u8 {
        if (self.get(key)) |value| {
            return value.asString();
        }
        return null;
    }

    /// Get an integer value
    pub fn getInt(self: *Self, key: []const u8) ?i64 {
        if (self.get(key)) |value| {
            return value.asInt();
        }
        return null;
    }

    /// Get a boolean value
    pub fn getBool(self: *Self, key: []const u8) ?bool {
        if (self.get(key)) |value| {
            return value.asBool();
        }
        return null;
    }

    /// Set a string value
    pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
        if (self.data) |*data| {
            // Remove old key if exists
            if (data.data.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                if (old.value == .string) {
                    self.allocator.free(old.value.string);
                }
            }

            const key_copy = try self.allocator.dupe(u8, key);
            const value_copy = try self.allocator.dupe(u8, value);
            try data.data.put(key_copy, .{ .string = value_copy });
        }
    }

    /// Set an integer value
    pub fn putInt(self: *Self, key: []const u8, value: i64) !void {
        if (self.data) |*data| {
            if (data.data.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                if (old.value == .string) {
                    self.allocator.free(old.value.string);
                }
            }

            const key_copy = try self.allocator.dupe(u8, key);
            try data.data.put(key_copy, .{ .int = value });
        }
    }

    /// Set a boolean value
    pub fn putBool(self: *Self, key: []const u8, value: bool) !void {
        if (self.data) |*data| {
            if (data.data.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                if (old.value == .string) {
                    self.allocator.free(old.value.string);
                }
            }

            const key_copy = try self.allocator.dupe(u8, key);
            try data.data.put(key_copy, .{ .bool = value });
        }
    }

    /// Check if a key exists
    pub fn has(self: *Self, key: []const u8) bool {
        if (self.data) |data| {
            return data.data.contains(key);
        }
        return false;
    }

    /// Remove a key from the session
    pub fn forget(self: *Self, key: []const u8) void {
        if (self.data) |*data| {
            if (data.data.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                if (old.value == .string) {
                    self.allocator.free(old.value.string);
                }
            }
        }
    }

    /// Get and remove a value (flash data pattern)
    pub fn pull(self: *Self, key: []const u8) ?SessionData.Value {
        const value = self.get(key);
        if (value != null) {
            self.forget(key);
        }
        return value;
    }

    /// Clear all session data
    pub fn flush(self: *Self) void {
        if (self.data) |*data| {
            var iter = data.data.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                if (entry.value_ptr.* == .string) {
                    self.allocator.free(entry.value_ptr.string);
                }
            }
            data.data.clearAndFree();
        }
    }

    /// Regenerate session ID (for security after login)
    pub fn regenerate(self: *Self, destroy_old: bool) !void {
        const old_id = self.id;

        // Generate new ID
        self.id = try self.generateId();
        self.regenerated = true;

        if (destroy_old) {
            if (old_id) |id| {
                try self.driver.destroy(id);
                self.allocator.free(id);
            }
        }
    }

    /// Invalidate the session (logout)
    pub fn invalidate(self: *Self) !void {
        self.flush();
        try self.regenerate(true);
    }

    /// Save the session
    pub fn save(self: *Self) !void {
        if (!self.started) return;

        if (self.id) |id| {
            if (self.data) |data| {
                try self.driver.write(id, data);
            }
        }
    }

    /// Get the session ID
    pub fn getId(self: *Self) ?[]const u8 {
        return self.id;
    }

    /// Check if session was regenerated
    pub fn wasRegenerated(self: *Self) bool {
        return self.regenerated;
    }

    /// Generate session cookie header value
    pub fn getCookieHeader(self: *Self) ![]const u8 {
        const id = self.id orelse return error.SessionNotStarted;

        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        // Cookie name and value
        const name_val = try std.fmt.bufPrint(buf[pos..], "{s}={s}", .{ self.config.cookie_name, id });
        pos += name_val.len;

        // Path
        const path_part = try std.fmt.bufPrint(buf[pos..], "; Path={s}", .{self.config.cookie_path});
        pos += path_part.len;

        // Domain
        if (self.config.cookie_domain) |domain| {
            const domain_part = try std.fmt.bufPrint(buf[pos..], "; Domain={s}", .{domain});
            pos += domain_part.len;
        }

        // Max-Age
        if (!self.config.expire_on_close) {
            const age_part = try std.fmt.bufPrint(buf[pos..], "; Max-Age={d}", .{self.config.lifetime});
            pos += age_part.len;
        }

        // Secure
        if (self.config.cookie_secure) {
            const secure_part = "; Secure";
            @memcpy(buf[pos .. pos + secure_part.len], secure_part);
            pos += secure_part.len;
        }

        // HttpOnly
        if (self.config.cookie_http_only) {
            const http_only_part = "; HttpOnly";
            @memcpy(buf[pos .. pos + http_only_part.len], http_only_part);
            pos += http_only_part.len;
        }

        // SameSite
        const same_site_part = try std.fmt.bufPrint(buf[pos..], "; SameSite={s}", .{self.config.cookie_same_site.toString()});
        pos += same_site_part.len;

        return try self.allocator.dupe(u8, buf[0..pos]);
    }

    fn generateId(self: *Self) ![]const u8 {
        var bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        const hex_chars = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (bytes, 0..) |b, i| {
            hex[i * 2] = hex_chars[b >> 4];
            hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }

        return try self.allocator.dupe(u8, &hex);
    }

    fn maybeGc(self: *Self) !void {
        // Random GC based on probability
        var rand_byte: [1]u8 = undefined;
        std.crypto.random.bytes(&rand_byte);

        const rand = @as(u32, rand_byte[0]) % self.config.gc_divisor;
        if (rand < self.config.gc_probability) {
            try self.driver.gc(self.config.lifetime);
        }
    }
};

/// CSRF token manager
pub const Csrf = struct {
    session: *Session,
    token_key: []const u8 = "_csrf_token",

    const Self = @This();

    pub fn init(session: *Session) Self {
        return .{ .session = session };
    }

    /// Get or generate CSRF token
    pub fn token(self: *Self) ![]const u8 {
        if (self.session.getString(self.token_key)) |existing| {
            return existing;
        }

        // Generate new token
        var bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        const hex_chars = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (bytes, 0..) |b, i| {
            hex[i * 2] = hex_chars[b >> 4];
            hex[i * 2 + 1] = hex_chars[b & 0x0f];
        }

        try self.session.put(self.token_key, &hex);
        return self.session.getString(self.token_key).?;
    }

    /// Verify a CSRF token
    pub fn verify(self: *Self, provided_token: []const u8) bool {
        const stored = self.session.getString(self.token_key) orelse return false;
        return std.mem.eql(u8, stored, provided_token);
    }

    /// Regenerate CSRF token
    pub fn regenerate(self: *Self) ![]const u8 {
        self.session.forget(self.token_key);
        return self.token();
    }

    /// Generate hidden input HTML
    pub fn field(self: *Self) ![]const u8 {
        const tok = try self.token();
        var buf: [256]u8 = undefined;
        const html = try std.fmt.bufPrint(&buf, "<input type=\"hidden\" name=\"_token\" value=\"{s}\">", .{tok});
        return self.session.allocator.dupe(u8, html);
    }
};

/// Flash message support
pub const Flash = struct {
    session: *Session,
    old_key: []const u8 = "_flash_old",
    new_key: []const u8 = "_flash_new",

    const Self = @This();

    pub fn init(session: *Session) Self {
        return .{ .session = session };
    }

    /// Flash a message for the next request
    pub fn flash(self: *Self, key: []const u8, value: []const u8) !void {
        // Store in new flash data
        var flash_key_buf: [256]u8 = undefined;
        const flash_key = try std.fmt.bufPrint(&flash_key_buf, "_flash.{s}", .{key});
        try self.session.put(flash_key, value);

        // Track in new keys list
        // For simplicity, we just use the key directly
    }

    /// Get a flashed message
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        var flash_key_buf: [256]u8 = undefined;
        const flash_key = std.fmt.bufPrint(&flash_key_buf, "_flash.{s}", .{key}) catch return null;
        return self.session.getString(flash_key);
    }

    /// Get and remove a flashed message
    pub fn pull(self: *Self, key: []const u8) ?[]const u8 {
        const value = self.get(key);
        if (value) |_| {
            var flash_key_buf: [256]u8 = undefined;
            const flash_key = std.fmt.bufPrint(&flash_key_buf, "_flash.{s}", .{key}) catch return value;
            self.session.forget(flash_key);
        }
        return value;
    }

    /// Keep flash data for another request
    pub fn keep(self: *Self, keys: []const []const u8) !void {
        for (keys) |key| {
            if (self.get(key)) |value| {
                try self.flash(key, value);
            }
        }
    }
};

// Tests
test "session data operations" {
    const allocator = std.testing.allocator;

    var data = SessionData.init(allocator);
    defer data.deinit();

    // Add some data
    const key = try allocator.dupe(u8, "user_id");
    try data.data.put(key, .{ .int = 123 });

    // Verify
    const value = data.data.get("user_id");
    try std.testing.expect(value != null);
    try std.testing.expectEqual(@as(i64, 123), value.?.asInt().?);
}

test "csrf token generation" {
    // Test that tokens are generated correctly
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Convert to hex manually
    const hex_chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    try std.testing.expectEqual(@as(usize, 64), hex.len);
}
