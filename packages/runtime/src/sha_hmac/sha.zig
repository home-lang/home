const std = @import("std");

fn NewStdHasher(comptime Hash: type) type {
    return struct {
        hasher: Hash = Hash.init(.{}),

        pub const Digest = [Hash.digest_length]u8;
        pub const digest: comptime_int = Hash.digest_length;

        pub fn init() @This() {
            return .{
                .hasher = Hash.init(.{}),
            };
        }

        pub fn hash(bytes: []const u8, out: *Digest) void {
            Hash.hash(bytes, out, .{});
        }

        pub fn update(this: *@This(), data: []const u8) void {
            this.hasher.update(data);
        }

        pub fn final(this: *@This(), out: *Digest) void {
            this.hasher.final(out);
        }
    };
}

fn NewStdEVP(comptime Hash: type) type {
    return struct {
        hasher: Hash = Hash.init(.{}),

        pub const Digest = [Hash.digest_length]u8;
        pub const digest: comptime_int = Hash.digest_length;

        pub fn init() @This() {
            return .{
                .hasher = Hash.init(.{}),
            };
        }

        pub fn hash(bytes: []const u8, out: *Digest, engine: anytype) void {
            _ = engine;
            Hash.hash(bytes, out, .{});
        }

        pub fn update(this: *@This(), data: []const u8) void {
            this.hasher.update(data);
        }

        pub fn final(this: *@This(), out: *Digest) void {
            this.hasher.final(out);
        }

        pub fn deinit(this: *@This()) void {
            _ = this;
        }
    };
}

fn UnsupportedStdHasher(comptime digest_size: comptime_int, comptime name: []const u8) type {
    return struct {
        pub const Digest = [digest_size]u8;
        pub const digest: comptime_int = digest_size;

        pub fn init() @This() {
            @panic(name ++ " is not available in the pure Zig sha_hmac shim");
        }

        pub fn hash(bytes: []const u8, out: *Digest) void {
            _ = bytes;
            _ = out;
            @panic(name ++ " is not available in the pure Zig sha_hmac shim");
        }

        pub fn update(this: *@This(), data: []const u8) void {
            _ = this;
            _ = data;
            @panic(name ++ " is not available in the pure Zig sha_hmac shim");
        }

        pub fn final(this: *@This(), out: *Digest) void {
            _ = this;
            _ = out;
            @panic(name ++ " is not available in the pure Zig sha_hmac shim");
        }

        pub fn deinit(this: *@This()) void {
            _ = this;
        }
    };
}

fn UnsupportedEVPHasher(comptime digest_size: comptime_int, comptime name: []const u8) type {
    return struct {
        pub const Digest = [digest_size]u8;
        pub const digest: comptime_int = digest_size;

        pub fn init() @This() {
            @panic(name ++ " is not available in the pure Zig sha_hmac shim");
        }

        pub fn hash(bytes: []const u8, out: *Digest, engine: anytype) void {
            _ = bytes;
            _ = out;
            _ = engine;
            @panic(name ++ " is not available in the pure Zig sha_hmac shim");
        }

        pub fn update(this: *@This(), data: []const u8) void {
            _ = this;
            _ = data;
            @panic(name ++ " is not available in the pure Zig sha_hmac shim");
        }

        pub fn final(this: *@This(), out: *Digest) void {
            _ = this;
            _ = out;
            @panic(name ++ " is not available in the pure Zig sha_hmac shim");
        }

        pub fn deinit(this: *@This()) void {
            _ = this;
        }
    };
}

pub const EVP = struct {
    pub const SHA1 = NewStdEVP(std.crypto.hash.Sha1);
    pub const MD5 = NewStdEVP(std.crypto.hash.Md5);
    pub const MD4 = NewStdEVP(@import("md4.zig").Md4);
    pub const SHA224 = NewStdEVP(std.crypto.hash.sha2.Sha224);
    pub const SHA512 = NewStdEVP(std.crypto.hash.sha2.Sha512);
    pub const SHA384 = NewStdEVP(std.crypto.hash.sha2.Sha384);
    pub const SHA256 = NewStdEVP(std.crypto.hash.sha2.Sha256);
    pub const SHA512_256 = NewStdEVP(std.crypto.hash.sha2.Sha512_256);
    pub const MD5_SHA1 = UnsupportedEVPHasher(36, "MD5_SHA1");
    pub const Blake2 = NewStdEVP(std.crypto.hash.blake2.Blake2b256);
};

