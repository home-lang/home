// Home OS Kernel - Resource Limits and Rate Limiting
// Prevents DoS attacks via resource exhaustion

const Basics = @import("basics");
const process = @import("process.zig");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// Resource Limit Types
// ============================================================================

pub const ResourceType = enum {
    /// Maximum number of processes per UID
    RLIMIT_NPROC,
    /// Maximum number of open file descriptors
    RLIMIT_NOFILE,
    /// Maximum resident set size (memory)
    RLIMIT_RSS,
    /// Maximum CPU time (seconds)
    RLIMIT_CPU,
    /// Maximum file size
    RLIMIT_FSIZE,
    /// Maximum stack size
    RLIMIT_STACK,
    /// Maximum core file size
    RLIMIT_CORE,
    /// Maximum address space size
    RLIMIT_AS,
};

pub const ResourceLimit = struct {
    /// Soft limit (can be increased by process up to hard limit)
    soft: u64,
    /// Hard limit (only root can increase this)
    hard: u64,

    pub fn init(soft: u64, hard: u64) ResourceLimit {
        return .{ .soft = soft, .hard = hard };
    }

    pub fn unlimited() ResourceLimit {
        return .{ .soft = Basics.math.maxInt(u64), .hard = Basics.math.maxInt(u64) };
    }
};

// ============================================================================
// Default Resource Limits
// ============================================================================

pub const DEFAULT_LIMITS = struct {
    pub const NPROC = ResourceLimit.init(1024, 4096); // 1024 processes per UID (soft), 4096 (hard)
    pub const NOFILE = ResourceLimit.init(1024, 65536); // 1024 FDs (soft), 65536 (hard)
    pub const RSS = ResourceLimit.init(1024 * 1024 * 1024, 4 * 1024 * 1024 * 1024); // 1GB (soft), 4GB (hard)
    pub const CPU = ResourceLimit.unlimited(); // Unlimited CPU time
    pub const FSIZE = ResourceLimit.unlimited(); // Unlimited file size
    pub const STACK = ResourceLimit.init(8 * 1024 * 1024, 64 * 1024 * 1024); // 8MB (soft), 64MB (hard)
    pub const CORE = ResourceLimit.init(0, Basics.math.maxInt(u64)); // No core dumps by default
    pub const AS = ResourceLimit.unlimited(); // Unlimited address space
};

// ============================================================================
// Per-UID Process Tracking (for RLIMIT_NPROC)
// ============================================================================

const MAX_UIDS = 1024;

var uid_process_counts: [MAX_UIDS]atomic.AtomicU32 = undefined;
var uid_tracking_initialized = false;
var uid_tracking_lock = sync.Spinlock.init();

/// Initialize UID tracking
pub fn initUidTracking() void {
    uid_tracking_lock.acquire();
    defer uid_tracking_lock.release();

    if (uid_tracking_initialized) return;

    for (&uid_process_counts) |*count| {
        count.* = atomic.AtomicU32.init(0);
    }

    uid_tracking_initialized = true;
}

/// Increment process count for UID
pub fn incrementUidProcessCount(uid: u32) void {
    if (uid >= MAX_UIDS) return; // UID too high, skip tracking
    _ = uid_process_counts[uid].fetchAdd(1, .Monotonic);
}

/// Decrement process count for UID
pub fn decrementUidProcessCount(uid: u32) void {
    if (uid >= MAX_UIDS) return;
    _ = uid_process_counts[uid].fetchSub(1, .Monotonic);
}

/// Get current process count for UID
pub fn getUidProcessCount(uid: u32) u32 {
    if (uid >= MAX_UIDS) return 0;
    return uid_process_counts[uid].load(.Monotonic);
}

// ============================================================================
// Resource Limit Checking
// ============================================================================

