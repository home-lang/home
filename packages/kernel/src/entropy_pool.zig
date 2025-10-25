// Home OS Kernel - Enhanced Entropy Pool
// Advanced random number generation with multiple entropy sources

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const random = @import("random.zig");

// ============================================================================
// Entropy Pool with Multiple Sources
// ============================================================================

pub const EntropySource = enum(u8) {
    /// Hardware RNG (RDRAND/RDSEED)
    HARDWARE_RNG = 0,
    /// Interrupt timing jitter
    INTERRUPT_TIMING = 1,
    /// Disk I/O timing
    DISK_TIMING = 2,
    /// Keyboard/Mouse timing
    INPUT_TIMING = 3,
    /// Network packet timing
    NETWORK_TIMING = 4,
    /// CPU performance counters
    CPU_COUNTERS = 5,
    /// Temperature sensors
    THERMAL_NOISE = 6,
    /// Boot-time entropy
    BOOT_ENTROPY = 7,
};

pub const EntropyPool = struct {
    /// Pool data (4096 bytes = 32768 bits)
    pool: [POOL_SIZE]u8,
    /// Pool position for adding entropy
    pool_pos: atomic.AtomicU32,
    /// Estimated entropy bits available
    entropy_count: atomic.AtomicU32,
    /// Pool lock for mixing
    lock: sync.Spinlock,
    /// Initialized flag
    initialized: atomic.AtomicBool,
    /// Last reseed time
    last_reseed_ns: atomic.AtomicU64,
    /// Entropy source contributions
    source_contributions: [8]atomic.AtomicU64,

    const POOL_SIZE = 4096;
    const MIN_RESEED_INTERVAL_NS = 100_000_000; // 100ms

    pub fn init() EntropyPool {
        var pool: EntropyPool = undefined;
        pool.pool = [_]u8{0} ** POOL_SIZE;
        pool.pool_pos = atomic.AtomicU32.init(0);
        pool.entropy_count = atomic.AtomicU32.init(0);
        pool.lock = sync.Spinlock.init();
        pool.initialized = atomic.AtomicBool.init(false);
        pool.last_reseed_ns = atomic.AtomicU64.init(0);

        for (&pool.source_contributions) |*contrib| {
            contrib.* = atomic.AtomicU64.init(0);
        }

        return pool;
    }

    /// Add entropy from a source
    pub fn addEntropy(self: *EntropyPool, source: EntropySource, data: []const u8, entropy_bits: u32) void {
        self.lock.acquire();
        defer self.lock.release();

        // Mix data into pool
        var pos = self.pool_pos.load(.Acquire);

        for (data) |byte| {
            self.pool[pos % POOL_SIZE] ^= byte;
            pos = (pos + 1) % POOL_SIZE;
        }

        self.pool_pos.store(pos, .Release);

        // Update entropy count (credit at most the data size in bits)
        const credit = Basics.math.min(entropy_bits, @as(u32, @intCast(data.len * 8)));
        const current = self.entropy_count.fetchAdd(credit, .Release);

        // Cap at pool size
        if (current + credit > POOL_SIZE * 8) {
            self.entropy_count.store(POOL_SIZE * 8, .Release);
        }

        // Track source contribution
        const source_idx = @intFromEnum(source);
        _ = self.source_contributions[source_idx].fetchAdd(credit, .Release);

        // Mark as initialized if we have enough entropy
        if (self.entropy_count.load(.Acquire) >= 256) {
            self.initialized.store(true, .Release);
        }
    }

    /// Check if pool is initialized
    pub fn isInitialized(self: *const EntropyPool) bool {
        return self.initialized.load(.Acquire);
    }

    /// Get estimated entropy bits
    pub fn getEntropyBits(self: *const EntropyPool) u32 {
        return self.entropy_count.load(.Acquire);
    }

    /// Extract random bytes (may block if not enough entropy)
    pub fn extractBlocking(self: *EntropyPool, output: []u8) !void {
        // Wait for initialization
        while (!self.isInitialized()) {
            // In production, would sleep/wait
            // For now, just spin
        }

        try self.extractNonBlocking(output);
    }

    /// Extract random bytes (non-blocking, uses available entropy)
    pub fn extractNonBlocking(self: *EntropyPool, output: []u8) !void {
        self.lock.acquire();
        defer self.lock.release();

        // Check if we need to reseed
        const now = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp()))));
        const last_reseed = self.last_reseed_ns.load(.Acquire);

        if (now - last_reseed > MIN_RESEED_INTERVAL_NS) {
            self.reseed();
            self.last_reseed_ns.store(now, .Release);
        }

        // Extract using simple mixing
        // In production, would use HMAC-DRBG or similar
        var hash_state: u64 = 0x9e3779b97f4a7c15; // Arbitrary constant

        for (output, 0..) |*out_byte, i| {
            const pool_idx = (i * 7) % POOL_SIZE;
            hash_state ^= @as(u64, self.pool[pool_idx]);
            hash_state = hash_state *% 0x9e3779b97f4a7c15;
            hash_state ^= hash_state >> 32;
            out_byte.* = @truncate(hash_state & 0xFF);
        }

        // Debit entropy (1 byte = 8 bits)
        const bits_needed = @as(u32, @intCast(output.len * 8));
        const current = self.entropy_count.load(.Acquire);

        if (bits_needed < current) {
            _ = self.entropy_count.fetchSub(bits_needed, .Release);
        } else {
            self.entropy_count.store(0, .Release);
        }
    }

    fn reseed(self: *EntropyPool) void {
        // Add fresh hardware entropy
        if (random.hasHardwareRng()) {
            var hw_entropy: [32]u8 = undefined;
            for (&hw_entropy) |*byte| {
                byte.* = @truncate(random.getRandom());
            }
            self.addEntropyInternal(EntropySource.HARDWARE_RNG, &hw_entropy, 256);
        }

        // Mix pool thoroughly
        self.mixPool();
    }

    fn addEntropyInternal(self: *EntropyPool, source: EntropySource, data: []const u8, bits: u32) void {
        _ = source;
        var pos = self.pool_pos.load(.Acquire);

        for (data) |byte| {
            self.pool[pos % POOL_SIZE] ^= byte;
            pos = (pos + 1) % POOL_SIZE;
        }

        self.pool_pos.store(pos, .Release);
        _ = self.entropy_count.fetchAdd(bits, .Release);
    }

    fn mixPool(self: *EntropyPool) void {
        // Simple pool mixing - in production would use ChaCha20 or similar
        var state: u64 = 0x123456789abcdef0;

        for (&self.pool) |*byte| {
            state = state *% 0x9e3779b97f4a7c15;
            state ^= state >> 32;
            byte.* ^= @truncate(state & 0xFF);
        }
    }

    /// Get entropy source statistics
    pub fn getSourceStats(self: *const EntropyPool) [8]u64 {
        var stats: [8]u64 = undefined;
        for (&stats, 0..) |*stat, i| {
            stat.* = self.source_contributions[i].load(.Acquire);
        }
        return stats;
    }
};

