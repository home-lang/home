const std = @import("std");
const http_router = @import("http_router.zig");
const compat = @import("compat.zig");

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
        // Dupe in two steps so the first allocation doesn't leak if the
        // second one fails.
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);
        return .{
            .allocator = allocator,
            .name = name_copy,
            .value = value_copy,
            .options = options,
        };
    }

    pub fn deinit(self: *Cookie) void {
        self.allocator.free(self.name);
        self.allocator.free(self.value);
    }

    /// Serialize cookie to Set-Cookie header format
    pub fn serialize(self: *Cookie) ![]const u8 {
        // Build the result directly into a growing buffer so we don't
        // leak per-attribute allocPrint strings when join() succeeds
        // (the old implementation appended allocated strings to an
        // ArrayList that was deinit'd without freeing its items).
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        try buf.print(self.allocator, "{s}={s}", .{ self.name, self.value });

        if (self.options.max_age) |age| try buf.print(self.allocator, "; Max-Age={d}", .{age});
        if (self.options.expires) |exp| try buf.print(self.allocator, "; Expires={d}", .{exp});
        try buf.print(self.allocator, "; Path={s}", .{self.options.path});
        if (self.options.domain) |domain| try buf.print(self.allocator, "; Domain={s}", .{domain});
        if (self.options.secure) try buf.appendSlice(self.allocator, "; Secure");
        if (self.options.http_only) try buf.appendSlice(self.allocator, "; HttpOnly");
        try buf.print(self.allocator, "; SameSite={s}", .{self.options.same_site.toString()});

        return buf.toOwnedSlice(self.allocator);
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
        var cookie = try Cookie.init(self.allocator, name, value, options);
        errdefer cookie.deinit();

        if (self.cookies.fetchRemove(name)) |old| {
            var previous = old.value;
            previous.deinit();
        }
        try self.cookies.put(cookie.name, cookie);
    }

    pub fn get(self: *CookieManager, name: []const u8) ?*Cookie {
        return self.cookies.getPtr(name);
    }

    pub fn delete(self: *CookieManager, name: []const u8) void {
        if (self.cookies.fetchRemove(name)) |removed| {
            var cookie = removed.value;
            cookie.deinit();
        }
    }
};

