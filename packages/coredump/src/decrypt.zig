// Core dump decryption and analysis

const std = @import("std");
const coredump = @import("coredump.zig");
const keys = @import("keys.zig");
const encrypt = @import("encrypt.zig");
const compat = @import("compat.zig");

fn readExactAt(file: std.Io.File, io: std.Io, buffer: []u8, offset: u64) !void {
    if (try file.readPositionalAll(io, buffer, offset) != buffer.len) return error.UnexpectedEof;
}

/// Load encrypted dump from file
pub fn loadDump(allocator: std.mem.Allocator, path: []const u8) !encrypt.EncryptedDump {
    const io = compat.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var offset: u64 = 0;

    // Read and verify header
    var magic: [8]u8 = undefined;
    try readExactAt(file, io, &magic, offset);
    offset += magic.len;

    if (!std.mem.eql(u8, &magic, "HOMECORE")) {
        return error.InvalidDumpFile;
    }

    // Read version
    var encoded_u16: [2]u8 = undefined;
    try readExactAt(file, io, &encoded_u16, offset);
    offset += encoded_u16.len;
    const version = std.mem.readInt(u16, &encoded_u16, .little);
    if (version != 1) {
        return error.UnsupportedVersion;
    }

    // Read algorithm
    var algorithm_byte: [1]u8 = undefined;
    try readExactAt(file, io, &algorithm_byte, offset);
    offset += algorithm_byte.len;
    const algorithm: coredump.EncryptionAlgorithm = @enumFromInt(algorithm_byte[0]);

    // Read key ID
    var key_id: [16]u8 = undefined;
    try readExactAt(file, io, &key_id, offset);
    offset += key_id.len;

    // Read nonce
    var nonce: [12]u8 = undefined;
    try readExactAt(file, io, &nonce, offset);
    offset += nonce.len;

    // Read auth tag
    var auth_tag: [16]u8 = undefined;
    try readExactAt(file, io, &auth_tag, offset);
    offset += auth_tag.len;

    // Read metadata
    var metadata: coredump.DumpMetadata = undefined;
    const metadata_bytes = std.mem.asBytes(&metadata);
    try readExactAt(file, io, metadata_bytes, offset);
    offset += metadata_bytes.len;

    // Update algorithm from file
    metadata.algorithm = algorithm;

    // Read data length
    var encoded_u64: [8]u8 = undefined;
    try readExactAt(file, io, &encoded_u64, offset);
    offset += encoded_u64.len;
    const data_len_u64 = std.mem.readInt(u64, &encoded_u64, .little);
    const data_len = std.math.cast(usize, data_len_u64) orelse return error.DumpTooLarge;
    const stat = try file.stat(io);
    if (data_len_u64 > stat.size -| offset) return error.UnexpectedEof;

    // Read encrypted data
    const encrypted_data = try allocator.alloc(u8, data_len);
    errdefer allocator.free(encrypted_data);

    try readExactAt(file, io, encrypted_data, offset);

    return .{
        .metadata = metadata,
        .key_id = key_id,
        .nonce = nonce,
        .encrypted_data = encrypted_data,
        .auth_tag = auth_tag,
        .allocator = allocator,
    };
}

/// Decrypt core dump
pub fn decryptDump(
    allocator: std.mem.Allocator,
    encrypted: *const encrypt.EncryptedDump,
    key: *const keys.EncryptionKey,
) ![]u8 {
    // Verify key matches
    if (!std.mem.eql(u8, &encrypted.key_id, &key.key_id)) {
        return error.KeyMismatch;
    }

    // Allocate plaintext buffer
    const plaintext = try allocator.alloc(u8, encrypted.encrypted_data.len);
    errdefer allocator.free(plaintext);

    // Decrypt based on algorithm
    switch (key.algorithm) {
        .aes_256_gcm => {
            try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
                plaintext,
                encrypted.encrypted_data,
                encrypted.auth_tag,
                &std.mem.toBytes(encrypted.metadata),
                encrypted.nonce,
                key.key_data[0..32].*,
            );
        },
        .chacha20_poly1305 => {
            try std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(
                plaintext,
                encrypted.encrypted_data,
                encrypted.auth_tag,
                &std.mem.toBytes(encrypted.metadata),
                encrypted.nonce,
                key.key_data[0..32].*,
            );
        },
    }

    return plaintext;
}

/// Decrypt dump using key ring
pub fn decryptWithKeyRing(
    allocator: std.mem.Allocator,
    encrypted: *const encrypt.EncryptedDump,
    keyring: *const keys.KeyRing,
) ![]u8 {
    // Find matching key
    const key = keyring.findKey(&encrypted.key_id) orelse {
        return error.KeyNotFound;
    };

    return try decryptDump(allocator, encrypted, key);
}

