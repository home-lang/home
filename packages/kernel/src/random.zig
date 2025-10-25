// Home OS Kernel - Cryptographically Secure Random Number Generator
// Uses hardware RNG (RDRAND/RDSEED) when available, falls back to entropy pool

const Basics = @import("basics");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// ============================================================================
// Hardware Random Number Generation (x86-64)
// ============================================================================

/// Check if RDRAND instruction is available
pub fn hasRdrand() bool {
    // CPUID.01H:ECX.RDRAND[bit 30]
    const cpuid_result = asm volatile (
        \\mov $1, %%eax
        \\cpuid
        : [ecx] "={ecx}" (-> u32),
        :
        : "eax", "ebx", "edx"
    );
    return (cpuid_result & (1 << 30)) != 0;
}

/// Check if RDSEED instruction is available
pub fn hasRdseed() bool {
    // CPUID.07H:EBX.RDSEED[bit 18]
    const cpuid_result = asm volatile (
        \\mov $7, %%eax
        \\xor %%ecx, %%ecx
        \\cpuid
        : [ebx] "={ebx}" (-> u32),
        :
        : "eax", "ecx", "edx"
    );
    return (cpuid_result & (1 << 18)) != 0;
}

/// Get random 64-bit value using RDRAND
pub fn rdrand() !u64 {
    var value: u64 = undefined;
    var success: u8 = undefined;

    // Try up to 10 times (RDRAND can fail rarely)
    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        asm volatile (
            \\rdrand %[value]
            \\setc %[success]
            : [value] "=r" (value),
              [success] "=r" (success),
        );

        if (success != 0) return value;
    }

    return error.RdrandFailed;
}

/// Get random 64-bit value using RDSEED (better quality)
pub fn rdseed() !u64 {
    var value: u64 = undefined;
    var success: u8 = undefined;

    // Try up to 10 times
    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        asm volatile (
            \\rdseed %[value]
            \\setc %[success]
            : [value] "=r" (value),
              [success] "=r" (success),
        );

        if (success != 0) return value;
    }

    return error.RdseedFailed;
}

// ============================================================================
// Entropy Pool (Software Fallback)
// ============================================================================

const POOL_SIZE = 256; // 256 bytes = 2048 bits

var entropy_pool: [POOL_SIZE]u8 = undefined;
var pool_position: usize = 0;
var pool_lock = sync.Spinlock.init();
var pool_initialized = false;

/// Initialize entropy pool with boot-time entropy
pub fn initEntropyPool() void {
    pool_lock.acquire();
    defer pool_lock.release();

    if (pool_initialized) return;

    // Seed with hardware RNG if available
    if (hasRdrand()) {
        var i: usize = 0;
        while (i < POOL_SIZE / 8) : (i += 1) {
            const rand_val = rdrand() catch {
                // If RDRAND fails, use timestamp
                const tsc = readTSC();
                @as(*u64, @ptrCast(@alignCast(&entropy_pool[i * 8]))).* = tsc;
                continue;
            };
            @as(*u64, @ptrCast(@alignCast(&entropy_pool[i * 8]))).* = rand_val;
        }
    } else {
        // Fallback: use timestamp-based entropy
        var i: usize = 0;
        while (i < POOL_SIZE / 8) : (i += 1) {
            const tsc = readTSC();
            @as(*u64, @ptrCast(@alignCast(&entropy_pool[i * 8]))).* = tsc +% i;
        }
    }

    pool_initialized = true;
}

/// Read CPU timestamp counter for entropy
fn readTSC() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile (
        \\rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );

    return (@as(u64, high) << 32) | low;
}

/// Mix new entropy into the pool
pub fn addEntropy(data: []const u8) void {
    pool_lock.acquire();
    defer pool_lock.release();

    for (data) |byte| {
        entropy_pool[pool_position] ^= byte;
        pool_position = (pool_position + 1) % POOL_SIZE;
    }
}

/// Get random bytes from entropy pool
fn getEntropyBytes(out: []u8) void {
    pool_lock.acquire();
    defer pool_lock.release();

    for (out) |*byte| {
        byte.* = entropy_pool[pool_position];
        pool_position = (pool_position + 1) % POOL_SIZE;

        // Mix pool with TSC for forward secrecy
        const tsc = readTSC();
        entropy_pool[pool_position] ^= @as(u8, @truncate(tsc));
    }
}

// ============================================================================
// Public Random Number API
// ============================================================================

/// Get cryptographically secure random u64
pub fn getRandom() u64 {
    // Prefer hardware RNG
    if (hasRdseed()) {
        if (rdseed()) |value| return value;
    }
    if (hasRdrand()) {
        if (rdrand()) |value| return value;
    }

    // Fallback to entropy pool
    var bytes: [8]u8 = undefined;
    getEntropyBytes(&bytes);
    return @as(*u64, @ptrCast(@alignCast(&bytes))).* ;
}

/// Get random u64 in range [min, max)
pub fn getRandomRange(min: u64, max: u64) u64 {
    if (min >= max) return min;
    const range = max - min;
    const rand = getRandom();
    return min + (rand % range);
}

/// Get random bytes
pub fn getRandomBytes(out: []u8) void {
    // Try hardware RNG first for better quality
    if (hasRdrand()) {
        var i: usize = 0;
        while (i + 8 <= out.len) : (i += 8) {
            if (rdrand()) |value| {
                @as(*u64, @ptrCast(@alignCast(&out[i]))).* = value;
            } else {
                getEntropyBytes(out[i..i + 8]);
            }
        }

        // Handle remaining bytes
        if (i < out.len) {
            var temp: [8]u8 = undefined;
            if (rdrand()) |value| {
                @as(*u64, @ptrCast(@alignCast(&temp))).* = value;
            } else {
                getEntropyBytes(&temp);
            }
            @memcpy(out[i..], temp[0 .. out.len - i]);
        }
    } else {
        // Fallback to entropy pool
        getEntropyBytes(out);
    }
}

// ============================================================================
// ASLR Support
// ============================================================================

/// Generate random offset for ASLR
/// Returns a page-aligned random offset within reasonable bounds
pub fn getAslrOffset(max_offset: u64) u64 {
    const PAGE_SIZE = 4096;
    const rand = getRandom();

    // Ensure page alignment
    const offset = (rand % max_offset) & ~@as(u64, PAGE_SIZE - 1);
    return offset;
}

/// Generate random base address for ASLR with specific alignment
pub fn getAslrBase(base: u64, max_offset: u64, alignment: u64) u64 {
    const rand = getRandom();
    const offset = (rand % max_offset) & ~(alignment - 1);
    return base + offset;
}

// ============================================================================
// Tests
// ============================================================================

test "hardware RNG availability check" {
    // This test just checks the functions don't crash
    _ = hasRdrand();
    _ = hasRdseed();
}

test "entropy pool initialization" {
    initEntropyPool();
    try Basics.testing.expect(pool_initialized);
}

test "random number generation" {
    initEntropyPool();

    const r1 = getRandom();
    const r2 = getRandom();

    // Extremely unlikely to get the same value twice
    try Basics.testing.expect(r1 != r2);
}

test "random range" {
    initEntropyPool();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const val = getRandomRange(10, 20);
        try Basics.testing.expect(val >= 10 and val < 20);
    }
}

test "ASLR offset generation" {
    initEntropyPool();

    const offset = getAslrOffset(0x10000000); // 256MB max offset

    // Should be page-aligned
    try Basics.testing.expect(offset % 4096 == 0);

    // Should be within bounds
    try Basics.testing.expect(offset < 0x10000000);
}
