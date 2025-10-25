// Home OS Kernel - Encrypted Filesystem (dm-crypt style)
// Block-level encryption for secure data storage

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const random = @import("random.zig");
const capabilities = @import("capabilities.zig");

// ============================================================================
// Encryption Algorithms
// ============================================================================

pub const CipherType = enum(u8) {
    /// AES-256 (placeholder - would use real AES in production)
    AES_256_XTS = 0,
    /// AES-128
    AES_128_XTS = 1,
    /// ChaCha20
    CHACHA20 = 2,
};

pub const HashType = enum(u8) {
    /// SHA-256
    SHA256 = 0,
    /// SHA-512
    SHA512 = 1,
};

// ============================================================================
// Encryption Key
// ============================================================================

pub const EncryptionKey = struct {
    /// Key material (up to 64 bytes for 512-bit keys)
    key_material: [64]u8,
    /// Key size in bytes
    key_size: usize,
    /// Cipher type
    cipher: CipherType,
    /// Key generation timestamp
    generation_time: u64,
    /// Use count (for key rotation)
    use_count: atomic.AtomicU64,

    pub fn init(cipher: CipherType) EncryptionKey {
        const key_size: usize = switch (cipher) {
            .AES_256_XTS => 64, // 2x256 bits for XTS mode
            .AES_128_XTS => 32, // 2x128 bits for XTS mode
            .CHACHA20 => 32, // 256 bits
        };

        var key: EncryptionKey = undefined;
        key.key_material = [_]u8{0} ** 64;
        key.key_size = key_size;
        key.cipher = cipher;
        key.generation_time = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp()))));
        key.use_count = atomic.AtomicU64.init(0);

        return key;
    }

    /// Generate random key
    pub fn generate(self: *EncryptionKey) void {
        for (self.key_material[0..self.key_size]) |*byte| {
            byte.* = @truncate(random.getRandom());
        }
    }

    /// Derive key from password using PBKDF2-like scheme
    pub fn deriveFromPassword(self: *EncryptionKey, password: []const u8, salt: []const u8, iterations: u32) void {
        // Simple password derivation (production would use actual PBKDF2)
        var state: u64 = 0x123456789abcdef0;

        var iter: u32 = 0;
        while (iter < iterations) : (iter += 1) {
            // Mix password
            for (password) |byte| {
                state ^= byte;
                state = state *% 0x9e3779b97f4a7c15;
            }

            // Mix salt
            for (salt) |byte| {
                state ^= byte;
                state = state *% 0x9e3779b97f4a7c15;
            }

            // Mix iteration count
            state ^= iter;
            state = state *% 0x9e3779b97f4a7c15;
        }

        // Generate key material
        for (self.key_material[0..self.key_size]) |*byte| {
            state = state *% 0x9e3779b97f4a7c15;
            state ^= state >> 32;
            byte.* = @truncate(state & 0xFF);
        }
    }

    /// Securely erase key
    pub fn erase(self: *EncryptionKey) void {
        // Volatile writes to prevent compiler optimization
        for (&self.key_material) |*byte| {
            @as(*volatile u8, byte).* = 0;
        }
    }

    /// Increment use count
    pub fn incrementUse(self: *EncryptionKey) u64 {
        return self.use_count.fetchAdd(1, .Release);
    }
};

// ============================================================================
// Block Encryption/Decryption
// ============================================================================

