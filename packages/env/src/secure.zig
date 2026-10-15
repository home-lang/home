// Home Programming Language - Secure Environment Variables
// Encryption/decryption of sensitive environment variables using ChaCha20-Poly1305

const std = @import("std");
const crypto = std.crypto;
const compat = @import("compat.zig");
const Io = std.Io;

// Use ChaCha20-Poly1305 for authenticated encryption
const Cipher = crypto.aead.chacha_poly.ChaCha20Poly1305;
const key_len = Cipher.key_length;
const nonce_len = Cipher.nonce_length;
const tag_len = Cipher.tag_length;

pub const SecureEnvError = error{
    InvalidKey,
    InvalidEncryptedData,
    DecryptionFailed,
    KeyDerivationFailed,
    InvalidFormat,
} || std.mem.Allocator.Error ||
    Io.RandomSecureError ||
    Io.Dir.ReadFileAllocError ||
    Io.File.OpenError ||
    Io.File.Writer.Error;

fn privateFilePermissions() Io.File.Permissions {
    return if (@bitSizeOf(Io.File.Permissions) == 0)
        .default_file
    else
        @fromBackingInt(@intCast(0o600));
}

// Encrypted value format: nonce (12 bytes) + ciphertext + tag (16 bytes)
pub const EncryptedValue = struct {
    nonce: [nonce_len]u8,
    ciphertext: []u8,
    tag: [tag_len]u8,

    pub fn deinit(self: *EncryptedValue, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
    }
};

// Key management
pub const SecureKey = struct {
    key: [key_len]u8,

    const Self = @This();

    // Generate a new random key
    pub fn generate() !Self {
        return generateWithIo(compat.io());
    }

    pub fn generateWithIo(io: Io) Io.RandomSecureError!Self {
        var key: [key_len]u8 = undefined;
        try io.randomSecure(&key);
        return .{ .key = key };
    }

    // Derive key from password using Argon2id
    pub fn fromPassword(password: []const u8, salt: []const u8) !Self {
        return fromPasswordWithIo(std.heap.page_allocator, compat.io(), password, salt);
    }

    pub fn fromPasswordWithIo(
        allocator: std.mem.Allocator,
        io: Io,
        password: []const u8,
        salt: []const u8,
    ) !Self {
        if (salt.len < 16) return error.InvalidKey;

        var key: [key_len]u8 = undefined;

        // Use Argon2id with secure parameters
        // These parameters provide good security while being reasonable for most systems
        crypto.pwhash.argon2.kdf(
            allocator,
            &key,
            password,
            salt,
            .{
                .t = 3, // time cost (iterations)
                .m = 65536, // memory cost in KiB (64 MB)
                .p = 4, // parallelism
            },
            .argon2id,
            io,
        ) catch return error.KeyDerivationFailed;

        return .{ .key = key };
    }

    // Load key from file (base64 encoded)
    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
        return fromFileWithIo(allocator, compat.io(), path);
    }

    pub fn fromFileWithIo(allocator: std.mem.Allocator, io: Io, path: []const u8) !Self {
        const content = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
        defer allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        return try fromBase64(allocator, trimmed);
    }

    // Save key to file (base64 encoded)
    pub fn saveToFile(self: *const Self, path: []const u8) !void {
        return self.saveToFileWithIo(compat.io(), path);
    }

    pub fn saveToFileWithIo(self: *const Self, io: Io, path: []const u8) !void {
        const file = try Io.Dir.cwd().createFile(io, path, .{ .permissions = privateFilePermissions() });
        defer file.close(io);

        var buf: [128]u8 = undefined;
        const encoded = std.base64.standard.Encoder.encode(&buf, &self.key);
        try file.writeStreamingAll(io, encoded);
        try file.writeStreamingAll(io, "\n");
    }

    // Encode key as base64
    pub fn toBase64(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        const encoded_len = std.base64.standard.Encoder.calcSize(key_len);
        const buf = try allocator.alloc(u8, encoded_len);
        const result = std.base64.standard.Encoder.encode(buf, &self.key);
        return result;
    }

    // Decode key from base64
    pub fn fromBase64(_: std.mem.Allocator, encoded: []const u8) !Self {
        var key: [key_len]u8 = undefined;
        const decoder = std.base64.standard.Decoder;

        const decoded_len = try decoder.calcSizeForSlice(encoded);
        if (decoded_len != key_len) return error.InvalidKey;

        try decoder.decode(&key, encoded);
        return .{ .key = key };
    }

    // Generate a random salt for key derivation
    pub fn generateSalt() ![32]u8 {
        return generateSaltWithIo(compat.io());
    }

    pub fn generateSaltWithIo(io: Io) Io.RandomSecureError![32]u8 {
        var salt: [32]u8 = undefined;
        try io.randomSecure(&salt);
        return salt;
    }

    // Securely zero out key from memory
    pub fn destroy(self: *Self) void {
        @memset(&self.key, 0);
        // Prevent compiler from optimizing away the zeroing
        std.mem.doNotOptimizeAway(&self.key);
    }
};

