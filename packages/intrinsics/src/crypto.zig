// Home Programming Language - Cryptographic Intrinsics
// Hardware-accelerated cryptographic operations

const std = @import("std");
const builtin = @import("builtin");

// AES encryption intrinsics (x86 AES-NI)
pub const AES = struct {
    /// Check if AES-NI is available
    pub fn isAvailable() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .aes),
            .aarch64, .arm => std.Target.aarch64.featureSetHas(builtin.cpu.features, .aes),
            else => false,
        };
    }

    /// AES encryption round
    pub fn encryptRound(state: u128, round_key: u128) u128 {
        // On x86 this would map to AESENC instruction
        // On ARM this would map to AESE/AESMC instructions
        // For now, provide a software fallback
        _ = state;
        _ = round_key;
        @compileError("AES hardware intrinsics require platform-specific inline assembly");
    }

    /// AES encryption last round
    pub fn encryptLastRound(state: u128, round_key: u128) u128 {
        _ = state;
        _ = round_key;
        @compileError("AES hardware intrinsics require platform-specific inline assembly");
    }

    /// AES decryption round
    pub fn decryptRound(state: u128, round_key: u128) u128 {
        _ = state;
        _ = round_key;
        @compileError("AES hardware intrinsics require platform-specific inline assembly");
    }

    /// AES decryption last round
    pub fn decryptLastRound(state: u128, round_key: u128) u128 {
        _ = state;
        _ = round_key;
        @compileError("AES hardware intrinsics require platform-specific inline assembly");
    }

    /// AES key generation assist
    pub fn keyGenAssist(comptime imm8: u8, a: u128) u128 {
        _ = imm8;
        _ = a;
        @compileError("AES hardware intrinsics require platform-specific inline assembly");
    }
};

// SHA intrinsics
pub const SHA = struct {
    /// Check if SHA extensions are available
    pub fn isAvailable() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .sha),
            .aarch64, .arm => std.Target.aarch64.featureSetHas(builtin.cpu.features, .sha2),
            else => false,
        };
    }

    /// SHA-256 message schedule update (sigma0)
    pub fn sha256msg1(a: u128, b: u128) u128 {
        _ = a;
        _ = b;
        @compileError("SHA hardware intrinsics require platform-specific inline assembly");
    }

    /// SHA-256 message schedule update (sigma1)
    pub fn sha256msg2(a: u128, b: u128) u128 {
        _ = a;
        _ = b;
        @compileError("SHA hardware intrinsics require platform-specific inline assembly");
    }

    /// SHA-256 rounds 0-3
    pub fn sha256rnds2(a: u128, b: u128, wk: u128) u128 {
        _ = a;
        _ = b;
        _ = wk;
        @compileError("SHA hardware intrinsics require platform-specific inline assembly");
    }
};

// CRC32 intrinsics
pub const CRC32 = struct {
    /// Check if CRC32 is available
    pub fn isAvailable() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2),
            .aarch64, .arm => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc),
            else => false,
        };
    }

    /// CRC32 for 8-bit value
    pub fn crc32_u8(crc: u32, value: u8) u32 {
        // Always use software fallback for now
        // Hardware CRC32 instruction would require platform-specific inline assembly
        return softwareCrc32_u8(crc, value);
    }

    /// CRC32 for 16-bit value
    pub fn crc32_u16(crc: u32, value: u16) u32 {
        return softwareCrc32_u16(crc, value);
    }

    /// CRC32 for 32-bit value
    pub fn crc32_u32(crc: u32, value: u32) u32 {
        return softwareCrc32_u32(crc, value);
    }

    /// CRC32 for 64-bit value
    pub fn crc32_u64(crc: u32, value: u64) u32 {
        return softwareCrc32_u64(crc, value);
    }

    // Software fallback implementations
    const polynomial: u32 = 0xEDB88320;

    fn softwareCrc32_u8(crc: u32, value: u8) u32 {
        var c = crc ^ value;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            c = if (c & 1 != 0) (c >> 1) ^ polynomial else c >> 1;
        }
        return c;
    }

    fn softwareCrc32_u16(crc: u32, value: u16) u32 {
        const c = softwareCrc32_u8(crc, @truncate(value));
        return softwareCrc32_u8(c, @truncate(value >> 8));
    }

    fn softwareCrc32_u32(crc: u32, value: u32) u32 {
        const c = softwareCrc32_u16(crc, @truncate(value));
        return softwareCrc32_u16(c, @truncate(value >> 16));
    }

    fn softwareCrc32_u64(crc: u32, value: u64) u32 {
        const c = softwareCrc32_u32(crc, @truncate(value));
        return softwareCrc32_u32(c, @truncate(value >> 32));
    }

    /// Calculate CRC32 for a byte slice
    pub fn crc32(data: []const u8) u32 {
        var crc: u32 = 0xFFFFFFFF;
        for (data) |byte| {
            crc = crc32_u8(crc, byte);
        }
        return ~crc;
    }
};

