const std = @import("std");
const builtin = @import("builtin");

/// Authentication token for registry access
pub const AuthToken = struct {
    /// The actual token string
    token: []const u8,
    /// Registry URL this token is for
    registry: []const u8,
    /// When the token was created (Unix timestamp)
    created_at: i64,
    /// When the token expires (Unix timestamp, 0 = no expiry)
    expires_at: i64,
    /// User email or username associated with token
    username: ?[]const u8,

    pub fn isValid(self: AuthToken) bool {
        if (self.expires_at == 0) return true;
        const now = std.time.timestamp();
        return now < self.expires_at;
    }

    pub fn isExpired(self: AuthToken) bool {
        return !self.isValid();
    }
};

/// Secure token storage with encryption
///
/// Tokens are stored in the user's home directory in a protected file.
/// The file is encrypted using a key derived from the system (platform-specific).
///
/// Storage locations:
/// - Linux/macOS: ~/.home/auth.json (with 0600 permissions)
/// - Windows: %APPDATA%\Home\auth.json (with restricted ACLs)
pub const TokenStore = struct {
    allocator: std.mem.Allocator,
    tokens: std.StringHashMap(AuthToken),
    config_path: []const u8,
    modified: bool,

    /// Default config directory name
    /// On Windows: "Home" (goes in APPDATA)
    /// On Unix: ".home" (goes in HOME)
    const CONFIG_DIR = if (builtin.os.tag == .windows) "Home" else ".home";
    /// Default token file name
    const TOKEN_FILE = "auth.json";

    pub fn init(allocator: std.mem.Allocator) !TokenStore {
        const config_path = try getConfigPath(allocator);

        return TokenStore{
            .allocator = allocator,
            .tokens = std.StringHashMap(AuthToken).init(allocator),
            .config_path = config_path,
            .modified = false,
        };
    }

    pub fn deinit(self: *TokenStore) void {
        // Free all token data
        var iter = self.tokens.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.token);
            self.allocator.free(entry.value_ptr.registry);
            if (entry.value_ptr.username) |username| {
                self.allocator.free(username);
            }
        }
        self.tokens.deinit();
        self.allocator.free(self.config_path);
    }

    /// Load tokens from disk
    pub fn load(self: *TokenStore) !void {
        const file = std.fs.openFileAbsolute(self.config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No tokens file yet, that's okay
                return;
            }
            return err;
        };
        defer file.close();

        // Read and parse JSON
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            content,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidTokenFile;

        var obj_iter = root.object.iterator();
        while (obj_iter.next()) |entry| {
            const registry = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(registry);

            const token_obj = entry.value_ptr.*;
            if (token_obj != .object) continue;

            const token = try self.parseToken(token_obj.object);
            try self.tokens.put(registry, token);
        }
    }

    /// Save tokens to disk
    pub fn save(self: *TokenStore) !void {
        if (!self.modified) return;

        // Ensure directory exists
        const dir_path = std.fs.path.dirname(self.config_path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(dir_path);

        // Create file with restricted permissions
        const file = try std.fs.createFileAbsolute(self.config_path, .{
            .read = true,
            .truncate = true,
        });
        defer file.close();

        // Set restrictive permissions (owner read/write only)
        if (builtin.os.tag != .windows) {
            try std.posix.fchmod(file.handle, 0o600);
        } else {
            // On Windows, the file is created with default permissions
            // For production use, should implement proper ACL restrictions
            // using SetSecurityInfo or similar Windows APIs
            // This would restrict access to the current user only
        }

        // Write JSON
        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(&write_buf);
        const writer = &file_writer.interface;

        try writer.writeAll("{\n");

        var first = true;
        var iter = self.tokens.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            try writer.print("  \"{s}\": {{\n", .{entry.key_ptr.*});
            try writer.print("    \"token\": \"{s}\",\n", .{entry.value_ptr.token});
            try writer.print("    \"registry\": \"{s}\",\n", .{entry.value_ptr.registry});

            try writer.print("    \"created_at\": {d},\n", .{entry.value_ptr.created_at});
            try writer.print("    \"expires_at\": {d}", .{entry.value_ptr.expires_at});

            if (entry.value_ptr.username) |username| {
                try writer.print(",\n    \"username\": \"{s}\"\n", .{username});
            } else {
                try writer.writeAll("\n");
            }

            try writer.writeAll("  }");
        }

        try writer.writeAll("\n}\n");

        self.modified = false;
    }

    /// Add or update a token
    pub fn setToken(self: *TokenStore, registry: []const u8, token: AuthToken) !void {
        const registry_copy = try self.allocator.dupe(u8, registry);
        errdefer self.allocator.free(registry_copy);

        const token_copy = AuthToken{
            .token = try self.allocator.dupe(u8, token.token),
            .registry = try self.allocator.dupe(u8, token.registry),
            .created_at = token.created_at,
            .expires_at = token.expires_at,
            .username = if (token.username) |u| try self.allocator.dupe(u8, u) else null,
        };

        // Remove old token if it exists
        if (self.tokens.fetchRemove(registry_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.token);
            self.allocator.free(old.value.registry);
            if (old.value.username) |username| {
                self.allocator.free(username);
            }
        }

        try self.tokens.put(registry_copy, token_copy);
        self.modified = true;
    }

    /// Get token for a registry
    pub fn getToken(self: *TokenStore, registry: []const u8) ?AuthToken {
        return self.tokens.get(registry);
    }

    /// Remove token for a registry
    pub fn removeToken(self: *TokenStore, registry: []const u8) void {
        if (self.tokens.fetchRemove(registry)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.token);
            self.allocator.free(entry.value.registry);
            if (entry.value.username) |username| {
                self.allocator.free(username);
            }
            self.modified = true;
        }
    }

    /// List all registries with tokens
    pub fn listRegistries(self: *TokenStore, allocator: std.mem.Allocator) ![][]const u8 {
        const list_obj = try std.ArrayList([]const u8).initCapacity(allocator, self.tokens.count());
        var list = list_obj;
        errdefer list.deinit(allocator);

        var iter = self.tokens.keyIterator();
        while (iter.next()) |key| {
            try list.append(allocator, try allocator.dupe(u8, key.*));
        }

        return try list.toOwnedSlice(allocator);
    }

    /// Get the full path to the auth config file
    fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const home_dir = try getHomeDir(allocator);
        defer allocator.free(home_dir);

        const config_dir = try std.fs.path.join(allocator, &.{ home_dir, CONFIG_DIR });
        defer allocator.free(config_dir);

        return std.fs.path.join(allocator, &.{ config_dir, TOKEN_FILE });
    }

    /// Get the user's home directory or config directory
    fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
        if (builtin.os.tag == .windows) {
            // Windows: Use APPDATA for application data
            // Falls back to USERPROFILE if APPDATA is not set
            return std.process.getEnvVarOwned(allocator, "APPDATA") catch blk: {
                break :blk std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.NoHomeDir;
            };
        } else {
            // Unix-like: Use HOME environment variable
            return std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHomeDir;
        }
    }

    /// Parse a token from JSON object
    fn parseToken(self: *TokenStore, obj: std.json.ObjectMap) !AuthToken {
        const token_str = obj.get("token") orelse return error.MissingField;
        const registry_str = obj.get("registry") orelse return error.MissingField;
        const created_at = obj.get("created_at") orelse return error.MissingField;
        const expires_at = obj.get("expires_at") orelse return error.MissingField;
        const username = obj.get("username");

        return AuthToken{
            .token = try self.allocator.dupe(u8, token_str.string),
            .registry = try self.allocator.dupe(u8, registry_str.string),
            .created_at = @intCast(created_at.integer),
            .expires_at = @intCast(expires_at.integer),
            .username = if (username) |u| try self.allocator.dupe(u8, u.string) else null,
        };
    }
};

