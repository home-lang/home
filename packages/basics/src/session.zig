const std = @import("std");
const http_router = @import("http_router.zig");
const crypto = @import("crypto.zig");

/// Session and Cookie Management for Home
/// Provides secure session handling with multiple backend stores

/// Cookie Options
pub const CookieOptions = struct {
    max_age: ?i64 = null, // seconds
    expires: ?i64 = null, // unix timestamp
    path: []const u8 = "/",
    domain: ?[]const u8 = null,
    secure: bool = false,
    http_only: bool = true,
    same_site: SameSite = .lax,

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
};

/// Cookie
pub const Cookie = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    options: CookieOptions,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, value: []const u8, options: CookieOptions) !Cookie {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
            .options = options,
        };
    }

    pub fn deinit(self: *Cookie) void {
        self.allocator.free(self.name);
        self.allocator.free(self.value);
    }

    /// Serialize cookie to Set-Cookie header format
    pub fn serialize(self: *Cookie) ![]const u8 {
        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();

        // Name=Value
        const name_value = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ self.name, self.value });
        try parts.append(name_value);

        // Max-Age
        if (self.options.max_age) |age| {
            const max_age_str = try std.fmt.allocPrint(self.allocator, "Max-Age={d}", .{age});
            try parts.append(max_age_str);
        }

        // Expires
        if (self.options.expires) |exp| {
            const expires_str = try std.fmt.allocPrint(self.allocator, "Expires={d}", .{exp});
            try parts.append(expires_str);
        }

        // Path
        const path_str = try std.fmt.allocPrint(self.allocator, "Path={s}", .{self.options.path});
        try parts.append(path_str);

        // Domain
        if (self.options.domain) |domain| {
            const domain_str = try std.fmt.allocPrint(self.allocator, "Domain={s}", .{domain});
            try parts.append(domain_str);
        }

        // Secure
        if (self.options.secure) {
            try parts.append("Secure");
        }

        // HttpOnly
        if (self.options.http_only) {
            try parts.append("HttpOnly");
        }

        // SameSite
        const same_site_str = try std.fmt.allocPrint(self.allocator, "SameSite={s}", .{self.options.same_site.toString()});
        try parts.append(same_site_str);

        // Join with "; "
        return std.mem.join(self.allocator, "; ", parts.items);
    }

    /// Parse cookie from Cookie header
    pub fn parse(allocator: std.mem.Allocator, cookie_header: []const u8) !std.StringHashMap([]const u8) {
        var cookies = std.StringHashMap([]const u8).init(allocator);

        var iter = std.mem.splitSequence(u8, cookie_header, "; ");
        while (iter.next()) |pair| {
            const eq_pos = std.mem.indexOf(u8, pair, "=") orelse continue;
            const name = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];

            try cookies.put(name, value);
        }

        return cookies;
    }
};

/// Cookie Manager
pub const CookieManager = struct {
    allocator: std.mem.Allocator,
    cookies: std.StringHashMap(Cookie),

    pub fn init(allocator: std.mem.Allocator) CookieManager {
        return .{
            .allocator = allocator,
            .cookies = std.StringHashMap(Cookie).init(allocator),
        };
    }

    pub fn deinit(self: *CookieManager) void {
        var iter = self.cookies.iterator();
        while (iter.next()) |entry| {
            var cookie = entry.value_ptr.*;
            cookie.deinit();
        }
        self.cookies.deinit();
    }

    pub fn set(self: *CookieManager, name: []const u8, value: []const u8, options: CookieOptions) !void {
        const cookie = try Cookie.init(self.allocator, name, value, options);
        try self.cookies.put(name, cookie);
    }

    pub fn get(self: *CookieManager, name: []const u8) ?*Cookie {
        return self.cookies.getPtr(name);
    }

    pub fn delete(self: *CookieManager, name: []const u8) void {
        if (self.cookies.getPtr(name)) |cookie| {
            cookie.deinit();
            _ = self.cookies.remove(name);
        }
    }
};

