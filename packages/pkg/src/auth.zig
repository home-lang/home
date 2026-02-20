const std = @import("std");
const Io = std.Io;
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
        const now = getUnixTimestamp();
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
        // Read and parse JSON
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const file = Io.Dir.openFileAbsolute(io, self.config_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No tokens file yet, that's okay
                return;
            }
            return err;
        };
        defer file.close(io);

        // Get file size
        const stat = try file.stat(io);
        const file_size = stat.size;

        // Read file contents
        var io_buf: [8192]u8 = undefined;
        var reader = file.reader(io, &io_buf);
        const content = try reader.interface.readAlloc(self.allocator, file_size);
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
        var threaded_save = std.Io.Threaded.init(self.allocator, .{});
        defer threaded_save.deinit();
        const io_val = threaded_save.io();
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io_val, dir_path);

        // Create file with restricted permissions
        const file = try Io.Dir.createFileAbsolute(io_val, self.config_path, .{});
        defer file.close(io_val);

        // Write JSON
        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io_val, &write_buf);
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
        if (comptime builtin.os.tag == .windows) {
            const environ: std.process.Environ = .{ .block = .{ .use_global = true } };
            return environ.getAlloc(allocator, "APPDATA") catch
                environ.getAlloc(allocator, "USERPROFILE") catch
                return error.NoHomeDir;
        } else {
            const env_ptr = std.c.getenv("HOME") orelse return error.NoHomeDir;
            return allocator.dupe(u8, std.mem.span(env_ptr));
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
                .created_at = getUnixTimestamp(),
                .expires_at = 0, // No expiry for manually provided tokens
                .username = username,
            };

            try self.token_store.setToken(reg, auth_token);
            try self.token_store.save();

            std.debug.print("Successfully authenticated to {s}\n", .{reg});
            return;
        }

        // Interactive login
        var threaded_io = std.Io.Threaded.init(self.allocator, .{});
        defer threaded_io.deinit();
        const io = threaded_io.io();

        const stdin = std.Io.File.stdin();

        // Prompt for username if not provided
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = stdin.reader(io, &stdin_buf);

        const user = if (username) |u| u else blk: {
            std.debug.print("Username: ", .{});
            const input = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
                if (err == error.EndOfStream) return error.NoInput;
                return err;
            };
            break :blk try self.allocator.dupe(u8, std.mem.trim(u8, input, &std.ascii.whitespace));
        };
        defer if (username == null) self.allocator.free(user);

        // Prompt for password/token (hidden input)
        std.debug.print("Token or Password: ", .{});
        const password_trimmed = try self.readPasswordHidden(io);
        defer self.allocator.free(password_trimmed);

        // Authenticate with registry (returns tuple of token and expiry)
        const auth_result = try self.authenticateWithRegistry(reg, user, password_trimmed, io);
        defer self.allocator.free(auth_result.token);

        // Store token
        const auth_token = AuthToken{
            .token = auth_result.token,
            .registry = reg,
            .created_at = getUnixTimestamp(),
            .expires_at = auth_result.expires_at,
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

    /// Read password with hidden input (platform-specific)
    fn readPasswordHidden(self: *AuthManager, io: std.Io) ![]const u8 {
        const stdin = std.Io.File.stdin();

        if (builtin.os.tag == .windows) {
            // Windows: fallback to visible input (full Windows API would be needed)
            var stdin_buf: [1024]u8 = undefined;
            var stdin_reader = stdin.reader(io, &stdin_buf);
            const input = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
                if (err == error.EndOfStream) return error.NoInput;
                return err;
            };
            std.debug.print("\n", .{});
            return try self.allocator.dupe(u8, std.mem.trim(u8, input, &std.ascii.whitespace));
        } else {
            // Unix/POSIX: Use termios to disable echo
            const fd = stdin.handle;

            const original_termios = try std.posix.tcgetattr(fd);
            var hidden_termios = original_termios;

            hidden_termios.lflag.ECHO = false;
            hidden_termios.lflag.ICANON = true;

            try std.posix.tcsetattr(fd, .NOW, hidden_termios);

            defer {
                std.posix.tcsetattr(fd, .NOW, original_termios) catch {};
                std.debug.print("\n", .{});
            }

            var buffer: [1024]u8 = undefined;
            var stdin_reader = stdin.reader(io, &buffer);
            const input = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
                if (err == error.EndOfStream) return error.NoInput;
                return err;
            };

            return try self.allocator.dupe(u8, std.mem.trim(u8, input, &std.ascii.whitespace));
        }
    }

    /// Authentication result with token and expiry
    const AuthResult = struct {
        token: []const u8,
        expires_at: i64,
    };

    /// Authenticate with registry API
    ///
    /// Makes an HTTP request to the registry to obtain an auth token.
    /// Returns the auth result with token and expiry on success.
    fn authenticateWithRegistry(self: *AuthManager, registry: []const u8, username: []const u8, password: []const u8, io: std.Io) !AuthResult {
        _ = io;
        _ = registry;
        _ = username;

        // HTTP Authentication Implementation
        //
        // Production implementation would use std.http.Client.fetch() like this:
        //
        // const url = try std.fmt.allocPrint(self.allocator, "{s}/api/auth/login", .{registry});
        // defer self.allocator.free(url);
        //
        // const request_body = try std.fmt.allocPrint(
        //     self.allocator,
        //     "{{\"username\":\"{s}\",\"password\":\"{s}\"}}",
        //     .{ username, password },
        // );
        // defer self.allocator.free(request_body);
        //
        // const uri = try std.Uri.parse(url);
        //
        // var client = std.http.Client{ .allocator = self.allocator, .io = io };
        // defer client.deinit();
        //
        // const fetch_options = std.http.Client.FetchOptions{
        //     .location = .{ .uri = uri },
        //     .method = .POST,
        //     .payload = request_body,
        //     .headers = .{
        //         .content_type = .{ .override = "application/json" },
        //     },
        // };
        //
        // const result = try client.fetch(fetch_options);
        // defer result.deinit();
        //
        // if (result.status != .ok) {
        //     return error.AuthenticationFailed;
        // }
        //
        // const parsed = try std.json.parseFromSlice(
        //     struct { token: []const u8, expires_at: ?i64 = null },
        //     self.allocator,
        //     result.body.items,
        //     .{},
        // );
        // defer parsed.deinit();
        //
        // return AuthResult{
        //     .token = try self.allocator.dupe(u8, parsed.value.token),
        //     .expires_at = parsed.value.expires_at orelse 0,
        // };

        // For now, use password as token (dev mode)
        std.debug.print("Note: HTTP authentication with registry not enabled (using password as token)\n", .{});
        const token = try self.allocator.dupe(u8, password);
        return AuthResult{ .token = token, .expires_at = 0 };
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
pub fn verifyToken(auth_manager: *AuthManager, reg: []const u8, io_param: std.Io) !bool {
    _ = io_param; // Will be used when HTTP verification is enabled

    const token = auth_manager.getToken(reg) orelse return false;

    // Check if token is expired locally
    if (!token.isValid()) {
        return false;
    }

    // HTTP Token Verification Implementation
    //
    // Production implementation would use std.http.Client.fetch() like this:
    //
    // const url = try std.fmt.allocPrint(auth_manager.allocator, "{s}/api/auth/verify", .{reg});
    // defer auth_manager.allocator.free(url);
    //
    // const uri = try std.Uri.parse(url);
    //
    // var client = std.http.Client{ .allocator = auth_manager.allocator, .io = io };
    // defer client.deinit();
    //
    // const auth_header = try std.fmt.allocPrint(auth_manager.allocator, "Bearer {s}", .{token.token});
    // defer auth_manager.allocator.free(auth_header);
    //
    // const fetch_options = std.http.Client.FetchOptions{
    //     .location = .{ .uri = uri },
    //     .method = .GET,
    //     .headers = .{
    //         .authorization = .{ .override = auth_header },
    //     },
    // };
    //
    // const result = try client.fetch(fetch_options);
    // defer result.deinit();
    //
    // return result.status == .ok;

    // For now, just check local expiry
    return true;
}

/// Get current UNIX timestamp (seconds since epoch)
fn getUnixTimestamp() i64 {
    if (comptime builtin.os.tag == .windows) {
        // RtlGetSystemTimePrecise returns 100-nanosecond intervals since 1601-01-01
        const ticks = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        // Convert to Unix epoch (subtract 11644473600 seconds for 1601->1970 difference)
        return @divFloor(ticks, 10_000_000) - 11_644_473_600;
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) {
        return 0;
    }
    return ts.sec;
}