/// Dump analysis result
pub const DumpAnalysis = struct {
    metadata: coredump.DumpMetadata,
    data_size: usize,
    encrypted: bool,
    algorithm: ?coredump.EncryptionAlgorithm,
    key_id: ?[16]u8,
    can_decrypt: bool,

    pub fn format(
        self: DumpAnalysis,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Dump Analysis:\n", .{});
        try writer.print("  {}\n", .{self.metadata});
        try writer.print("  Data Size: {d} bytes\n", .{self.data_size});
        try writer.print("  Encrypted: {}\n", .{self.encrypted});

        if (self.algorithm) |algo| {
            try writer.print("  Algorithm: {s}\n", .{algo.name()});
        }

        if (self.key_id) |key_id| {
            try writer.print("  Key ID: ", .{});
            for (key_id) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.print("\n", .{});
        }

        try writer.print("  Can Decrypt: {}\n", .{self.can_decrypt});
    }
};

/// Analyze dump file without decrypting
pub fn analyzeDump(allocator: std.mem.Allocator, path: []const u8, keyring: ?*const keys.KeyRing) !DumpAnalysis {
    var dump = try loadDump(allocator, path);
    defer dump.deinit();

    var can_decrypt = false;
    if (keyring) |ring| {
        if (ring.findKey(&dump.key_id)) |_| {
            can_decrypt = true;
        }
    }

    return .{
        .metadata = dump.metadata,
        .data_size = dump.encrypted_data.len,
        .encrypted = true,
        .algorithm = dump.metadata.algorithm,
        .key_id = dump.key_id,
        .can_decrypt = can_decrypt,
    };
}

/// Extract metadata from encrypted dump
pub fn extractMetadata(path: []const u8) !coredump.DumpMetadata {
    const io = compat.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // Read header
    var magic: [8]u8 = undefined;
    if (try file.readPositionalAll(io, &magic, 0) != magic.len) return error.UnexpectedEof;

    if (!std.mem.eql(u8, &magic, "HOMECORE")) {
        return error.InvalidDumpFile;
    }

    // Read metadata
    var metadata: coredump.DumpMetadata = undefined;
    const metadata_offset = 8 + 2 + 1 + 16 + 12 + 16;
    const metadata_bytes = std.mem.asBytes(&metadata);
    if (try file.readPositionalAll(io, metadata_bytes, metadata_offset) != metadata_bytes.len)
        return error.UnexpectedEof;

    return metadata;
}

test "encrypt and decrypt roundtrip" {
    const testing = std.testing;

    var key = try keys.EncryptionKey.generate(testing.allocator, .chacha20_poly1305);
    defer key.deinit();

    const original = "crash dump data with sensitive info";
    const metadata = try coredump.DumpMetadata.init(9999, "crasher", 6);

    var encrypted = try encrypt.encryptDump(testing.allocator, original, metadata, &key);
    defer encrypted.deinit();

    const decrypted = try decryptDump(testing.allocator, &encrypted, &key);
    defer testing.allocator.free(decrypted);

    try testing.expectEqualStrings(original, decrypted);
}

test "decrypt with wrong key" {
    const testing = std.testing;

    var key1 = try keys.EncryptionKey.generate(testing.allocator, .aes_256_gcm);
    defer key1.deinit();

    var key2 = try keys.EncryptionKey.generate(testing.allocator, .aes_256_gcm);
    defer key2.deinit();

    const data = "secret data";
    const metadata = try coredump.DumpMetadata.init(1, "test", 11);

    var encrypted = try encrypt.encryptDump(testing.allocator, data, metadata, &key1);
    defer encrypted.deinit();

    const result = decryptDump(testing.allocator, &encrypted, &key2);
    try testing.expectError(error.KeyMismatch, result);
}

test "decrypt with keyring" {
    const testing = std.testing;

    var keyring = keys.KeyRing.init(testing.allocator);
    defer keyring.deinit();

    const key = try keys.EncryptionKey.generate(testing.allocator, .aes_256_gcm);
    const key_id = key.key_id;
    try keyring.addKey(key);

    const data = "dump data";
    const metadata = try coredump.DumpMetadata.init(100, "app", 9);

    var encrypted = try encrypt.encryptDump(testing.allocator, data, metadata, keyring.findKey(&key_id).?);
    defer encrypted.deinit();

    const decrypted = try decryptWithKeyRing(testing.allocator, &encrypted, &keyring);
    defer testing.allocator.free(decrypted);

    try testing.expectEqualStrings(data, decrypted);
}

test "encrypted dump file roundtrip" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(compat.io(), &path_buffer);
    const suffix = try std.fmt.bufPrint(path_buffer[root_len..], "/dump.ecore", .{});
    const path = path_buffer[0 .. root_len + suffix.len];

    var key = try keys.EncryptionKey.generate(testing.allocator, .chacha20_poly1305);
    defer key.deinit();
    const original = "persisted crash dump";
    const metadata = try coredump.DumpMetadata.init(42, "roundtrip", 11);
    var encrypted = try encrypt.encryptDump(testing.allocator, original, metadata, &key);
    defer encrypted.deinit();
    try encrypt.saveDump(&encrypted, path);

    var loaded = try loadDump(testing.allocator, path);
    defer loaded.deinit();
    const decrypted = try decryptDump(testing.allocator, &loaded, &key);
    defer testing.allocator.free(decrypted);
    try testing.expectEqualStrings(original, decrypted);
    try testing.expectEqual(@as(u32, 42), (try extractMetadata(path)).pid);
}
