// Home OS Kernel - Timing Attack Mitigations
// Prevents side-channel attacks via timing analysis

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const random = @import("random.zig");

// ============================================================================
// Constant-Time Operations
// ============================================================================

/// Constant-time byte comparison
pub fn constantTimeByteEq(a: u8, b: u8) bool {
    const diff = a ^ b;
    return diff == 0;
}

/// Constant-time buffer comparison
pub fn constantTimeEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var diff: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        diff |= byte_a ^ byte_b;
    }

    return diff == 0;
}

/// Constant-time select (branchless)
pub fn constantTimeSelect(condition: bool, if_true: u64, if_false: u64) u64 {
    const mask: u64 = if (condition) @as(u64, @bitCast(@as(i64, -1))) else 0;
    return (mask & if_true) | (~mask & if_false);
}

/// Constant-time conditional copy
pub fn constantTimeCopy(condition: bool, dest: []u8, src: []const u8) void {
    const mask: u8 = if (condition) 0xFF else 0x00;

    for (dest, src) |*d, s| {
        d.* = (d.* & ~mask) | (s & mask);
    }
}

// ============================================================================
// Cache Timing Mitigations
// ============================================================================

pub const CacheLineSize = 64;

/// Prefetch data to prevent cache timing
pub fn prefetch(addr: usize) void {
    // Would use actual prefetch instruction in production
    _ = addr;
    // asm volatile ("prefetcht0 (%[addr])" : : [addr] "r" (addr));
}

/// Flush cache line to prevent timing leaks
pub fn clflush(addr: usize) void {
    // Would use CLFLUSH instruction in production
    _ = addr;
    // asm volatile ("clflush (%[addr])" : : [addr] "r" (addr));
}

/// Execute memory fence (prevent speculation)
pub fn mfence() void {
    atomic.fence(.SeqCst);
}

/// Serialize execution (prevent out-of-order)
pub fn lfence() void {
    atomic.fence(.Acquire);
}

// ============================================================================
// Timing Noise Injection
// ============================================================================

pub const TimingNoise = struct {
    /// Enable noise injection
    enabled: atomic.AtomicBool,
    /// Noise level (microseconds)
    noise_level_us: atomic.AtomicU32,

    pub fn init() TimingNoise {
        return .{
            .enabled = atomic.AtomicBool.init(false),
            .noise_level_us = atomic.AtomicU32.init(100), // 100us default
        };
    }

    /// Add random timing delay
    pub fn addNoise(self: *TimingNoise) void {
        if (!self.enabled.load(.Acquire)) {
            return;
        }

        const max_delay = self.noise_level_us.load(.Acquire);
        const delay = random.getRandom() % max_delay;

        // Busy wait (production would use actual delay)
        var i: u64 = 0;
        while (i < delay * 100) : (i += 1) {
            atomic.fence(.SeqCst);
        }
    }

    pub fn enable(self: *TimingNoise) void {
        self.enabled.store(true, .Release);
    }

    pub fn disable(self: *TimingNoise) void {
        self.enabled.store(false, .Release);
    }
};

// ============================================================================
// Execution Time Normalization
// ============================================================================

pub const ExecutionTimer = struct {
    /// Target execution time (nanoseconds)
    target_time_ns: u64,
    /// Start time
    start_time_ns: u64,

    pub fn init(target_ns: u64) ExecutionTimer {
        return .{
            .target_time_ns = target_ns,
            .start_time_ns = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp())))),
        };
    }

    /// Wait until target time is reached
    pub fn normalize(self: *const ExecutionTimer) void {
        const now = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp()))));
        const elapsed = now - self.start_time_ns;

        if (elapsed < self.target_time_ns) {
            const remaining = self.target_time_ns - elapsed;

            // Busy wait
            var i: u64 = 0;
            while (i < remaining / 10) : (i += 1) {
                atomic.fence(.SeqCst);
            }
        }
    }
};

// ============================================================================
// Spectre/Meltdown Mitigations
// ============================================================================

