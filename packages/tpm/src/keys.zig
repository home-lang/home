// TPM Key Management

const std = @import("std");

/// TPM key types
pub const KeyType = enum {
    storage, // Storage Root Key (SRK)
    signing, // Attestation Identity Key (AIK)
    encryption, // Encryption key
    binding, // Binding key
    legacy, // Legacy key

    pub fn toString(self: KeyType) []const u8 {
        return @tagName(self);
    }
};

/// Key algorithm
pub const Algorithm = enum {
    rsa_2048,
    rsa_3072,
    rsa_4096,
    ecc_p256,
    ecc_p384,
    ecc_p521,

    pub fn toString(self: Algorithm) []const u8 {
        return @tagName(self);
    }

    pub fn keySize(self: Algorithm) usize {
        return switch (self) {
            .rsa_2048 => 2048 / 8,
            .rsa_3072 => 3072 / 8,
            .rsa_4096 => 4096 / 8,
            .ecc_p256 => 32,
            .ecc_p384 => 48,
            .ecc_p521 => 66,
        };
    }
};

/// TPM key handle
pub const KeyHandle = u32;

/// Special key handles
pub const KeyHandles = struct {
    pub const OWNER: KeyHandle = 0x40000001;
    pub const ENDORSEMENT: KeyHandle = 0x40000002;
    pub const PLATFORM: KeyHandle = 0x40000003;
    pub const NULL: KeyHandle = 0x40000007;
};

/// Key attributes
pub const KeyAttributes = struct {
    fixed_tpm: bool = false, // Key cannot be duplicated
    fixed_parent: bool = false, // Key has fixed parent
    sensitive_data_origin: bool = true, // TPM generated sensitive data
    user_with_auth: bool = false, // Requires user authorization
    admin_with_policy: bool = false, // Requires policy authorization
    no_da: bool = false, // Not subject to dictionary attack protection
    encrypted_duplication: bool = false, // Can be duplicated with encryption
    restricted: bool = false, // Restricted key (signing/decryption)
    decrypt: bool = false, // Can decrypt
    sign: bool = false, // Can sign

    pub fn forStorage() KeyAttributes {
        return .{
            .fixed_tpm = true,
            .fixed_parent = true,
            .sensitive_data_origin = true,
            .user_with_auth = true,
            .restricted = true,
            .decrypt = true,
        };
    }

    pub fn forSigning() KeyAttributes {
        return .{
            .fixed_tpm = true,
            .fixed_parent = true,
            .sensitive_data_origin = true,
            .user_with_auth = true,
            .sign = true,
        };
    }

    pub fn forEncryption() KeyAttributes {
        return .{
            .fixed_tpm = true,
            .sensitive_data_origin = true,
            .user_with_auth = true,
            .decrypt = true,
        };
    }
};

