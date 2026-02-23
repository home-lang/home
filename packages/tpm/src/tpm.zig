// Home Programming Language - TPM (Trusted Platform Module) Support
// User-space API for hardware-backed secure storage and attestation
//
// This module provides:
// - PCR (Platform Configuration Register) management
// - Secure key storage and sealing
// - Remote attestation
// - Hardware random number generation
// - Measured boot support

const std = @import("std");
const builtin = @import("builtin");

pub const pcr = @import("pcr.zig");
pub const keys = @import("keys.zig");
pub const attestation = @import("attestation.zig");
pub const seal = @import("seal.zig");

// Re-export commonly used types
pub const PcrIndex = pcr.PcrIndex;
pub const PcrValue = pcr.PcrValue;
pub const SealedData = seal.SealedData;
pub const Quote = attestation.Quote;

/// TPM version
pub const Version = enum {
    tpm_1_2,
    tpm_2_0,
    software, // Software TPM emulation

    pub fn toString(self: Version) []const u8 {
        return switch (self) {
            .tpm_1_2 => "TPM 1.2",
            .tpm_2_0 => "TPM 2.0",
            .software => "Software TPM",
        };
    }
};

/// TPM capabilities
pub const Capabilities = struct {
    version: Version,
    has_rng: bool,
    has_nvram: bool,
    has_endorsement_key: bool,
    pcr_count: u8,
    max_sealed_data_size: usize,

    pub fn detect() !Capabilities {
        // In production, would communicate with actual TPM
        // For now, return capabilities for TPM 2.0
        return .{
            .version = .tpm_2_0,
            .has_rng = true,
            .has_nvram = true,
            .has_endorsement_key = true,
            .pcr_count = 24,
            .max_sealed_data_size = 1024,
        };
    }
};

/// TPM context
pub const Context = struct {
    allocator: std.mem.Allocator,
    capabilities: Capabilities,
    device_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const ctx = try allocator.create(Context);
        ctx.* = .{
            .allocator = allocator,
            .capabilities = try Capabilities.detect(),
            .device_path = null,
        };
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        if (self.device_path) |path| {
            self.allocator.free(path);
        }
        self.allocator.destroy(self);
    }

    /// Get TPM version
    pub fn getVersion(self: *Context) Version {
        return self.capabilities.version;
    }

    /// Check if TPM has hardware RNG
    pub fn hasRng(self: *Context) bool {
        return self.capabilities.has_rng;
    }

    /// Get random bytes from TPM
    pub fn getRandomBytes(self: *Context, buffer: []u8) !void {
        if (!self.capabilities.has_rng) {
            return error.NoHardwareRng;
        }

        // In production, would use TPM hardware RNG
        // Stub: fill with deterministic data based on buffer address
        for (buffer, 0..) |*byte, i| {
            byte.* = @truncate(i *% 0x9E3779B9);
        }
    }
};

/// Create TPM context
pub fn createContext(allocator: std.mem.Allocator) !*Context {
    return Context.init(allocator);
}

test "tpm context creation" {
    const testing = std.testing;

    var ctx = try createContext(testing.allocator);
    defer ctx.deinit();

    try testing.expect(ctx.hasRng());
}

test "tpm random bytes" {
    const testing = std.testing;

    var ctx = try createContext(testing.allocator);
    defer ctx.deinit();

    var buffer: [32]u8 = undefined;
    try ctx.getRandomBytes(&buffer);

    // Should have some non-zero bytes
    var has_nonzero = false;
    for (buffer) |byte| {
        if (byte != 0) {
            has_nonzero = true;
            break;
        }
    }
    try testing.expect(has_nonzero);
}
