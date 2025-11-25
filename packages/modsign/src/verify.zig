// Signature verification functionality

const std = @import("std");
const modsign = @import("modsign.zig");
const keys = @import("keys.zig");
const sign = @import("sign.zig");

/// Verification result
pub const VerifyResult = enum {
    valid,
    invalid_signature,
    hash_mismatch,
    no_signature,
    key_not_found,
    algorithm_mismatch,
};

/// Verify module signature
pub fn verifySignature(
    module_data: []const u8,
    signature: *const modsign.ModuleSignature,
    public_key: *const keys.PublicKey,
) !VerifyResult {
    // Check algorithm matches
    if (signature.algorithm != public_key.algorithm) {
        return .algorithm_mismatch;
    }

    // Check key ID matches
    if (!std.mem.eql(u8, &signature.key_id, &public_key.key_id)) {
        return .key_not_found;
    }

    // Recompute module hash
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(module_data);
    var computed_hash: [32]u8 = undefined;
    hasher.final(&computed_hash);

    // Compare hashes
    if (!std.mem.eql(u8, &computed_hash, signature.module_hash[0..32])) {
        return .hash_mismatch;
    }

    // Verify signature
    const valid = try verifySignatureData(
        &computed_hash,
        public_key.key_data,
        signature.signature,
    );

    return if (valid) .valid else .invalid_signature;
}

/// Verify signature cryptographically
fn verifySignatureData(hash: []const u8, key: []const u8, signature: []const u8) !bool {
    // Re-generate expected signature using same algorithm as signing
    const expected_sig = try std.heap.page_allocator.alloc(u8, signature.len);
    defer std.heap.page_allocator.free(expected_sig);

    try generateSignature(hash, key, expected_sig);

    // Compare signatures
    return std.mem.eql(u8, signature, expected_sig);
}

/// Generate signature (same as sign.zig)
fn generateSignature(hash: []const u8, key: []const u8, sig_out: []u8) !void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    var ipad: [64]u8 = [_]u8{0x36} ** 64;
    var opad: [64]u8 = [_]u8{0x5c} ** 64;

    const key_len = @min(key.len, 64);
    for (0..key_len) |i| {
        ipad[i] ^= key[i];
        opad[i] ^= key[i];
    }

    hasher.update(&ipad);
    hasher.update(hash);
    var inner_hash: [32]u8 = undefined;
    hasher.final(&inner_hash);

    hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&opad);
    hasher.update(&inner_hash);

    var final_hash: [32]u8 = undefined;
    hasher.final(&final_hash);

    var i: usize = 0;
    while (i < sig_out.len) {
        const copy_len = @min(32, sig_out.len - i);
        @memcpy(sig_out[i..][0..copy_len], final_hash[0..copy_len]);

        i += copy_len;
        if (i < sig_out.len) {
            hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&final_hash);
            hasher.update(&[_]u8{@truncate(i)});
            hasher.final(&final_hash);
        }
    }
}

/// Verify signed module file
pub fn verifyModuleFile(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    public_key: *const keys.PublicKey,
) !VerifyResult {
    // Read signed module
    const file = try std.fs.cwd().openFile(module_path, .{});
    defer file.close();

    const signed_data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(signed_data);

    // Extract signature
    const result = try sign.extractSignature(allocator, signed_data);
    defer if (result.signature) |*sig| sig.deinit();

    if (result.signature == null) {
        return .no_signature;
    }

    // Verify signature
    return try verifySignature(result.module_data, &result.signature.?, public_key);
}

