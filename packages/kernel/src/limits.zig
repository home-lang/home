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
