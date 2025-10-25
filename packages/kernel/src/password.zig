// Home OS Kernel - Password Hashing
// Secure password storage using bcrypt-style hashing

const Basics = @import("basics");
const random = @import("random.zig");

// ============================================================================
// Password Hashing Constants
// ============================================================================

const SALT_LENGTH = 16; // 128 bits
const HASH_LENGTH = 32; // 256 bits
const DEFAULT_COST = 12; // 2^12 iterations (4096)

// ============================================================================
// Password Hash Structure
// ============================================================================

pub const PasswordHash = struct {
    /// Salt (random bytes)
    salt: [SALT_LENGTH]u8,
    /// Hash output
    hash: [HASH_LENGTH]u8,
    /// Cost factor (iterations = 2^cost)
    cost: u8,

    /// Format: $2b$[cost]$[salt][hash] (base64-like encoding)
    pub fn toString(self: *const PasswordHash, buffer: []u8) ![]const u8 {
        if (buffer.len < 60) return error.BufferTooSmall;

        // Simple hex encoding for now (in production, use base64)
        var pos: usize = 0;

        // Prefix
        @memcpy(buffer[pos .. pos + 4], "$2b$");
        pos += 4;

        // Cost (2 digits)
        buffer[pos] = '0' + (self.cost / 10);
        buffer[pos + 1] = '0' + (self.cost % 10);
        pos += 2;

        buffer[pos] = '$';
        pos += 1;

        // Salt (hex encoded)
        for (self.salt) |byte| {
            const hex_chars = "0123456789abcdef";
            buffer[pos] = hex_chars[byte >> 4];
            buffer[pos + 1] = hex_chars[byte & 0xF];
            pos += 2;
        }

        // Hash (hex encoded) - abbreviated for space
        for (self.hash[0..8]) |byte| {
            const hex_chars = "0123456789abcdef";
            buffer[pos] = hex_chars[byte >> 4];
            buffer[pos + 1] = hex_chars[byte & 0xF];
            pos += 2;
        }

        return buffer[0..pos];
    }
};

// ============================================================================
// Password Hashing Functions
// ============================================================================

/// Generate a random salt
fn generateSalt() [SALT_LENGTH]u8 {
    var salt: [SALT_LENGTH]u8 = undefined;
    random.getRandomBytes(&salt);
    return salt;
}

/// Simple PBKDF2-like key derivation (simplified for demonstration)
/// In production, use bcrypt, Argon2id, or scrypt
fn deriveKey(password: []const u8, salt: []const u8, iterations: u32, output: []u8) void {
    // Initialize output with salt
    var state: [HASH_LENGTH]u8 = undefined;
    @memset(&state, 0);

    // Copy salt into state
    const copy_len = Basics.math.min(salt.len, HASH_LENGTH);
    @memcpy(state[0..copy_len], salt[0..copy_len]);

    // Iterate (simplified mixing - not cryptographically secure)
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Mix password into state
        for (password, 0..) |byte, j| {
            state[j % HASH_LENGTH] ^= byte;
            state[j % HASH_LENGTH] = rotateLeft(state[j % HASH_LENGTH], 3);
        }

        // Self-mixing
        var j: usize = 0;
        while (j < HASH_LENGTH) : (j += 1) {
            state[j] ^= state[(j + 1) % HASH_LENGTH];
            state[j] = rotateLeft(state[j], 5);
        }
    }

    // Copy to output
    @memcpy(output, &state);
}

fn rotateLeft(byte: u8, count: u3) u8 {
    return (byte << count) | (byte >> (8 - count));
}

/// Hash a password with automatic salt generation
pub fn hashPassword(password: []const u8, cost: u8) !PasswordHash {
    if (password.len == 0) return error.EmptyPassword;
    if (password.len > 128) return error.PasswordTooLong;
    if (cost > 20) return error.CostTooHigh; // Max 2^20 iterations

    const salt = generateSalt();
    const iterations = @as(u32, 1) << @intCast(cost);

    var hash: [HASH_LENGTH]u8 = undefined;
    deriveKey(password, &salt, iterations, &hash);

    return PasswordHash{
        .salt = salt,
        .hash = hash,
        .cost = cost,
    };
}

/// Hash a password with a specific salt (for verification)
pub fn hashPasswordWithSalt(password: []const u8, salt: []const u8, cost: u8) !PasswordHash {
    if (password.len == 0) return error.EmptyPassword;
    if (salt.len != SALT_LENGTH) return error.InvalidSalt;

    var salt_copy: [SALT_LENGTH]u8 = undefined;
    @memcpy(&salt_copy, salt);

    const iterations = @as(u32, 1) << @intCast(cost);

    var hash: [HASH_LENGTH]u8 = undefined;
    deriveKey(password, salt, iterations, &hash);

    return PasswordHash{
        .salt = salt_copy,
        .hash = hash,
        .cost = cost,
    };
}