// Encrypt a plaintext value
pub fn encrypt(allocator: std.mem.Allocator, plaintext: []const u8, key: *const SecureKey) !EncryptedValue {
    return encryptWithIo(allocator, compat.io(), plaintext, key);
}

pub fn encryptWithIo(
    allocator: std.mem.Allocator,
    io: Io,
    plaintext: []const u8,
    key: *const SecureKey,
) !EncryptedValue {
    // Generate random nonce
    var nonce: [nonce_len]u8 = undefined;
    try io.randomSecure(&nonce);

    // Allocate ciphertext buffer
    const ciphertext = try allocator.alloc(u8, plaintext.len);
    errdefer allocator.free(ciphertext);

    var tag: [tag_len]u8 = undefined;

    // Encrypt with authenticated encryption
    Cipher.encrypt(ciphertext, &tag, plaintext, "", nonce, key.key);

    return .{
        .nonce = nonce,
        .ciphertext = ciphertext,
        .tag = tag,
    };
}

// Decrypt a ciphertext value
pub fn decrypt(allocator: std.mem.Allocator, encrypted: *const EncryptedValue, key: *const SecureKey) ![]u8 {
    const plaintext = try allocator.alloc(u8, encrypted.ciphertext.len);
    errdefer allocator.free(plaintext);

    // Decrypt and verify authentication tag
    Cipher.decrypt(plaintext, encrypted.ciphertext, encrypted.tag, "", encrypted.nonce, key.key) catch {
        return error.DecryptionFailed;
    };

    return plaintext;
}

// Serialize encrypted value to bytes
pub fn serializeEncrypted(allocator: std.mem.Allocator, encrypted: *const EncryptedValue) ![]u8 {
    const total_len = nonce_len + encrypted.ciphertext.len + tag_len;
    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    var offset: usize = 0;

    // nonce
    @memcpy(buf[offset..][0..nonce_len], &encrypted.nonce);
    offset += nonce_len;

    // ciphertext
    @memcpy(buf[offset..][0..encrypted.ciphertext.len], encrypted.ciphertext);
    offset += encrypted.ciphertext.len;

    // tag
    @memcpy(buf[offset..][0..tag_len], &encrypted.tag);

    return buf;
}

// Deserialize encrypted value from bytes
pub fn deserializeEncrypted(allocator: std.mem.Allocator, data: []const u8) !EncryptedValue {
    if (data.len < nonce_len + tag_len) return error.InvalidEncryptedData;

    var nonce: [nonce_len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;

    var offset: usize = 0;

    // nonce
    @memcpy(&nonce, data[offset..][0..nonce_len]);
    offset += nonce_len;

    // ciphertext
    const ciphertext_len = data.len - nonce_len - tag_len;
    const ciphertext = try allocator.alloc(u8, ciphertext_len);
    errdefer allocator.free(ciphertext);
    @memcpy(ciphertext, data[offset..][0..ciphertext_len]);
    offset += ciphertext_len;

    // tag
    @memcpy(&tag, data[offset..][0..tag_len]);

    return .{
        .nonce = nonce,
        .ciphertext = ciphertext,
        .tag = tag,
    };
}

// Encode encrypted value as base64
pub fn encodeEncrypted(allocator: std.mem.Allocator, encrypted: *const EncryptedValue) ![]const u8 {
    const serialized = try serializeEncrypted(allocator, encrypted);
    defer allocator.free(serialized);

    const encoded_len = std.base64.standard.Encoder.calcSize(serialized.len);
    const buf = try allocator.alloc(u8, encoded_len);
    const result = std.base64.standard.Encoder.encode(buf, serialized);
    return result;
}

// Decode encrypted value from base64
pub fn decodeEncrypted(allocator: std.mem.Allocator, encoded: []const u8) !EncryptedValue {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);

    const buf = try allocator.alloc(u8, decoded_len);
    defer allocator.free(buf);

    try decoder.decode(buf, encoded);

    return try deserializeEncrypted(allocator, buf);
}

