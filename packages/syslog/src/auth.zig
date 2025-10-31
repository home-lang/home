// Log authentication and integrity protection

const std = @import("std");
const syslog = @import("syslog.zig");

/// Authentication key for HMAC
pub const AuthKey = struct {
    key_data: [32]u8,
    key_id: [16]u8,
    created_at: i64,

    pub fn generate() AuthKey {
        var key: AuthKey = undefined;
        std.crypto.random.bytes(&key.key_data);
        std.crypto.random.bytes(&key.key_id);
        key.created_at = std.time.timestamp();
        return key;
    }

    pub fn fromBytes(data: []const u8) !AuthKey {
        if (data.len < 32) return error.InvalidKeyLength;

        var key: AuthKey = undefined;
        @memcpy(&key.key_data, data[0..32]);

        // Generate key ID from key data
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&key.key_data);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        @memcpy(&key.key_id, hash[0..16]);

        key.created_at = std.time.timestamp();

        return key;
    }
};

/// Authenticated log message
pub const AuthenticatedLog = struct {
    message: syslog.LogMessage,
    hmac: [32]u8,
    key_id: [16]u8,
    sequence: u64,

    pub fn deinit(self: *AuthenticatedLog) void {
        self.message.deinit();
    }
};

/// Authenticate log message with HMAC-SHA256
pub fn authenticateLog(
    message: *const syslog.LogMessage,
    key: *const AuthKey,
    sequence: u64,
) !AuthenticatedLog {
    var hmac: [32]u8 = undefined;

    // Compute HMAC over message fields
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Include key data
    hasher.update(&key.key_data);

    // Include message fields
    hasher.update(&[_]u8{@intFromEnum(message.facility)});
    hasher.update(&[_]u8{@intFromEnum(message.severity)});
    hasher.update(&std.mem.toBytes(message.timestamp));
    hasher.update(message.getHostname());
    hasher.update(message.getAppName());
    hasher.update(&std.mem.toBytes(message.process_id));
    hasher.update(message.message);
    hasher.update(&std.mem.toBytes(sequence));

    hasher.final(&hmac);

    return .{
        .message = message.*,
        .hmac = hmac,
        .key_id = key.key_id,
        .sequence = sequence,
    };
}

/// Verify log message authentication
pub fn verifyLog(
    auth_log: *const AuthenticatedLog,
    key: *const AuthKey,
) !bool {
    // Verify key ID matches
    if (!std.mem.eql(u8, &auth_log.key_id, &key.key_id)) {
        return error.KeyMismatch;
    }

    // Recompute HMAC
    var computed_hmac: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    hasher.update(&key.key_data);
    hasher.update(&[_]u8{@intFromEnum(auth_log.message.facility)});
    hasher.update(&[_]u8{@intFromEnum(auth_log.message.severity)});
    hasher.update(&std.mem.toBytes(auth_log.message.timestamp));
    hasher.update(auth_log.message.getHostname());
    hasher.update(auth_log.message.getAppName());
    hasher.update(&std.mem.toBytes(auth_log.message.process_id));
    hasher.update(auth_log.message.message);
    hasher.update(&std.mem.toBytes(auth_log.sequence));

    hasher.final(&computed_hmac);

    // Compare HMACs
    return std.mem.eql(u8, &auth_log.hmac, &computed_hmac);
}

/// Log chain for detecting tampering
pub const LogChain = struct {
    previous_hash: [32]u8,
    sequence: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LogChain {
        return .{
            .previous_hash = [_]u8{0} ** 32,
            .sequence = 0,
            .allocator = allocator,
        };
    }

    pub fn addLog(
        self: *LogChain,
        message: *const syslog.LogMessage,
        key: *const AuthKey,
    ) !AuthenticatedLog {
        // Authenticate log
        var auth_log = try authenticateLog(message, key, self.sequence);

        // Compute chain hash (hash of previous hash + current log)
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&self.previous_hash);
        hasher.update(&auth_log.hmac);
        hasher.final(&self.previous_hash);

        self.sequence += 1;

        return auth_log;
    }

    pub fn verifyChain(
        self: *LogChain,
        logs: []const AuthenticatedLog,
        key: *const AuthKey,
    ) !bool {
        var expected_hash = [_]u8{0} ** 32;
        var expected_seq: u64 = 0;

        for (logs) |*log| {
            // Verify sequence
            if (log.sequence != expected_seq) {
                return false;
            }

            // Verify authentication
            if (!try verifyLog(log, key)) {
                return false;
            }

            // Update chain hash
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&expected_hash);
            hasher.update(&log.hmac);
            hasher.final(&expected_hash);

            expected_seq += 1;
        }

        return true;
    }
};

test "auth key generation" {
    const testing = std.testing;

    const key = AuthKey.generate();

    // Key ID should be non-zero
    var all_zero = true;
    for (key.key_id) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "log authentication" {
    const testing = std.testing;

    const key = AuthKey.generate();

    var message = try syslog.LogMessage.init(
        testing.allocator,
        .daemon,
        .info,
        "localhost",
        "test",
        100,
        "Test log",
    );
    defer message.deinit();

    var auth_log = try authenticateLog(&message, &key, 0);

    // Verify
    const valid = try verifyLog(&auth_log, &key);
    try testing.expect(valid);

    // Tamper with message
    auth_log.message.process_id = 999;

    // Should fail verification
    const tampered = try verifyLog(&auth_log, &key);
    try testing.expect(!tampered);
}

test "log chain" {
    const testing = std.testing;

    var chain = LogChain.init(testing.allocator);
    const key = AuthKey.generate();

    var msg1 = try syslog.LogMessage.init(
        testing.allocator,
        .user,
        .info,
        "host1",
        "app",
        1,
        "First",
    );
    defer msg1.deinit();

    var msg2 = try syslog.LogMessage.init(
        testing.allocator,
        .user,
        .info,
        "host1",
        "app",
        2,
        "Second",
    );
    defer msg2.deinit();

    var auth1 = try chain.addLog(&msg1, &key);
    var auth2 = try chain.addLog(&msg2, &key);

    try testing.expectEqual(@as(u64, 0), auth1.sequence);
    try testing.expectEqual(@as(u64, 1), auth2.sequence);

    // Verify chain
    const logs = [_]AuthenticatedLog{ auth1, auth2 };
    const valid = try chain.verifyChain(&logs, &key);
    try testing.expect(valid);
}