/// TPM key
pub const Key = struct {
    handle: KeyHandle,
    key_type: KeyType,
    algorithm: Algorithm,
    attributes: KeyAttributes,
    public_key: []u8,
    auth_value: []u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        handle: KeyHandle,
        key_type: KeyType,
        algorithm: Algorithm,
        attributes: KeyAttributes,
    ) !Key {
        // Generate simulated public key
        const key_size = algorithm.keySize();
        const public_key = try allocator.alloc(u8, key_size);
        std.crypto.random.bytes(public_key);

        return .{
            .handle = handle,
            .key_type = key_type,
            .algorithm = algorithm,
            .attributes = attributes,
            .public_key = public_key,
            .auth_value = &[_]u8{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Key) void {
        self.allocator.free(self.public_key);
        if (self.auth_value.len > 0) {
            // Secure erase
            @memset(self.auth_value, 0);
            self.allocator.free(self.auth_value);
        }
    }

    pub fn setAuth(self: *Key, auth: []const u8) !void {
        if (self.auth_value.len > 0) {
            @memset(self.auth_value, 0);
            self.allocator.free(self.auth_value);
        }
        self.auth_value = try self.allocator.dupe(u8, auth);
    }

    pub fn getPublicKey(self: *const Key) []const u8 {
        return self.public_key;
    }
};

/// Create primary key (SRK, EK, etc.)
pub fn createPrimary(
    allocator: std.mem.Allocator,
    hierarchy: KeyHandle,
    key_type: KeyType,
    algorithm: Algorithm,
) !Key {
    _ = hierarchy;

    const attributes = switch (key_type) {
        .storage => KeyAttributes.forStorage(),
        .signing => KeyAttributes.forSigning(),
        .encryption => KeyAttributes.forEncryption(),
        else => KeyAttributes{},
    };

    // In production, would send TPM2_CreatePrimary command
    const handle: KeyHandle = 0x80000000; // Simulated transient handle

    return Key.init(allocator, handle, key_type, algorithm, attributes);
}

/// Create child key under parent
pub fn createKey(
    allocator: std.mem.Allocator,
    parent: *const Key,
    key_type: KeyType,
    algorithm: Algorithm,
    auth_value: ?[]const u8,
) !Key {
    _ = parent;

    const attributes = switch (key_type) {
        .signing => KeyAttributes.forSigning(),
        .encryption => KeyAttributes.forEncryption(),
        else => KeyAttributes{},
    };

    // In production, would send TPM2_Create command
    const handle: KeyHandle = 0x80000001; // Simulated transient handle

    var key = try Key.init(allocator, handle, key_type, algorithm, attributes);

    if (auth_value) |auth| {
        try key.setAuth(auth);
    }

    return key;
}

/// Load key into TPM
pub fn loadKey(
    allocator: std.mem.Allocator,
    parent: *const Key,
    key_blob: []const u8,
) !Key {
    _ = parent;
    _ = key_blob;

    // In production, would send TPM2_Load command
    // For now, create a dummy key
    return Key.init(
        allocator,
        0x80000002,
        .signing,
        .rsa_2048,
        KeyAttributes.forSigning(),
    );
}

/// Flush key from TPM (unload transient key)
pub fn flushKey(key: *Key) void {
    // In production, would send TPM2_FlushContext command
    key.deinit();
}

/// Make key persistent
pub fn evictControl(
    key: *const Key,
    persistent_handle: KeyHandle,
) !void {
    _ = key;
    _ = persistent_handle;

    // In production, would send TPM2_EvictControl command
}

/// Sign data with TPM key
pub fn sign(
    allocator: std.mem.Allocator,
    key: *const Key,
    data: []const u8,
) ![]u8 {
    if (!key.attributes.sign) {
        return error.KeyCannotSign;
    }

    // In production, would send TPM2_Sign command
    // For now, create simulated signature
    const signature = try allocator.alloc(u8, key.algorithm.keySize());
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    hasher.update(key.public_key);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    @memcpy(signature[0..@min(32, signature.len)], digest[0..@min(32, signature.len)]);

    return signature;
}

/// Decrypt data with TPM key
pub fn decrypt(
    allocator: std.mem.Allocator,
    key: *const Key,
    encrypted: []const u8,
) ![]u8 {
    if (!key.attributes.decrypt) {
        return error.KeyCannotDecrypt;
    }

    // In production, would send TPM2_RSA_Decrypt command
    // For now, return copy (simulated decryption)
    return try allocator.dupe(u8, encrypted);
}

test "create primary key" {
    const testing = std.testing;

    var key = try createPrimary(
        testing.allocator,
        KeyHandles.OWNER,
        .storage,
        .rsa_2048,
    );
    defer key.deinit();

    try testing.expect(key.public_key.len == 256); // 2048 bits = 256 bytes
    try testing.expect(key.attributes.restricted);
    try testing.expect(key.attributes.decrypt);
}

test "create child key" {
    const testing = std.testing;

    var parent = try createPrimary(
        testing.allocator,
        KeyHandles.OWNER,
        .storage,
        .rsa_2048,
    );
    defer parent.deinit();

    var child = try createKey(
        testing.allocator,
        &parent,
        .signing,
        .rsa_2048,
        "my_auth_value",
    );
    defer child.deinit();

    try testing.expect(child.attributes.sign);
    try testing.expect(child.auth_value.len > 0);
}

test "sign with key" {
    const testing = std.testing;

    var key = try createPrimary(
        testing.allocator,
        KeyHandles.OWNER,
        .signing,
        .rsa_2048,
    );
    key.attributes.sign = true; // Override for test
    defer key.deinit();

    const data = "message to sign";
    const signature = try sign(testing.allocator, &key, data);
    defer testing.allocator.free(signature);

    try testing.expect(signature.len == 256);
}
