const std = @import("std");
const Cookie = @import("cookies.zig").Cookie;

// Module-level PRNG (Zig 0.16: std.crypto.random removed)
var g_prng = std.Random.DefaultPrng.init(0xa1b2c3d4e5f67890);

/// HTTP Session management for stateful web applications
pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(*Session),
    config: Config,

    pub const Config = struct {
        cookie_name: []const u8 = "session_id",
        timeout: i64 = 3600, // 1 hour in seconds
        secure: bool = true,
        http_only: bool = true,
        same_site: Cookie.SameSite = .Lax,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) SessionManager {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*Session).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    /// Create new session
    pub fn create(self: *SessionManager) !*Session {
        const session_id = try generateSessionId(self.allocator);
        errdefer self.allocator.free(session_id);

        const session = try self.allocator.create(Session);
        session.* = Session.init(self.allocator, session_id);

        try self.sessions.put(try self.allocator.dupe(u8, session_id), session);

        return session;
    }

    /// Get session by ID
    pub fn get(self: *SessionManager, session_id: []const u8) ?*Session {
        if (self.sessions.get(session_id)) |session| {
            // Check if session has expired
            const now = std.time.timestamp();
            if (now - session.last_accessed > self.config.timeout) {
                // Session expired, remove it
                self.destroy(session_id);
                return null;
            }

            // Update last accessed time
            session.last_accessed = now;
            return session;
        }

        return null;
    }

    /// Destroy session
    pub fn destroy(self: *SessionManager, session_id: []const u8) void {
        if (self.sessions.fetchRemove(session_id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    /// Generate session cookie
    pub fn generateCookie(self: *SessionManager, session_id: []const u8) !Cookie {
        return Cookie{
            .name = try self.allocator.dupe(u8, self.config.cookie_name),
            .value = try self.allocator.dupe(u8, session_id),
            .max_age = self.config.timeout,
            .secure = self.config.secure,
            .http_only = self.config.http_only,
            .same_site = self.config.same_site,
            .path = try self.allocator.dupe(u8, "/"),
        };
    }

    /// Clean up expired sessions
    pub fn cleanup(self: *SessionManager) void {
        const now = std.time.timestamp();
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            if (now - session.last_accessed > self.config.timeout) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |session_id| {
            self.destroy(session_id);
        }
    }
};

/// Individual session with key-value storage
pub const Session = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    data: std.StringHashMap(Value),
    created_at: i64,
    last_accessed: i64,

    pub const Value = union(enum) {
        String: []const u8,
        Int: i64,
        Float: f64,
        Bool: bool,
        Null: void,
    };

    pub fn init(allocator: std.mem.Allocator, id: []const u8) Session {
        const now = std.time.timestamp();
        return .{
            .allocator = allocator,
            .id = id,
            .data = std.StringHashMap(Value).init(allocator),
            .created_at = now,
            .last_accessed = now,
        };
    }

    pub fn deinit(self: *Session) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .String => |str| self.allocator.free(str),
                else => {},
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.data.deinit();
        self.allocator.free(self.id);
    }

    /// Set string value
    pub fn setString(self: *Session, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.data.put(key_copy, .{ .String = value_copy });
    }

    /// Set int value
    pub fn setInt(self: *Session, key: []const u8, value: i64) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        try self.data.put(key_copy, .{ .Int = value });
    }

    /// Set bool value
    pub fn setBool(self: *Session, key: []const u8, value: bool) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        try self.data.put(key_copy, .{ .Bool = value });
    }

    /// Get value
    pub fn get(self: *const Session, key: []const u8) ?Value {
        return self.data.get(key);
    }

    /// Get string value
    pub fn getString(self: *const Session, key: []const u8) ?[]const u8 {
        if (self.data.get(key)) |value| {
            return switch (value) {
                .String => |str| str,
                else => null,
            };
        }
        return null;
    }

    /// Get int value
    pub fn getInt(self: *const Session, key: []const u8) ?i64 {
        if (self.data.get(key)) |value| {
            return switch (value) {
                .Int => |num| num,
                else => null,
            };
        }
        return null;
    }

    /// Remove value
    pub fn remove(self: *Session, key: []const u8) void {
        if (self.data.fetchRemove(key)) |kv| {
            switch (kv.value) {
                .String => |str| self.allocator.free(str),
                else => {},
            }
            self.allocator.free(kv.key);
        }
    }

    /// Clear all data
    pub fn clear(self: *Session) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .String => |str| self.allocator.free(str),
                else => {},
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.data.clearAndFree();
    }
};

/// Generate cryptographically secure session ID
fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [32]u8 = undefined;
    g_prng.random().bytes(&random_bytes);

    // Convert to hex string
    var session_id = try allocator.alloc(u8, 64);
    _ = std.fmt.bufPrint(session_id, "{}", .{std.fmt.fmtSliceHexLower(&random_bytes)}) catch unreachable;

    return session_id;
}

test "Session basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = SessionManager.init(allocator, .{});
    defer manager.deinit();

    // Create session
    const session = try manager.create();
    try testing.expect(session.id.len > 0);

    // Set and get values
    try session.setString("username", "alice");
    try session.setInt("user_id", 123);

    const username = session.getString("username");
    try testing.expect(username != null);
    try testing.expectEqualStrings("alice", username.?);

    const user_id = session.getInt("user_id");
    try testing.expect(user_id != null);
    try testing.expectEqual(@as(i64, 123), user_id.?);

    // Retrieve session
    const retrieved = manager.get(session.id);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(session.id, retrieved.?.id);
}