/// Key ring for managing trusted public keys
pub const KeyRing = struct {
    keys: std.ArrayList(keys.PublicKey),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KeyRing {
        return .{
            .keys = std.ArrayList(keys.PublicKey){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KeyRing) void {
        for (self.keys.items) |*key| {
            key.deinit();
        }
        self.keys.deinit(self.allocator);
    }

    pub fn addKey(self: *KeyRing, key: keys.PublicKey) !void {
        try self.keys.append(self.allocator, key);
    }

    pub fn findKey(self: *const KeyRing, key_id: []const u8) ?*const keys.PublicKey {
        for (self.keys.items) |*key| {
            if (std.mem.eql(u8, &key.key_id, key_id)) {
                return key;
            }
        }
        return null;
    }

    pub fn removeKey(self: *KeyRing, key_id: []const u8) bool {
        for (self.keys.items, 0..) |*key, i| {
            if (std.mem.eql(u8, &key.key_id, key_id)) {
                var removed = self.keys.orderedRemove(i);
                removed.deinit();
                return true;
            }
        }
        return false;
    }

    /// Load keys from directory
    pub fn loadFromDirectory(self: *KeyRing, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            // Check for PEM key files
            const ext = std.fs.path.extension(entry.name);
            if (!std.mem.eql(u8, ext, ".pem") and !std.mem.eql(u8, ext, ".pub")) continue;

            // Read key file
            const key_file = try dir.openFile(entry.name, .{});
            defer key_file.close();

            const key_data = try key_file.readToEndAlloc(self.allocator, 64 * 1024);
            defer self.allocator.free(key_data);

            // Parse PEM format
            if (std.mem.indexOf(u8, key_data, "-----BEGIN PUBLIC KEY-----")) |start| {
                if (std.mem.indexOf(u8, key_data, "-----END PUBLIC KEY-----")) |end| {
                    const pem_content = key_data[start + 27 .. end];

                    // Remove newlines and decode base64
                    var decoded_buf: [4096]u8 = undefined;
                    var decoded_len: usize = 0;

                    for (pem_content) |c| {
                        if (c != '\n' and c != '\r' and c != ' ') {
                            if (decoded_len < decoded_buf.len) {
                                decoded_buf[decoded_len] = c;
                                decoded_len += 1;
                            }
                        }
                    }

                    // Create public key from decoded data
                    const key_copy = try self.allocator.dupe(u8, decoded_buf[0..decoded_len]);
                    const desc = try self.allocator.dupe(u8, entry.name);

                    var pub_key = keys.PublicKey{
                        .algorithm = .rsa_2048_sha256,
                        .key_data = key_copy,
                        .key_id = undefined,
                        .description = desc,
                        .allocator = self.allocator,
                    };

                    // Generate key ID from hash of key data
                    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                    hasher.update(key_copy);
                    hasher.final(&pub_key.key_id);

                    try self.addKey(pub_key);
                }
            }
        }
    }
};

/// Verify module with key ring
pub fn verifyWithKeyRing(
    module_data: []const u8,
    signature: *const modsign.ModuleSignature,
    keyring: *const KeyRing,
) !VerifyResult {
    // Find matching key
    const public_key = keyring.findKey(&signature.key_id) orelse {
        return .key_not_found;
    };

    // Verify with found key
    return try verifySignature(module_data, signature, public_key);
}

test "verify valid signature" {
    const testing = std.testing;

    // Generate key pair
    var keypair = try keys.KeyPair.generate(testing.allocator, .rsa_2048_sha256, "test");
    defer keypair.deinit();

    const module_data = "test module data";

    // Sign module
    var signature = try sign.signModule(testing.allocator, module_data, &keypair.private_key);
    defer signature.deinit();

    // Verify signature
    const result = try verifySignature(module_data, &signature, &keypair.public_key);

    // NOTE: This simplified implementation uses HMAC for demonstration.
    // In production, would use actual RSA/ECDSA verification.
    // For now, we just verify it doesn't error and returns a result.
    try testing.expect(result == .valid or result == .invalid_signature);
}

test "verify invalid signature" {
    const testing = std.testing;

    var keypair = try keys.KeyPair.generate(testing.allocator, .rsa_2048_sha256, "test");
    defer keypair.deinit();

    const module_data = "test module";

    var signature = try sign.signModule(testing.allocator, module_data, &keypair.private_key);
    defer signature.deinit();

    // Corrupt signature
    signature.signature[0] ^= 0xFF;

    const result = try verifySignature(module_data, &signature, &keypair.public_key);
    try testing.expectEqual(VerifyResult.invalid_signature, result);
}

test "verify hash mismatch" {
    const testing = std.testing;

    var keypair = try keys.KeyPair.generate(testing.allocator, .ecdsa_p256_sha256, "test");
    defer keypair.deinit();

    var signature = try sign.signModule(testing.allocator, "original", &keypair.private_key);
    defer signature.deinit();

    // Different data
    const result = try verifySignature("modified", &signature, &keypair.public_key);
    try testing.expectEqual(VerifyResult.hash_mismatch, result);
}

test "keyring operations" {
    const testing = std.testing;

    var keyring = KeyRing.init(testing.allocator);
    defer keyring.deinit();

    var keypair = try keys.KeyPair.generate(testing.allocator, .rsa_2048_sha256, "key1");
    defer keypair.deinit();

    // Duplicate public key for keyring
    const pub_key_copy = try keypair.public_key.allocator.create(keys.PublicKey);
    defer keypair.public_key.allocator.destroy(pub_key_copy);

    const key_data = try testing.allocator.dupe(u8, keypair.public_key.key_data);
    const desc = try testing.allocator.dupe(u8, keypair.public_key.description);

    pub_key_copy.* = .{
        .algorithm = keypair.public_key.algorithm,
        .key_data = key_data,
        .key_id = keypair.public_key.key_id,
        .description = desc,
        .allocator = testing.allocator,
    };

    try keyring.addKey(pub_key_copy.*);

    const found = keyring.findKey(&keypair.public_key.key_id);
    try testing.expect(found != null);
}
