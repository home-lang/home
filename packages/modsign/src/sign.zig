// Module signing functionality

const std = @import("std");
const modsign = @import("modsign.zig");
const keys = @import("keys.zig");

/// Sign a kernel module
pub fn signModule(
    allocator: std.mem.Allocator,
    module_data: []const u8,
    private_key: *const keys.PrivateKey,
) !modsign.ModuleSignature {
    var signature = try modsign.ModuleSignature.init(allocator, private_key.algorithm);
    errdefer signature.deinit();

    // Hash the module data
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(module_data);
    hasher.final(signature.module_hash[0..32]);
    signature.hash_len = 32;

    // Copy key ID
    @memcpy(&signature.key_id, &private_key.key_id);

    // Generate signature
    // In production, this would use RSA/ECDSA signing
    // For now, use HMAC-SHA256 as a simplified signature
    try generateSignature(
        &signature.module_hash,
        private_key.key_data,
        signature.signature,
    );

    return signature;
}

/// Generate cryptographic signature
fn generateSignature(hash: []const u8, key: []const u8, sig_out: []u8) !void {
    // HMAC-SHA256 based signature
    // In production, would use RSA-PSS or ECDSA

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Inner hash: hash(key XOR ipad || message)
    var ipad: [64]u8 = [_]u8{0x36} ** 64;
    var opad: [64]u8 = [_]u8{0x5c} ** 64;

    // XOR key into pads
    const key_len = @min(key.len, 64);
    for (0..key_len) |i| {
        ipad[i] ^= key[i];
        opad[i] ^= key[i];
    }

    // Inner hash
    hasher.update(&ipad);
    hasher.update(hash);
    var inner_hash: [32]u8 = undefined;
    hasher.final(&inner_hash);

    // Outer hash
    hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&opad);
    hasher.update(&inner_hash);

    var final_hash: [32]u8 = undefined;
    hasher.final(&final_hash);

    // Expand hash to signature size if needed
    var i: usize = 0;
    while (i < sig_out.len) {
        const copy_len = @min(32, sig_out.len - i);
        @memcpy(sig_out[i..][0..copy_len], final_hash[0..copy_len]);

        i += copy_len;
        if (i < sig_out.len) {
            // Generate more bytes by hashing again
            hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&final_hash);
            hasher.update(&[_]u8{@truncate(i)});
            hasher.final(&final_hash);
        }
    }
}

/// Sign module file and append signature
pub fn signModuleFile(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    private_key: *const keys.PrivateKey,
    output_path: ?[]const u8,
) !void {
    // Read module file
    const module_file = try std.fs.cwd().openFile(module_path, .{});
    defer module_file.close();

    const module_data = try module_file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB max
    defer allocator.free(module_data);

    // Sign the module
    var signature = try signModule(allocator, module_data, private_key);
    defer signature.deinit();

    // Serialize signature
    const sig_bytes = try serializeSignature(allocator, &signature);
    defer allocator.free(sig_bytes);

    // Write signed module
    const out_path = output_path orelse module_path;
    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();

    // Write original module
    try out_file.writeAll(module_data);

    // Append signature
    try out_file.writeAll(sig_bytes);

    // Write signature magic and length at end
    const magic = "~Module signature appended~\n";
    try out_file.writeAll(magic);

    var sig_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &sig_len_buf, @truncate(sig_bytes.len), .little);
    try out_file.writeAll(&sig_len_buf);
}

/// Serialize signature to binary format
pub fn serializeSignature(allocator: std.mem.Allocator, sig: *const modsign.ModuleSignature) ![]u8 {
    // Format: algorithm(1) | key_id(32) | hash_len(1) | hash(N) | sig_len(2) | signature(M)
    const total_len = 1 + 32 + 1 + sig.hash_len + 2 + sig.signature.len;
    const bytes = try allocator.alloc(u8, total_len);
    errdefer allocator.free(bytes);

    var offset: usize = 0;

    // Algorithm
    bytes[offset] = @intFromEnum(sig.algorithm);
    offset += 1;

    // Key ID
    @memcpy(bytes[offset..][0..32], &sig.key_id);
    offset += 32;

    // Hash length
    bytes[offset] = @truncate(sig.hash_len);
    offset += 1;

    // Hash
    @memcpy(bytes[offset..][0..sig.hash_len], sig.module_hash[0..sig.hash_len]);
    offset += sig.hash_len;

    // Signature length
    std.mem.writeInt(u16, bytes[offset..][0..2], @truncate(sig.signature.len), .little);
    offset += 2;

    // Signature
    @memcpy(bytes[offset..][0..sig.signature.len], sig.signature);

    return bytes;
}

