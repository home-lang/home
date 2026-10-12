const std = @import("std");

const X25519 = std.crypto.dh.X25519;

/// Bridge the X25519 recovery signature across Zig 0.17 and 0.18.
///
/// Zig 0.17 exposes `recoverPublicKey` as an error union. Zig 0.18 returns the
/// public key directly because recovery from a fixed-size secret cannot fail.
/// Keep the old error path while the repository supports both compilers. This
/// intentionally does not cover `scalarmult`: that operation still rejects
/// attacker-chosen identity elements and its error must remain observable.
pub fn recoverX25519PublicKey(seed: [X25519.seed_length]u8) ?[X25519.public_length]u8 {
    const recovered = X25519.recoverPublicKey(seed);
    return switch (@typeInfo(@TypeOf(recovered))) {
        .error_union => recovered catch null,
        else => recovered,
    };
}

test "X25519 public-key recovery accepts both std.crypto signatures" {
    const seed = [_]u8{
        0xc8, 0x83, 0x8e, 0x76, 0xd0, 0x57, 0xdf, 0xb7,
        0xd8, 0xc9, 0x5a, 0x69, 0xe1, 0x38, 0x16, 0x0a,
        0xdd, 0x63, 0x73, 0xfd, 0x71, 0xa4, 0xd2, 0x76,
        0xbb, 0x56, 0xe3, 0xa8, 0x1b, 0x64, 0xff, 0x61,
    };
    const expected = [_]u8{
        0x1c, 0xf2, 0xb1, 0xe6, 0x02, 0x2e, 0xc5, 0x37,
        0x37, 0x1e, 0xd7, 0xf5, 0x3e, 0x54, 0xfa, 0x11,
        0x54, 0xd8, 0x3e, 0x98, 0xeb, 0x64, 0xea, 0x51,
        0xfa, 0xe5, 0xb3, 0x30, 0x7c, 0xfe, 0x97, 0x06,
    };

    const public_key = recoverX25519PublicKey(seed) orelse return error.UnexpectedRecoveryFailure;
    try std.testing.expectEqualSlices(u8, &expected, &public_key);
}
