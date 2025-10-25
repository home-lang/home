// Home OS Kernel - TPM (Trusted Platform Module) Support
// Hardware-backed secure storage and attestation

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const random = @import("random.zig");
const capabilities = @import("capabilities.zig");

// ============================================================================
// TPM Constants
// ============================================================================

pub const TPM_VERSION = enum(u8) {
    TPM_1_2 = 1,
    TPM_2_0 = 2,
};

pub const PCR_COUNT = 24; // TPM 2.0 has 24 PCRs

// ============================================================================
// Platform Configuration Registers (PCRs)
// ============================================================================

pub const PcrBank = enum(u8) {
    SHA1 = 0,
    SHA256 = 1,
    SHA384 = 2,
    SHA512 = 3,
};

pub const Pcr = struct {
    /// PCR index (0-23)
    index: u8,
    /// Current value (hash)
    value: [64]u8, // Max 512 bits
    /// Value length
    value_len: usize,
    /// Extend count
    extend_count: atomic.AtomicU64,
    /// Lock for extensions
    lock: sync.Spinlock,

    pub fn init(index: u8, hash_size: usize) Pcr {
        return .{
            .index = index,
            .value = [_]u8{0} ** 64,
            .value_len = hash_size,
            .extend_count = atomic.AtomicU64.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    /// Extend PCR (hash current value || new value)
    pub fn extend(self: *Pcr, data: []const u8) void {
        self.lock.acquire();
        defer self.lock.release();

        // Simple hash extension (production would use real SHA-256)
        var new_value: [64]u8 = undefined;

        // Mix current value with data
        for (&new_value, 0..) |*byte, i| {
            const cur_byte = if (i < self.value_len) self.value[i] else 0;
            const data_byte = if (i < data.len) data[i] else 0;
            byte.* = cur_byte ^ data_byte;
        }

        // Simple "hash" mixing
        var state: u64 = 0x9e3779b97f4a7c15;
        for (new_value[0..self.value_len]) |*byte| {
            state ^= byte.*;
            state = state *% 0x9e3779b97f4a7c15;
            state ^= state >> 32;
            byte.* = @truncate(state & 0xFF);
        }

        @memcpy(self.value[0..self.value_len], new_value[0..self.value_len]);

        _ = self.extend_count.fetchAdd(1, .Release);
    }

    /// Reset PCR (only allowed for certain indices)
    pub fn reset(self: *Pcr) !void {
        // Only certain PCRs can be reset (16-23 in TPM 2.0)
        if (self.index < 16) {
            return error.PcrNotResettable;
        }

        self.lock.acquire();
        defer self.lock.release();

        for (self.value[0..self.value_len]) |*byte| {
            byte.* = 0;
        }

        audit.logSecurityViolation("PCR reset");
    }

    /// Get current value
    pub fn getValue(self: *const Pcr) []const u8 {
        return self.value[0..self.value_len];
    }
};

// ============================================================================
// TPM Device
// ============================================================================

pub const TpmDevice = struct {
    /// TPM version
    version: TPM_VERSION,
    /// PCRs (24 for TPM 2.0)
    pcrs: [PCR_COUNT]Pcr,
    /// Random number generator available
    has_rng: bool,
    /// Endorsement Key (EK) present
    has_ek: bool,
    /// Storage Root Key (SRK) present
    has_srk: bool,
    /// Device lock
    lock: sync.RwLock,
    /// Initialized flag
    initialized: atomic.AtomicBool,

    pub fn init(version: TPM_VERSION) TpmDevice {
        var device: TpmDevice = undefined;
        device.version = version;
        device.has_rng = false; // Detected during init
        device.has_ek = false;
        device.has_srk = false;
        device.lock = sync.RwLock.init();
        device.initialized = atomic.AtomicBool.init(false);

        // Initialize PCRs
        const hash_size = switch (version) {
            .TPM_1_2 => 20, // SHA-1
            .TPM_2_0 => 32, // SHA-256
        };

        for (&device.pcrs, 0..) |*pcr, i| {
            pcr.* = Pcr.init(@intCast(i), hash_size);
        }

        return device;
    }

    /// Initialize TPM device
    pub fn initDevice(self: *TpmDevice) !void {
        if (!capabilities.hasCapability(.CAP_SYS_ADMIN)) {
            return error.PermissionDenied;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (self.initialized.load(.Acquire)) {
            return error.AlreadyInitialized;
        }

        // Simulate TPM detection (production would communicate with real TPM)
        self.has_rng = true;
        self.has_ek = true;
        self.has_srk = true;

        self.initialized.store(true, .Release);

        audit.logSecurityViolation("TPM initialized");
    }

    /// Read PCR
    pub fn readPcr(self: *TpmDevice, index: u8) ![]const u8 {
        if (!self.initialized.load(.Acquire)) {
            return error.NotInitialized;
        }

        if (index >= PCR_COUNT) {
            return error.InvalidPcrIndex;
        }

        self.lock.acquireRead();
        defer self.lock.releaseRead();

        return self.pcrs[index].getValue();
    }

    /// Extend PCR
    pub fn extendPcr(self: *TpmDevice, index: u8, data: []const u8) !void {
        if (!self.initialized.load(.Acquire)) {
            return error.NotInitialized;
        }

        if (index >= PCR_COUNT) {
            return error.InvalidPcrIndex;
        }

        self.lock.acquireRead();
        defer self.lock.releaseRead();

        self.pcrs[index].extend(data);

        var buf: [128]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "PCR[{}] extended", .{index}) catch "pcr_extend";
        audit.logSecurityViolation(msg);
    }

    /// Get random bytes from TPM RNG
    pub fn getRandomBytes(self: *TpmDevice, output: []u8) !void {
        if (!self.initialized.load(.Acquire)) {
            return error.NotInitialized;
        }

        if (!self.has_rng) {
            return error.NoTpmRng;
        }

        // Simulate TPM RNG (production would use real TPM)
        for (output) |*byte| {
            byte.* = @truncate(random.getRandom());
        }
    }

    /// Get TPM quote (attestation)
    pub fn getQuote(self: *TpmDevice, nonce: []const u8, pcr_selection: []const u8) !Quote {
        if (!self.initialized.load(.Acquire)) {
            return error.NotInitialized;
        }

        self.lock.acquireRead();
        defer self.lock.releaseRead();

        var quote = Quote.init();

        // Copy nonce
        const nonce_len = Basics.math.min(nonce.len, 32);
        @memcpy(quote.nonce[0..nonce_len], nonce[0..nonce_len]);
        quote.nonce_len = nonce_len;

        // Copy selected PCRs
        for (pcr_selection) |pcr_idx| {
            if (pcr_idx < PCR_COUNT and quote.pcr_count < 24) {
                const pcr_value = self.pcrs[pcr_idx].getValue();
                @memcpy(quote.pcr_values[quote.pcr_count][0..pcr_value.len], pcr_value);
                quote.pcr_indices[quote.pcr_count] = pcr_idx;
                quote.pcr_count += 1;
            }
        }

        // Generate signature (simplified - real TPM would sign with AIK)
        quote.generateSignature();

        return quote;
    }
};

// ============================================================================
// TPM Quote (Attestation)
// ============================================================================

pub const Quote = struct {
    /// Nonce provided by challenger
    nonce: [32]u8,
    /// Nonce length
    nonce_len: usize,
    /// PCR indices included
    pcr_indices: [24]u8,
    /// PCR values
    pcr_values: [24][64]u8,
    /// PCR count
    pcr_count: usize,
    /// Signature over nonce + PCRs
    signature: [256]u8,
    /// Signature length
    signature_len: usize,
    /// Timestamp
    timestamp: u64,

    pub fn init() Quote {
        return .{
            .nonce = [_]u8{0} ** 32,
            .nonce_len = 0,
            .pcr_indices = [_]u8{0} ** 24,
            .pcr_values = [_][64]u8{[_]u8{0} ** 64} ** 24,
            .pcr_count = 0,
            .signature = [_]u8{0} ** 256,
            .signature_len = 0,
            .timestamp = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp())))),
        };
    }

    fn generateSignature(self: *Quote) void {
        // Simplified signature generation (real would use TPM AIK)
        var state: u64 = 0x123456789abcdef0;

        // Mix nonce
        for (self.nonce[0..self.nonce_len]) |byte| {
            state ^= byte;
            state = state *% 0x9e3779b97f4a7c15;
        }

        // Mix PCR values
        var i: usize = 0;
        while (i < self.pcr_count) : (i += 1) {
            for (self.pcr_values[i]) |byte| {
                state ^= byte;
                state = state *% 0x9e3779b97f4a7c15;
            }
        }

        // Generate signature bytes
        self.signature_len = 32;
        for (self.signature[0..self.signature_len]) |*byte| {
            state = state *% 0x9e3779b97f4a7c15;
            state ^= state >> 32;
            byte.* = @truncate(state & 0xFF);
        }
    }

    /// Verify quote signature
    pub fn verify(self: *const Quote) bool {
        // In production, would verify with TPM public key
        // For now, just check signature is non-zero
        var has_sig = false;
        for (self.signature[0..self.signature_len]) |byte| {
            if (byte != 0) {
                has_sig = true;
                break;
            }
        }
        return has_sig;
    }
};