pub const SHA1 = EVP.SHA1;
pub const MD5 = EVP.MD5;
pub const MD4 = EVP.MD4;
pub const SHA224 = EVP.SHA224;
pub const SHA512 = EVP.SHA512;
pub const SHA384 = EVP.SHA384;
pub const SHA256 = EVP.SHA256;
pub const SHA512_256 = EVP.SHA512_256;
pub const MD5_SHA1 = EVP.MD5_SHA1;

pub const Hashers = struct {
    pub const SHA1 = NewStdHasher(std.crypto.hash.Sha1);
    pub const MD5 = NewStdHasher(std.crypto.hash.Md5);
    pub const MD4 = UnsupportedStdHasher(16, "MD4");
    pub const SHA224 = NewStdHasher(std.crypto.hash.sha2.Sha224);
    pub const SHA512 = NewStdHasher(std.crypto.hash.sha2.Sha512);
    pub const SHA384 = NewStdHasher(std.crypto.hash.sha2.Sha384);
    pub const SHA256 = NewStdHasher(std.crypto.hash.sha2.Sha256);
    pub const SHA512_256 = NewStdHasher(std.crypto.hash.sha2.Sha512_256);
    pub const RIPEMD160 = UnsupportedStdHasher(20, "RIPEMD160");
};

const boring = [_]type{
    Hashers.SHA1,
    Hashers.SHA512,
    Hashers.SHA384,
    Hashers.SHA256,
    Hashers.SHA512_256,
    void,
    void,
};

const zig = [_]type{
    std.crypto.hash.Sha1,
    std.crypto.hash.sha2.Sha512,
    std.crypto.hash.sha2.Sha384,
    std.crypto.hash.sha2.Sha256,
    std.crypto.hash.sha2.Sha512_256,
    std.crypto.hash.blake2.Blake2b256,
    std.crypto.hash.Blake3,
};

const evp = [_]type{
    EVP.SHA1,
    EVP.SHA512,
    EVP.SHA384,
    EVP.SHA256,
    EVP.SHA512_256,
    EVP.Blake2,
    void,
};

const labels = [_][]const u8{
    "SHA1",
    "SHA512",
    "SHA384",
    "SHA256",
    "SHA512_256",
    "Blake2",
    "Blake3",
};

fn expectHex(bytes: []const u8, expected: []const u8) !void {
    var actual: [std.crypto.hash.sha2.Sha512.digest_length * 2]u8 = undefined;
    const hex = try std.fmt.bufPrint(&actual, "{x}", .{bytes});
    try std.testing.expectEqualStrings(expected, hex);
}

test "sha_hmac sha one-shot vectors" {
    var sha1: SHA1.Digest = undefined;
    SHA1.hash("abc", &sha1, null);
    try expectHex(&sha1, "a9993e364706816aba3e25717850c26c9cd0d89d");

    var sha256: SHA256.Digest = undefined;
    SHA256.hash("abc", &sha256, null);
    try expectHex(&sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    var sha512_256: SHA512_256.Digest = undefined;
    SHA512_256.hash("abc", &sha512_256, null);
    try expectHex(&sha512_256, "53048e2681941ef99b2e29b76b4c7dabe4c2d0c634fc6d46e0e2f13107e7af23");
}

test "sha_hmac sha streaming matches one-shot" {
    var one_shot: Hashers.SHA256.Digest = undefined;
    Hashers.SHA256.hash("abc", &one_shot);

    var streaming = Hashers.SHA256.init();
    streaming.update("a");
    streaming.update("bc");

    var streamed: Hashers.SHA256.Digest = undefined;
    streaming.final(&streamed);

    try std.testing.expectEqualSlices(u8, &one_shot, &streamed);
}
