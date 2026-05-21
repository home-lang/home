const std = @import("std");

pub const EVP_MAX_MD_SIZE: usize = std.crypto.hash.sha2.Sha512.digest_length;

pub const Algorithm = enum {
    blake2b256,
    blake2b512,
    blake2s256,
    md5,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    @"sha512-256",
};

pub fn generate(key: []const u8, data: []const u8, algorithm: anytype, out: *[EVP_MAX_MD_SIZE]u8) ?[]const u8 {
    const name = algorithmName(algorithm);

    if (std.mem.eql(u8, name, "sha1")) return create(std.crypto.auth.hmac.HmacSha1, key, data, out);
    if (std.mem.eql(u8, name, "sha224")) return create(std.crypto.auth.hmac.sha2.HmacSha224, key, data, out);
    if (std.mem.eql(u8, name, "sha256")) return create(std.crypto.auth.hmac.sha2.HmacSha256, key, data, out);
    if (std.mem.eql(u8, name, "sha384")) return create(std.crypto.auth.hmac.sha2.HmacSha384, key, data, out);
    if (std.mem.eql(u8, name, "sha512")) return create(std.crypto.auth.hmac.sha2.HmacSha512, key, data, out);
    if (std.mem.eql(u8, name, "sha512-256") or std.mem.eql(u8, name, "sha512_256")) {
        return create(std.crypto.auth.hmac.Hmac(std.crypto.hash.sha2.Sha512_256), key, data, out);
    }
    if (std.mem.eql(u8, name, "md5")) return create(std.crypto.auth.hmac.HmacMd5, key, data, out);
    if (std.mem.eql(u8, name, "blake2b256")) {
        return create(std.crypto.auth.hmac.Hmac(std.crypto.hash.blake2.Blake2b256), key, data, out);
    }
    if (std.mem.eql(u8, name, "blake2b512")) {
        return create(std.crypto.auth.hmac.Hmac(std.crypto.hash.blake2.Blake2b512), key, data, out);
    }
    if (std.mem.eql(u8, name, "blake2s256")) {
        return create(std.crypto.auth.hmac.Hmac(std.crypto.hash.blake2.Blake2s256), key, data, out);
    }

    return null;
}

fn create(comptime Hmac: type, key: []const u8, data: []const u8, out: *[EVP_MAX_MD_SIZE]u8) []const u8 {
    var digest: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&digest, data, key);
    @memcpy(out[0..Hmac.mac_length], &digest);
    return out[0..Hmac.mac_length];
}

fn algorithmName(algorithm: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(algorithm))) {
        .@"enum", .enum_literal => @tagName(algorithm),
        else => @compileError("sha_hmac.hmac.generate expects an enum algorithm tag"),
    };
}

fn expectHex(bytes: []const u8, expected: []const u8) !void {
    var actual: [EVP_MAX_MD_SIZE * 2]u8 = undefined;
    const hex = try std.fmt.bufPrint(&actual, "{x}", .{bytes});
    try std.testing.expectEqualStrings(expected, hex);
}

test "sha_hmac hmac sha1 rfc 2202 vector" {
    const key: [20]u8 = @splat(0x0b);
    var out: [EVP_MAX_MD_SIZE]u8 = undefined;
    const digest = generate(&key, "Hi There", .sha1, &out).?;

    try expectHex(digest, "b617318655057264e28bc0b6fb378c8ef146be00");
}

test "sha_hmac hmac sha256 rfc 4231 vector" {
    const key: [20]u8 = @splat(0x0b);
    var out: [EVP_MAX_MD_SIZE]u8 = undefined;
    const digest = generate(&key, "Hi There", .sha256, &out).?;

    try expectHex(digest, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
}

test "sha_hmac hmac accepts sha512-256 tags" {
    var dash: [EVP_MAX_MD_SIZE]u8 = undefined;
    var underscore: [EVP_MAX_MD_SIZE]u8 = undefined;

    const dash_digest = generate("key", "data", .@"sha512-256", &dash).?;
    const underscore_digest = generate("key", "data", .sha512_256, &underscore).?;

    try std.testing.expectEqualSlices(u8, dash_digest, underscore_digest);
    try std.testing.expectEqual(@as(usize, std.crypto.hash.sha2.Sha512_256.digest_length), dash_digest.len);
}