// ============================================================================
// Sealed Storage
// ============================================================================

pub const SealedData = struct {
    /// PCR selection (which PCRs must match to unseal)
    pcr_selection: [24]u8,
    /// PCR count
    pcr_count: usize,
    /// Expected PCR values
    expected_pcr_values: [24][64]u8,
    /// Encrypted data
    encrypted_data: [1024]u8,
    /// Data length
    data_len: usize,

    pub fn init() SealedData {
        return .{
            .pcr_selection = [_]u8{0} ** 24,
            .pcr_count = 0,
            .expected_pcr_values = [_][64]u8{[_]u8{0} ** 64} ** 24,
            .encrypted_data = [_]u8{0} ** 1024,
            .data_len = 0,
        };
    }
};

pub const TpmSealing = struct {
    device: *TpmDevice,

    pub fn init(device: *TpmDevice) TpmSealing {
        return .{ .device = device };
    }

    /// Seal data to PCRs
    pub fn seal(self: *TpmSealing, data: []const u8, pcr_indices: []const u8) !SealedData {
        if (data.len > 1024) {
            return error.DataTooLarge;
        }

        var sealed = SealedData.init();

        // Record current PCR values
        for (pcr_indices) |pcr_idx| {
            if (pcr_idx < PCR_COUNT and sealed.pcr_count < 24) {
                const pcr_value = try self.device.readPcr(pcr_idx);
                @memcpy(sealed.expected_pcr_values[sealed.pcr_count][0..pcr_value.len], pcr_value);
                sealed.pcr_selection[sealed.pcr_count] = pcr_idx;
                sealed.pcr_count += 1;
            }
        }

        // "Encrypt" data (simplified - real would use TPM storage key)
        sealed.data_len = data.len;
        @memcpy(sealed.encrypted_data[0..data.len], data);

        // XOR with first PCR value for simple "encryption"
        if (sealed.pcr_count > 0) {
            for (sealed.encrypted_data[0..sealed.data_len], 0..) |*byte, i| {
                byte.* ^= sealed.expected_pcr_values[0][i % 32];
            }
        }

        return sealed;
    }

    /// Unseal data (only if PCRs match)
    pub fn unseal(self: *TpmSealing, sealed: *const SealedData, output: []u8) !void {
        if (output.len < sealed.data_len) {
            return error.OutputTooSmall;
        }

        // Verify PCRs match
        var i: usize = 0;
        while (i < sealed.pcr_count) : (i += 1) {
            const pcr_idx = sealed.pcr_selection[i];
            const current_pcr = try self.device.readPcr(pcr_idx);

            if (!Basics.mem.eql(u8, current_pcr, sealed.expected_pcr_values[i][0..current_pcr.len])) {
                audit.logSecurityViolation("TPM unseal failed - PCR mismatch");
                return error.PcrMismatch;
            }
        }

        // PCRs match - decrypt data
        @memcpy(output[0..sealed.data_len], sealed.encrypted_data[0..sealed.data_len]);

        // XOR with first PCR to decrypt
        if (sealed.pcr_count > 0) {
            const pcr_value = try self.device.readPcr(sealed.pcr_selection[0]);
            for (output[0..sealed.data_len], 0..) |*byte, j| {
                byte.* ^= pcr_value[j % pcr_value.len];
            }
        }

        audit.logSecurityViolation("TPM unseal successful");
    }
};