/// Verify a password against a hash
pub fn verifyPassword(password: []const u8, stored_hash: *const PasswordHash) !bool {
    // Hash the password with the same salt and cost
    const candidate = try hashPasswordWithSalt(password, &stored_hash.salt, stored_hash.cost);

    // Constant-time comparison to prevent timing attacks
    return constantTimeEqual(&candidate.hash, &stored_hash.hash);
}

/// Constant-time comparison of two byte arrays
fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var result: u8 = 0;
    for (a, b) |a_byte, b_byte| {
        result |= a_byte ^ b_byte;
    }

    return result == 0;
}

// ============================================================================
// User Database Entry
// ============================================================================

pub const UserEntry = struct {
    username: [32]u8,
    username_len: usize,
    password_hash: PasswordHash,
    uid: u32,
    gid: u32,

    pub fn init(username: []const u8, password: []const u8, uid: u32, gid: u32) !UserEntry {
        if (username.len > 31) return error.UsernameTooLong;

        var entry: UserEntry = undefined;

        // Copy username
        @memcpy(entry.username[0..username.len], username);
        entry.username_len = username.len;

        // Hash password
        entry.password_hash = try hashPassword(password, DEFAULT_COST);

        entry.uid = uid;
        entry.gid = gid;

        return entry;
    }

    pub fn getUsername(self: *const UserEntry) []const u8 {
        return self.username[0..self.username_len];
    }

    pub fn verifyPassword(self: *const UserEntry, password: []const u8) !bool {
        return password.verifyPassword(password, &self.password_hash);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "generate salt" {
    const salt1 = generateSalt();
    const salt2 = generateSalt();

    // Salts should be different (very high probability)
    var different = false;
    for (salt1, salt2) |b1, b2| {
        if (b1 != b2) {
            different = true;
            break;
        }
    }

    try Basics.testing.expect(different);
}

test "hash password" {
    const password = "test_password_123";
    const hash = try hashPassword(password, 4); // Low cost for testing

    try Basics.testing.expect(hash.cost == 4);
    try Basics.testing.expect(hash.salt.len == SALT_LENGTH);
    try Basics.testing.expect(hash.hash.len == HASH_LENGTH);
}

test "verify password success" {
    const password = "correct_password";
    const hash = try hashPassword(password, 4);

    const verified = try verifyPassword(password, &hash);
    try Basics.testing.expect(verified);
}

test "verify password failure" {
    const password = "correct_password";
    const wrong_password = "wrong_password";

    const hash = try hashPassword(password, 4);

    const verified = try verifyPassword(wrong_password, &hash);
    try Basics.testing.expect(!verified);
}

test "same password different salts" {
    const password = "same_password";

    const hash1 = try hashPassword(password, 4);
    const hash2 = try hashPassword(password, 4);

    // Salts should be different
    var salts_different = false;
    for (hash1.salt, hash2.salt) |b1, b2| {
        if (b1 != b2) {
            salts_different = true;
            break;
        }
    }

    try Basics.testing.expect(salts_different);

    // Hashes should be different (because salts are different)
    var hashes_different = false;
    for (hash1.hash, hash2.hash) |b1, b2| {
        if (b1 != b2) {
            hashes_different = true;
            break;
        }
    }

    try Basics.testing.expect(hashes_different);
}

test "constant time comparison" {
    const a = "hello";
    const b = "hello";
    const c = "world";

    try Basics.testing.expect(constantTimeEqual(a, b));
    try Basics.testing.expect(!constantTimeEqual(a, c));
}

test "user entry creation" {
    const entry = try UserEntry.init("testuser", "password123", 1000, 1000);

    try Basics.testing.expectEqualStrings("testuser", entry.getUsername());
    try Basics.testing.expect(entry.uid == 1000);
    try Basics.testing.expect(entry.gid == 1000);
}

test "empty password rejection" {
    const result = hashPassword("", 4);
    try Basics.testing.expectError(error.EmptyPassword, result);
}

test "password hash to string" {
    const hash = try hashPassword("test", 4);

    var buffer: [128]u8 = undefined;
    const str = try hash.toString(&buffer);

    // Should start with $2b$
    try Basics.testing.expect(str.len > 4);
    try Basics.testing.expect(str[0] == '$');
    try Basics.testing.expect(str[1] == '2');
    try Basics.testing.expect(str[2] == 'b');
    try Basics.testing.expect(str[3] == '$');
}