// ============================================================================
// Interrupt Timing Entropy Collector
// ============================================================================

pub const InterruptEntropyCollector = struct {
    /// Last interrupt timestamp
    last_interrupt_ns: atomic.AtomicU64,
    /// Samples collected
    sample_count: atomic.AtomicU32,
    /// Entropy pool reference
    pool: *EntropyPool,

    pub fn init(pool: *EntropyPool) InterruptEntropyCollector {
        return .{
            .last_interrupt_ns = atomic.AtomicU64.init(0),
            .sample_count = atomic.AtomicU32.init(0),
            .pool = pool,
        };
    }

    /// Called on every interrupt
    pub fn onInterrupt(self: *InterruptEntropyCollector, current_time_ns: u64) void {
        const last = self.last_interrupt_ns.swap(current_time_ns, .AcqRel);

        if (last == 0) return;

        // Calculate timing delta (jitter)
        const delta = if (current_time_ns > last) current_time_ns - last else 0;

        // Use low bits of delta as entropy (timing jitter)
        const entropy_byte: u8 = @truncate(delta & 0xFF);

        // Add to pool (credit 1-2 bits of entropy per interrupt)
        const samples = self.sample_count.fetchAdd(1, .Release);

        // Batch samples before adding to pool
        if (samples % 16 == 0) {
            var entropy_data: [2]u8 = undefined;
            entropy_data[0] = entropy_byte;
            entropy_data[1] = @truncate((delta >> 8) & 0xFF);

            self.pool.addEntropy(.INTERRUPT_TIMING, &entropy_data, 2);
        }
    }
};

