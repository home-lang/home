const std = @import("std");
const posix = std.posix;
const session = @import("../session.zig");

/// Helper to get current timestamp
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// Cookie-based session driver (encrypted client-side sessions)
/// Note: This stores session data in cookies, encrypted with a secret key
pub const CookieDriver = struct {
    allocator: std.mem.Allocator,
    secret_key: [32]u8,
    pending_data: ?[]const u8, // Data to be written to cookie

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, secret_key: []const u8) !*Self {
        const self = try allocator.create(Self);

        // Hash the secret key to get exactly 32 bytes
        var key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(secret_key, &key, .{});

        self.* = .{
            .allocator = allocator,
            .secret_key = key,
            .pending_data = null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.pending_data) |data| {
            self.allocator.free(data);
        }
        self.allocator.destroy(self);
    }

    pub fn driver(self: *Self) session.SessionDriver {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Get the encrypted cookie value to send to client
    pub fn getCookieValue(self: *Self) ?[]const u8 {
        return self.pending_data;
    }

    /// Set cookie data received from client
    pub fn setCookieData(self: *Self, data: []const u8) !void {
        if (self.pending_data) |old| {
            self.allocator.free(old);
        }
        self.pending_data = try self.allocator.dupe(u8, data);
    }

    fn read(ptr: *anyopaque, id: []const u8) anyerror!?session.SessionData {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = id; // Cookie driver doesn't use session ID

        const encrypted = self.pending_data orelse return null;
        if (encrypted.len == 0) return null;

        // Decode base64
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encrypted) catch return null;
        const decoded = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(decoded);

        std.base64.standard.Decoder.decode(decoded, encrypted) catch return null;

        if (decoded.len < 12 + 16) return null; // nonce + tag minimum

        // Decrypt (using ChaCha20-Poly1305)
        const nonce: [12]u8 = decoded[0..12].*;
        const tag: [16]u8 = decoded[decoded.len - 16 ..][0..16].*;
        const ciphertext = decoded[12 .. decoded.len - 16];

        const plaintext = try self.allocator.alloc(u8, ciphertext.len);
        errdefer self.allocator.free(plaintext);

        std.crypto.aead.chacha20_poly1305.ChaCha20Poly1305.decrypt(
            plaintext,
            ciphertext,
            tag,
            "",
            nonce,
            self.secret_key,
        ) catch return null;

        // Parse session data
        var data = session.SessionData.init(self.allocator);
        errdefer data.deinit();

        var lines = std.mem.splitScalar(u8, plaintext, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "__created_at=")) {
                data.created_at = std.fmt.parseInt(i64, line[13..], 10) catch 0;
                continue;
            }
            if (std.mem.startsWith(u8, line, "__last_activity=")) {
                data.last_activity = std.fmt.parseInt(i64, line[16..], 10) catch 0;
                continue;
            }

            const eq_pos = std.mem.indexOf(u8, line, "=") orelse continue;
            const key = line[0..eq_pos];
            const rest = line[eq_pos + 1 ..];

            const colon_pos = std.mem.indexOf(u8, rest, ":") orelse continue;
            const type_str = rest[0..colon_pos];
            const value_str = rest[colon_pos + 1 ..];

            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);

            const value: session.SessionData.Value = if (std.mem.eql(u8, type_str, "s")) blk: {
                break :blk .{ .string = try self.allocator.dupe(u8, value_str) };
            } else if (std.mem.eql(u8, type_str, "i")) blk: {
                break :blk .{ .int = std.fmt.parseInt(i64, value_str, 10) catch 0 };
            } else if (std.mem.eql(u8, type_str, "b")) blk: {
                break :blk .{ .bool = std.mem.eql(u8, value_str, "true") };
            } else blk: {
                break :blk .null;
            };

            try data.data.put(key_copy, value);
        }

        self.allocator.free(plaintext);
        return data;
    }

    fn write(ptr: *anyopaque, id: []const u8, data: session.SessionData) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = id;

        // Serialize session data
        var plaintext_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        // Metadata
        const created = try std.fmt.bufPrint(plaintext_buf[pos..], "__created_at={d}\n", .{data.created_at});
        pos += created.len;

        const activity = try std.fmt.bufPrint(plaintext_buf[pos..], "__last_activity={d}\n", .{data.last_activity});
        pos += activity.len;

        // Data
        var iter = data.data.iterator();
        while (iter.next()) |entry| {
            const line = switch (entry.value_ptr.*) {
                .string => |s| try std.fmt.bufPrint(plaintext_buf[pos..], "{s}=s:{s}\n", .{ entry.key_ptr.*, s }),
                .int => |i| try std.fmt.bufPrint(plaintext_buf[pos..], "{s}=i:{d}\n", .{ entry.key_ptr.*, i }),
                .bool => |b| try std.fmt.bufPrint(plaintext_buf[pos..], "{s}=b:{s}\n", .{ entry.key_ptr.*, if (b) "true" else "false" }),
                .float => |f| try std.fmt.bufPrint(plaintext_buf[pos..], "{s}=f:{d}\n", .{ entry.key_ptr.*, f }),
                .null => try std.fmt.bufPrint(plaintext_buf[pos..], "{s}=n:\n", .{entry.key_ptr.*}),
            };
            pos += line.len;
        }

        const plaintext = plaintext_buf[0..pos];

        // Encrypt
        var nonce: [12]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        var ciphertext = try self.allocator.alloc(u8, plaintext.len);
        defer self.allocator.free(ciphertext);

        var tag: [16]u8 = undefined;

        std.crypto.aead.chacha20_poly1305.ChaCha20Poly1305.encrypt(
            ciphertext,
            &tag,
            plaintext,
            "",
            nonce,
            self.secret_key,
        );

        // Combine: nonce + ciphertext + tag
        const total_len = 12 + ciphertext.len + 16;
        var combined = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(combined);

        @memcpy(combined[0..12], &nonce);
        @memcpy(combined[12 .. 12 + ciphertext.len], ciphertext);
        @memcpy(combined[12 + ciphertext.len ..], &tag);

        // Base64 encode
        const encoded_len = std.base64.standard.Encoder.calcSize(total_len);
        const encoded = try self.allocator.alloc(u8, encoded_len);

        _ = std.base64.standard.Encoder.encode(encoded, combined);

        // Store for cookie
        if (self.pending_data) |old| {
            self.allocator.free(old);
        }
        self.pending_data = encoded;
    }

    fn destroy(ptr: *anyopaque, id: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = id;

        if (self.pending_data) |old| {
            self.allocator.free(old);
        }
        self.pending_data = null;
    }

    fn gc(ptr: *anyopaque, max_lifetime: i64) anyerror!void {
        _ = ptr;
        _ = max_lifetime;
        // Cookie sessions don't need GC - they expire on the client
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = session.SessionDriver.VTable{
        .read = read,
        .write = write,
        .destroy = destroy,
        .gc = gc,
        .deinit = deinitFn,
    };
};

// Tests
test "cookie driver encryption" {
    const allocator = std.testing.allocator;

    const drv = try CookieDriver.init(allocator, "my-secret-key-for-testing");
    defer drv.deinit();

    var d = drv.driver();

    // Create session data
    var data = session.SessionData.init(allocator);
    const key = try allocator.dupe(u8, "user_id");
    try data.data.put(key, .{ .int = 123 });

    // Write (encrypt)
    try d.write("ignored", data);
    data.deinit();

    // Verify we have encrypted data
    const cookie_value = drv.getCookieValue();
    try std.testing.expect(cookie_value != null);
    try std.testing.expect(cookie_value.?.len > 0);

    // Read back (decrypt)
    const read_data = try d.read("ignored");
    try std.testing.expect(read_data != null);

    var rd = read_data.?;
    defer rd.deinit();

    const value = rd.data.get("user_id");
    try std.testing.expect(value != null);
    try std.testing.expectEqual(@as(i64, 123), value.?.asInt().?);
}
