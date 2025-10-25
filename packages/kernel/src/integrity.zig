// Home OS Kernel - File Integrity Monitoring (FIM)
// Verifies integrity of critical files and kernel modules

const Basics = @import("basics");
const sync = @import("sync.zig");
const audit = @import("audit.zig");

// ============================================================================
// Hash Algorithm (Simple SHA-256-like)
// ============================================================================

const HASH_SIZE = 32; // 256 bits

pub const Hash = struct {
    bytes: [HASH_SIZE]u8,

    pub fn init() Hash {
        return .{ .bytes = [_]u8{0} ** HASH_SIZE };
    }

    pub fn equal(self: *const Hash, other: *const Hash) bool {
        for (self.bytes, other.bytes) |a, b| {
            if (a != b) return false;
        }
        return true;
    }

    /// Convert hash to hex string
    pub fn toHex(self: *const Hash, buffer: []u8) ![]const u8 {
        if (buffer.len < HASH_SIZE * 2) return error.BufferTooSmall;

        const hex_chars = "0123456789abcdef";
        for (self.bytes, 0..) |byte, i| {
            buffer[i * 2] = hex_chars[byte >> 4];
            buffer[i * 2 + 1] = hex_chars[byte & 0xF];
        }

        return buffer[0 .. HASH_SIZE * 2];
    }
};

/// Simplified hash function (not cryptographically secure - use SHA-256 in production)
pub fn hashData(data: []const u8) Hash {
    var hash = Hash.init();

    // Simple mixing (NOT secure - replace with SHA-256)
    for (data, 0..) |byte, i| {
        hash.bytes[i % HASH_SIZE] ^= byte;
        hash.bytes[i % HASH_SIZE] = rotateLeft(hash.bytes[i % HASH_SIZE], 5);

        // Mix with adjacent bytes
        hash.bytes[(i + 1) % HASH_SIZE] ^= byte;
        hash.bytes[(i + 2) % HASH_SIZE] ^= rotateLeft(byte, 3);
    }

    // Final mixing pass
    var i: usize = 0;
    while (i < HASH_SIZE) : (i += 1) {
        hash.bytes[i] ^= hash.bytes[(i + 1) % HASH_SIZE];
        hash.bytes[i] = rotateLeft(hash.bytes[i], 7);
    }

    return hash;
}

fn rotateLeft(byte: u8, count: u3) u8 {
    return (byte << count) | (byte >> (8 - count));
}

// ============================================================================
// File Integrity Record
// ============================================================================

pub const IntegrityRecord = struct {
    /// File path
    path: [256]u8,
    path_len: usize,
    /// Expected hash
    expected_hash: Hash,
    /// Last verification time
    last_check: u64,
    /// Check failures count
    failures: u32,

    pub fn init(path: []const u8, hash: Hash) !IntegrityRecord {
        if (path.len > 255) return error.PathTooLong;

        var record: IntegrityRecord = undefined;
        @memcpy(record.path[0..path.len], path);
        record.path_len = path.len;
        record.expected_hash = hash;
        record.last_check = 0;
        record.failures = 0;

        return record;
    }

    pub fn getPath(self: *const IntegrityRecord) []const u8 {
        return self.path[0..self.path_len];
    }
};

// ============================================================================
// Integrity Database
// ============================================================================

const MAX_MONITORED_FILES = 256;