// ============================================================================
// Disk I/O Timing Entropy
// ============================================================================

pub const DiskEntropyCollector = struct {
    last_io_ns: atomic.AtomicU64,
    pool: *EntropyPool,

    pub fn init(pool: *EntropyPool) DiskEntropyCollector {
        return .{
            .last_io_ns = atomic.AtomicU64.init(0),
            .pool = pool,
        };
    }

    pub fn onDiskIo(self: *DiskEntropyCollector, current_time_ns: u64, sector: u64) void {
        const last = self.last_io_ns.swap(current_time_ns, .AcqRel);

        var entropy_data: [16]u8 = undefined;

        // Mix time delta and sector number
        const delta = if (current_time_ns > last) current_time_ns - last else 0;

        for (&entropy_data, 0..) |*byte, i| {
            if (i < 8) {
                byte.* = @truncate((delta >> @as(u6, @intCast(i * 8))) & 0xFF);
            } else {
                byte.* = @truncate((sector >> @as(u6, @intCast((i - 8) * 8))) & 0xFF);
            }
        }

        self.pool.addEntropy(.DISK_TIMING, &entropy_data, 4);
    }
};

// ============================================================================
// Input Device Entropy
// ============================================================================

pub const InputEntropyCollector = struct {
    last_input_ns: atomic.AtomicU64,
    pool: *EntropyPool,

    pub fn init(pool: *EntropyPool) InputEntropyCollector {
        return .{
            .last_input_ns = atomic.AtomicU64.init(0),
            .pool = pool,
        };
    }

    pub fn onKeyPress(self: *InputEntropyCollector, current_time_ns: u64, scancode: u8) void {
        const last = self.last_input_ns.swap(current_time_ns, .AcqRel);

        var entropy_data: [9]u8 = undefined;
        const delta = if (current_time_ns > last) current_time_ns - last else 0;

        for (&entropy_data, 0..) |*byte, i| {
            if (i < 8) {
                byte.* = @truncate((delta >> @as(u6, @intCast(i * 8))) & 0xFF);
            } else {
                byte.* = scancode;
            }
        }

        // Keyboard timing is good entropy (human unpredictability)
        self.pool.addEntropy(.INPUT_TIMING, &entropy_data, 8);
    }

    pub fn onMouseMove(self: *InputEntropyCollector, current_time_ns: u64, x: i16, y: i16) void {
        const last = self.last_input_ns.swap(current_time_ns, .AcqRel);

        var entropy_data: [12]u8 = undefined;
        const delta = if (current_time_ns > last) current_time_ns - last else 0;

        for (&entropy_data, 0..) |*byte, i| {
            if (i < 8) {
                byte.* = @truncate((delta >> @as(u6, @intCast(i * 8))) & 0xFF);
            } else if (i < 10) {
                const x_bytes: [2]u8 = @bitCast(x);
                byte.* = x_bytes[i - 8];
            } else {
                const y_bytes: [2]u8 = @bitCast(y);
                byte.* = y_bytes[i - 10];
            }
        }

        self.pool.addEntropy(.INPUT_TIMING, &entropy_data, 6);
    }
};

// ============================================================================
// CPU Performance Counter Entropy
// ============================================================================

