const std = @import("std");
const auth = @import("auth.zig");
const jwt_mod = @import("jwt.zig");

/// Authentication guard interface
pub const Guard = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        check: *const fn (ptr: *anyopaque) bool,
        user: *const fn (ptr: *anyopaque) ?auth.Authenticatable,
        validate: *const fn (ptr: *anyopaque, credentials: anytype) bool,
        setUser: *const fn (ptr: *anyopaque, user: auth.Authenticatable) void,
    };

    pub fn check(self: Guard) bool {
        return self.vtable.check(self.ptr);
    }

    pub fn user(self: Guard) ?auth.Authenticatable {
        return self.vtable.user(self.ptr);
    }

    pub fn setUser(self: Guard, u: auth.Authenticatable) void {
        return self.vtable.setUser(self.ptr, u);
    }
};

/// Session-based authentication guard
pub const SessionGuard = struct {
    allocator: std.mem.Allocator,
    provider: auth.UserProvider,
    current_user: ?auth.Authenticatable,
    session_key: []const u8,

    const Self = @This();

    pub const Config = struct {
        session_key: []const u8 = "auth_user_id",
    };

    pub fn init(allocator: std.mem.Allocator, provider: auth.UserProvider, config: Config) Self {
        return .{
            .allocator = allocator,
            .provider = provider,
            .current_user = null,
            .session_key = config.session_key,
        };
    }

    /// Attempt to authenticate with credentials
    pub fn attempt(self: *Self, identifier: []const u8, password: []const u8) !bool {
        const user_result = try self.provider.findByCredentials(identifier);
        const u = user_result orelse return false;

        if (!self.provider.validateCredentials(u, password)) {
            return false;
        }

        self.current_user = u;
        return true;
    }

    /// Login a user directly
    pub fn login(self: *Self, u: auth.Authenticatable) void {
        self.current_user = u;
    }

    /// Logout current user
    pub fn logout(self: *Self) void {
        self.current_user = null;
    }

    /// Check if authenticated
    pub fn check(self: *Self) bool {
        return self.current_user != null;
    }

    /// Get current user
    pub fn user(self: *Self) ?auth.Authenticatable {
        return self.current_user;
    }

    /// Restore from session data
    pub fn restoreFromSession(self: *Self, user_id_str: []const u8) !bool {
        const user_id = std.fmt.parseInt(u64, user_id_str, 10) catch return false;
        const u = try self.provider.findById(user_id) orelse return false;
        self.current_user = u;
        return true;
    }

    /// Get session value for current user
    pub fn getSessionValue(self: *Self) ?[]const u8 {
        if (self.current_user) |u| {
            var buf: [20]u8 = undefined;
            const id_str = std.fmt.bufPrint(&buf, "{d}", .{u.getId()}) catch return null;
            return self.allocator.dupe(u8, id_str) catch return null;
        }
        return null;
    }

    fn checkFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.check();
    }

    fn userFn(ptr: *anyopaque) ?auth.Authenticatable {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.user();
    }

    fn validateFn(ptr: *anyopaque, credentials: anytype) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = credentials;
        return false; // Not implemented for session guard via generic interface
    }

    fn setUserFn(ptr: *anyopaque, u: auth.Authenticatable) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.login(u);
    }

    pub fn guard(self: *Self) Guard {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Guard.VTable{
        .check = checkFn,
        .user = userFn,
        .validate = validateFn,
        .setUser = setUserFn,
    };
};

/// Token-based authentication guard (for API authentication)
pub const TokenGuard = struct {
    allocator: std.mem.Allocator,
    provider: auth.UserProvider,
    current_user: ?auth.Authenticatable,
    token_key: []const u8,

    const Self = @This();

    pub const Config = struct {
        token_key: []const u8 = "api_token",
    };

    pub fn init(allocator: std.mem.Allocator, provider: auth.UserProvider, config: Config) Self {
        return .{
            .allocator = allocator,
            .provider = provider,
            .current_user = null,
            .token_key = config.token_key,
        };
    }

    /// Authenticate via API token
    pub fn authenticateToken(self: *Self, token: []const u8) !bool {
        const u = try self.provider.findByToken(token) orelse return false;
        self.current_user = u;
        return true;
    }

    /// Check if authenticated
    pub fn check(self: *Self) bool {
        return self.current_user != null;
    }

    /// Get current user
    pub fn user(self: *Self) ?auth.Authenticatable {
        return self.current_user;
    }

    /// Logout
    pub fn logout(self: *Self) void {
        self.current_user = null;
    }

    fn checkFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.check();
    }

    fn userFn(ptr: *anyopaque) ?auth.Authenticatable {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.user();
    }

    fn validateFn(ptr: *anyopaque, credentials: anytype) bool {
        _ = ptr;
        _ = credentials;
        return false;
    }

    fn setUserFn(ptr: *anyopaque, u: auth.Authenticatable) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.current_user = u;
    }

    pub fn guard(self: *Self) Guard {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Guard.VTable{
        .check = checkFn,
        .user = userFn,
        .validate = validateFn,
        .setUser = setUserFn,
    };
};

