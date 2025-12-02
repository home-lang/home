// Home Programming Language - Cryptographic Functions
// SHA-256 and other cryptographic primitives

const std = @import("std");
const Basics = @import("basics");

/// SHA-256 hash (256 bits = 32 bytes)
pub const Sha256Hash = [32]u8;

/// SHA-1 hash (160 bits = 20 bytes)
pub const Sha1Hash = [20]u8;

/// Calculate SHA-256 hash of data
pub fn sha256(data: []const u8) Sha256Hash {
    var hash: Sha256Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

/// Calculate SHA-1 hash of data
pub fn sha1(data: []const u8) Sha1Hash {
    var hash: Sha1Hash = undefined;
    std.crypto.hash.Sha1.hash(data, &hash, .{});
    return hash;
}

/// Format hash as hex string
pub fn hashToHex(hash: []const u8, buffer: []u8) ![]const u8 {
    if (buffer.len < hash.len * 2) {
        return error.BufferTooSmall;
    }

    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        buffer[i * 2] = hex_chars[byte >> 4];
        buffer[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return buffer[0 .. hash.len * 2];
}

// ============================================================================
// Tests
// ============================================================================

test "crypto - sha256 basic" {
    const testing = std.testing;

    // Test empty string
    const empty_hash = sha256("");
    const expected_empty = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try testing.expectEqualSlices(u8, &expected_empty, &empty_hash);

    // Test "hello world"
    const hello_hash = sha256("hello world");
    // SHA256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
    const expected_hello = [_]u8{
        0xb9, 0x4d, 0x27, 0xb9, 0x93, 0x4d, 0x3e, 0x08,
        0xa5, 0x2e, 0x52, 0xd7, 0xda, 0x7d, 0xab, 0xfa,
        0xc4, 0x84, 0xef, 0xe3, 0x7a, 0x53, 0x80, 0xee,
        0x90, 0x88, 0xf7, 0xac, 0xe2, 0xef, 0xcd, 0xe9,
    };
    try testing.expectEqualSlices(u8, &expected_hello, &hello_hash);
}

test "crypto - sha1 basic" {
    const testing = std.testing;

    // Test empty string
    const empty_hash = sha1("");
    const expected_empty = [_]u8{
        0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d,
        0x32, 0x55, 0xbf, 0xef, 0x95, 0x60, 0x18, 0x90,
        0xaf, 0xd8, 0x07, 0x09,
    };
    try testing.expectEqualSlices(u8, &expected_empty, &empty_hash);
}

test "crypto - hash to hex" {
    const testing = std.testing;

    const hash = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var buffer: [8]u8 = undefined;

    const hex = try hashToHex(&hash, &buffer);
    try testing.expectEqualStrings("deadbeef", hex);
}