pub const CpuEntropyCollector = struct {
    pool: *EntropyPool,

    pub fn init(pool: *EntropyPool) CpuEntropyCollector {
        return .{ .pool = pool };
    }

    /// Collect entropy from CPU performance counters
    pub fn collect(self: *CpuEntropyCollector) void {
        // In production, would read actual CPU performance counters
        // For now, use timestamp counter as proxy
        const tsc = self.readTsc();

        var entropy_data: [8]u8 = undefined;
        for (&entropy_data, 0..) |*byte, i| {
            byte.* = @truncate((tsc >> @as(u6, @intCast(i * 8))) & 0xFF);
        }

        // Low bits of TSC have some jitter
        self.pool.addEntropy(.CPU_COUNTERS, &entropy_data, 4);
    }

    fn readTsc(self: *CpuEntropyCollector) u64 {
        _ = self;
        // In production, would use RDTSC instruction
        return @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp()))));
    }
};

// ============================================================================
// Global Entropy System
// ============================================================================

var global_entropy_pool: EntropyPool = undefined;
var entropy_initialized = false;

pub fn init() void {
    if (entropy_initialized) return;

    global_entropy_pool = EntropyPool.init();

    // Add initial boot entropy
    var boot_entropy: [32]u8 = undefined;
    if (random.hasHardwareRng()) {
        for (&boot_entropy) |*byte| {
            byte.* = @truncate(random.getRandom());
        }
        global_entropy_pool.addEntropy(.BOOT_ENTROPY, &boot_entropy, 256);
    }

    entropy_initialized = true;
}

pub fn getGlobalPool() *EntropyPool {
    if (!entropy_initialized) init();
    return &global_entropy_pool;
}

pub fn getRandomBytes(output: []u8) !void {
    const pool = getGlobalPool();
    try pool.extractNonBlocking(output);
}

pub fn getRandomBytesBlocking(output: []u8) !void {
    const pool = getGlobalPool();
    try pool.extractBlocking(output);
}

// ============================================================================
// Tests
// ============================================================================

test "entropy pool initialization" {
    var pool = EntropyPool.init();

    try Basics.testing.expect(!pool.isInitialized());
    try Basics.testing.expect(pool.getEntropyBits() == 0);
}

test "entropy pool add entropy" {
    var pool = EntropyPool.init();

    const data = "test entropy data";
    pool.addEntropy(.HARDWARE_RNG, data, 128);

    try Basics.testing.expect(pool.getEntropyBits() == 128);
}

test "entropy pool extraction" {
    var pool = EntropyPool.init();

    // Add enough entropy to initialize
    var entropy_data: [64]u8 = undefined;
    for (&entropy_data, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    pool.addEntropy(.HARDWARE_RNG, &entropy_data, 512);

    try Basics.testing.expect(pool.isInitialized());

    // Extract random bytes
    var output: [32]u8 = undefined;
    try pool.extractNonBlocking(&output);

    // Should have debited entropy
    try Basics.testing.expect(pool.getEntropyBits() < 512);
}

test "interrupt entropy collector" {
    var pool = EntropyPool.init();
    var collector = InterruptEntropyCollector.init(&pool);

    collector.onInterrupt(1000);
    collector.onInterrupt(1500);
    collector.onInterrupt(2100);

    // Should have collected some samples
    try Basics.testing.expect(collector.sample_count.load(.Acquire) > 0);
}

test "disk entropy collector" {
    var pool = EntropyPool.init();
    var collector = DiskEntropyCollector.init(&pool);

    collector.onDiskIo(1000, 12345);
    collector.onDiskIo(2000, 67890);

    // Should have added entropy
    try Basics.testing.expect(pool.getEntropyBits() > 0);
}

test "input entropy collector keypress" {
    var pool = EntropyPool.init();
    var collector = InputEntropyCollector.init(&pool);

    collector.onKeyPress(1000, 0x1E); // 'A' key
    collector.onKeyPress(1100, 0x30); // 'B' key

    try Basics.testing.expect(pool.getEntropyBits() > 0);
}

test "entropy source statistics" {
    var pool = EntropyPool.init();

    var data: [16]u8 = undefined;
    pool.addEntropy(.HARDWARE_RNG, &data, 128);
    pool.addEntropy(.INTERRUPT_TIMING, &data, 32);

    const stats = pool.getSourceStats();

    try Basics.testing.expect(stats[@intFromEnum(EntropySource.HARDWARE_RNG)] == 128);
    try Basics.testing.expect(stats[@intFromEnum(EntropySource.INTERRUPT_TIMING)] == 32);
}
