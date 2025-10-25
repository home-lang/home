// Home OS Kernel - Module Signing Enforcement
// Ensures only trusted kernel modules can be loaded

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const capabilities = @import("capabilities.zig");
const lockdown = @import("lockdown.zig");

// ============================================================================
// Module Signature
// ============================================================================

pub const SignatureAlgorithm = enum(u8) {
    RSA_2048_SHA256 = 0,
    RSA_4096_SHA256 = 1,
    ECDSA_P256_SHA256 = 2,
};

pub const ModuleSignature = struct {
    /// Algorithm used
    algorithm: SignatureAlgorithm,
    /// Key ID (fingerprint of signing key)
    key_id: [32]u8,
    /// Signature data
    signature: [512]u8,
    /// Signature length
    signature_len: usize,
    /// Module hash
    module_hash: [64]u8,
    /// Hash length
    hash_len: usize,

    pub fn init(algorithm: SignatureAlgorithm) ModuleSignature {
        return .{
            .algorithm = algorithm,
            .key_id = [_]u8{0} ** 32,
            .signature = [_]u8{0} ** 512,
            .signature_len = 0,
            .module_hash = [_]u8{0} ** 64,
            .hash_len = 32, // SHA-256
        };
    }

    /// Verify signature against module data
    pub fn verify(self: *const ModuleSignature, module_data: []const u8, public_key: *const PublicKey) !void {
        // Hash module data
        var computed_hash: [64]u8 = undefined;
        hashModule(module_data, computed_hash[0..self.hash_len]);

        // Check hash matches
        if (!Basics.mem.eql(u8, &self.module_hash, &computed_hash)) {
            return error.HashMismatch;
        }

        // Verify signature (simplified - production would use real crypto)
        if (self.signature_len == 0) {
            return error.InvalidSignature;
        }

        // Check key ID matches
        if (!Basics.mem.eql(u8, &self.key_id, &public_key.key_id)) {
            return error.KeyMismatch;
        }

        // Simplified signature verification
        var check_byte: u8 = 0;
        for (self.signature[0..self.signature_len]) |byte| {
            check_byte ^= byte;
        }

        if (check_byte == 0) {
            return error.InvalidSignature;
        }
    }
};

fn hashModule(data: []const u8, hash: []u8) void {
    // Simple hash (production would use SHA-256)
    var state: u64 = 0x6a09e667f3bcc908; // SHA-256 initial value

    for (data) |byte| {
        state ^= byte;
        state = state *% 0x9e3779b97f4a7c15;
        state ^= state >> 32;
    }

    // Generate hash bytes
    for (hash, 0..) |*h_byte, i| {
        _ = i;
        state = state *% 0x9e3779b97f4a7c15;
        state ^= state >> 32;
        h_byte.* = @truncate(state & 0xFF);
    }
}

// ============================================================================
// Public Key Ring
// ============================================================================

pub const PublicKey = struct {
    /// Key ID (fingerprint)
    key_id: [32]u8,
    /// Algorithm
    algorithm: SignatureAlgorithm,
    /// Public key data (modulus for RSA, point for ECDSA)
    key_data: [512]u8,
    /// Key data length
    key_len: usize,
    /// Description
    description: [64]u8,
    /// Description length
    desc_len: usize,
    /// Trusted flag
    trusted: bool,

    pub fn init(algorithm: SignatureAlgorithm, description: []const u8) !PublicKey {
        if (description.len > 63) {
            return error.DescriptionTooLong;
        }

        var key: PublicKey = undefined;
        key.algorithm = algorithm;
        key.key_id = [_]u8{0} ** 32;
        key.key_data = [_]u8{0} ** 512;
        key.key_len = 0;
        key.description = [_]u8{0} ** 64;
        key.desc_len = description.len;
        key.trusted = false;

        @memcpy(key.description[0..description.len], description);

        return key;
    }

    /// Generate key ID from key data
    pub fn generateKeyId(self: *PublicKey) void {
        // Simple key ID generation (production would use SHA-256 of key)
        var state: u64 = 0x123456789abcdef0;

        for (self.key_data[0..self.key_len]) |byte| {
            state ^= byte;
            state = state *% 0x9e3779b97f4a7c15;
        }

        for (&self.key_id, 0..) |*id_byte, i| {
            _ = i;
            state = state *% 0x9e3779b97f4a7c15;
            state ^= state >> 32;
            id_byte.* = @truncate(state & 0xFF);
        }
    }
};

