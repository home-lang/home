const std = @import("std");

const X25519 = std.crypto.dh.X25519;

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn timestamp(io_context: std.Io) i64 {
    return std.Io.Clock.real.now(io_context).toSeconds();
}

pub fn randomSecure(io_context: std.Io, buffer: []u8) std.Io.RandomSecureError!void {
    try std.Io.randomSecure(io_context, buffer);
}

/// Bridge the X25519 deterministic-key signature across Zig 0.17 and 0.18.
/// Zig 0.18 removed the impossible identity-element error from fixed-base
/// public-key recovery. The scalar multiplication API is deliberately not
/// wrapped: it still validates attacker-controlled public keys and remains
/// fallible on both compiler versions.
pub fn x25519KeyPair(seed: [X25519.seed_length]u8) std.crypto.errors.IdentityElementError!X25519.KeyPair {
    const key_pair = X25519.KeyPair.generateDeterministic(seed);
    return switch (@typeInfo(@TypeOf(key_pair))) {
        .error_union => try key_pair,
        else => key_pair,
    };
}