/// Session Data
pub const SessionData = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    data: std.StringHashMap([]const u8),
    created_at: i64,
    last_accessed: i64,
    expires_at: i64,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, ttl: i64) !SessionData {
        const now = std.time.timestamp();
        return .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .data = std.StringHashMap([]const u8).init(allocator),
            .created_at = now,
            .last_accessed = now,
            .expires_at = now + ttl,
        };
    }

    pub fn deinit(self: *SessionData) void {
        self.allocator.free(self.id);
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    pub fn set(self: *SessionData, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.data.put(key_copy, value_copy);
        self.last_accessed = std.time.timestamp();
    }

    pub fn get(self: *SessionData, key: []const u8) ?[]const u8 {
        self.last_accessed = std.time.timestamp();
        return self.data.get(key);
    }

    pub fn remove(self: *SessionData, key: []const u8) void {
        if (self.data.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        self.last_accessed = std.time.timestamp();
    }

    pub fn isExpired(self: *SessionData) bool {
        return std.time.timestamp() > self.expires_at;
    }

    pub fn touch(self: *SessionData, ttl: i64) void {
        const now = std.time.timestamp();
        self.last_accessed = now;
        self.expires_at = now + ttl;
    }
};

/// Session Store Interface
pub const SessionStore = struct {
    vtable: *const VTable,
    ptr: *anyopaque,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!?SessionData,
        set: *const fn (ptr: *anyopaque, session: *SessionData) anyerror!void,
        destroy: *const fn (ptr: *anyopaque, session_id: []const u8) anyerror!void,
        cleanup: *const fn (ptr: *anyopaque) anyerror!void,
    };

    pub fn get(self: *SessionStore, allocator: std.mem.Allocator, session_id: []const u8) !?SessionData {
        return self.vtable.get(self.ptr, allocator, session_id);
    }

    pub fn set(self: *SessionStore, session: *SessionData) !void {
        return self.vtable.set(self.ptr, session);
    }

    pub fn destroy(self: *SessionStore, session_id: []const u8) !void {
        return self.vtable.destroy(self.ptr, session_id);
    }

    pub fn cleanup(self: *SessionStore) !void {
        return self.vtable.cleanup(self.ptr);
    }
};

/// Memory Session Store
pub const MemorySessionStore = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(SessionData),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) MemorySessionStore {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(SessionData).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *MemorySessionStore) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            var session = entry.value_ptr.*;
            session.deinit();
        }
        self.sessions.deinit();
    }

    pub fn store(self: *MemorySessionStore) SessionStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .get = getImpl,
                .set = setImpl,
                .destroy = destroyImpl,
                .cleanup = cleanupImpl,
            },
        };
    }

    fn getImpl(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) !?SessionData {
        const self: *MemorySessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |session| {
            if (session.isExpired()) {
                return null;
            }
            // Create a copy
            var copy = try SessionData.init(allocator, session.id, 0);
            copy.created_at = session.created_at;
            copy.last_accessed = session.last_accessed;
            copy.expires_at = session.expires_at;

            var iter = session.data.iterator();
            while (iter.next()) |entry| {
                try copy.set(entry.key_ptr.*, entry.value_ptr.*);
            }
            return copy;
        }
        return null;
    }

    fn setImpl(ptr: *anyopaque, session: *SessionData) !void {
        const self: *MemorySessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        // Create a copy for storage
        var copy = try SessionData.init(self.allocator, session.id, 0);
        copy.created_at = session.created_at;
        copy.last_accessed = session.last_accessed;
        copy.expires_at = session.expires_at;

        var iter = session.data.iterator();
        while (iter.next()) |entry| {
            try copy.set(entry.key_ptr.*, entry.value_ptr.*);
        }

        try self.sessions.put(session.id, copy);
    }

    fn destroyImpl(ptr: *anyopaque, session_id: []const u8) !void {
        const self: *MemorySessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.fetchRemove(session_id)) |kv| {
            var session = kv.value;
            session.deinit();
        }
    }

    fn cleanupImpl(ptr: *anyopaque) !void {
        const self: *MemorySessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |session_id| {
            if (self.sessions.fetchRemove(session_id)) |kv| {
                var session = kv.value;
                session.deinit();
            }
        }
    }
};