// ============================================================================
// Global TPM
// ============================================================================

var global_tpm: TpmDevice = undefined;
var tpm_initialized = false;

pub fn init() !void {
    if (tpm_initialized) return;

    global_tpm = TpmDevice.init(.TPM_2_0);
    try global_tpm.initDevice();

    tpm_initialized = true;
}

pub fn getTpm() *TpmDevice {
    return &global_tpm;
}

// ============================================================================
// Tests
// ============================================================================

test "pcr extend" {
    var pcr = Pcr.init(0, 32);

    pcr.extend("test data");

    try Basics.testing.expect(pcr.extend_count.load(.Acquire) == 1);

    // Value should be non-zero after extend
    var has_nonzero = false;
    for (pcr.getValue()) |byte| {
        if (byte != 0) {
            has_nonzero = true;
            break;
        }
    }

    try Basics.testing.expect(has_nonzero);
}

test "tpm device initialization" {
    var tpm = TpmDevice.init(.TPM_2_0);

    try tpm.initDevice();

    try Basics.testing.expect(tpm.initialized.load(.Acquire));
    try Basics.testing.expect(tpm.has_rng);
}

test "tpm extend pcr" {
    var tpm = TpmDevice.init(.TPM_2_0);
    try tpm.initDevice();

    try tpm.extendPcr(0, "test_measurement");

    const pcr_value = try tpm.readPcr(0);
    try Basics.testing.expect(pcr_value.len == 32);
}