/// Extract module data and signature from signed module file
pub fn extractSignature(
    allocator: std.mem.Allocator,
    signed_module: []const u8,
) !struct { module_data: []const u8, signature: ?modsign.ModuleSignature } {
    const magic = "~Module signature appended~\n";

    // Check for signature magic at end
    if (signed_module.len < magic.len + 4) {
        return .{ .module_data = signed_module, .signature = null };
    }

    const magic_start = signed_module.len - magic.len - 4;
    const found_magic = signed_module[magic_start..][0..magic.len];

    if (!std.mem.eql(u8, found_magic, magic)) {
        return .{ .module_data = signed_module, .signature = null };
    }

    // Read signature length
    const sig_len = std.mem.readInt(u32, signed_module[signed_module.len - 4 ..][0..4], .little);

    if (magic_start < sig_len) {
        return error.InvalidSignatureLength;
    }

    const sig_start = magic_start - sig_len;
    const sig_bytes = signed_module[sig_start..magic_start];

    // Deserialize signature
    const signature = try deserializeSignature(allocator, sig_bytes);

    return .{
        .module_data = signed_module[0..sig_start],
        .signature = signature,
    };
}

/// Deserialize binary signature format
pub fn deserializeSignature(allocator: std.mem.Allocator, bytes: []const u8) !modsign.ModuleSignature {
    if (bytes.len < 36) {
        return error.InvalidSignatureData;
    }

    var offset: usize = 0;

    // Algorithm
    const algorithm: modsign.SignatureAlgorithm = @enumFromInt(bytes[offset]);
    offset += 1;

    var sig = try modsign.ModuleSignature.init(allocator, algorithm);
    errdefer sig.deinit();

    // Key ID
    @memcpy(&sig.key_id, bytes[offset..][0..32]);
    offset += 32;

    // Hash length
    const hash_len = bytes[offset];
    offset += 1;

    if (hash_len > 64) {
        return error.InvalidHashLength;
    }

    sig.hash_len = hash_len;

    // Hash
    if (offset + hash_len > bytes.len) {
        return error.InvalidSignatureData;
    }

    @memcpy(sig.module_hash[0..hash_len], bytes[offset..][0..hash_len]);
    offset += hash_len;

    // Signature length
    if (offset + 2 > bytes.len) {
        return error.InvalidSignatureData;
    }

    const sig_len = std.mem.readInt(u16, bytes[offset..][0..2], .little);
    offset += 2;

    // Signature
    if (offset + sig_len > bytes.len) {
        return error.InvalidSignatureData;
    }

    // Reallocate signature buffer if needed
    if (sig.signature.len != sig_len) {
        allocator.free(sig.signature);
        sig.signature = try allocator.alloc(u8, sig_len);
    }

    @memcpy(sig.signature, bytes[offset..][0..sig_len]);

    return sig;
}

test "sign module" {
    const testing = std.testing;

    var key = try keys.PrivateKey.generate(testing.allocator, .rsa_2048_sha256, "test");
    defer key.deinit();

    const module_data = "fake kernel module data";

    var signature = try signModule(testing.allocator, module_data, &key);
    defer signature.deinit();

    try testing.expectEqual(@as(usize, 256), signature.signature.len);
    try testing.expectEqualSlices(u8, &key.key_id, &signature.key_id);
}

test "signature serialization" {
    const testing = std.testing;

    var key = try keys.PrivateKey.generate(testing.allocator, .ecdsa_p256_sha256, "test");
    defer key.deinit();

    const module_data = "module";

    var sig = try signModule(testing.allocator, module_data, &key);
    defer sig.deinit();

    const bytes = try serializeSignature(testing.allocator, &sig);
    defer testing.allocator.free(bytes);

    var deserialized = try deserializeSignature(testing.allocator, bytes);
    defer deserialized.deinit();

    try testing.expectEqual(sig.algorithm, deserialized.algorithm);
    try testing.expectEqualSlices(u8, &sig.key_id, &deserialized.key_id);
}

test "extract signature" {
    const testing = std.testing;

    var key = try keys.PrivateKey.generate(testing.allocator, .rsa_2048_sha256, "test");
    defer key.deinit();

    const module_data = "original module data";

    var signature = try signModule(testing.allocator, module_data, &key);
    defer signature.deinit();

    // Create signed module
    const sig_bytes = try serializeSignature(testing.allocator, &signature);
    defer testing.allocator.free(sig_bytes);

    const magic = "~Module signature appended~\n";
    var sig_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &sig_len_buf, @truncate(sig_bytes.len), .little);

    const signed = try std.mem.concat(testing.allocator, u8, &[_][]const u8{
        module_data,
        sig_bytes,
        magic,
        &sig_len_buf,
    });
    defer testing.allocator.free(signed);

    // Extract
    var result = try extractSignature(testing.allocator, signed);
    defer if (result.signature) |*sig| sig.deinit();

    try testing.expectEqualStrings(module_data, result.module_data);
    try testing.expect(result.signature != null);
}
