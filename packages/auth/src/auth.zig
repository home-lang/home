const std = @import("std");
const posix = std.posix;

/// Helper to get current timestamp
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

// Re-export modules
pub const jwt = @import("jwt.zig");
pub const guards = @import("guards.zig");
pub const hash = @import("hash.zig");

/// User interface that authenticatable models should implement
pub const Authenticatable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getId: *const fn (ptr: *anyopaque) u64,
        getIdentifier: *const fn (ptr: *anyopaque) []const u8,
        getPassword: *const fn (ptr: *anyopaque) []const u8,
        getRememberToken: *const fn (ptr: *anyopaque) ?[]const u8,
        setRememberToken: *const fn (ptr: *anyopaque, token: ?[]const u8) anyerror!void,
    };

    pub fn getId(self: Authenticatable) u64 {
        return self.vtable.getId(self.ptr);
    }

    pub fn getIdentifier(self: Authenticatable) []const u8 {
        return self.vtable.getIdentifier(self.ptr);
    }

    pub fn getPassword(self: Authenticatable) []const u8 {
        return self.vtable.getPassword(self.ptr);
    }

    pub fn getRememberToken(self: Authenticatable) ?[]const u8 {
        return self.vtable.getRememberToken(self.ptr);
    }

    pub fn setRememberToken(self: Authenticatable, token: ?[]const u8) !void {
        return self.vtable.setRememberToken(self.ptr, token);
    }
};

/// User provider interface - retrieves users from storage
pub const UserProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        findById: *const fn (ptr: *anyopaque, id: u64) anyerror!?Authenticatable,
        findByCredentials: *const fn (ptr: *anyopaque, identifier: []const u8) anyerror!?Authenticatable,
        findByToken: *const fn (ptr: *anyopaque, token: []const u8) anyerror!?Authenticatable,
        validateCredentials: *const fn (ptr: *anyopaque, user: Authenticatable, password: []const u8) bool,
    };

    pub fn findById(self: UserProvider, id: u64) !?Authenticatable {
        return self.vtable.findById(self.ptr, id);
    }

    pub fn findByCredentials(self: UserProvider, identifier: []const u8) !?Authenticatable {
        return self.vtable.findByCredentials(self.ptr, identifier);
    }

    pub fn findByToken(self: UserProvider, token: []const u8) !?Authenticatable {
        return self.vtable.findByToken(self.ptr, token);
    }

    pub fn validateCredentials(self: UserProvider, user: Authenticatable, password: []const u8) bool {
        return self.vtable.validateCredentials(self.ptr, user, password);
    }
};