/// Session Data
pub const SessionData = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: []const u8,
    data: std.StringHashMap([]const u8),
    created_at: i64,
    last_accessed: i64,
    expires_at: i64,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, ttl: i64) !SessionData {
        return initWithIo(compat.io(), allocator, id, ttl);
    }

    pub fn initWithIo(io_context: std.Io, allocator: std.mem.Allocator, id: []const u8, ttl: i64) !SessionData {
        const now = compat.timestamp(io_context);
        return .{
            .allocator = allocator,
            .io = io_context,
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
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        // If the key already exists, reuse its owned copy and only replace
        // the value — otherwise the old key/value pair would leak.
        if (self.data.fetchRemove(key)) |old| {
            self.allocator.free(old.value);
            errdefer self.allocator.free(old.key);
            try self.data.put(old.key, value_copy);
        } else {
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            try self.data.put(key_copy, value_copy);
        }
        self.last_accessed = compat.timestamp(self.io);
    }

    pub fn get(self: *SessionData, key: []const u8) ?[]const u8 {
        self.last_accessed = compat.timestamp(self.io);
        return self.data.get(key);
    }

    pub fn remove(self: *SessionData, key: []const u8) void {
        if (self.data.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        self.last_accessed = compat.timestamp(self.io);
    }

    pub fn isExpired(self: *SessionData) bool {
        return compat.timestamp(self.io) >= self.expires_at;
    }

    pub fn touch(self: *SessionData, ttl: i64) void {
        const now = compat.timestamp(self.io);
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
    io: std.Io,
    sessions: std.StringHashMap(SessionData),
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator) MemorySessionStore {
        return initWithIo(compat.io(), allocator);
    }

    pub fn initWithIo(io_context: std.Io, allocator: std.mem.Allocator) MemorySessionStore {
        return .{
            .allocator = allocator,
            .io = io_context,
            .sessions = std.StringHashMap(SessionData).init(allocator),
            .mutex = .init,
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.sessions.getPtr(session_id)) |session| {
            if (session.isExpired()) {
                return null;
            }
            // Create a copy. Seed with a large TTL so the constructor's
            // computed expires_at (which we overwrite below anyway) never
            // expires the copy before we've filled it in.
            var copy = try SessionData.initWithIo(self.io, allocator, session.id, std.math.maxInt(i32));
            errdefer copy.deinit();

            var iter = session.data.iterator();
            while (iter.next()) |entry| {
                try copy.set(entry.key_ptr.*, entry.value_ptr.*);
            }
            copy.created_at = session.created_at;
            copy.last_accessed = session.last_accessed;
            copy.expires_at = session.expires_at;
            return copy;
        }
        return null;
    }

    fn setImpl(ptr: *anyopaque, session: *SessionData) !void {
        const self: *MemorySessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Create a copy for storage
        var copy = try SessionData.initWithIo(self.io, self.allocator, session.id, 0);
        errdefer copy.deinit();

        var iter = session.data.iterator();
        while (iter.next()) |entry| {
            try copy.set(entry.key_ptr.*, entry.value_ptr.*);
        }
        copy.created_at = session.created_at;
        copy.last_accessed = session.last_accessed;
        copy.expires_at = session.expires_at;

        if (self.sessions.fetchRemove(copy.id)) |old| {
            var previous = old.value;
            previous.deinit();
        }
        try self.sessions.put(copy.id, copy);
    }

    fn destroyImpl(ptr: *anyopaque, session_id: []const u8) !void {
        const self: *MemorySessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.sessions.fetchRemove(session_id)) |kv| {
            var session = kv.value;
            session.deinit();
        }
    }

    fn cleanupImpl(ptr: *anyopaque) !void {
        const self: *MemorySessionStore = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
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
    io: std.Io,
    config: SessionConfig,
    store: SessionStore,

    pub fn init(allocator: std.mem.Allocator, config: SessionConfig, store: SessionStore) SessionManager {
        return initWithIo(compat.io(), allocator, config, store);
    }

    pub fn initWithIo(io_context: std.Io, allocator: std.mem.Allocator, config: SessionConfig, store: SessionStore) SessionManager {
        return .{
            .allocator = allocator,
            .io = io_context,
            .config = config,
            .store = store,
        };
    }

    /// Generate secure session ID
    fn generateSessionId(self: *SessionManager) ![]const u8 {
        var random_bytes: [32]u8 = undefined;
        try compat.randomSecure(self.io, &random_bytes);

        // Create HMAC with secret
        var hmac_bytes: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&hmac_bytes, &random_bytes, self.config.secret);

        // Base64 encode
        var encoded: [64]u8 = undefined;
        const encoder = std.base64.standard.Encoder;
        const encoded_slice = encoder.encode(&encoded, &hmac_bytes);

        return try self.allocator.dupe(u8, encoded_slice);
    }

    /// Get or create session from request
    pub fn getSession(self: *SessionManager, req: *http_router.Request) !SessionData {
        const cookie_header = req.header("Cookie");

        if (cookie_header) |cookies_str| {
            var cookies = try Cookie.parse(self.allocator, cookies_str);
            defer cookies.deinit();

            if (cookies.get(self.config.cookie_name)) |session_id| {
                if (try self.store.get(self.allocator, session_id)) |stored_session| {
                    var session = stored_session;
                    if (!session.isExpired()) {
                        return session;
                    }
                    session.deinit();
                }
            }
        }

        // Create new session
        const session_id = try self.generateSessionId();
        defer self.allocator.free(session_id);

        return try SessionData.initWithIo(self.io, self.allocator, session_id, self.config.ttl);
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

        _ = try res.setHeaderCopy("Set-Cookie", cookie_header);
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

        _ = try res.setHeaderCopy("Set-Cookie", cookie_header);
    }

    /// Cleanup expired sessions
    pub fn cleanup(self: *SessionManager) !void {
        try self.store.cleanup();
    }
};