// PCLMULQDQ - Carry-less multiplication
pub const CarryLessMultiply = struct {
    /// Check if PCLMULQDQ is available
    pub fn isAvailable() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul),
            .aarch64, .arm => std.Target.aarch64.featureSetHas(builtin.cpu.features, .aes),
            else => false,
        };
    }

    /// Carry-less multiplication of two 64-bit values
    pub fn pclmulqdq(comptime imm8: u8, a: u128, b: u128) u128 {
        _ = imm8;
        _ = a;
        _ = b;
        @compileError("PCLMULQDQ hardware intrinsics require platform-specific inline assembly");
    }
};

// Random number generation intrinsics
pub const Random = struct {
    /// Check if RDRAND is available (x86)
    pub fn hasRdrand() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .rdrnd),
            else => false,
        };
    }

    /// Check if RDSEED is available (x86)
    pub fn hasRdseed() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .rdseed),
            else => false,
        };
    }

    /// Generate random 16-bit value using RDRAND
    pub fn rdrand16() ?u16 {
        if (hasRdrand()) {
            _ = "";
            @compileError("RDRAND hardware intrinsics require platform-specific inline assembly");
        }
        return null;
    }

    /// Generate random 32-bit value using RDRAND
    pub fn rdrand32() ?u32 {
        if (hasRdrand()) {
            _ = "";
            @compileError("RDRAND hardware intrinsics require platform-specific inline assembly");
        }
        return null;
    }

    /// Generate random 64-bit value using RDRAND
    pub fn rdrand64() ?u64 {
        if (hasRdrand()) {
            _ = "";
            @compileError("RDRAND hardware intrinsics require platform-specific inline assembly");
        }
        return null;
    }

    /// Generate seed using RDSEED
    pub fn rdseed16() ?u16 {
        if (hasRdseed()) {
            _ = "";
            @compileError("RDSEED hardware intrinsics require platform-specific inline assembly");
        }
        return null;
    }

    /// Generate seed using RDSEED
    pub fn rdseed32() ?u32 {
        if (hasRdseed()) {
            _ = "";
            @compileError("RDSEED hardware intrinsics require platform-specific inline assembly");
        }
        return null;
    }

    /// Generate seed using RDSEED
    pub fn rdseed64() ?u64 {
        if (hasRdseed()) {
            _ = "";
            @compileError("RDSEED hardware intrinsics require platform-specific inline assembly");
        }
        return null;
    }
};

test "crypto intrinsic availability" {
    _ = AES.isAvailable();
    _ = SHA.isAvailable();
    _ = CRC32.isAvailable();
    _ = CarryLessMultiply.isAvailable();
    _ = Random.hasRdrand();
    _ = Random.hasRdseed();
}

test "crc32 software fallback" {
    const testing = std.testing;

    // Test basic CRC32 calculation
    const data = "123456789";
    const result = CRC32.crc32(data);

    // CRC32 of "123456789" should be 0xCBF43926
    try testing.expectEqual(@as(u32, 0xCBF43926), result);
}
