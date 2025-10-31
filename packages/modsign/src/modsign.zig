// Module Signing Tools - User-space utilities for kernel module signing
//
// This package provides tools to sign kernel modules before deployment
// and verify signatures. Works with the kernel's module_signing verification.

const std = @import("std");

pub const keys = @import("keys.zig");
pub const sign = @import("sign.zig");
pub const verify = @import("verify.zig");
pub const format = @import("format.zig");

/// Signature algorithm types
pub const SignatureAlgorithm = enum(u8) {
    rsa_2048_sha256 = 0,
    rsa_4096_sha256 = 1,
    ecdsa_p256_sha256 = 2,

    pub fn name(self: SignatureAlgorithm) []const u8 {
        return switch (self) {
            .rsa_2048_sha256 => "RSA-2048-SHA256",
            .rsa_4096_sha256 => "RSA-4096-SHA256",
            .ecdsa_p256_sha256 => "ECDSA-P256-SHA256",
        };
    }

    pub fn keySize(self: SignatureAlgorithm) usize {
        return switch (self) {
            .rsa_2048_sha256 => 2048 / 8,
            .rsa_4096_sha256 => 4096 / 8,
            .ecdsa_p256_sha256 => 32,
        };
    }

    pub fn signatureSize(self: SignatureAlgorithm) usize {
        return switch (self) {
            .rsa_2048_sha256 => 256,
            .rsa_4096_sha256 => 512,
            .ecdsa_p256_sha256 => 64,
        };
    }
};

/// Module signature structure
pub const ModuleSignature = struct {
    algorithm: SignatureAlgorithm,
    key_id: [32]u8,
    signature: []u8,
    module_hash: [64]u8,
    hash_len: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, algorithm: SignatureAlgorithm) !ModuleSignature {
        return .{
            .algorithm = algorithm,
            .key_id = [_]u8{0} ** 32,
            .signature = try allocator.alloc(u8, algorithm.signatureSize()),
            .module_hash = [_]u8{0} ** 64,
            .hash_len = 32, // SHA-256
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleSignature) void {
        self.allocator.free(self.signature);
    }

    pub fn getSignature(self: *const ModuleSignature) []const u8 {
        return self.signature;
    }

    pub fn getHash(self: *const ModuleSignature) []const u8 {
        return self.module_hash[0..self.hash_len];
    }
};

/// Configuration for module signing
pub const SigningConfig = struct {
    algorithm: SignatureAlgorithm = .rsa_2048_sha256,
    key_description: []const u8 = "kernel_module",
    verify_after_sign: bool = true,
    strip_signature: bool = false,
};

test "signature algorithm" {
    const testing = std.testing;

    const rsa = SignatureAlgorithm.rsa_2048_sha256;
    try testing.expectEqual(@as(usize, 256), rsa.signatureSize());
    try testing.expectEqual(@as(usize, 256), rsa.keySize());

    const ecdsa = SignatureAlgorithm.ecdsa_p256_sha256;
    try testing.expectEqual(@as(usize, 64), ecdsa.signatureSize());
}

test "module signature" {
    const testing = std.testing;

    var sig = try ModuleSignature.init(testing.allocator, .rsa_2048_sha256);
    defer sig.deinit();

    try testing.expectEqual(@as(usize, 256), sig.signature.len);
}
