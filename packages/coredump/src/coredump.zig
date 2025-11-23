// Core Dump Encryption - Protect sensitive data in crash dumps
//
// This package provides encrypted core dump generation and analysis,
// preventing sensitive information leakage from crash dumps.

const std = @import("std");

/// Get current Unix timestamp in seconds since epoch
fn getUnixTimestamp() i64 {
    if (@hasDecl(std.posix, "CLOCK") and @hasDecl(std.posix, "clock_gettime")) {
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec;
    }
    return 0;
}

pub const encrypt = @import("encrypt.zig");
pub const decrypt = @import("decrypt.zig");
pub const keys = @import("keys.zig");
pub const format = @import("format.zig");
pub const capture = @import("capture.zig");

/// Encryption algorithm for core dumps
pub const EncryptionAlgorithm = enum(u8) {
    aes_256_gcm = 0,
    chacha20_poly1305 = 1,

    pub fn name(self: EncryptionAlgorithm) []const u8 {
        return switch (self) {
            .aes_256_gcm => "AES-256-GCM",
            .chacha20_poly1305 => "ChaCha20-Poly1305",
        };
    }

    pub fn keySize(self: EncryptionAlgorithm) usize {
        return switch (self) {
            .aes_256_gcm => 32,
            .chacha20_poly1305 => 32,
        };
    }

    pub fn nonceSize(self: EncryptionAlgorithm) usize {
        return switch (self) {
            .aes_256_gcm => 12,
            .chacha20_poly1305 => 12,
        };
    }

    pub fn tagSize(self: EncryptionAlgorithm) usize {
        return switch (self) {
            .aes_256_gcm => 16,
            .chacha20_poly1305 => 16,
        };
    }
};

/// Core dump metadata
pub const DumpMetadata = struct {
    /// Process ID
    pid: u32,
    /// Process name
    process_name: [256]u8,
    process_name_len: usize,
    /// Signal that caused dump
    signal: u32,
    /// Timestamp
    timestamp: i64,
    /// Encryption algorithm
    algorithm: EncryptionAlgorithm,
    /// User ID
    uid: u32,
    /// Group ID
    gid: u32,

    pub fn init(pid: u32, process_name: []const u8, signal: u32) !DumpMetadata {
        if (process_name.len > 255) {
            return error.ProcessNameTooLong;
        }

        var metadata: DumpMetadata = undefined;
        metadata.pid = pid;
        metadata.process_name = [_]u8{0} ** 256;
        metadata.process_name_len = process_name.len;
        metadata.signal = signal;
        metadata.timestamp = getUnixTimestamp();
        metadata.algorithm = .aes_256_gcm;
        metadata.uid = 0;
        metadata.gid = 0;

        @memcpy(metadata.process_name[0..process_name.len], process_name);

        return metadata;
    }

    pub fn getProcessName(self: *const DumpMetadata) []const u8 {
        return self.process_name[0..self.process_name_len];
    }

    pub fn format(
        self: DumpMetadata,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Core Dump (PID={d}, Process={s}, Signal={d}, Time={d})", .{
            self.pid,
            self.getProcessName(),
            self.signal,
            self.timestamp,
        });
    }
};

/// Encrypted core dump configuration
pub const DumpConfig = struct {
    algorithm: EncryptionAlgorithm = .aes_256_gcm,
    compress: bool = true,
    max_dump_size: usize = 100 * 1024 * 1024, // 100MB
    encrypt_stack: bool = true,
    encrypt_heap: bool = true,
    encrypt_registers: bool = true,
    redact_sensitive: bool = true,
};

test "encryption algorithm properties" {
    const testing = std.testing;

    const aes = EncryptionAlgorithm.aes_256_gcm;
    try testing.expectEqual(@as(usize, 32), aes.keySize());
    try testing.expectEqual(@as(usize, 12), aes.nonceSize());
    try testing.expectEqual(@as(usize, 16), aes.tagSize());
    try testing.expectEqualStrings("AES-256-GCM", aes.name());

    const chacha = EncryptionAlgorithm.chacha20_poly1305;
    try testing.expectEqual(@as(usize, 32), chacha.keySize());
    try testing.expectEqual(@as(usize, 12), chacha.nonceSize());
    try testing.expectEqual(@as(usize, 16), chacha.tagSize());
}

test "dump metadata" {
    const testing = std.testing;

    var metadata = try DumpMetadata.init(1234, "test_process", 11);

    try testing.expectEqual(@as(u32, 1234), metadata.pid);
    try testing.expectEqual(@as(u32, 11), metadata.signal);
    try testing.expectEqualStrings("test_process", metadata.getProcessName());
}