pub const BlockCipher = struct {
    key: EncryptionKey,
    block_size: usize,

    const BLOCK_SIZE = 4096; // Standard 4KB blocks

    pub fn init(cipher: CipherType) BlockCipher {
        return .{
            .key = EncryptionKey.init(cipher),
            .block_size = BLOCK_SIZE,
        };
    }

    /// Encrypt a block
    pub fn encryptBlock(self: *BlockCipher, plaintext: []const u8, ciphertext: []u8, block_num: u64) !void {
        if (plaintext.len != self.block_size or ciphertext.len != self.block_size) {
            return error.InvalidBlockSize;
        }

        _ = self.key.incrementUse();

        // Simple XOR cipher (placeholder for real AES-XTS in production)
        // Real implementation would use proper AES-XTS with IV derived from block_num
        var key_stream = self.generateKeyStream(block_num);

        for (plaintext, ciphertext, 0..) |plain_byte, *cipher_byte, i| {
            cipher_byte.* = plain_byte ^ key_stream[i % self.key.key_size];
        }
    }

    /// Decrypt a block
    pub fn decryptBlock(self: *BlockCipher, ciphertext: []const u8, plaintext: []u8, block_num: u64) !void {
        if (ciphertext.len != self.block_size or plaintext.len != self.block_size) {
            return error.InvalidBlockSize;
        }

        _ = self.key.incrementUse();

        // XOR is symmetric, same operation for decrypt
        var key_stream = self.generateKeyStream(block_num);

        for (ciphertext, plaintext, 0..) |cipher_byte, *plain_byte, i| {
            plain_byte.* = cipher_byte ^ key_stream[i % self.key.key_size];
        }
    }

    fn generateKeyStream(self: *BlockCipher, block_num: u64) [64]u8 {
        var stream: [64]u8 = undefined;

        // Mix key with block number to generate unique keystream per block
        var state: u64 = block_num;

        for (&stream, 0..) |*byte, i| {
            state ^= self.key.key_material[i % self.key.key_size];
            state = state *% 0x9e3779b97f4a7c15;
            state ^= state >> 32;
            byte.* = @truncate(state & 0xFF);
        }

        return stream;
    }
};

// ============================================================================
// Encrypted Block Device
// ============================================================================

pub const EncryptedDevice = struct {
    /// Device ID
    device_id: u64,
    /// Block cipher
    cipher: BlockCipher,
    /// Total blocks
    total_blocks: u64,
    /// Read operations
    read_count: atomic.AtomicU64,
    /// Write operations
    write_count: atomic.AtomicU64,
    /// Device lock
    lock: sync.RwLock,
    /// Opened flag
    opened: atomic.AtomicBool,

    pub fn init(device_id: u64, total_blocks: u64, cipher_type: CipherType) EncryptedDevice {
        return .{
            .device_id = device_id,
            .cipher = BlockCipher.init(cipher_type),
            .total_blocks = total_blocks,
            .read_count = atomic.AtomicU64.init(0),
            .write_count = atomic.AtomicU64.init(0),
            .lock = sync.RwLock.init(),
            .opened = atomic.AtomicBool.init(false),
        };
    }

    /// Open device with key
    pub fn open(self: *EncryptedDevice, key: EncryptionKey) !void {
        if (!capabilities.hasCapability(.CAP_SYS_ADMIN)) {
            return error.PermissionDenied;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (self.opened.load(.Acquire)) {
            return error.AlreadyOpened;
        }

        self.cipher.key = key;
        self.opened.store(true, .Release);

        audit.logSecurityViolation("Encrypted device opened");
    }

    /// Close device and erase keys
    pub fn close(self: *EncryptedDevice) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        self.cipher.key.erase();
        self.opened.store(false, .Release);

        audit.logSecurityViolation("Encrypted device closed");
    }

    /// Read encrypted block
    pub fn readBlock(self: *EncryptedDevice, block_num: u64, ciphertext: []const u8, plaintext: []u8) !void {
        if (!self.opened.load(.Acquire)) {
            return error.DeviceClosed;
        }

        if (block_num >= self.total_blocks) {
            return error.BlockOutOfRange;
        }

        self.lock.acquireRead();
        defer self.lock.releaseRead();

        try self.cipher.decryptBlock(ciphertext, plaintext, block_num);
        _ = self.read_count.fetchAdd(1, .Release);
    }

    /// Write encrypted block
    pub fn writeBlock(self: *EncryptedDevice, block_num: u64, plaintext: []const u8, ciphertext: []u8) !void {
        if (!self.opened.load(.Acquire)) {
            return error.DeviceClosed;
        }

        if (block_num >= self.total_blocks) {
            return error.BlockOutOfRange;
        }

        self.lock.acquireRead();
        defer self.lock.releaseRead();

        try self.cipher.encryptBlock(plaintext, ciphertext, block_num);
        _ = self.write_count.fetchAdd(1, .Release);
    }

    /// Get device statistics
    pub fn getStats(self: *const EncryptedDevice) DeviceStats {
        return .{
            .read_count = self.read_count.load(.Acquire),
            .write_count = self.write_count.load(.Acquire),
            .total_blocks = self.total_blocks,
            .key_uses = self.cipher.key.use_count.load(.Acquire),
        };
    }
};

pub const DeviceStats = struct {
    read_count: u64,
    write_count: u64,
    total_blocks: u64,
    key_uses: u64,
};

// ============================================================================
// Key Derivation and Storage
// ============================================================================

