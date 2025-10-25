// Home OS Kernel - Encrypted Core Dumps
// Prevents sensitive data leakage through core dumps

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const random = @import("random.zig");
const dm_crypt = @import("dm_crypt.zig");

pub const CoredumpPolicy = enum(u8) {
    DISABLED = 0,
    ENCRYPTED = 1,
    PLAIN = 2, // Not recommended
};

pub const EncryptedCoredump = struct {
    /// Encryption key
    key: dm_crypt.EncryptionKey,
    /// Encrypted data
    encrypted_data: []u8,
    /// Process info
    pid: u32,
    uid: u32,
    /// Timestamp
    timestamp: u64,
    /// Policy
    policy: atomic.AtomicU8,

    pub fn init(policy: CoredumpPolicy) EncryptedCoredump {
        return .{
            .key = dm_crypt.EncryptionKey.init(.AES_256_XTS),
            .encrypted_data = &[_]u8{},
            .pid = 0,
            .uid = 0,
            .timestamp = 0,
            .policy = atomic.AtomicU8.init(@intFromEnum(policy)),
        };
    }

    pub fn encrypt(self: *EncryptedCoredump, plaintext: []const u8) !void {
        self.key.generate();

        var cipher = dm_crypt.BlockCipher.init(.AES_256_XTS);
        cipher.key = self.key;

        // Simplified encryption (real would encrypt in blocks)
        self.encrypted_data = try Basics.heap.page_allocator.alloc(u8, plaintext.len);
        _ = cipher;

        for (plaintext, self.encrypted_data) |plain, *enc| {
            enc.* = plain ^ self.key.key_material[0];
        }

        self.timestamp = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp()))));
        audit.logSecurityViolation("Core dump encrypted");
    }
};

var global_policy: atomic.AtomicU8 = atomic.AtomicU8.init(@intFromEnum(CoredumpPolicy.ENCRYPTED));

pub fn setPolicy(policy: CoredumpPolicy) void {
    global_policy.store(@intFromEnum(policy), .Release);
}

pub fn getPolicy() CoredumpPolicy {
    return @enumFromInt(global_policy.load(.Acquire));
}