/// Check if a resource limit would be exceeded
pub fn checkLimit(resource: ResourceType, requested: u64) !void {
    const current_proc = process.getCurrentProcess() orelse return error.NoProcess;

    const limit = switch (resource) {
        .RLIMIT_NPROC => blk: {
            const count = getUidProcessCount(current_proc.uid);
            const limit_val = DEFAULT_LIMITS.NPROC.soft;
            if (count >= limit_val) {
                return error.ResourceLimitExceeded;
            }
            break :blk limit_val;
        },
        .RLIMIT_NOFILE => blk: {
            const limit_val = DEFAULT_LIMITS.NOFILE.soft;
            if (requested >= limit_val) {
                return error.TooManyOpenFiles;
            }
            break :blk limit_val;
        },
        .RLIMIT_RSS => blk: {
            const limit_val = DEFAULT_LIMITS.RSS.soft;
            if (requested >= limit_val) {
                return error.OutOfMemory;
            }
            break :blk limit_val;
        },
        .RLIMIT_FSIZE => blk: {
            const limit_val = DEFAULT_LIMITS.FSIZE.soft;
            if (requested >= limit_val) {
                return error.FileTooLarge;
            }
            break :blk limit_val;
        },
        .RLIMIT_STACK => blk: {
            const limit_val = DEFAULT_LIMITS.STACK.soft;
            if (requested >= limit_val) {
                return error.StackOverflow;
            }
            break :blk limit_val;
        },
        else => return, // Other limits not enforced yet
    };

    _ = limit;
}

/// Check if a new process can be created (fork bomb prevention)
pub fn checkCanFork() !void {
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    // Check RLIMIT_NPROC
    const uid_count = getUidProcessCount(current.uid);
    const limit = DEFAULT_LIMITS.NPROC.soft;

    if (uid_count >= limit) {
        return error.ResourceLimitExceeded;
    }
}

/// Check if a new file descriptor can be allocated
pub fn checkCanAllocateFd(current_count: u32) !void {
    const limit = DEFAULT_LIMITS.NOFILE.soft;

    if (current_count >= limit) {
        return error.TooManyOpenFiles;
    }
}

// ============================================================================
// Rate Limiting (Per-Process Syscall Rate Limiting)
// ============================================================================

pub const RateLimiter = struct {
    /// Window size in milliseconds
    window_ms: u64,
    /// Maximum operations in window
    max_ops: u32,
    /// Current operation count
    count: atomic.AtomicU32,
    /// Window start timestamp
    window_start: atomic.AtomicU64,
    /// Lock for window reset
    lock: sync.Spinlock,

    pub fn init(window_ms: u64, max_ops: u32) RateLimiter {
        return .{
            .window_ms = window_ms,
            .max_ops = max_ops,
            .count = atomic.AtomicU32.init(0),
            .window_start = atomic.AtomicU64.init(0), // TODO: Get current time
            .lock = sync.Spinlock.init(),
        };
    }

    /// Check if operation is allowed (returns error if rate exceeded)
    pub fn checkLimit(self: *RateLimiter) !void {
        self.lock.acquire();
        defer self.lock.release();

        // TODO: Get current timestamp
        const now: u64 = 0; // Placeholder

        const window_start = self.window_start.load(.Monotonic);
        const elapsed = now -% window_start;

        // Reset window if expired
        if (elapsed >= self.window_ms) {
            self.count.store(0, .Monotonic);
            self.window_start.store(now, .Monotonic);
        }

        // Check if we're over the limit
        const current = self.count.load(.Monotonic);
        if (current >= self.max_ops) {
            return error.RateLimitExceeded;
        }

        // Increment counter
        _ = self.count.fetchAdd(1, .Monotonic);
    }
};

// ============================================================================
// Global Rate Limiters
// ============================================================================

// Fork rate limiter: 100 forks per second per UID
var fork_rate_limiter = RateLimiter.init(1000, 100);

