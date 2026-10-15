const std = @import("std");
const crypto = @import("basics_crypto");
const advanced = crypto.Advanced;

test "seeded random generation is deterministic" {
    var left = crypto.Random.init(0x1234);
    var right = crypto.Random.init(0x1234);
    var left_bytes: [32]u8 = undefined;
    var right_bytes: [32]u8 = undefined;
    left.bytes(&left_bytes);
    right.bytes(&right_bytes);
    try std.testing.expectEqualSlices(u8, &left_bytes, &right_bytes);
}

test "secure random utilities return correctly shaped values" {
    var random_bytes: [32]u8 = undefined;
    try crypto.SecureRandom.bytesWithIo(std.testing.io, &random_bytes);
    try std.testing.expectError(error.EntropyUnavailable, crypto.SecureRandom.bytesWithIo(std.Io.failing, &random_bytes));

    for (0..64) |_| {
        const value = try crypto.SecureRandom.intRangeWithIo(std.testing.io, i16, -7, 11);
        try std.testing.expect(value >= -7 and value <= 11);
    }
    try std.testing.expectError(error.EntropyUnavailable, crypto.SecureRandom.intRangeWithIo(std.Io.failing, u32, 10, 20));

    const uuid = try crypto.UUID.v4WithIo(std.testing.io);
    try std.testing.expectEqual(@as(u8, 4), uuid.bytes[6] >> 4);
    try std.testing.expectEqual(@as(u8, 2), uuid.bytes[8] >> 6);
}

test "salt allocation is rolled back when secure entropy is unavailable" {
    try std.testing.expectError(error.EntropyUnavailable, crypto.Password.generateSaltWithIo(std.testing.allocator, std.Io.failing));
}

test "password hashes verify with the same salt" {
    const hash = try crypto.Password.hash(std.testing.allocator, "correct horse battery staple", "0123456789abcdef");
    defer std.testing.allocator.free(hash);

    try std.testing.expect(try crypto.Password.verifyWithAllocator(std.testing.allocator, "correct horse battery staple", "0123456789abcdef", hash));
    try std.testing.expect(!try crypto.Password.verifyWithAllocator(std.testing.allocator, "wrong password", "0123456789abcdef", hash));
}

test "advanced signing and key agreement APIs are usable" {
    var random = try advanced.Random.initWithIo(std.testing.io);
    var bytes: [16]u8 = undefined;
    random.bytes(&bytes);
    try std.testing.expectError(error.EntropyUnavailable, advanced.Random.initWithIo(std.Io.failing));

    const signing_key = try advanced.Ed25519.generateKeyPairWithIo(std.testing.io);
    const signature = try advanced.Ed25519.sign("home", signing_key.secret_key);
    try advanced.Ed25519.verify(signature, "home", signing_key.public_key);
    try std.testing.expectError(error.EntropyUnavailable, advanced.Ed25519.generateKeyPairWithIo(std.Io.failing));

    const key_pair = try advanced.X25519.generateKeyPairWithIo(std.testing.io);
    _ = try advanced.X25519.computeSharedSecret(key_pair.secret, key_pair.public);
    const identity_public_key: advanced.X25519.PublicKey = @splat(0);
    try std.testing.expectError(error.IdentityElement, advanced.X25519.computeSharedSecret(key_pair.secret, identity_public_key));
    try std.testing.expectError(error.EntropyUnavailable, advanced.X25519.generateKeyPairWithIo(std.Io.failing));
}

test "authenticated decryption rejects a modified tag" {
    const key: [advanced.Aes256Gcm.key_length]u8 = @splat(0x42);
    const nonce: [advanced.Aes256Gcm.nonce_length]u8 = @splat(0x24);
    const plaintext = "authenticated";
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [advanced.Aes256Gcm.tag_length]u8 = undefined;

    try advanced.Aes256Gcm.encrypt(&key, &nonce, plaintext, "home", &ciphertext, &tag);

    var decrypted: [plaintext.len]u8 = undefined;
    try advanced.Aes256Gcm.decrypt(&key, &nonce, &ciphertext, tag, "home", &decrypted);
    try std.testing.expectEqualStrings(plaintext, &decrypted);

    tag[0] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, advanced.Aes256Gcm.decrypt(&key, &nonce, &ciphertext, tag, "home", &decrypted));
}

test "secureZero clears the whole buffer" {
    var secret: [32]u8 = @splat(0xa5);
    advanced.secureZero(&secret);
    const zeros: [32]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zeros, &secret);
}