/// Session Manager
pub const SessionConfig = struct {
    cookie_name: []const u8 = "home_session",
    secret: []const u8,
    ttl: i64 = 3600, // 1 hour in seconds
    cookie_options: CookieOptions = .{
        .http_only = true,
        .secure = false, // Set to true in production with HTTPS
        .same_site = .lax,
    },
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    config: SessionConfig,
    store: SessionStore,

    pub fn init(allocator: std.mem.Allocator, config: SessionConfig, store: SessionStore) SessionManager {
        return .{
            .allocator = allocator,
            .config = config,
            .store = store,
        };
    }

    /// Generate secure session ID
    fn generateSessionId(self: *SessionManager) ![]const u8 {
        var random_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        // Create HMAC with secret
        var hmac_bytes: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&hmac_bytes, &random_bytes, self.config.secret);

        // Base64 encode
        var encoded: [64]u8 = undefined;
        const encoder = std.base64.standard.Encoder;
        const len = encoder.encode(&encoded, &hmac_bytes);

        return try self.allocator.dupe(u8, encoded[0..len]);
    }

    /// Get or create session from request
    pub fn getSession(self: *SessionManager, req: *http_router.Request) !SessionData {
        const cookie_header = req.header("Cookie");

        if (cookie_header) |cookies_str| {
            var cookies = try Cookie.parse(self.allocator, cookies_str);
            defer cookies.deinit();

            if (cookies.get(self.config.cookie_name)) |session_id| {
                if (try self.store.get(self.allocator, session_id)) |session| {
                    if (!session.isExpired()) {
                        return session;
                    }
                }
            }
        }

        // Create new session
        const session_id = try self.generateSessionId();
        defer self.allocator.free(session_id);

        return try SessionData.init(self.allocator, session_id, self.config.ttl);
    }

    /// Save session and set cookie
    pub fn saveSession(self: *SessionManager, res: *http_router.Response, session: *SessionData) !void {
        // Touch session to update expiry
        session.touch(self.config.ttl);

        // Save to store
        try self.store.set(session);

        // Set cookie
        var cookie = try Cookie.init(
            self.allocator,
            self.config.cookie_name,
            session.id,
            self.config.cookie_options,
        );
        defer cookie.deinit();

        const cookie_header = try cookie.serialize();
        defer self.allocator.free(cookie_header);

        _ = try res.setHeader("Set-Cookie", cookie_header);
    }

    /// Destroy session
    pub fn destroySession(self: *SessionManager, res: *http_router.Response, session_id: []const u8) !void {
        try self.store.destroy(session_id);

        // Clear cookie
        var cookie_options = self.config.cookie_options;
        cookie_options.max_age = 0;

        var cookie = try Cookie.init(
            self.allocator,
            self.config.cookie_name,
            "",
            cookie_options,
        );
        defer cookie.deinit();

        const cookie_header = try cookie.serialize();
        defer self.allocator.free(cookie_header);

        _ = try res.setHeader("Set-Cookie", cookie_header);
    }

    /// Cleanup expired sessions
    pub fn cleanup(self: *SessionManager) !void {
        try self.store.cleanup();
    }
};

/// Session Middleware
pub fn sessionMiddleware(manager: *SessionManager) http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            var session = try manager.getSession(req);
            defer session.deinit();

            // Store session ID in request headers for handlers to access
            try req.headers.put("X-Session-ID", session.id);

            try next();

            // Save session after handler completes
            try manager.saveSession(res, &session);
        }
    }.middleware;
}
