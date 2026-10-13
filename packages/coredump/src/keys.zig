// Key management for core dump encryption

const std = @import("std");
const coredump = @import("coredump.zig");
const compat = @import("compat.zig");

/// Encryption key for core dumps
pub const EncryptionKey = struct {
    /// Algorithm this key is for
    algorithm: coredump.EncryptionAlgorithm,
    /// Key material
    key_data: []u8,
    /// Key ID (for rotation)
    key_id: [16]u8,
    /// Creation timestamp
    created_at: i64,
    /// Expiration timestamp (0 = never)
    expires_at: i64,
    /// Allocator
    allocator: std.mem.Allocator,

    pub fn generate(
        allocator: std.mem.Allocator,
        algorithm: coredump.EncryptionAlgorithm,
    ) !EncryptionKey {
        const key_size = algorithm.keySize();
        const key_data = try allocator.alloc(u8, key_size);
        errdefer allocator.free(key_data);

        // Generate random key
        try compat.randomSecure(key_data);

        var key_id: [16]u8 = undefined;
        try compat.randomSecure(&key_id);

        return .{
            .algorithm = algorithm,
            .key_data = key_data,
            .key_id = key_id,
            .created_at = compat.timestamp(),
            .expires_at = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EncryptionKey) void {
        // Securely zero key material
        @memset(self.key_data, 0);
        self.allocator.free(self.key_data);
    }

    pub fn isExpired(self: *const EncryptionKey) bool {
        if (self.expires_at == 0) return false;
        return compat.timestamp() >= self.expires_at;
    }

    pub fn setExpiration(self: *EncryptionKey, days: u32) void {
        const seconds_per_day = 24 * 60 * 60;
        self.expires_at = self.created_at + (@as(i64, days) * seconds_per_day);
    }

    /// Save key to file (encrypted with password)
    pub fn saveToFile(self: *const EncryptionKey, path: []const u8, password: []const u8) !void {
        const io = compat.io();
        const private_permissions: std.Io.File.Permissions = if (@bitSizeOf(std.Io.File.Permissions) == 0)
            .default_file
        else
            @enumFromInt(0o600);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = private_permissions });
        defer file.close(io);

        // Derive key from password
        var derived_key: [32]u8 = undefined;
        try deriveKeyFromPassword(password, &derived_key);

        // Encrypt key data
        var nonce: [12]u8 = undefined;
        try compat.randomSecure(&nonce);

        const encrypted_len = self.key_data.len + 16; // + auth tag
        const encrypted = try self.allocator.alloc(u8, encrypted_len);
        defer self.allocator.free(encrypted);

        try encryptData(self.key_data, encrypted, &derived_key, &nonce);

        // Write header
        try file.writeStreamingAll(io, "HOMEKEY\x00");
        try file.writeStreamingAll(io, &.{@intFromEnum(self.algorithm)});
        try file.writeStreamingAll(io, &self.key_id);
        var encoded_int: [8]u8 = undefined;
        std.mem.writeInt(i64, &encoded_int, self.created_at, .little);
        try file.writeStreamingAll(io, &encoded_int);
        std.mem.writeInt(i64, &encoded_int, self.expires_at, .little);
        try file.writeStreamingAll(io, &encoded_int);
        try file.writeStreamingAll(io, &nonce);
        try file.writeStreamingAll(io, encrypted);
    }

    /// Load key from file
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8, password: []const u8) !EncryptionKey {
        const contents = try std.Io.Dir.cwd().readFileAlloc(compat.io(), path, allocator, .limited(1024));
        defer allocator.free(contents);
        var reader = std.Io.Reader.fixed(contents);

        // Read and verify header
        const magic = try reader.takeArray(8);

        if (!std.mem.eql(u8, magic, "HOMEKEY\x00")) {
            return error.InvalidKeyFile;
        }

        const algorithm: coredump.EncryptionAlgorithm = @enumFromInt(try reader.takeByte());

        var key_id: [16]u8 = undefined;
        try reader.readSliceAll(&key_id);

        const created_at = try reader.takeInt(i64, .little);
        const expires_at = try reader.takeInt(i64, .little);

        var nonce: [12]u8 = undefined;
        try reader.readSliceAll(&nonce);

        // Read encrypted key
        const key_size = algorithm.keySize();
        const encrypted_len = key_size + 16;
        const encrypted = try allocator.alloc(u8, encrypted_len);
        defer allocator.free(encrypted);

        try reader.readSliceAll(encrypted);

        // Derive decryption key
        var derived_key: [32]u8 = undefined;
        try deriveKeyFromPassword(password, &derived_key);

        // Decrypt key data
        const key_data = try allocator.alloc(u8, key_size);
        errdefer allocator.free(key_data);

        try decryptData(encrypted, key_data, &derived_key, &nonce);

        return .{
            .algorithm = algorithm,
            .key_data = key_data,
            .key_id = key_id,
            .created_at = created_at,
            .expires_at = expires_at,
            .allocator = allocator,
        };
    }
};

/// Derive key from password using PBKDF2
fn deriveKeyFromPassword(password: []const u8, key_out: *[32]u8) !void {
    const salt = "home_coredump_v1"; // In production, use random salt per file
    const iterations = 100000;

    // Simplified key derivation (production would use proper PBKDF2)
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        hasher.update(password);
        hasher.update(salt);
    }
    hasher.final(key_out);
}