// Secure environment variable storage
pub const SecureEnv = struct {
    allocator: std.mem.Allocator,
    vars: std.StringHashMap([]const u8), // Stores base64-encoded encrypted values
    key: ?SecureKey,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, key: ?SecureKey) Self {
        return .{
            .allocator = allocator,
            .vars = std.StringHashMap([]const u8).init(allocator),
            .key = key,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.vars.deinit();

        if (self.key) |*k| {
            k.destroy();
        }
    }

    // Set encrypted value
    pub fn set(self: *Self, key_name: []const u8, plaintext: []const u8) !void {
        return self.setWithIo(compat.io(), key_name, plaintext);
    }

    pub fn setWithIo(self: *Self, io: Io, key_name: []const u8, plaintext: []const u8) !void {
        if (self.key == null) return error.InvalidKey;

        var encrypted = try encryptWithIo(self.allocator, io, plaintext, &self.key.?);
        defer encrypted.deinit(self.allocator);

        const encoded = try encodeEncrypted(self.allocator, &encrypted);
        errdefer self.allocator.free(encoded);

        if (self.vars.getPtr(key_name)) |old_value| {
            self.allocator.free(old_value.*);
            old_value.* = encoded;
        } else {
            const key_owned = try self.allocator.dupe(u8, key_name);
            errdefer self.allocator.free(key_owned);
            try self.vars.put(key_owned, encoded);
        }
    }

    // Get and decrypt value
    pub fn get(self: *Self, key_name: []const u8) !?[]u8 {
        if (self.key == null) return error.InvalidKey;

        const encoded = self.vars.get(key_name) orelse return null;

        var encrypted = try decodeEncrypted(self.allocator, encoded);
        defer encrypted.deinit(self.allocator);

        return try decrypt(self.allocator, &encrypted, &self.key.?);
    }

    // Load from encrypted .env file
    pub fn loadFromFile(self: *Self, path: []const u8) !void {
        return self.loadFromFileWithIo(compat.io(), path);
    }

    pub fn loadFromFileWithIo(self: *Self, io: Io, path: []const u8) !void {
        const content = try Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(10 * 1024 * 1024),
        );
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key_name = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            if (key_name.len > 0 and value.len > 0) {
                const value_owned = try self.allocator.dupe(u8, value);
                errdefer self.allocator.free(value_owned);

                if (self.vars.getPtr(key_name)) |old_value| {
                    self.allocator.free(old_value.*);
                    old_value.* = value_owned;
                } else {
                    const key_owned = try self.allocator.dupe(u8, key_name);
                    errdefer self.allocator.free(key_owned);
                    try self.vars.put(key_owned, value_owned);
                }
            }
        }
    }

    // Save to encrypted .env file
    pub fn saveToFile(self: *Self, path: []const u8) !void {
        return self.saveToFileWithIo(compat.io(), path);
    }

    pub fn saveToFileWithIo(self: *Self, io: Io, path: []const u8) !void {
        const file = try Io.Dir.cwd().createFile(io, path, .{ .permissions = privateFilePermissions() });
        defer file.close(io);

        var output: Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;

        try writer.writeAll("# Encrypted environment variables\n");
        try writer.writeAll("# Generated by Home Programming Language\n");
        try writer.writeAll("# DO NOT EDIT MANUALLY\n\n");

        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            try writer.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try file.writeStreamingAll(io, output.written());
    }
};