test "tpm random bytes" {
    var tpm = TpmDevice.init(.TPM_2_0);
    try tpm.initDevice();

    var random_bytes: [32]u8 = undefined;
    try tpm.getRandomBytes(&random_bytes);

    // Should have some non-zero bytes
    var has_nonzero = false;
    for (random_bytes) |byte| {
        if (byte != 0) {
            has_nonzero = true;
            break;
        }
    }

    try Basics.testing.expect(has_nonzero);
}

test "tpm quote" {
    var tpm = TpmDevice.init(.TPM_2_0);
    try tpm.initDevice();

    try tpm.extendPcr(0, "measurement1");
    try tpm.extendPcr(1, "measurement2");

    const nonce = "challenge_nonce";
    const pcr_selection = [_]u8{ 0, 1 };

    const quote = try tpm.getQuote(nonce, &pcr_selection);

    try Basics.testing.expect(quote.pcr_count == 2);
    try Basics.testing.expect(quote.verify());
}

test "tpm sealing" {
    var tpm = TpmDevice.init(.TPM_2_0);
    try tpm.initDevice();

    try tpm.extendPcr(7, "boot_measurement");

    var sealing = TpmSealing.init(&tpm);

    const secret_data = "secret_key_12345";
    const pcr_indices = [_]u8{7};

    const sealed = try sealing.seal(secret_data, &pcr_indices);

    var unsealed: [32]u8 = undefined;
    try sealing.unseal(&sealed, &unsealed);

    try Basics.testing.expect(Basics.mem.eql(u8, unsealed[0..secret_data.len], secret_data));
}

test "tpm unseal fails with changed pcr" {
    var tpm = TpmDevice.init(.TPM_2_0);
    try tpm.initDevice();

    try tpm.extendPcr(7, "boot_measurement");

    var sealing = TpmSealing.init(&tpm);

    const secret_data = "secret";
    const pcr_indices = [_]u8{7};

    const sealed = try sealing.seal(secret_data, &pcr_indices);

    // Change PCR after sealing
    try tpm.extendPcr(7, "tampered");

    var unsealed: [32]u8 = undefined;
    const result = sealing.unseal(&sealed, &unsealed);

    try Basics.testing.expect(result == error.PcrMismatch);
}