/// Encrypt data using ChaCha20-Poly1305
fn encryptData(plaintext: []const u8, ciphertext: []u8, key: *const [32]u8, nonce: *const [12]u8) !void {
    std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(
        ciphertext[0..plaintext.len],
        ciphertext[plaintext.len..][0..16],
        plaintext,
        "",
        nonce.*,
        key.*,
    );
}

/// Decrypt data using ChaCha20-Poly1305
fn decryptData(ciphertext: []const u8, plaintext: []u8, key: *const [32]u8, nonce: *const [12]u8) !void {
    const tag_start = ciphertext.len - 16;
    try std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(
        plaintext,
        ciphertext[0..tag_start],
        ciphertext[tag_start..][0..16].*,
        "",
        nonce.*,
        key.*,
    );
}

/// Key ring for managing multiple encryption keys
pub const KeyRing = struct {
    keys: std.ArrayList(EncryptionKey),
    active_key_id: ?[16]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KeyRing {
        return .{
            .keys = std.ArrayList(EncryptionKey).empty,
            .active_key_id = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KeyRing) void {
        for (self.keys.items) |*key| {
            key.deinit();
        }
        self.keys.deinit(self.allocator);
    }

    pub fn addKey(self: *KeyRing, key: EncryptionKey) !void {
        try self.keys.append(self.allocator, key);

        // Set as active if first key or no active key
        if (self.active_key_id == null) {
            self.active_key_id = key.key_id;
        }
    }

    pub fn getActiveKey(self: *const KeyRing) ?*const EncryptionKey {
        const active_id = self.active_key_id orelse return null;

        for (self.keys.items) |*key| {
            if (std.mem.eql(u8, &key.key_id, &active_id)) {
                return key;
            }
        }

        return null;
    }

    pub fn findKey(self: *const KeyRing, key_id: []const u8) ?*const EncryptionKey {
        for (self.keys.items) |*key| {
            if (std.mem.eql(u8, &key.key_id, key_id)) {
                return key;
            }
        }
        return null;
    }

    pub fn setActiveKey(self: *KeyRing, key_id: [16]u8) !void {
        // Verify key exists
        const key = self.findKey(&key_id) orelse return error.KeyNotFound;

        if (key.isExpired()) {
            return error.KeyExpired;
        }

        self.active_key_id = key_id;
    }

    pub fn rotate(self: *KeyRing, algorithm: coredump.EncryptionAlgorithm) !void {
        // Generate new key
        var new_key = try EncryptionKey.generate(self.allocator, algorithm);
        errdefer new_key.deinit();

        // Add to ring
        try self.addKey(new_key);

        // Set as active
        self.active_key_id = new_key.key_id;
    }

    pub fn removeExpiredKeys(self: *KeyRing) void {
        var i: usize = 0;
        while (i < self.keys.items.len) {
            if (self.keys.items[i].isExpired()) {
                var removed = self.keys.orderedRemove(i);
                removed.deinit();
            } else {
                i += 1;
            }
        }
    }
};

test "key generation" {
    const testing = std.testing;

    var key = try EncryptionKey.generate(testing.allocator, .aes_256_gcm);
    defer key.deinit();

    try testing.expectEqual(@as(usize, 32), key.key_data.len);
    try testing.expect(!key.isExpired());
}

test "key expiration" {
    const testing = std.testing;

    var key = try EncryptionKey.generate(testing.allocator, .chacha20_poly1305);
    defer key.deinit();

    key.setExpiration(30); // 30 days
    try testing.expect(!key.isExpired());
}

test "key file roundtrip" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(compat.io(), &path_buffer);
    const path = try std.fmt.bufPrint(path_buffer[root_len..], "/key.home", .{});
    const full_path = path_buffer[0 .. root_len + path.len];

    var key = try EncryptionKey.generate(testing.allocator, .aes_256_gcm);
    defer key.deinit();
    try key.saveToFile(full_path, "test password");

    var loaded = try EncryptionKey.loadFromFile(testing.allocator, full_path, "test password");
    defer loaded.deinit();
    try testing.expectEqual(key.algorithm, loaded.algorithm);
    try testing.expectEqualSlices(u8, key.key_data, loaded.key_data);
    try testing.expectEqualSlices(u8, &key.key_id, &loaded.key_id);
}

test "keyring operations" {
    const testing = std.testing;

    var keyring = KeyRing.init(testing.allocator);
    defer keyring.deinit();

    const key1 = try EncryptionKey.generate(testing.allocator, .aes_256_gcm);
    const key1_id = key1.key_id;

    try keyring.addKey(key1);

    const active = keyring.getActiveKey();
    try testing.expect(active != null);
    try testing.expectEqualSlices(u8, &key1_id, &active.?.key_id);
}

test "key rotation" {
    const testing = std.testing;

    var keyring = KeyRing.init(testing.allocator);
    defer keyring.deinit();

    const key1 = try EncryptionKey.generate(testing.allocator, .aes_256_gcm);
    const key1_id = key1.key_id;
    try keyring.addKey(key1);

    try keyring.rotate(.chacha20_poly1305);

    const active = keyring.getActiveKey();
    try testing.expect(active != null);
    try testing.expect(!std.mem.eql(u8, &key1_id, &active.?.key_id));
}