pub const KeySlot = struct {
    /// Slot number
    slot: u8,
    /// Active flag
    active: bool,
    /// Salt for password derivation
    salt: [32]u8,
    /// Iterations for PBKDF2
    iterations: u32,
    /// Encrypted master key
    encrypted_master_key: [64]u8,
    /// Hash type
    hash: HashType,

    pub fn init(slot: u8) KeySlot {
        return .{
            .slot = slot,
            .active = false,
            .salt = [_]u8{0} ** 32,
            .iterations = 100000, // Default PBKDF2 iterations
            .encrypted_master_key = [_]u8{0} ** 64,
            .hash = .SHA256,
        };
    }

    /// Setup key slot with password
    pub fn setup(self: *KeySlot, password: []const u8, master_key: *const EncryptionKey) !void {
        // Generate random salt
        for (&self.salt) |*byte| {
            byte.* = @truncate(random.getRandom());
        }

        // Derive key from password
        var derived_key = EncryptionKey.init(.AES_256_XTS);
        derived_key.deriveFromPassword(password, &self.salt, self.iterations);

        // Encrypt master key with derived key
        var temp_cipher = BlockCipher.init(.AES_256_XTS);
        temp_cipher.key = derived_key;

        // Simple encryption of master key (production would use proper key wrap)
        for (master_key.key_material[0..master_key.key_size], &self.encrypted_master_key, 0..) |mk_byte, *enc_byte, i| {
            enc_byte.* = mk_byte ^ derived_key.key_material[i % derived_key.key_size];
        }

        // Erase derived key
        derived_key.erase();

        self.active = true;
    }

    /// Unlock key slot with password
    pub fn unlock(self: *const KeySlot, password: []const u8, master_key: *EncryptionKey) !void {
        if (!self.active) {
            return error.SlotInactive;
        }

        // Derive key from password
        var derived_key = EncryptionKey.init(.AES_256_XTS);
        derived_key.deriveFromPassword(password, &self.salt, self.iterations);

        // Decrypt master key
        for (self.encrypted_master_key[0..master_key.key_size], &master_key.key_material, 0..) |enc_byte, *mk_byte, i| {
            mk_byte.* = enc_byte ^ derived_key.key_material[i % derived_key.key_size];
        }

        // Erase derived key
        derived_key.erase();
    }

    /// Erase key slot
    pub fn erase(self: *KeySlot) void {
        for (&self.salt) |*byte| {
            @as(*volatile u8, byte).* = 0;
        }
        for (&self.encrypted_master_key) |*byte| {
            @as(*volatile u8, byte).* = 0;
        }
        self.active = false;
    }
};

// ============================================================================
// LUKS-like Header
// ============================================================================