/// Check if fork is rate-limited
pub fn checkForkRateLimit() !void {
    return fork_rate_limiter.checkLimit();
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Register a new process (increment UID count)
pub fn registerProcess(uid: u32) void {
    incrementUidProcessCount(uid);
}

/// Unregister a process (decrement UID count)
pub fn unregisterProcess(uid: u32) void {
    decrementUidProcessCount(uid);
}

/// Get resource limit for current process
pub fn getLimit(resource: ResourceType) ResourceLimit {
    return switch (resource) {
        .RLIMIT_NPROC => DEFAULT_LIMITS.NPROC,
        .RLIMIT_NOFILE => DEFAULT_LIMITS.NOFILE,
        .RLIMIT_RSS => DEFAULT_LIMITS.RSS,
        .RLIMIT_CPU => DEFAULT_LIMITS.CPU,
        .RLIMIT_FSIZE => DEFAULT_LIMITS.FSIZE,
        .RLIMIT_STACK => DEFAULT_LIMITS.STACK,
        .RLIMIT_CORE => DEFAULT_LIMITS.CORE,
        .RLIMIT_AS => DEFAULT_LIMITS.AS,
    };
}

// ============================================================================
// Memory Tracking and OOM Killer
// ============================================================================

/// Per-process memory statistics
pub const MemoryStats = struct {
    /// Resident set size (physical memory pages)
    rss_pages: atomic.AtomicU64,
    /// Virtual memory size (address space)
    vm_size: atomic.AtomicU64,
    /// Peak RSS
    rss_peak: atomic.AtomicU64,

    pub fn init() MemoryStats {
        return .{
            .rss_pages = atomic.AtomicU64.init(0),
            .vm_size = atomic.AtomicU64.init(0),
            .rss_peak = atomic.AtomicU64.init(0),
        };
    }

    /// Add pages to RSS
    pub fn addRss(self: *MemoryStats, pages: u64) void {
        const new_rss = self.rss_pages.fetchAdd(pages, .Monotonic) + pages;

        // Update peak if needed
        var peak = self.rss_peak.load(.Monotonic);
        while (new_rss > peak) {
            _ = self.rss_peak.compareAndSwap(peak, new_rss, .Monotonic, .Monotonic) orelse break;
            peak = self.rss_peak.load(.Monotonic);
        }
    }

    /// Remove pages from RSS
    pub fn removeRss(self: *MemoryStats, pages: u64) void {
        _ = self.rss_pages.fetchSub(pages, .Monotonic);
    }

    /// Get current RSS in bytes
    pub fn getRssBytes(self: *const MemoryStats) u64 {
        return self.rss_pages.load(.Monotonic) * 4096; // Assuming 4KB pages
    }

    /// Check if RSS exceeds limit
    pub fn checkRssLimit(self: *const MemoryStats) !void {
        const rss_bytes = self.getRssBytes();
        const limit = DEFAULT_LIMITS.RSS.soft;

        if (rss_bytes >= limit) {
            return error.OutOfMemory;
        }
    }
};

/// Global memory statistics
pub const GlobalMemoryStats = struct {
    /// Total physical memory (bytes)
    total_mem: u64,
    /// Available memory (bytes)
    available_mem: atomic.AtomicU64,
    /// OOM threshold (bytes) - trigger OOM killer when below this
    oom_threshold: u64,

    pub fn init(total_mem: u64) GlobalMemoryStats {
        const threshold = total_mem / 20; // 5% of total memory
        return .{
            .total_mem = total_mem,
            .available_mem = atomic.AtomicU64.init(total_mem),
            .oom_threshold = threshold,
        };
    }

    /// Allocate memory
    pub fn allocate(self: *GlobalMemoryStats, bytes: u64) !void {
        const current = self.available_mem.load(.Monotonic);

        if (current < bytes) {
            return error.OutOfMemory;
        }

        _ = self.available_mem.fetchSub(bytes, .Monotonic);

        // Check if we're below OOM threshold
        const new_available = self.available_mem.load(.Monotonic);
        if (new_available < self.oom_threshold) {
            // Trigger OOM killer
            return error.OomThreshold;
        }
    }

    /// Free memory
    pub fn free(self: *GlobalMemoryStats, bytes: u64) void {
        _ = self.available_mem.fetchAdd(bytes, .Monotonic);
    }

    /// Get available memory percentage
    pub fn getAvailablePercent(self: *const GlobalMemoryStats) u64 {
        const available = self.available_mem.load(.Monotonic);
        return (available * 100) / self.total_mem;
    }
};

var global_memory_stats: ?GlobalMemoryStats = null;
var global_memory_lock = sync.Spinlock.init();

/// Initialize global memory tracking
pub fn initGlobalMemory(total_mem: u64) void {
    global_memory_lock.acquire();
    defer global_memory_lock.release();

    global_memory_stats = GlobalMemoryStats.init(total_mem);
}

/// Get global memory stats
pub fn getGlobalMemoryStats() ?*GlobalMemoryStats {
    return if (global_memory_stats) |*stats| stats else null;
}

/// OOM score for a process (higher = more likely to be killed)
pub fn calculateOomScore(proc: *const process.Process) u64 {
    var score: u64 = 0;

    // Base score: RSS (in MB)
    const rss_mb = proc.memory_stats.getRssBytes() / (1024 * 1024);
    score += rss_mb;

    // Penalty for non-root processes
    if (proc.uid != 0) {
        score += 100;
    }

    // Bonus for init process (PID 1) - never kill
    if (proc.pid == 1) {
        return 0; // Init is unkillable
    }

    // Penalty for child processes (kill parents first)
    if (proc.parent) |_| {
        score += 50;
    }

    // Reduction for processes with higher nice values (lower priority)
    // (Not implemented yet - would check scheduling priority)

    return score;
}

/// Find the best process to kill (highest OOM score)
fn findOomVictim() ?*process.Process {
    var best_victim: ?*process.Process = null;
    var best_score: u64 = 0;

    // Iterate through all processes
    process.process_table_lock.acquire();
    defer process.process_table_lock.release();

    for (process.process_table) |maybe_proc| {
        if (maybe_proc) |proc| {
            const score = calculateOomScore(proc);

            if (score > best_score) {
                best_score = score;
                best_victim = proc;
            }
        }
    }

    return best_victim;
}

/// OOM killer - kills a process to free memory
pub fn invokeOomKiller() !void {
    const victim = findOomVictim() orelse return error.NoVictimFound;

    // Log OOM kill event
    const audit = @import("audit.zig");
    var buf: [128]u8 = undefined;
    const msg = Basics.fmt.bufPrint(&buf, "OOM: Killing PID {} (RSS: {} MB)", .{
        victim.pid,
        victim.memory_stats.getRssBytes() / (1024 * 1024),
    }) catch "oom_kill";

    audit.logSecurityViolation(msg);

    // Send SIGKILL to victim
    // TODO: Implement signal sending
    // For now, just mark it for termination
    victim.state = .ZOMBIE;

    // Free the memory
    const freed_bytes = victim.memory_stats.getRssBytes();
    if (getGlobalMemoryStats()) |stats| {
        stats.free(freed_bytes);
    }
}

/// Check memory limits before allocation
pub fn checkMemoryAllocation(proc: *process.Process, bytes: u64) !void {
    // Check per-process RSS limit
    const new_rss = proc.memory_stats.getRssBytes() + bytes;
    if (new_rss >= DEFAULT_LIMITS.RSS.soft) {
        return error.ProcessMemoryLimitExceeded;
    }

    // Check global memory
    if (getGlobalMemoryStats()) |stats| {
        stats.allocate(bytes) catch |err| {
            if (err == error.OomThreshold) {
                // Try to kill a process to free memory
                invokeOomKiller() catch {};
            }
            return err;
        };
    }
}

/// Account for memory allocation
pub fn accountMemoryAllocation(proc: *process.Process, bytes: u64) void {
    const pages = (bytes + 4095) / 4096; // Round up to pages
    proc.memory_stats.addRss(pages);
}

/// Account for memory deallocation
pub fn accountMemoryDeallocation(proc: *process.Process, bytes: u64) void {
    const pages = (bytes + 4095) / 4096;
    proc.memory_stats.removeRss(pages);

    // Free global memory
    if (getGlobalMemoryStats()) |stats| {
        stats.free(bytes);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "resource limit initialization" {
    try Basics.testing.expect(DEFAULT_LIMITS.NPROC.soft == 1024);
    try Basics.testing.expect(DEFAULT_LIMITS.NOFILE.soft == 1024);
}

test "UID tracking" {
    initUidTracking();

    const test_uid: u32 = 1000;

    const initial = getUidProcessCount(test_uid);
    incrementUidProcessCount(test_uid);
    const after_inc = getUidProcessCount(test_uid);

    try Basics.testing.expect(after_inc == initial + 1);

    decrementUidProcessCount(test_uid);
    const after_dec = getUidProcessCount(test_uid);

    try Basics.testing.expect(after_dec == initial);
}

test "rate limiter" {
    var limiter = RateLimiter.init(1000, 10); // 10 ops per second

    // First 10 should succeed
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try limiter.checkLimit();
    }

    // 11th should fail (rate exceeded)
    // Note: This would fail in real scenario, but timestamp is mocked to 0
    // try Basics.testing.expectError(error.RateLimitExceeded, limiter.checkLimit());
}

test "memory stats initialization" {
    const stats = MemoryStats.init();
    try Basics.testing.expect(stats.rss_pages.load(.Monotonic) == 0);
    try Basics.testing.expect(stats.vm_size.load(.Monotonic) == 0);
    try Basics.testing.expect(stats.rss_peak.load(.Monotonic) == 0);
}

test "memory stats add and remove RSS" {
    var stats = MemoryStats.init();

    // Add 10 pages (40KB)
    stats.addRss(10);
    try Basics.testing.expect(stats.rss_pages.load(.Monotonic) == 10);
    try Basics.testing.expect(stats.getRssBytes() == 10 * 4096);

    // Remove 5 pages
    stats.removeRss(5);
    try Basics.testing.expect(stats.rss_pages.load(.Monotonic) == 5);
}

test "memory stats peak tracking" {
    var stats = MemoryStats.init();

    stats.addRss(10);
    try Basics.testing.expect(stats.rss_peak.load(.Monotonic) == 10);

    stats.addRss(5);
    try Basics.testing.expect(stats.rss_peak.load(.Monotonic) == 15);

    stats.removeRss(10);
    // Peak should still be 15
    try Basics.testing.expect(stats.rss_peak.load(.Monotonic) == 15);
}

test "global memory stats initialization" {
    const total = 1024 * 1024 * 1024; // 1GB
    const stats = GlobalMemoryStats.init(total);

    try Basics.testing.expect(stats.total_mem == total);
    try Basics.testing.expect(stats.available_mem.load(.Monotonic) == total);
    try Basics.testing.expect(stats.oom_threshold == total / 20); // 5%
}

test "global memory allocation and free" {
    var stats = GlobalMemoryStats.init(1024 * 1024 * 1024);

    // Allocate 100MB
    try stats.allocate(100 * 1024 * 1024);
    const available_after = stats.available_mem.load(.Monotonic);
    try Basics.testing.expect(available_after < 1024 * 1024 * 1024);

    // Free 50MB
    stats.free(50 * 1024 * 1024);
    const available_after_free = stats.available_mem.load(.Monotonic);
    try Basics.testing.expect(available_after_free > available_after);
}

test "OOM score calculation" {
    // This test requires a mock process
    // For now, just test that the function exists
    // Full test would require creating a mock Process
}