/// Authentication manager
pub const Auth = struct {
    allocator: std.mem.Allocator,
    provider: UserProvider,
    current_user: ?Authenticatable,
    session_key: []const u8,
    remember_key: []const u8,

    const Self = @This();

    pub const Config = struct {
        session_key: []const u8 = "auth_user_id",
        remember_key: []const u8 = "remember_token",
        remember_duration: i64 = 60 * 60 * 24 * 30, // 30 days
    };

    pub fn init(allocator: std.mem.Allocator, provider: UserProvider, config: Config) Self {
        return .{
            .allocator = allocator,
            .provider = provider,
            .current_user = null,
            .session_key = config.session_key,
            .remember_key = config.remember_key,
        };
    }

    /// Attempt to authenticate a user with credentials
    pub fn attempt(self: *Self, identifier: []const u8, password: []const u8) !bool {
        const found_user = try self.provider.findByCredentials(identifier) orelse return false;

        if (!self.provider.validateCredentials(found_user, password)) {
            return false;
        }

        self.current_user = found_user;
        return true;
    }

    /// Login a user by instance
    pub fn login(self: *Self, u: Authenticatable) void {
        self.current_user = u;
    }

    /// Login by user ID
    pub fn loginById(self: *Self, user_id: u64) !bool {
        const found_user = try self.provider.findById(user_id) orelse return false;
        self.current_user = found_user;
        return true;
    }

    /// Logout the current user
    pub fn logout(self: *Self) void {
        if (self.current_user) |u| {
            u.setRememberToken(null) catch {};
        }
        self.current_user = null;
    }

    /// Check if user is authenticated
    pub fn check(self: *Self) bool {
        return self.current_user != null;
    }

    /// Check if user is a guest
    pub fn guest(self: *Self) bool {
        return self.current_user == null;
    }

    /// Get the currently authenticated user
    pub fn user(self: *Self) ?Authenticatable {
        return self.current_user;
    }

    /// Get user ID if authenticated
    pub fn id(self: *Self) ?u64 {
        if (self.current_user) |u| {
            return u.getId();
        }
        return null;
    }

    /// Generate remember token
    pub fn generateRememberToken(self: *Self) ![]const u8 {
        var bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        const hex_chars = "0123456789abcdef";
        var token: [64]u8 = undefined;
        for (bytes, 0..) |b, i| {
            token[i * 2] = hex_chars[b >> 4];
            token[i * 2 + 1] = hex_chars[b & 0x0f];
        }

        return try self.allocator.dupe(u8, &token);
    }

    /// Create remember token for current user
    pub fn rememberUser(self: *Self) !?[]const u8 {
        if (self.current_user) |u| {
            const token = try self.generateRememberToken();
            try u.setRememberToken(token);
            return token;
        }
        return null;
    }

    /// Attempt to login via remember token
    pub fn viaRemember(self: *Self, token: []const u8) !bool {
        const found_user = try self.provider.findByToken(token) orelse return false;
        self.current_user = found_user;
        return true;
    }

    /// Validate credentials without logging in
    pub fn validate(self: *Self, identifier: []const u8, password: []const u8) !bool {
        const found_user = try self.provider.findByCredentials(identifier) orelse return false;
        return self.provider.validateCredentials(found_user, password);
    }

    /// Get user's ID for session storage
    pub fn getSessionUserId(self: *Self) ?[]const u8 {
        if (self.current_user) |u| {
            var buf: [20]u8 = undefined;
            const id_str = std.fmt.bufPrint(&buf, "{d}", .{u.getId()}) catch return null;
            return self.allocator.dupe(u8, id_str) catch return null;
        }
        return null;
    }

    /// Restore user from session
    pub fn restoreFromSession(self: *Self, user_id_str: []const u8) !bool {
        const user_id = std.fmt.parseInt(u64, user_id_str, 10) catch return false;
        return self.loginById(user_id);
    }
};

/// Credentials structure for authentication
pub const Credentials = struct {
    identifier: []const u8,
    password: []const u8,
    remember: bool = false,

    pub fn init(identifier: []const u8, password: []const u8) Credentials {
        return .{
            .identifier = identifier,
            .password = password,
        };
    }

    pub fn withRemember(identifier: []const u8, password: []const u8) Credentials {
        return .{
            .identifier = identifier,
            .password = password,
            .remember = true,
        };
    }
};

/// Simple in-memory user for testing
pub const TestUser = struct {
    id: u64,
    email: []const u8,
    password_hash: []const u8,
    remember_token: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: u64, email: []const u8, password_hash: []const u8) !*Self {
        const user = try allocator.create(Self);
        user.* = .{
            .id = id,
            .email = try allocator.dupe(u8, email),
            .password_hash = try allocator.dupe(u8, password_hash),
            .remember_token = null,
            .allocator = allocator,
        };
        return user;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.email);
        self.allocator.free(self.password_hash);
        if (self.remember_token) |t| self.allocator.free(t);
        self.allocator.destroy(self);
    }

    pub fn authenticatable(self: *Self) Authenticatable {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn getId(ptr: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.id;
    }

    fn getIdentifier(ptr: *anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.email;
    }

    fn getPassword(ptr: *anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.password_hash;
    }

    fn getRememberToken(ptr: *anyopaque) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.remember_token;
    }

    fn setRememberToken(ptr: *anyopaque, token: ?[]const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.remember_token) |t| self.allocator.free(t);
        self.remember_token = if (token) |t| try self.allocator.dupe(u8, t) else null;
    }

    const vtable = Authenticatable.VTable{
        .getId = getId,
        .getIdentifier = getIdentifier,
        .getPassword = getPassword,
        .getRememberToken = getRememberToken,
        .setRememberToken = setRememberToken,
    };
};