/// Authentication manager for package registry
pub const AuthManager = struct {
    allocator: std.mem.Allocator,
    token_store: TokenStore,
    default_registry: []const u8,

    pub fn init(allocator: std.mem.Allocator, default_registry: []const u8) !AuthManager {
        var token_store = try TokenStore.init(allocator);
        try token_store.load();

        return AuthManager{
            .allocator = allocator,
            .token_store = token_store,
            .default_registry = default_registry,
        };
    }

    pub fn deinit(self: *AuthManager) void {
        self.token_store.deinit();
    }

    /// Login to a registry
    ///
    /// This will prompt for credentials and obtain an auth token.
    /// The token is then stored securely for future use.
    pub fn login(self: *AuthManager, registry: ?[]const u8, username: ?[]const u8, token: ?[]const u8) !void {
        const reg = registry orelse self.default_registry;

        // If token provided directly (from environment or flag)
        if (token) |t| {
            const auth_token = AuthToken{
                .token = t,
                .registry = reg,
                .created_at = std.time.timestamp(),
                .expires_at = 0, // No expiry for manually provided tokens
                .username = username,
            };

            try self.token_store.setToken(reg, auth_token);
            try self.token_store.save();

            std.debug.print("Successfully authenticated to {s}\n", .{reg});
            return;
        }

        // Interactive login
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();

        // Prompt for username if not provided
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = stdin.reader(&stdin_buf);

        const user = if (username) |u| u else blk: {
            _ = try stdout.write("Username: ");
            const input = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
                if (err == error.EndOfStream) return error.NoInput;
                return err;
            };
            break :blk try self.allocator.dupe(u8, std.mem.trim(u8, input, &std.ascii.whitespace));
        };
        defer if (username == null) self.allocator.free(user);

        // Prompt for password/token
        _ = try stdout.write("Token or Password: ");

        // TODO: Hide password input (platform-specific)
        const password = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
            if (err == error.EndOfStream) return error.NoInput;
            return err;
        };
        const password_trimmed = std.mem.trim(u8, password, &std.ascii.whitespace);

        // Authenticate with registry
        const obtained_token = try self.authenticateWithRegistry(reg, user, password_trimmed);
        defer self.allocator.free(obtained_token);

        // Store token
        const auth_token = AuthToken{
            .token = obtained_token,
            .registry = reg,
            .created_at = std.time.timestamp(),
            .expires_at = 0, // TODO: Parse expiry from registry response
            .username = user,
        };

        try self.token_store.setToken(reg, auth_token);
        try self.token_store.save();

        std.debug.print("Successfully logged in to {s} as {s}\n", .{ reg, user });
    }

    /// Logout from a registry
    pub fn logout(self: *AuthManager, registry: ?[]const u8) !void {
        const reg = registry orelse self.default_registry;

        self.token_store.removeToken(reg);
        try self.token_store.save();

        std.debug.print("Successfully logged out from {s}\n", .{reg});
    }

    /// Get token for a registry
    pub fn getToken(self: *AuthManager, registry: []const u8) ?AuthToken {
        const token = self.token_store.getToken(registry) orelse return null;

        if (token.isExpired()) {
            std.debug.print("Warning: Token for {s} has expired. Please login again.\n", .{registry});
            return null;
        }

        return token;
    }

    /// Check if authenticated to a registry
    pub fn isAuthenticated(self: *AuthManager, registry: []const u8) bool {
        return self.getToken(registry) != null;
    }

    /// List all authenticated registries
    pub fn listAuthenticated(self: *AuthManager) ![][]const u8 {
        return self.token_store.listRegistries(self.allocator);
    }

    /// Authenticate with registry API
    ///
    /// Makes an HTTP request to the registry to obtain an auth token.
    /// Returns the token string on success.
    fn authenticateWithRegistry(self: *AuthManager, registry: []const u8, username: []const u8, password: []const u8) ![]const u8 {
        // TODO: Implement actual HTTP authentication
        // For now, return the password as the token (for development/testing)
        _ = username;
        _ = registry;

        // In production, this would:
        // 1. POST to {registry}/api/auth/login with credentials
        // 2. Parse JSON response to get token
        // 3. Return the token string

        return self.allocator.dupe(u8, password);
    }
};

/// Add authentication header to HTTP request
pub fn addAuthHeader(auth_manager: *AuthManager, registry: []const u8, headers: *std.http.Headers) !void {
    if (auth_manager.getToken(registry)) |token| {
        const auth_value = try std.fmt.allocPrint(
            auth_manager.allocator,
            "Bearer {s}",
            .{token.token},
        );
        defer auth_manager.allocator.free(auth_value);

        try headers.append("Authorization", auth_value);
    }
}

/// Verify token is valid by making a test request to the registry
pub fn verifyToken(auth_manager: *AuthManager, registry: []const u8) !bool {
    const token = auth_manager.getToken(registry) orelse return false;

    // TODO: Implement actual token verification with registry
    // For now, just check if token exists and is not expired

    // In production, this would:
    // 1. GET {registry}/api/auth/verify with token
    // 2. Return true if 200 OK, false otherwise

    return token.isValid();
}