test "secure key generation" {
    const testing = std.testing;

    var key = try SecureKey.generate();
    defer key.destroy();

    // Key should be non-zero
    var all_zero = true;
    for (key.key) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "secure key base64 encoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var key = try SecureKey.generate();
    defer key.destroy();

    const encoded = try key.toBase64(allocator);
    defer allocator.free(encoded);

    var decoded = try SecureKey.fromBase64(allocator, encoded);
    defer decoded.destroy();

    try testing.expectEqualSlices(u8, &key.key, &decoded.key);
}

test "encrypt and decrypt" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var key = try SecureKey.generate();
    defer key.destroy();

    const plaintext = "secret_password_123";

    var encrypted = try encrypt(allocator, plaintext, &key);
    defer encrypted.deinit(allocator);

    const decrypted = try decrypt(allocator, &encrypted, &key);
    defer allocator.free(decrypted);

    try testing.expectEqualStrings(plaintext, decrypted);
}

test "encrypt decrypt with wrong key fails" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var key1 = try SecureKey.generate();
    defer key1.destroy();

    var key2 = try SecureKey.generate();
    defer key2.destroy();

    const plaintext = "secret_password_123";

    var encrypted = try encrypt(allocator, plaintext, &key1);
    defer encrypted.deinit(allocator);

    const result = decrypt(allocator, &encrypted, &key2);
    try testing.expectError(error.DecryptionFailed, result);
}

test "serialize and deserialize encrypted" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var key = try SecureKey.generate();
    defer key.destroy();

    const plaintext = "test_data";

    var encrypted = try encrypt(allocator, plaintext, &key);
    defer encrypted.deinit(allocator);

    const serialized = try serializeEncrypted(allocator, &encrypted);
    defer allocator.free(serialized);

    var deserialized = try deserializeEncrypted(allocator, serialized);
    defer deserialized.deinit(allocator);

    const decrypted = try decrypt(allocator, &deserialized, &key);
    defer allocator.free(decrypted);

    try testing.expectEqualStrings(plaintext, decrypted);
}

test "secure env set and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const key = try SecureKey.generate();
    var secure_env = SecureEnv.init(allocator, key);
    defer secure_env.deinit();

    try secure_env.set("API_KEY", "super_secret_key_123");

    const value = try secure_env.get("API_KEY");
    try testing.expect(value != null);
    defer allocator.free(value.?);

    try testing.expectEqualStrings("super_secret_key_123", value.?);
}

test "password derivation preserves salt validation and uses explicit IO" {
    const testing = std.testing;
    try testing.expectError(
        error.InvalidKey,
        SecureKey.fromPasswordWithIo(testing.allocator, testing.io, "password", "too-short"),
    );

    var key = try SecureKey.fromPasswordWithIo(
        testing.allocator,
        testing.io,
        "correct horse battery staple",
        "0123456789abcdef",
    );
    defer key.destroy();
    try testing.expect(!std.mem.allEqual(u8, &key.key, 0));
}

test "secure key and environment files round trip through explicit IO" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const key_path = try std.fs.path.join(allocator, &.{ root, "env.key" });
    defer allocator.free(key_path);
    const env_path = try std.fs.path.join(allocator, &.{ root, "env.encrypted" });
    defer allocator.free(env_path);

    var key = try SecureKey.generateWithIo(testing.io);
    defer key.destroy();
    try key.saveToFileWithIo(testing.io, key_path);

    var loaded_key = try SecureKey.fromFileWithIo(allocator, testing.io, key_path);
    defer loaded_key.destroy();
    try testing.expectEqualSlices(u8, &key.key, &loaded_key.key);

    var original = SecureEnv.init(allocator, loaded_key);
    defer original.deinit();
    try original.setWithIo(testing.io, "API_KEY", "secret-value");
    try original.saveToFileWithIo(testing.io, env_path);

    var loaded = SecureEnv.init(allocator, loaded_key);
    defer loaded.deinit();
    try loaded.loadFromFileWithIo(testing.io, env_path);
    const value = (try loaded.get("API_KEY")).?;
    defer allocator.free(value);
    try testing.expectEqualStrings("secret-value", value);
}