/// JWT-based authentication guard
pub const JwtGuard = struct {
    allocator: std.mem.Allocator,
    provider: auth.UserProvider,
    jwt: jwt_mod.Jwt,
    current_user: ?auth.Authenticatable,

    const Self = @This();

    pub const Config = struct {
        secret: []const u8,
        issuer: ?[]const u8 = null,
        ttl: i64 = 3600,
    };

    pub fn init(allocator: std.mem.Allocator, provider: auth.UserProvider, config: Config) Self {
        return .{
            .allocator = allocator,
            .provider = provider,
            .jwt = jwt_mod.Jwt.init(allocator, .{
                .secret = config.secret,
                .issuer = config.issuer,
                .default_ttl = config.ttl,
            }),
            .current_user = null,
        };
    }

    /// Attempt to authenticate and return JWT token
    pub fn attempt(self: *Self, identifier: []const u8, password: []const u8) !?[]const u8 {
        const user_result = try self.provider.findByCredentials(identifier);
        const u = user_result orelse return null;

        if (!self.provider.validateCredentials(u, password)) {
            return null;
        }

        self.current_user = u;

        // Generate JWT with user ID as subject
        var id_buf: [20]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{u.getId()});

        return try self.jwt.create(id_str);
    }

    /// Authenticate from JWT token
    pub fn authenticateToken(self: *Self, token: []const u8) !bool {
        const result = self.jwt.verify(token) catch return false;
        defer if (result.subject) |s| self.allocator.free(s);

        if (result.subject) |subject| {
            const user_id = std.fmt.parseInt(u64, subject, 10) catch return false;
            const u = try self.provider.findById(user_id) orelse return false;
            self.current_user = u;
            return true;
        }
        return false;
    }

    /// Refresh token
    pub fn refresh(self: *Self, token: []const u8) !?[]const u8 {
        return self.jwt.refresh(token) catch null;
    }

    /// Check if authenticated
    pub fn check(self: *Self) bool {
        return self.current_user != null;
    }

    /// Get current user
    pub fn user(self: *Self) ?auth.Authenticatable {
        return self.current_user;
    }

    /// Logout
    pub fn logout(self: *Self) void {
        self.current_user = null;
    }

    fn checkFn(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.check();
    }

    fn userFn(ptr: *anyopaque) ?auth.Authenticatable {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.user();
    }

    fn validateFn(ptr: *anyopaque, credentials: anytype) bool {
        _ = ptr;
        _ = credentials;
        return false;
    }

    fn setUserFn(ptr: *anyopaque, u: auth.Authenticatable) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.current_user = u;
    }

    pub fn guard(self: *Self) Guard {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Guard.VTable{
        .check = checkFn,
        .user = userFn,
        .validate = validateFn,
        .setUser = setUserFn,
    };
};

// Tests
test "session guard basic" {
    const allocator = std.testing.allocator;

    // Create provider
    var provider = auth.TestUserProvider.init(allocator);
    defer provider.deinit();

    // Add user
    const user = try auth.TestUser.init(allocator, 1, "test@example.com", "password123");
    try provider.addUser(user);

    // Create guard
    var guard_inst = SessionGuard.init(allocator, provider.provider(), .{});

    // Test not authenticated
    try std.testing.expect(!guard_inst.check());
    try std.testing.expect(guard_inst.user() == null);

    // Test attempt with wrong password
    const failed = try guard_inst.attempt("test@example.com", "wrong");
    try std.testing.expect(!failed);

    // Test attempt with correct password
    const success = try guard_inst.attempt("test@example.com", "password123");
    try std.testing.expect(success);
    try std.testing.expect(guard_inst.check());

    // Test logout
    guard_inst.logout();
    try std.testing.expect(!guard_inst.check());
}

test "jwt guard basic" {
    const allocator = std.testing.allocator;

    var provider = auth.TestUserProvider.init(allocator);
    defer provider.deinit();

    const user = try auth.TestUser.init(allocator, 1, "test@example.com", "password123");
    try provider.addUser(user);

    var guard_inst = JwtGuard.init(allocator, provider.provider(), .{
        .secret = "test-secret",
    });

    // Attempt login
    const token = try guard_inst.attempt("test@example.com", "password123");
    try std.testing.expect(token != null);
    defer allocator.free(token.?);

    // Logout and re-authenticate with token
    guard_inst.logout();
    try std.testing.expect(!guard_inst.check());

    const auth_result = try guard_inst.authenticateToken(token.?);
    try std.testing.expect(auth_result);
    try std.testing.expect(guard_inst.check());
}