/// Session Middleware
pub fn sessionMiddleware(manager: *SessionManager) http_router.Middleware {
    return .{
        .context = manager,
        .handle_fn = struct {
            fn middleware(raw_context: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                const session_manager: *SessionManager = @ptrCast(@alignCast(raw_context.?));
                var session = try session_manager.getSession(req);
                defer session.deinit();

                // Store session ID in request headers for handlers to access
                try req.setHeaderCopy("X-Session-ID", session.id);

                try next.call();

                // Save session after handler completes
                try session_manager.saveSession(res, &session);
            }
        }.middleware,
    };
}

fn cookieAllocationProbe(allocator: std.mem.Allocator) !void {
    var manager = CookieManager.init(allocator);
    defer manager.deinit();

    try manager.set("session", "first", .{});
    try manager.set("session", "replacement", .{ .secure = true });

    const cookie = manager.get("session").?;
    try std.testing.expectEqualStrings("replacement", cookie.value);
    const serialized = try cookie.serialize();
    defer allocator.free(serialized);
    try std.testing.expectEqualStrings(
        "session=replacement; Path=/; Secure; HttpOnly; SameSite=Lax",
        serialized,
    );

    manager.delete("session");
    try std.testing.expect(manager.get("session") == null);
}

test "cookie replacement and serialization release every allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cookieAllocationProbe,
        .{},
    );
}

fn memoryStoreAllocationProbe(allocator: std.mem.Allocator) !void {
    var memory = MemorySessionStore.initWithIo(std.testing.io, allocator);
    defer memory.deinit();
    var store = memory.store();

    var session = try SessionData.initWithIo(std.testing.io, allocator, "owned-session-id", 3600);
    defer session.deinit();
    try session.set("user", "first");
    try store.set(&session);

    try session.set("user", "replacement");
    try store.set(&session);

    var stored = (try store.get(allocator, "owned-session-id")).?;
    defer stored.deinit();
    try std.testing.expectEqualStrings("replacement", stored.get("user").?);
    try std.testing.expectEqual(session.created_at, stored.created_at);
    try std.testing.expectEqual(session.expires_at, stored.expires_at);

    try store.destroy("owned-session-id");
    try std.testing.expect((try store.get(allocator, "owned-session-id")) == null);
}

test "memory store owns replacements and releases partial copies" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        memoryStoreAllocationProbe,
        .{},
    );
}

test "session IDs require secure entropy" {
    var memory = MemorySessionStore.initWithIo(std.Io.failing, std.testing.allocator);
    defer memory.deinit();
    const store = memory.store();
    var manager = SessionManager.initWithIo(
        std.Io.failing,
        std.testing.allocator,
        .{ .secret = "test secret" },
        store,
    );

    try std.testing.expectError(error.EntropyUnavailable, manager.generateSessionId());
}

test "sessions expire at their deadline" {
    var session = try SessionData.initWithIo(std.Io.failing, std.testing.allocator, "deadline", 0);
    defer session.deinit();
    try std.testing.expect(session.isExpired());
}

test "session middleware keeps generated headers alive" {
    const Route = struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            try std.testing.expect(req.header("X-Session-ID") != null);
            try res.send("ok");
        }
    };

    var memory = MemorySessionStore.initWithIo(std.testing.io, std.testing.allocator);
    defer memory.deinit();
    const store = memory.store();
    var manager = SessionManager.initWithIo(
        std.testing.io,
        std.testing.allocator,
        .{ .secret = "test secret" },
        store,
    );

    var router = http_router.Router.init(std.testing.allocator);
    defer router.deinit();
    try router.use(sessionMiddleware(&manager));
    try router.get("/", Route.handler);

    var request = http_router.Request.init(std.testing.allocator, .GET, "/");
    defer request.deinit();
    var response = http_router.Response.init(std.testing.allocator);
    defer response.deinit();

    try router.handle(&request, &response);
    try std.testing.expectEqualStrings("ok", response.body_content.items);
    try std.testing.expect(request.header("X-Session-ID").?.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, response.headers.get("Set-Cookie").?, "home_session="));
}

test {
    std.testing.refAllDecls(@This());
}