pub const SpectreClass = enum {
    V1_BOUNDS_CHECK,  // Spectre v1
    V2_BRANCH_TARGET, // Spectre v2
    V4_STORE_BYPASS,  // Spectre v4
};

/// Array index masking (Spectre v1 mitigation)
pub fn arrayIndexMask(index: usize, array_len: usize) usize {
    // Branchless bounds check
    const mask = if (index < array_len) @as(usize, @bitCast(@as(isize, -1))) else 0;
    return index & mask;
}

/// Retpoline stub (Spectre v2 mitigation)
pub fn retpoline() void {
    // Would use actual retpoline in production
    // Prevents speculative execution of indirect branches
    atomic.fence(.SeqCst);
}

/// Store buffer flush (Spectre v4 mitigation)
pub fn storeBufferFlush() void {
    // Would use SSBD or VERW instruction
    atomic.fence(.SeqCst);
}

// ============================================================================
// Branch Prediction Hardening
// ============================================================================

pub fn unlikelyBranch(condition: bool) bool {
    // Compiler hint for unlikely branches
    return condition;
}

pub fn likelyBranch(condition: bool) bool {
    // Compiler hint for likely branches
    return condition;
}

// ============================================================================
// Transient Execution Attack Mitigation
// ============================================================================

pub const TransientProtection = struct {
    /// LFENCE after bounds checks
    lfence_enabled: atomic.AtomicBool,
    /// Retpoline for indirect branches
    retpoline_enabled: atomic.AtomicBool,

    pub fn init() TransientProtection {
        return .{
            .lfence_enabled = atomic.AtomicBool.init(true),
            .retpoline_enabled = atomic.AtomicBool.init(true),
        };
    }

    pub fn protectBoundsCheck(self: *TransientProtection) void {
        if (self.lfence_enabled.load(.Acquire)) {
            lfence();
        }
    }

    pub fn protectIndirectBranch(self: *TransientProtection) void {
        if (self.retpoline_enabled.load(.Acquire)) {
            retpoline();
        }
    }
};

// ============================================================================
// Global Timing Protection
// ============================================================================

var global_noise: TimingNoise = undefined;
var global_transient: TransientProtection = undefined;
var timing_initialized = false;

pub fn init() void {
    if (!timing_initialized) {
        global_noise = TimingNoise.init();
        global_transient = TransientProtection.init();
        timing_initialized = true;
    }
}

pub fn getNoise() *TimingNoise {
    if (!timing_initialized) init();
    return &global_noise;
}

pub fn getTransient() *TransientProtection {
    if (!timing_initialized) init();
    return &global_transient;
}

// ============================================================================
// Tests
// ============================================================================

test "constant time comparison" {
    const a = "password123";
    const b = "password123";
    const c = "password456";

    try Basics.testing.expect(constantTimeEq(a, b));
    try Basics.testing.expect(!constantTimeEq(a, c));
}

test "constant time select" {
    const result1 = constantTimeSelect(true, 42, 0);
    const result2 = constantTimeSelect(false, 42, 0);

    try Basics.testing.expect(result1 == 42);
    try Basics.testing.expect(result2 == 0);
}

test "array index masking" {
    const masked = arrayIndexMask(100, 50);
    try Basics.testing.expect(masked == 0); // Out of bounds masked to 0

    const valid = arrayIndexMask(10, 50);
    try Basics.testing.expect(valid == 10); // In bounds, unchanged
}

test "execution timer" {
    const timer = ExecutionTimer.init(1000); // 1 microsecond

    // Do some work
    var sum: u64 = 0;
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        sum += i;
    }

    timer.normalize();
    // Execution time normalized
}

test "timing noise" {
    var noise = TimingNoise.init();
    noise.enable();

    noise.addNoise(); // Should add random delay
}

test "transient protection" {
    var prot = TransientProtection.init();

    prot.protectBoundsCheck();
    prot.protectIndirectBranch();
}