pub const PublicKeyRing = struct {
    /// Keys (up to 16 trusted keys)
    keys: [16]?PublicKey,
    /// Key count
    key_count: atomic.AtomicU32,
    /// Lock
    lock: sync.RwLock,

    pub fn init() PublicKeyRing {
        return .{
            .keys = [_]?PublicKey{null} ** 16,
            .key_count = atomic.AtomicU32.init(0),
            .lock = sync.RwLock.init(),
        };
    }

    /// Add trusted key
    pub fn addKey(self: *PublicKeyRing, key: PublicKey) !void {
        if (!capabilities.hasCapability(.CAP_SYS_MODULE)) {
            return error.PermissionDenied;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const count = self.key_count.load(.Acquire);
        if (count >= 16) {
            return error.KeyRingFull;
        }

        self.keys[count] = key;
        _ = self.key_count.fetchAdd(1, .Release);

        audit.logSecurityViolation("Module signing key added");
    }

    /// Find key by ID
    pub fn findKey(self: *PublicKeyRing, key_id: []const u8) ?*const PublicKey {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.keys) |*maybe_key| {
            if (maybe_key.*) |*key| {
                if (Basics.mem.eql(u8, &key.key_id, key_id)) {
                    return key;
                }
            }
        }

        return null;
    }

    /// Remove all keys
    pub fn clear(self: *PublicKeyRing) !void {
        if (!capabilities.hasCapability(.CAP_SYS_MODULE)) {
            return error.PermissionDenied;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        for (&self.keys) |*key| {
            key.* = null;
        }

        self.key_count.store(0, .Release);
    }
};

// ============================================================================
// Module Verification Policy
// ============================================================================

pub const VerificationPolicy = enum(u8) {
    /// No signature required
    NONE = 0,
    /// Signature required but allow unsigned if CAP_SYS_MODULE
    OPTIONAL = 1,
    /// Signature always required
    REQUIRED = 2,
    /// Signature required + lockdown enforcement
    STRICT = 3,
};

pub const ModuleVerifier = struct {
    /// Public key ring
    keyring: PublicKeyRing,
    /// Current policy
    policy: atomic.AtomicU8,
    /// Verification statistics
    verified_count: atomic.AtomicU64,
    /// Failed verification count
    failed_count: atomic.AtomicU64,
    /// Unsigned module count
    unsigned_count: atomic.AtomicU64,

    pub fn init(policy: VerificationPolicy) ModuleVerifier {
        return .{
            .keyring = PublicKeyRing.init(),
            .policy = atomic.AtomicU8.init(@intFromEnum(policy)),
            .verified_count = atomic.AtomicU64.init(0),
            .failed_count = atomic.AtomicU64.init(0),
            .unsigned_count = atomic.AtomicU64.init(0),
        };
    }

    /// Get current policy
    pub fn getPolicy(self: *const ModuleVerifier) VerificationPolicy {
        return @enumFromInt(self.policy.load(.Acquire));
    }

    /// Set policy
    pub fn setPolicy(self: *ModuleVerifier, policy: VerificationPolicy) !void {
        if (!capabilities.hasCapability(.CAP_SYS_MODULE)) {
            return error.PermissionDenied;
        }

        self.policy.store(@intFromEnum(policy), .Release);

        var buf: [128]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "Module verification policy: {s}", .{@tagName(policy)}) catch "policy_change";
        audit.logSecurityViolation(msg);
    }

    /// Verify module signature
    pub fn verifyModule(self: *ModuleVerifier, module_data: []const u8, signature: ?*const ModuleSignature) !void {
        const current_policy = self.getPolicy();

        // Check if signature is provided
        if (signature == null) {
            _ = self.unsigned_count.fetchAdd(1, .Release);

            return switch (current_policy) {
                .NONE => {}, // No signature required
                .OPTIONAL => {
                    // Allow if privileged
                    if (capabilities.hasCapability(.CAP_SYS_MODULE)) {
                        audit.logSecurityViolation("Unsigned module loaded (CAP_SYS_MODULE)");
                        return;
                    }
                    return error.SignatureRequired;
                },
                .REQUIRED, .STRICT => error.SignatureRequired,
            };
        }

        // Signature provided - verify it
        const sig = signature.?;

        // Find matching key
        const public_key = self.keyring.findKey(&sig.key_id) orelse {
            _ = self.failed_count.fetchAdd(1, .Release);
            audit.logSecurityViolation("Module signature: key not found");
            return error.KeyNotFound;
        };

        // Verify signature
        sig.verify(module_data, public_key) catch |err| {
            _ = self.failed_count.fetchAdd(1, .Release);

            var buf: [128]u8 = undefined;
            const msg = Basics.fmt.bufPrint(&buf, "Module signature verification failed: {s}", .{@errorName(err)}) catch "sig_verify_fail";
            audit.logSecurityViolation(msg);

            return err;
        };

        _ = self.verified_count.fetchAdd(1, .Release);
        audit.logSecurityViolation("Module signature verified");
    }

    /// Check if module loading is allowed (integrates with lockdown)
    pub fn checkModuleLoad(self: *ModuleVerifier, signature: ?*const ModuleSignature) !void {
        // Check lockdown mode
        const is_signed = signature != null;
        try lockdown.checkModuleLoad(is_signed);

        // Then check signature policy
        // Note: We need module_data for actual verification, but this is a policy check
        // In production, would be called with actual module data
        if (!is_signed and self.getPolicy() != .NONE) {
            if (!capabilities.hasCapability(.CAP_SYS_MODULE)) {
                return error.SignatureRequired;
            }
        }
    }

    /// Get verification statistics
    pub fn getStats(self: *const ModuleVerifier) VerificationStats {
        return .{
            .verified = self.verified_count.load(.Acquire),
            .failed = self.failed_count.load(.Acquire),
            .unsigned = self.unsigned_count.load(.Acquire),
        };
    }
};

