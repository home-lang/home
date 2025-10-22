const std = @import("std");

/// Cryptography utilities for Ion
/// Provides hashing, encoding, and basic encryption

/// SHA-256 hashing
pub const SHA256 = struct {
    /// Hash data with SHA-256
    pub fn hash(data: []const u8) [32]u8 {
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &result, .{});
        return result;
    }

    /// Hash and return hex string
    pub fn hashHex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const hash_bytes = hash(data);
        return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash_bytes)});
    }

    /// Verify hash matches data
    pub fn verify(data: []const u8, expected: [32]u8) bool {
        const actual = hash(data);
        return std.mem.eql(u8, &actual, &expected);
    }
};

/// SHA-512 hashing
pub const SHA512 = struct {
    /// Hash data with SHA-512
    pub fn hash(data: []const u8) [64]u8 {
        var result: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(data, &result, .{});
        return result;
    }

    /// Hash and return hex string
    pub fn hashHex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const hash_bytes = hash(data);
        return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash_bytes)});
    }
};

/// MD5 hashing (for compatibility, not cryptographically secure)
pub const MD5 = struct {
    /// Hash data with MD5
    pub fn hash(data: []const u8) [16]u8 {
        var result: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(data, &result, .{});
        return result;
    }

    /// Hash and return hex string
    pub fn hashHex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const hash_bytes = hash(data);
        return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash_bytes)});
    }
};

/// BLAKE3 hashing (modern, fast)
pub const BLAKE3 = struct {
    /// Hash data with BLAKE3
    pub fn hash(data: []const u8) [32]u8 {
        var result: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(data, &result, .{});
        return result;
    }

    /// Hash and return hex string
    pub fn hashHex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const hash_bytes = hash(data);
        return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash_bytes)});
    }
};

/// HMAC (Hash-based Message Authentication Code)
pub const HMAC = struct {
    /// HMAC-SHA256
    pub fn sha256(key: []const u8, message: []const u8) [32]u8 {
        var result: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&result, message, key);
        return result;
    }

    /// HMAC-SHA512
    pub fn sha512(key: []const u8, message: []const u8) [64]u8 {
        var result: [64]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha512.create(&result, message, key);
        return result;
    }

    /// Verify HMAC
    pub fn verifySha256(key: []const u8, message: []const u8, expected: [32]u8) bool {
        const actual = sha256(key, message);
        return std.mem.eql(u8, &actual, &expected);
    }
};

/// Base64 encoding/decoding
pub const Base64 = struct {
    const encoder = std.base64.standard.Encoder;
    const decoder = std.base64.standard.Decoder;

    /// Encode data to Base64
    pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const encoded_len = encoder.calcSize(data.len);
        const result = try allocator.alloc(u8, encoded_len);
        return encoder.encode(result, data);
    }

    /// Decode Base64 to data
    pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
        const max_decoded_len = try decoder.calcSizeForSlice(encoded);
        const result = try allocator.alloc(u8, max_decoded_len);
        const decoded_len = try decoder.decode(result, encoded);
        return result[0..decoded_len];
    }
};

/// Hex encoding/decoding
pub const Hex = struct {
    /// Encode data to hex string
    pub fn encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(data)});
    }

    /// Decode hex string to data
    pub fn decode(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
        if (hex.len % 2 != 0) return error.InvalidHexLength;

        const result = try allocator.alloc(u8, hex.len / 2);
        _ = try std.fmt.hexToBytes(result, hex);
        return result;
    }
};

/// Random number generation
pub const Random = struct {
    prng: std.rand.DefaultPrng,

    /// Initialize with seed
    pub fn init(seed: u64) Random {
        return .{
            .prng = std.rand.DefaultPrng.init(seed),
        };
    }

    /// Initialize with random seed
    pub fn initRandom() Random {
        var seed: u64 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&seed));
        return init(seed);
    }

    /// Generate random bytes
    pub fn bytes(self: *Random, buffer: []u8) void {
        self.prng.random().bytes(buffer);
    }

    /// Generate random integer in range
    pub fn intRange(self: *Random, comptime T: type, min: T, max: T) T {
        return self.prng.random().intRangeAtMost(T, min, max);
    }

    /// Generate random float in range [0, 1)
    pub fn float(self: *Random, comptime T: type) T {
        return self.prng.random().float(T);
    }

    /// Generate random boolean
    pub fn boolean(self: *Random) bool {
        return self.prng.random().boolean();
    }
};

