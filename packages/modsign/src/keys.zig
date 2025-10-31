// Key generation and management for module signing

const std = @import("std");
const modsign = @import("modsign.zig");

/// Private key for signing modules
pub const PrivateKey = struct {
    algorithm: modsign.SignatureAlgorithm,
    key_data: []u8,
    key_id: [32]u8,
    description: []u8,
    allocator: std.mem.Allocator,

    pub fn generate(
        allocator: std.mem.Allocator,
        algorithm: modsign.SignatureAlgorithm,
        description: []const u8,
    ) !PrivateKey {
        const key_size = algorithm.keySize();
        const key_data = try allocator.alloc(u8, key_size);
        errdefer allocator.free(key_data);

        // Generate random key material
        std.crypto.random.bytes(key_data);

        const desc = try allocator.dupe(u8, description);
        errdefer allocator.free(desc);

        var key = PrivateKey{
            .algorithm = algorithm,
            .key_data = key_data,
            .key_id = [_]u8{0} ** 32,
            .description = desc,
            .allocator = allocator,
        };

        // Generate key ID (fingerprint)
        key.generateKeyId();

        return key;
    }

    pub fn deinit(self: *PrivateKey) void {
        // Securely zero key material
        @memset(self.key_data, 0);
        self.allocator.free(self.key_data);
        self.allocator.free(self.description);
    }

    pub fn generateKeyId(self: *PrivateKey) void {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(self.key_data);
        hasher.update(self.description);
        hasher.final(&self.key_id);
    }

    pub fn getPublicKey(self: *const PrivateKey, allocator: std.mem.Allocator) !PublicKey {
        const pub_data = try allocator.alloc(u8, self.algorithm.keySize());
        errdefer allocator.free(pub_data);

        // In production, derive actual public key (e.g., RSA modulus+exponent, ECC point)
        // For this simplified implementation, we just copy the private key
        // (This is NOT secure - only for demonstration)
        @memcpy(pub_data, self.key_data);

        const desc = try allocator.dupe(u8, self.description);

        return PublicKey{
            .algorithm = self.algorithm,
            .key_data = pub_data,
            .key_id = self.key_id,
            .description = desc,
            .allocator = allocator,
        };
    }

    /// Save private key to file (PEM format)
    pub fn savePem(self: *const PrivateKey, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll("-----BEGIN PRIVATE KEY-----\n");

        // Base64 encode key data
        const encoder = std.base64.standard.Encoder;
        var buf: [1024]u8 = undefined;
        const encoded = encoder.encode(&buf, self.key_data);

        // Write in 64-character lines
        var i: usize = 0;
        while (i < encoded.len) {
            const end = @min(i + 64, encoded.len);
            try file.writeAll(encoded[i..end]);
            try file.writeAll("\n");
            i = end;
        }

        try file.writeAll("-----END PRIVATE KEY-----\n");
    }

    /// Load private key from PEM file
    pub fn loadPem(allocator: std.mem.Allocator, file_path: []const u8) !PrivateKey {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Extract base64 content between markers
        const begin = "-----BEGIN PRIVATE KEY-----\n";
        const end = "-----END PRIVATE KEY-----";

        const start_idx = std.mem.indexOf(u8, content, begin) orelse return error.InvalidPemFormat;
        const end_idx = std.mem.indexOf(u8, content, end) orelse return error.InvalidPemFormat;

        const b64_data = content[start_idx + begin.len .. end_idx];

        // Remove newlines
        var clean_data = std.ArrayList(u8){};
        defer clean_data.deinit(allocator);

        for (b64_data) |c| {
            if (c != '\n' and c != '\r' and c != ' ') {
                try clean_data.append(allocator, c);
            }
        }

        // Decode base64
        const decoder = std.base64.standard.Decoder;
        const key_data = try allocator.alloc(u8, try decoder.calcSizeForSlice(clean_data.items));
        errdefer allocator.free(key_data);

        try decoder.decode(key_data, clean_data.items);

        // Create key (algorithm and description would be in metadata)
        const desc = try allocator.dupe(u8, "loaded_key");

        var key = PrivateKey{
            .algorithm = .rsa_2048_sha256, // Default
            .key_data = key_data,
            .key_id = [_]u8{0} ** 32,
            .description = desc,
            .allocator = allocator,
        };

        key.generateKeyId();

        return key;
    }
};

/// Public key for verifying module signatures
pub const PublicKey = struct {
    algorithm: modsign.SignatureAlgorithm,
    key_data: []u8,
    key_id: [32]u8,
    description: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PublicKey) void {
        self.allocator.free(self.key_data);
        self.allocator.free(self.description);
    }

    /// Save public key to file
    pub fn savePem(self: *const PublicKey, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll("-----BEGIN PUBLIC KEY-----\n");

        const encoder = std.base64.standard.Encoder;
        var buf: [1024]u8 = undefined;
        const encoded = encoder.encode(&buf, self.key_data);

        var i: usize = 0;
        while (i < encoded.len) {
            const end = @min(i + 64, encoded.len);
            try file.writeAll(encoded[i..end]);
            try file.writeAll("\n");
            i = end;
        }

        try file.writeAll("-----END PUBLIC KEY-----\n");
    }

    /// Export key ID as hex string
    pub fn keyIdHex(self: *const PublicKey, allocator: std.mem.Allocator) ![]u8 {
        const hex = try allocator.alloc(u8, self.key_id.len * 2);
        _ = try std.fmt.bufPrint(hex, "{x}", .{std.fmt.fmtSliceHexLower(&self.key_id)});
        return hex;
    }
};

/// Key pair for signing and verification
pub const KeyPair = struct {
    private_key: PrivateKey,
    public_key: PublicKey,

    pub fn generate(
        allocator: std.mem.Allocator,
        algorithm: modsign.SignatureAlgorithm,
        description: []const u8,
    ) !KeyPair {
        var private_key = try PrivateKey.generate(allocator, algorithm, description);
        errdefer private_key.deinit();

        const public_key = try private_key.getPublicKey(allocator);

        return .{
            .private_key = private_key,
            .public_key = public_key,
        };
    }

    pub fn deinit(self: *KeyPair) void {
        var priv = self.private_key;
        var pub_key = self.public_key;
        priv.deinit();
        pub_key.deinit();
    }
};

test "key generation" {
    const testing = std.testing;

    var key = try PrivateKey.generate(testing.allocator, .rsa_2048_sha256, "test_key");
    defer key.deinit();

    try testing.expectEqual(@as(usize, 256), key.key_data.len);
    try testing.expectEqualStrings("test_key", key.description);

    // Key ID should be non-zero
    var all_zero = true;
    for (key.key_id) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "public key derivation" {
    const testing = std.testing;

    var priv_key = try PrivateKey.generate(testing.allocator, .rsa_2048_sha256, "test");
    defer priv_key.deinit();

    var pub_key = try priv_key.getPublicKey(testing.allocator);
    defer pub_key.deinit();

    try testing.expectEqual(priv_key.algorithm, pub_key.algorithm);
    try testing.expectEqualSlices(u8, &priv_key.key_id, &pub_key.key_id);
}

test "key pair generation" {
    const testing = std.testing;

    var keypair = try KeyPair.generate(testing.allocator, .ecdsa_p256_sha256, "module_signer");
    defer keypair.deinit();

    try testing.expectEqualSlices(u8, &keypair.private_key.key_id, &keypair.public_key.key_id);
}