pub const VerificationStats = struct {
    verified: u64,
    failed: u64,
    unsigned: u64,
};

// ============================================================================
// Module Trust Store
// ============================================================================

pub const TrustedModule = struct {
    /// Module name
    name: [64]u8,
    /// Name length
    name_len: usize,
    /// Module hash (for integrity)
    hash: [32]u8,
    /// Key ID that signed it
    key_id: [32]u8,

    pub fn init(name: []const u8) !TrustedModule {
        if (name.len > 63) {
            return error.NameTooLong;
        }

        var module: TrustedModule = undefined;
        module.name = [_]u8{0} ** 64;
        module.name_len = name.len;
        module.hash = [_]u8{0} ** 32;
        module.key_id = [_]u8{0} ** 32;

        @memcpy(module.name[0..name.len], name);

        return module;
    }
};

pub const TrustStore = struct {
    /// Trusted modules
    modules: [256]?TrustedModule,
    /// Module count
    module_count: atomic.AtomicU32,
    /// Lock
    lock: sync.RwLock,

    pub fn init() TrustStore {
        return .{
            .modules = [_]?TrustedModule{null} ** 256,
            .module_count = atomic.AtomicU32.init(0),
            .lock = sync.RwLock.init(),
        };
    }

    /// Add trusted module
    pub fn addModule(self: *TrustStore, module: TrustedModule) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const count = self.module_count.load(.Acquire);
        if (count >= 256) {
            return error.TrustStoreFull;
        }

        self.modules[count] = module;
        _ = self.module_count.fetchAdd(1, .Release);
    }

    /// Check if module is trusted
    pub fn isTrusted(self: *TrustStore, name: []const u8, hash: []const u8) bool {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.modules) |maybe_module| {
            if (maybe_module) |module| {
                if (Basics.mem.eql(u8, module.name[0..module.name_len], name) and
                    Basics.mem.eql(u8, &module.hash, hash))
                {
                    return true;
                }
            }
        }

        return false;
    }
};

// ============================================================================
// Global Module Signing
// ============================================================================

var global_verifier: ModuleVerifier = undefined;
var global_trust_store: TrustStore = undefined;
var module_signing_initialized = false;

pub fn init(policy: VerificationPolicy) void {
    if (module_signing_initialized) return;

    global_verifier = ModuleVerifier.init(policy);
    global_trust_store = TrustStore.init();

    module_signing_initialized = true;

    audit.logSecurityViolation("Module signing initialized");
}

pub fn getVerifier() *ModuleVerifier {
    if (!module_signing_initialized) init(.OPTIONAL);
    return &global_verifier;
}

pub fn getTrustStore() *TrustStore {
    if (!module_signing_initialized) init(.OPTIONAL);
    return &global_trust_store;
}

// ============================================================================
// Tests
// ============================================================================

test "module signature" {
    var sig = ModuleSignature.init(.RSA_2048_SHA256);

    const module_data = "fake module data";
    hashModule(module_data, sig.module_hash[0..sig.hash_len]);

    // Set fake signature
    sig.signature[0] = 0x42;
    sig.signature_len = 1;

    var key = try PublicKey.init(.RSA_2048_SHA256, "test_key");
    key.key_data[0] = 0x42;
    key.key_len = 1;
    key.generateKeyId();

    @memcpy(&sig.key_id, &key.key_id);

    try sig.verify(module_data, &key);
}

test "public key ring" {
    var keyring = PublicKeyRing.init();

    var key = try PublicKey.init(.RSA_2048_SHA256, "signing_key");
    key.key_data[0] = 1;
    key.key_len = 1;
    key.generateKeyId();

    try keyring.addKey(key);

    const found = keyring.findKey(&key.key_id);
    try Basics.testing.expect(found != null);
}

test "module verifier policy" {
    var verifier = ModuleVerifier.init(.OPTIONAL);

    try Basics.testing.expect(verifier.getPolicy() == .OPTIONAL);

    try verifier.setPolicy(.REQUIRED);
    try Basics.testing.expect(verifier.getPolicy() == .REQUIRED);
}

test "module verifier unsigned module" {
    var verifier = ModuleVerifier.init(.NONE);

    // Should succeed with NONE policy
    try verifier.verifyModule("module_data", null);

    const stats = verifier.getStats();
    try Basics.testing.expect(stats.unsigned == 1);
}

test "trust store" {
    var store = TrustStore.init();

    var module = try TrustedModule.init("test_module");
    module.hash[0] = 0x42;

    try store.addModule(module);

    var check_hash = [_]u8{0} ** 32;
    check_hash[0] = 0x42;

    try Basics.testing.expect(store.isTrusted("test_module", &check_hash));
    try Basics.testing.expect(!store.isTrusted("other_module", &check_hash));
}