/// Secure random for cryptographic use
pub const SecureRandom = struct {
    /// Generate secure random bytes
    pub fn bytes(buffer: []u8) void {
        std.crypto.random.bytes(buffer);
    }

    /// Generate secure random integer
    pub fn int(comptime T: type) T {
        var result: T = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&result));
        return result;
    }

    /// Generate secure random integer in range
    pub fn intRange(comptime T: type, min: T, max: T) T {
        const range = max - min + 1;
        return min + @mod(int(T), range);
    }

    /// Generate random hex string
    pub fn hex(allocator: std.mem.Allocator, length: usize) ![]u8 {
        const byte_len = (length + 1) / 2;
        const random_bytes = try allocator.alloc(u8, byte_len);
        defer allocator.free(random_bytes);

        bytes(random_bytes);

        const hex_str = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(random_bytes)});
        return hex_str[0..length];
    }

    /// Generate random base64 string
    pub fn base64(allocator: std.mem.Allocator, length: usize) ![]u8 {
        const random_bytes = try allocator.alloc(u8, length);
        defer allocator.free(random_bytes);

        bytes(random_bytes);

        return Base64.encode(allocator, random_bytes);
    }
};

/// Password hashing with bcrypt-style approach
pub const Password = struct {
    /// Hash a password (using Argon2)
    pub fn hash(allocator: std.mem.Allocator, password: []const u8, salt: []const u8) ![]u8 {
        // Using scrypt as a password hashing function
        var result: [32]u8 = undefined;

        try std.crypto.pwhash.scrypt(
            &result,
            password,
            salt,
            .{ .ln = 15, .r = 8, .p = 1 },
        );

        return allocator.dupe(u8, &result);
    }

    /// Verify password against hash
    pub fn verify(password: []const u8, salt: []const u8, expected_hash: []const u8) !bool {
        var computed: [32]u8 = undefined;

        try std.crypto.pwhash.scrypt(
            &computed,
            password,
            salt,
            .{ .ln = 15, .r = 8, .p = 1 },
        );

        return std.mem.eql(u8, &computed, expected_hash);
    }

    /// Generate a random salt
    pub fn generateSalt(allocator: std.mem.Allocator) ![]u8 {
        const salt = try allocator.alloc(u8, 16);
        SecureRandom.bytes(salt);
        return salt;
    }
};

/// UUID generation
pub const UUID = struct {
    bytes: [16]u8,

    /// Generate a random UUID v4
    pub fn v4() UUID {
        var uuid: UUID = undefined;
        SecureRandom.bytes(&uuid.bytes);

        // Set version to 4
        uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;

        // Set variant to RFC4122
        uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;

        return uuid;
    }

    /// Format UUID as string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
    pub fn toString(self: UUID, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
            .{
                self.bytes[0],  self.bytes[1],  self.bytes[2],  self.bytes[3],
                self.bytes[4],  self.bytes[5],  self.bytes[6],  self.bytes[7],
                self.bytes[8],  self.bytes[9],  self.bytes[10], self.bytes[11],
                self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15],
            },
        );
    }

    /// Parse UUID from string
    pub fn parse(str: []const u8) !UUID {
        if (str.len != 36) return error.InvalidUUIDLength;

        var uuid: UUID = undefined;
        var byte_idx: usize = 0;

        var i: usize = 0;
        while (i < str.len) {
            if (str[i] == '-') {
                i += 1;
                continue;
            }

            if (i + 1 >= str.len) return error.InvalidUUID;

            const hex_pair = str[i .. i + 2];
            uuid.bytes[byte_idx] = try std.fmt.parseInt(u8, hex_pair, 16);
            byte_idx += 1;
            i += 2;
        }

        if (byte_idx != 16) return error.InvalidUUID;

        return uuid;
    }
};

/// JWT token helpers (basic implementation)
pub const JWT = struct {
    /// Create a simple JWT header
    pub fn createHeader(allocator: std.mem.Allocator, alg: []const u8) ![]u8 {
        const header = try std.fmt.allocPrint(
            allocator,
            "{{\"alg\":\"{s}\",\"typ\":\"JWT\"}}",
            .{alg},
        );
        defer allocator.free(header);

        return Base64.encode(allocator, header);
    }

    /// Create JWT payload
    pub fn createPayload(allocator: std.mem.Allocator, claims: []const u8) ![]u8 {
        return Base64.encode(allocator, claims);
    }

    /// Sign JWT (HMAC-SHA256)
    pub fn sign(allocator: std.mem.Allocator, header: []const u8, payload: []const u8, secret: []const u8) ![]u8 {
        const message = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header, payload });
        defer allocator.free(message);

        const signature = HMAC.sha256(secret, message);
        return Base64.encode(allocator, &signature);
    }

    /// Create complete JWT token
    pub fn create(allocator: std.mem.Allocator, claims: []const u8, secret: []const u8) ![]u8 {
        const header = try createHeader(allocator, "HS256");
        defer allocator.free(header);

        const payload = try createPayload(allocator, claims);
        defer allocator.free(payload);

        const signature = try sign(allocator, header, payload, secret);
        defer allocator.free(signature);

        return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header, payload, signature });
    }
};

/// Constant-time comparison for security
pub fn constantTimeCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var diff: u8 = 0;
    for (a, b) |a_byte, b_byte| {
        diff |= a_byte ^ b_byte;
    }

    return diff == 0;
}