pub const EncryptionHeader = struct {
    /// Magic bytes
    magic: [6]u8,
    /// Version
    version: u16,
    /// Cipher type
    cipher: CipherType,
    /// Hash type
    hash: HashType,
    /// Master key length
    master_key_len: u32,
    /// UUID
    uuid: [16]u8,
    /// Key slots (8 slots like LUKS)
    key_slots: [8]KeySlot,
    /// Lock for header modifications
    lock: sync.RwLock,

    const MAGIC: [6]u8 = [_]u8{ 'H', 'O', 'M', 'E', 'C', 'R' };

    pub fn init(cipher: CipherType) EncryptionHeader {
        var header: EncryptionHeader = undefined;
        header.magic = MAGIC;
        header.version = 1;
        header.cipher = cipher;
        header.hash = .SHA256;
        header.master_key_len = 64;

        // Generate random UUID
        for (&header.uuid) |*byte| {
            byte.* = @truncate(random.getRandom());
        }

        // Initialize key slots
        for (&header.key_slots, 0..) |*slot, i| {
            slot.* = KeySlot.init(@intCast(i));
        }

        header.lock = sync.RwLock.init();

        return header;
    }

    /// Verify header magic
    pub fn verify(self: *const EncryptionHeader) bool {
        return Basics.mem.eql(u8, &self.magic, &MAGIC);
    }

    /// Add password to key slot
    pub fn addKey(self: *EncryptionHeader, slot_num: u8, password: []const u8, master_key: *const EncryptionKey) !void {
        if (slot_num >= 8) {
            return error.InvalidSlot;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        try self.key_slots[slot_num].setup(password, master_key);

        audit.logSecurityViolation("Encryption key slot added");
    }

    /// Remove key slot
    pub fn removeKey(self: *EncryptionHeader, slot_num: u8) !void {
        if (slot_num >= 8) {
            return error.InvalidSlot;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        self.key_slots[slot_num].erase();

        audit.logSecurityViolation("Encryption key slot removed");
    }

    /// Try to unlock with password
    pub fn tryUnlock(self: *const EncryptionHeader, password: []const u8, master_key: *EncryptionKey) !void {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        // Try each active key slot
        for (self.key_slots) |*slot| {
            if (slot.active) {
                slot.unlock(password, master_key) catch continue;
                return; // Success
            }
        }

        return error.InvalidPassword;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "encryption key generation" {
    var key = EncryptionKey.init(.AES_256_XTS);
    key.generate();

    // Key should be non-zero
    var has_nonzero = false;
    for (key.key_material[0..key.key_size]) |byte| {
        if (byte != 0) {
            has_nonzero = true;
            break;
        }
    }

    try Basics.testing.expect(has_nonzero);
}

test "encryption key derivation" {
    var key = EncryptionKey.init(.AES_256_XTS);
    const password = "test_password";
    const salt = "random_salt";

    key.deriveFromPassword(password, salt, 1000);

    // Derived key should be deterministic
    var key2 = EncryptionKey.init(.AES_256_XTS);
    key2.deriveFromPassword(password, salt, 1000);

    try Basics.testing.expect(Basics.mem.eql(u8, key.key_material[0..key.key_size], key2.key_material[0..key2.key_size]));
}

test "block cipher encrypt/decrypt" {
    var cipher = BlockCipher.init(.AES_256_XTS);
    cipher.key.generate();

    const plaintext = [_]u8{0x42} ** 4096;
    var ciphertext: [4096]u8 = undefined;
    var decrypted: [4096]u8 = undefined;

    try cipher.encryptBlock(&plaintext, &ciphertext, 0);
    try cipher.decryptBlock(&ciphertext, &decrypted, 0);

    try Basics.testing.expect(Basics.mem.eql(u8, &plaintext, &decrypted));
}

test "encrypted device operations" {
    var device = EncryptedDevice.init(1, 100, .AES_256_XTS);

    var key = EncryptionKey.init(.AES_256_XTS);
    key.generate();

    try device.open(key);
    try Basics.testing.expect(device.opened.load(.Acquire));

    const plaintext = [_]u8{0x55} ** 4096;
    var ciphertext: [4096]u8 = undefined;
    var decrypted: [4096]u8 = undefined;

    try device.writeBlock(0, &plaintext, &ciphertext);
    try device.readBlock(0, &ciphertext, &decrypted);

    try Basics.testing.expect(Basics.mem.eql(u8, &plaintext, &decrypted));

    device.close();
    try Basics.testing.expect(!device.opened.load(.Acquire));
}

test "key slot setup and unlock" {
    var slot = KeySlot.init(0);
    var master_key = EncryptionKey.init(.AES_256_XTS);
    master_key.generate();

    const password = "secure_password_123";
    try slot.setup(password, &master_key);

    try Basics.testing.expect(slot.active);

    var unlocked_key = EncryptionKey.init(.AES_256_XTS);
    try slot.unlock(password, &unlocked_key);

    try Basics.testing.expect(Basics.mem.eql(u8, master_key.key_material[0..master_key.key_size], unlocked_key.key_material[0..unlocked_key.key_size]));
}

test "encryption header" {
    var header = EncryptionHeader.init(.AES_256_XTS);

    try Basics.testing.expect(header.verify());

    var master_key = EncryptionKey.init(.AES_256_XTS);
    master_key.generate();

    try header.addKey(0, "password1", &master_key);

    var unlocked = EncryptionKey.init(.AES_256_XTS);
    try header.tryUnlock("password1", &unlocked);

    try Basics.testing.expect(Basics.mem.eql(u8, master_key.key_material[0..master_key.key_size], unlocked.key_material[0..unlocked.key_size]));
}

test "wrong password fails" {
    var header = EncryptionHeader.init(.AES_256_XTS);

    var master_key = EncryptionKey.init(.AES_256_XTS);
    master_key.generate();

    try header.addKey(0, "correct_password", &master_key);

    var unlocked = EncryptionKey.init(.AES_256_XTS);
    const result = header.tryUnlock("wrong_password", &unlocked);

    try Basics.testing.expect(result == error.InvalidPassword);
}
