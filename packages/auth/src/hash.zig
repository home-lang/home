const std = @import("std");

/// Password hashing using Argon2
pub const Hash = struct {
    allocator: std.mem.Allocator,
    config: Config,

    const Self = @This();

    pub const Config = struct {
        // Argon2 parameters
        time_cost: u32 = 3, // iterations
        memory_cost: u32 = 65536, // 64 MB in KB
        parallelism: u8 = 4, // threads
        hash_length: u32 = 32, // output length
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Hash a password
    pub fn make(self: *Self, password: []const u8) ![]const u8 {
        // Generate random salt
        var salt: [16]u8 = undefined;
        std.crypto.random.bytes(&salt);

        return self.hashWithSalt(password, &salt);
    }

    /// Hash with a specific salt (for testing)
    pub fn hashWithSalt(self: *Self, password: []const u8, salt: []const u8) ![]const u8 {
        var hash: [32]u8 = undefined;

        // Use Argon2id
        std.crypto.pwhash.argon2.kdf(
            &hash,
            password,
            salt[0..16].*,
            .{
                .t = self.config.time_cost,
                .m = self.config.memory_cost,
                .p = self.config.parallelism,
            },
        ) catch return error.HashingFailed;

        // Format: $argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>
        // Encode salt and hash to base64
        const salt_b64 = try base64Encode(self.allocator, salt[0..16]);
        defer self.allocator.free(salt_b64);

        const hash_b64 = try base64Encode(self.allocator, &hash);
        defer self.allocator.free(hash_b64);

        return std.fmt.allocPrint(
            self.allocator,
            "$argon2id$v=19$m={d},t={d},p={d}${s}${s}",
            .{
                self.config.memory_cost,
                self.config.time_cost,
                self.config.parallelism,
                salt_b64,
                hash_b64,
            },
        );
    }

    /// Verify a password against a hash
    pub fn verify(self: *Self, password: []const u8, hash_str: []const u8) bool {
        // Parse the hash string
        const params = parseHashString(hash_str) orelse return false;

        // Decode salt from base64
        const salt = base64Decode(self.allocator, params.salt) catch return false;
        defer self.allocator.free(salt);

        if (salt.len < 16) return false;

        // Decode expected hash
        const expected_hash = base64Decode(self.allocator, params.hash) catch return false;
        defer self.allocator.free(expected_hash);

        // Compute hash with same parameters
        var computed: [32]u8 = undefined;
        std.crypto.pwhash.argon2.kdf(
            &computed,
            password,
            salt[0..16].*,
            .{
                .t = params.t,
                .m = params.m,
                .p = params.p,
            },
        ) catch return false;

        // Constant-time comparison
        return constantTimeCompare(&computed, expected_hash);
    }

    /// Check if a hash needs to be rehashed (parameters changed)
    pub fn needsRehash(self: *Self, hash_str: []const u8) bool {
        const params = parseHashString(hash_str) orelse return true;

        return params.t != self.config.time_cost or
            params.m != self.config.memory_cost or
            params.p != self.config.parallelism;
    }
};

const HashParams = struct {
    m: u32,
    t: u32,
    p: u8,
    salt: []const u8,
    hash: []const u8,
};

fn parseHashString(hash_str: []const u8) ?HashParams {
    // Format: $argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>
    if (!std.mem.startsWith(u8, hash_str, "$argon2id$")) return null;

    var parts = std.mem.splitScalar(u8, hash_str[1..], '$');

    // Skip "argon2id"
    _ = parts.next() orelse return null;

    // Skip version "v=19"
    _ = parts.next() orelse return null;

    // Parse parameters "m=65536,t=3,p=4"
    const params_str = parts.next() orelse return null;
    var m: u32 = 65536;
    var t: u32 = 3;
    var p: u8 = 4;

    var param_iter = std.mem.splitScalar(u8, params_str, ',');
    while (param_iter.next()) |param| {
        if (std.mem.startsWith(u8, param, "m=")) {
            m = std.fmt.parseInt(u32, param[2..], 10) catch 65536;
        } else if (std.mem.startsWith(u8, param, "t=")) {
            t = std.fmt.parseInt(u32, param[2..], 10) catch 3;
        } else if (std.mem.startsWith(u8, param, "p=")) {
            p = std.fmt.parseInt(u8, param[2..], 10) catch 4;
        }
    }

    // Get salt
    const salt = parts.next() orelse return null;

    // Get hash
    const hash = parts.next() orelse return null;

    return HashParams{
        .m = m,
        .t = t,
        .p = p,
        .salt = salt,
        .hash = hash,
    };
}

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return encoded;
}

fn base64Decode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, data) catch return error.InvalidBase64;
    return decoded;
}

fn constantTimeCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var result: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        result |= byte_a ^ byte_b;
    }
    return result == 0;
}

/// Simple SHA256-based hash for non-password use cases
pub fn sha256(data: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

/// Simple HMAC-SHA256
pub fn hmacSha256(key: []const u8, data: []const u8) [32]u8 {
    var mac: [32]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
    hmac.update(data);
    hmac.final(&mac);
    return mac;
}

// Tests
test "hash and verify" {
    const allocator = std.testing.allocator;

    var hasher = Hash.init(allocator, .{
        .time_cost = 1, // Low for testing
        .memory_cost = 4096, // Low for testing
        .parallelism = 1,
    });

    // Hash password
    const hash_result = try hasher.make("my-password");
    defer allocator.free(hash_result);

    // Verify correct password
    try std.testing.expect(hasher.verify("my-password", hash_result));

    // Verify wrong password
    try std.testing.expect(!hasher.verify("wrong-password", hash_result));
}

test "needs rehash" {
    const allocator = std.testing.allocator;

    var hasher = Hash.init(allocator, .{
        .time_cost = 1,
        .memory_cost = 4096,
        .parallelism = 1,
    });

    const hash_result = try hasher.make("password");
    defer allocator.free(hash_result);

    // Same parameters - no rehash needed
    try std.testing.expect(!hasher.needsRehash(hash_result));

    // Change parameters
    hasher.config.time_cost = 2;
    try std.testing.expect(hasher.needsRehash(hash_result));
}

test "sha256" {
    const hash_result = sha256("hello");
    try std.testing.expectEqual(@as(usize, 32), hash_result.len);
}

test "hmac sha256" {
    const mac = hmacSha256("key", "data");
    try std.testing.expectEqual(@as(usize, 32), mac.len);
}