/// Simple in-memory user provider for testing
pub const TestUserProvider = struct {
    allocator: std.mem.Allocator,
    users: std.AutoHashMap(u64, *TestUser),
    users_by_email: std.StringHashMap(*TestUser),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .users = std.AutoHashMap(u64, *TestUser).init(allocator),
            .users_by_email = std.StringHashMap(*TestUser).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.users.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.users.deinit();
        self.users_by_email.deinit();
    }

    pub fn addUser(self: *Self, user: *TestUser) !void {
        try self.users.put(user.id, user);
        try self.users_by_email.put(user.email, user);
    }

    pub fn provider(self: *Self) UserProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn findById(ptr: *anyopaque, id: u64) anyerror!?Authenticatable {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.users.get(id)) |user| {
            return user.authenticatable();
        }
        return null;
    }

    fn findByCredentials(ptr: *anyopaque, identifier: []const u8) anyerror!?Authenticatable {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.users_by_email.get(identifier)) |user| {
            return user.authenticatable();
        }
        return null;
    }

    fn findByToken(ptr: *anyopaque, token: []const u8) anyerror!?Authenticatable {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var iter = self.users.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.remember_token) |t| {
                if (std.mem.eql(u8, t, token)) {
                    return entry.value_ptr.*.authenticatable();
                }
            }
        }
        return null;
    }

    fn validateCredentials(ptr: *anyopaque, user: Authenticatable, password: []const u8) bool {
        _ = ptr;
        const stored_hash = user.getPassword();
        // Simple comparison for testing - real implementation would use hash.verify
        return std.mem.eql(u8, stored_hash, password);
    }

    const vtable = UserProvider.VTable{
        .findById = findById,
        .findByCredentials = findByCredentials,
        .findByToken = findByToken,
        .validateCredentials = validateCredentials,
    };
};

// Tests
test "auth basic flow" {
    const allocator = std.testing.allocator;

    // Create provider
    var provider = TestUserProvider.init(allocator);
    defer provider.deinit();

    // Add a user
    const user = try TestUser.init(allocator, 1, "test@example.com", "password123");
    try provider.addUser(user);

    // Create auth manager
    var auth = Auth.init(allocator, provider.provider(), .{});

    // Test guest
    try std.testing.expect(auth.guest());
    try std.testing.expect(!auth.check());

    // Test attempt with wrong password
    const failed = try auth.attempt("test@example.com", "wrong");
    try std.testing.expect(!failed);

    // Test attempt with correct password
    const success = try auth.attempt("test@example.com", "password123");
    try std.testing.expect(success);
    try std.testing.expect(auth.check());
    try std.testing.expect(!auth.guest());

    // Test user ID
    try std.testing.expectEqual(@as(?u64, 1), auth.id());

    // Test logout
    auth.logout();
    try std.testing.expect(auth.guest());
}

test "remember token" {
    const allocator = std.testing.allocator;

    var provider = TestUserProvider.init(allocator);
    defer provider.deinit();

    const test_user = try TestUser.init(allocator, 1, "test@example.com", "password123");
    try provider.addUser(test_user);

    var auth_mgr = Auth.init(allocator, provider.provider(), .{});

    // Login and remember
    _ = try auth_mgr.attempt("test@example.com", "password123");
    const token = try auth_mgr.rememberUser();
    try std.testing.expect(token != null);
    defer allocator.free(token.?);

    // Clear current user without clearing remember token
    auth_mgr.current_user = null;
    try std.testing.expect(auth_mgr.guest());

    // Login via remember token
    const remembered = try auth_mgr.viaRemember(token.?);
    try std.testing.expect(remembered);
    try std.testing.expect(auth_mgr.check());
}
