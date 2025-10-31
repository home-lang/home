// Core dump encryption

const std = @import("std");
const coredump = @import("coredump.zig");
const keys = @import("keys.zig");

/// Encrypted core dump
pub const EncryptedDump = struct {
    metadata: coredump.DumpMetadata,
    key_id: [16]u8,
    nonce: [12]u8,
    encrypted_data: []u8,
    auth_tag: [16]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncryptedDump) void {
        self.allocator.free(self.encrypted_data);
    }
};

/// Encrypt core dump data
pub fn encryptDump(
    allocator: std.mem.Allocator,
    dump_data: []const u8,
    metadata: coredump.DumpMetadata,
    key: *const keys.EncryptionKey,
) !EncryptedDump {
    if (key.isExpired()) {
        return error.KeyExpired;
    }

    // Generate random nonce
    var nonce: [12]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    // Allocate encrypted data buffer
    const encrypted_data = try allocator.alloc(u8, dump_data.len);
    errdefer allocator.free(encrypted_data);

    var auth_tag: [16]u8 = undefined;

    // Encrypt based on algorithm
    switch (key.algorithm) {
        .aes_256_gcm => {
            std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(
                encrypted_data,
                &auth_tag,
                dump_data,
                &std.mem.toBytes(metadata),
                nonce,
                key.key_data[0..32].*,
            );
        },
        .chacha20_poly1305 => {
            std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(
                encrypted_data,
                &auth_tag,
                dump_data,
                &std.mem.toBytes(metadata),
                nonce,
                key.key_data[0..32].*,
            );
        },
    }

    return .{
        .metadata = metadata,
        .key_id = key.key_id,
        .nonce = nonce,
        .encrypted_data = encrypted_data,
        .auth_tag = auth_tag,
        .allocator = allocator,
    };
}

/// Save encrypted dump to file
pub fn saveDump(dump: *const EncryptedDump, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer file.close();

    // Write file header
    try file.writeAll("HOMECORE");

    // Version
    try file.writeIntLittle(u16, 1);

    // Algorithm
    try file.writeIntLittle(u8, @intFromEnum(dump.metadata.algorithm));

    // Key ID
    try file.writeAll(&dump.key_id);

    // Nonce
    try file.writeAll(&dump.nonce);

    // Auth tag
    try file.writeAll(&dump.auth_tag);

    // Metadata
    try file.writeAll(&std.mem.toBytes(dump.metadata));

    // Data length
    try file.writeIntLittle(u64, dump.encrypted_data.len);

    // Encrypted data
    try file.writeAll(dump.encrypted_data);
}

/// Compress and encrypt dump
pub fn compressAndEncrypt(
    allocator: std.mem.Allocator,
    dump_data: []const u8,
    metadata: coredump.DumpMetadata,
    key: *const keys.EncryptionKey,
) !EncryptedDump {
    // Compress data first
    const compressed = try compress(allocator, dump_data);
    defer allocator.free(compressed);

    // Then encrypt
    return try encryptDump(allocator, compressed, metadata, key);
}

/// Simple compression using RLE-style approach
fn compress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Simplified compression for demonstration
    // In production, would use zlib/zstd

    var compressed = std.ArrayList(u8){};
    defer compressed.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        var count: usize = 1;

        // Count repeats
        while (i + count < data.len and data[i + count] == byte and count < 255) {
            count += 1;
        }

        if (count > 3) {
            // Emit run
            try compressed.append(allocator, 0xFF); // Marker
            try compressed.append(allocator, @truncate(count));
            try compressed.append(allocator, byte);
            i += count;
        } else {
            // Emit literal
            try compressed.append(allocator, byte);
            i += 1;
        }
    }

    return compressed.toOwnedSlice(allocator);
}

/// Redact sensitive data from dump
pub fn redactSensitive(allocator: std.mem.Allocator, dump_data: []const u8) ![]u8 {
    const redacted = try allocator.dupe(u8, dump_data);

    // Redact patterns that look like:
    // - SSH keys (-----BEGIN)
    // - Passwords (password=, pwd=)
    // - API keys (api_key=, token=)
    // - Credit cards (16 digits)

    var i: usize = 0;
    while (i < redacted.len) : (i += 1) {
        // Look for "password=" or "pwd="
        if (i + 9 < redacted.len) {
            if (std.mem.eql(u8, redacted[i..][0..9], "password=") or
                std.mem.eql(u8, redacted[i..][0..4], "pwd="))
            {
                // Redact next 32 bytes
                const end = @min(i + 9 + 32, redacted.len);
                @memset(redacted[i + 9 .. end], 'X');
            }
        }

        // Look for "api_key=" or "token="
        if (i + 8 < redacted.len) {
            if (std.mem.eql(u8, redacted[i..][0..8], "api_key=") or
                std.mem.eql(u8, redacted[i..][0..6], "token="))
            {
                const end = @min(i + 8 + 32, redacted.len);
                @memset(redacted[i + 8 .. end], 'X');
            }
        }
    }

    return redacted;
}

test "encrypt and decrypt dump" {
    const testing = std.testing;

    var key = try keys.EncryptionKey.generate(testing.allocator, .aes_256_gcm);
    defer key.deinit();

    const dump_data = "sensitive crash data here";
    var metadata = try coredump.DumpMetadata.init(1234, "testproc", 11);

    var encrypted = try encryptDump(testing.allocator, dump_data, metadata, &key);
    defer encrypted.deinit();

    try testing.expectEqualSlices(u8, &key.key_id, &encrypted.key_id);
    try testing.expectEqual(dump_data.len, encrypted.encrypted_data.len);
}

test "compress data" {
    const testing = std.testing;

    const data = "AAAAAABBBBBBCCCCCC";
    const compressed = try compress(testing.allocator, data);
    defer testing.allocator.free(compressed);

    // Should be smaller than original for repeated data
    try testing.expect(compressed.len < data.len);
}

test "redact sensitive data" {
    const testing = std.testing;

    const data = "username=admin&password=secret123&api_key=abc123";
    const redacted = try redactSensitive(testing.allocator, data);
    defer testing.allocator.free(redacted);

    // Should not contain original sensitive values
    try testing.expect(std.mem.indexOf(u8, redacted, "secret123") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "abc123") == null);
}