pub const IntegrityDB = struct {
    records: [MAX_MONITORED_FILES]?IntegrityRecord,
    count: usize,
    lock: sync.RwLock,

    pub fn init() IntegrityDB {
        return .{
            .records = [_]?IntegrityRecord{null} ** MAX_MONITORED_FILES,
            .count = 0,
            .lock = sync.RwLock.init(),
        };
    }

    /// Add file to integrity monitoring
    pub fn addFile(self: *IntegrityDB, path: []const u8, hash: Hash) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (self.count >= MAX_MONITORED_FILES) {
            return error.DatabaseFull;
        }

        const record = try IntegrityRecord.init(path, hash);

        // Find empty slot
        for (&self.records) |*slot| {
            if (slot.* == null) {
                slot.* = record;
                self.count += 1;
                return;
            }
        }

        return error.DatabaseFull;
    }

    /// Verify file integrity
    pub fn verifyFile(self: *IntegrityDB, path: []const u8, data: []const u8) !bool {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        // Find record
        for (&self.records) |*slot| {
            if (slot.*) |*record| {
                if (Basics.mem.eql(u8, record.getPath(), path)) {
                    // Hash the current data
                    const current_hash = hashData(data);

                    // Compare with expected hash
                    if (!current_hash.equal(&record.expected_hash)) {
                        // Integrity violation!
                        return false;
                    }

                    return true;
                }
            }
        }

        // File not monitored
        return error.FileNotMonitored;
    }

    /// Check if file is monitored
    pub fn isMonitored(self: *IntegrityDB, path: []const u8) bool {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.records) |slot| {
            if (slot) |record| {
                if (Basics.mem.eql(u8, record.getPath(), path)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Update expected hash for a file
    pub fn updateHash(self: *IntegrityDB, path: []const u8, new_hash: Hash) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        for (&self.records) |*slot| {
            if (slot.*) |*record| {
                if (Basics.mem.eql(u8, record.getPath(), path)) {
                    record.expected_hash = new_hash;
                    return;
                }
            }
        }

        return error.FileNotMonitored;
    }
};

// Global integrity database
var global_integrity_db: IntegrityDB = undefined;
var integrity_initialized = false;

/// Initialize integrity monitoring
pub fn init() void {
    if (integrity_initialized) return;

    global_integrity_db = IntegrityDB.init();
    integrity_initialized = true;

    // Add critical system files to monitoring
    // In production, these would be loaded from a config file
    initializeCriticalFiles() catch {};
}

/// Initialize monitoring for critical system files
fn initializeCriticalFiles() !void {
    // Monitor kernel binary
    const kernel_hash = hashData("kernel_binary_placeholder");
    try global_integrity_db.addFile("/boot/kernel", kernel_hash);

    // Monitor init process
    const init_hash = hashData("init_binary_placeholder");
    try global_integrity_db.addFile("/sbin/init", init_hash);

    // Monitor critical system libraries
    const libc_hash = hashData("libc_placeholder");
    try global_integrity_db.addFile("/lib/libc.so", libc_hash);
}

/// Verify file integrity before execution
pub fn verifyBeforeExec(path: []const u8, data: []const u8) !void {
    if (!integrity_initialized) return;

    // Check if file is monitored
    if (!global_integrity_db.isMonitored(path)) {
        // Not a critical file, allow execution
        return;
    }

    // Verify integrity
    const verified = global_integrity_db.verifyFile(path, data) catch |err| {
        if (err == error.FileNotMonitored) return;
        return err;
    };

    if (!verified) {
        // Integrity violation!
        audit.logSecurityViolation("File integrity violation detected");

        var buf: [512]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "Integrity check failed for: {s}", .{path}) catch "integrity_violation";
        audit.logSecurityViolation(msg);

        return error.IntegrityViolation;
    }
}

/// Add file to integrity monitoring
pub fn addMonitoredFile(path: []const u8, data: []const u8) !void {
    if (!integrity_initialized) init();

    const hash = hashData(data);
    try global_integrity_db.addFile(path, hash);
}

// ============================================================================
// Kernel Module Verification
// ============================================================================

pub const ModuleSignature = struct {
    /// Module hash
    hash: Hash,
    /// Signature (placeholder - use real crypto in production)
    signature: [256]u8,
    signature_len: usize,

    pub fn verify(self: *const ModuleSignature, module_data: []const u8) bool {
        const computed_hash = hashData(module_data);
        return computed_hash.equal(&self.hash);
    }
};

/// Verify kernel module before loading
pub fn verifyKernelModule(module_data: []const u8, signature: ?*const ModuleSignature) !void {
    // Check if signature is required
    // In production, this would be a compile-time or boot-time setting
    const require_signatures = false;

    if (require_signatures) {
        const sig = signature orelse return error.MissingSignature;

        if (!sig.verify(module_data)) {
            audit.logSecurityViolation("Kernel module signature verification failed");
            return error.InvalidSignature;
        }
    } else {
        // Even without signature requirement, verify integrity if we have one
        if (signature) |sig| {
            if (!sig.verify(module_data)) {
                audit.logSecurityViolation("Kernel module integrity check failed");
                return error.IntegrityCheckFailed;
            }
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "hash data" {
    const data1 = "hello world";
    const data2 = "hello world";
    const data3 = "goodbye world";

    const hash1 = hashData(data1);
    const hash2 = hashData(data2);
    const hash3 = hashData(data3);

    try Basics.testing.expect(hash1.equal(&hash2));
    try Basics.testing.expect(!hash1.equal(&hash3));
}

test "integrity database add file" {
    var db = IntegrityDB.init();

    const hash = hashData("test data");
    try db.addFile("/test/file", hash);

    try Basics.testing.expect(db.isMonitored("/test/file"));
    try Basics.testing.expect(!db.isMonitored("/other/file"));
}

test "integrity database verify file" {
    var db = IntegrityDB.init();

    const data = "correct data";
    const hash = hashData(data);
    try db.addFile("/test/file", hash);

    // Verify with correct data
    const result1 = try db.verifyFile("/test/file", data);
    try Basics.testing.expect(result1);

    // Verify with wrong data
    const wrong_data = "wrong data";
    const result2 = try db.verifyFile("/test/file", wrong_data);
    try Basics.testing.expect(!result2);
}

test "hash to hex" {
    const data = "test";
    const hash = hashData(data);

    var buffer: [64]u8 = undefined;
    const hex = try hash.toHex(&buffer);

    try Basics.testing.expect(hex.len == 64); // 32 bytes = 64 hex chars
}

test "module signature verification" {
    const module_data = "module code here";
    const hash = hashData(module_data);

    var sig = ModuleSignature{
        .hash = hash,
        .signature = undefined,
        .signature_len = 0,
    };

    try Basics.testing.expect(sig.verify(module_data));

    const wrong_data = "wrong module code";
    try Basics.testing.expect(!sig.verify(wrong_data));
}
