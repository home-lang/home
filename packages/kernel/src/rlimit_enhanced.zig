// Home OS Kernel - Enhanced Resource Limits
// Advanced resource control beyond basic rlimits

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const capabilities = @import("capabilities.zig");

// ============================================================================
// Extended Resource Types
// ============================================================================

pub const ExtendedResourceType = enum {
    /// Network bandwidth (bytes per second)
    RLIMIT_NETWORK_BW,
    /// Disk I/O bandwidth (bytes per second)
    RLIMIT_DISK_BW,
    /// Number of threads
    RLIMIT_THREADS,
    /// Number of signals in queue
    RLIMIT_SIGPENDING,
    /// Number of message queues
    RLIMIT_MSGQUEUE,
    /// Number of locks
    RLIMIT_LOCKS,
    /// Nice value range
    RLIMIT_NICE,
    /// Real-time priority
    RLIMIT_RTPRIO,
    /// Real-time CPU time (microseconds)
    RLIMIT_RTTIME,
    /// Memory locks (mlock)
    RLIMIT_MEMLOCK,
    /// Swap usage
    RLIMIT_SWAP,
    /// Kernel memory
    RLIMIT_KMEM,
};

// ============================================================================
// Hierarchical Resource Groups (cgroups-like)
// ============================================================================

pub const ResourceGroup = struct {
    /// Group ID
    id: u64,
    /// Parent group (null = root)
    parent: ?*ResourceGroup,
    /// CPU shares (relative weight)
    cpu_shares: atomic.AtomicU32,
    /// CPU quota (nanoseconds per period)
    cpu_quota_ns: atomic.AtomicU64,
    /// Memory limit (bytes)
    memory_limit: atomic.AtomicU64,
    /// Current memory usage
    memory_usage: atomic.AtomicU64,
    /// I/O weight (100-1000)
    io_weight: atomic.AtomicU16,
    /// Number of processes in group
    process_count: atomic.AtomicU32,
    /// Lock for modifications
    lock: sync.RwLock,

    pub fn init(id: u64, parent: ?*ResourceGroup) ResourceGroup {
        return .{
            .id = id,
            .parent = parent,
            .cpu_shares = atomic.AtomicU32.init(1024), // Default shares
            .cpu_quota_ns = atomic.AtomicU64.init(Basics.math.maxInt(u64)), // Unlimited
            .memory_limit = atomic.AtomicU64.init(Basics.math.maxInt(u64)), // Unlimited
            .memory_usage = atomic.AtomicU64.init(0),
            .io_weight = atomic.AtomicU16.init(500), // Default weight
            .process_count = atomic.AtomicU32.init(0),
            .lock = sync.RwLock.init(),
        };
    }

    /// Set CPU quota
    pub fn setCpuQuota(self: *ResourceGroup, quota_ns: u64) void {
        self.cpu_quota_ns.store(quota_ns, .Release);
    }

    /// Set memory limit
    pub fn setMemoryLimit(self: *ResourceGroup, limit: u64) !void {
        const current_usage = self.memory_usage.load(.Acquire);
        if (limit < current_usage) {
            return error.LimitBelowUsage;
        }

        self.memory_limit.store(limit, .Release);
    }

    /// Try to charge memory
    pub fn chargeMemory(self: *ResourceGroup, amount: u64) !void {
        const limit = self.memory_limit.load(.Acquire);
        const current = self.memory_usage.fetchAdd(amount, .Acquire);

        if (current + amount > limit) {
            // Rollback
            _ = self.memory_usage.fetchSub(amount, .Release);
            return error.MemoryLimitExceeded;
        }

        // Also check parent limits
        if (self.parent) |parent| {
            parent.chargeMemory(amount) catch |err| {
                // Rollback
                _ = self.memory_usage.fetchSub(amount, .Release);
                return err;
            };
        }
    }

    /// Uncharge memory
    pub fn unchargeMemory(self: *ResourceGroup, amount: u64) void {
        _ = self.memory_usage.fetchSub(amount, .Release);

        if (self.parent) |parent| {
            parent.unchargeMemory(amount);
        }
    }

    /// Add process to group
    pub fn addProcess(self: *ResourceGroup) !void {
        const count = self.process_count.fetchAdd(1, .Acquire);
        _ = count;
    }

    /// Remove process from group
    pub fn removeProcess(self: *ResourceGroup) void {
        _ = self.process_count.fetchSub(1, .Release);
    }
};

// ============================================================================
// I/O Throttling
// ============================================================================

pub const IoThrottle = struct {
    /// Read bytes per second limit
    read_bps_limit: atomic.AtomicU64,
    /// Write bytes per second limit
    write_bps_limit: atomic.AtomicU64,
    /// Read operations per second limit
    read_ops_limit: atomic.AtomicU32,
    /// Write operations per second limit
    write_ops_limit: atomic.AtomicU32,
    /// Current period start time
    period_start_ns: atomic.AtomicU64,
    /// Bytes read this period
    read_bytes_period: atomic.AtomicU64,
    /// Bytes written this period
    write_bytes_period: atomic.AtomicU64,
    /// Read ops this period
    read_ops_period: atomic.AtomicU32,
    /// Write ops this period
    write_ops_period: atomic.AtomicU32,
    /// Period length (nanoseconds)
    period_ns: u64,

    pub fn init() IoThrottle {
        return .{
            .read_bps_limit = atomic.AtomicU64.init(Basics.math.maxInt(u64)),
            .write_bps_limit = atomic.AtomicU64.init(Basics.math.maxInt(u64)),
            .read_ops_limit = atomic.AtomicU32.init(Basics.math.maxInt(u32)),
            .write_ops_limit = atomic.AtomicU32.init(Basics.math.maxInt(u32)),
            .period_start_ns = atomic.AtomicU64.init(0),
            .read_bytes_period = atomic.AtomicU64.init(0),
            .write_bytes_period = atomic.AtomicU64.init(0),
            .read_ops_period = atomic.AtomicU32.init(0),
            .write_ops_period = atomic.AtomicU32.init(0),
            .period_ns = 1_000_000_000, // 1 second periods
        };
    }

    /// Check if read is allowed
    pub fn allowRead(self: *IoThrottle, bytes: u64, current_time_ns: u64) bool {
        self.resetPeriodIfNeeded(current_time_ns);

        const limit_bytes = self.read_bps_limit.load(.Acquire);
        const limit_ops = self.read_ops_limit.load(.Acquire);

        const current_bytes = self.read_bytes_period.load(.Acquire);
        const current_ops = self.read_ops_period.load(.Acquire);

        if (current_bytes + bytes > limit_bytes) return false;
        if (current_ops + 1 > limit_ops) return false;

        // Allowed, increment counters
        _ = self.read_bytes_period.fetchAdd(bytes, .Release);
        _ = self.read_ops_period.fetchAdd(1, .Release);

        return true;
    }

    /// Check if write is allowed
    pub fn allowWrite(self: *IoThrottle, bytes: u64, current_time_ns: u64) bool {
        self.resetPeriodIfNeeded(current_time_ns);

        const limit_bytes = self.write_bps_limit.load(.Acquire);
        const limit_ops = self.write_ops_limit.load(.Acquire);

        const current_bytes = self.write_bytes_period.load(.Acquire);
        const current_ops = self.write_ops_period.load(.Acquire);

        if (current_bytes + bytes > limit_bytes) return false;
        if (current_ops + 1 > limit_ops) return false;

        // Allowed, increment counters
        _ = self.write_bytes_period.fetchAdd(bytes, .Release);
        _ = self.write_ops_period.fetchAdd(1, .Release);

        return true;
    }

    fn resetPeriodIfNeeded(self: *IoThrottle, current_time_ns: u64) void {
        const period_start = self.period_start_ns.load(.Acquire);

        if (current_time_ns - period_start >= self.period_ns) {
            // New period
            self.period_start_ns.store(current_time_ns, .Release);
            self.read_bytes_period.store(0, .Release);
            self.write_bytes_period.store(0, .Release);
            self.read_ops_period.store(0, .Release);
            self.write_ops_period.store(0, .Release);
        }
    }

    /// Set I/O limits
    pub fn setLimits(self: *IoThrottle, read_bps: u64, write_bps: u64, read_ops: u32, write_ops: u32) void {
        self.read_bps_limit.store(read_bps, .Release);
        self.write_bps_limit.store(write_bps, .Release);
        self.read_ops_limit.store(read_ops, .Release);
        self.write_ops_limit.store(write_ops, .Release);
    }
};

// ============================================================================
// Network Throttling
// ============================================================================

pub const NetworkThrottle = struct {
    /// Receive bytes per second limit
    rx_bps_limit: atomic.AtomicU64,
    /// Transmit bytes per second limit
    tx_bps_limit: atomic.AtomicU64,
    /// Current period
    period_start_ns: atomic.AtomicU64,
    /// Bytes received this period
    rx_bytes_period: atomic.AtomicU64,
    /// Bytes transmitted this period
    tx_bytes_period: atomic.AtomicU64,
    /// Period length
    period_ns: u64,

    pub fn init() NetworkThrottle {
        return .{
            .rx_bps_limit = atomic.AtomicU64.init(Basics.math.maxInt(u64)),
            .tx_bps_limit = atomic.AtomicU64.init(Basics.math.maxInt(u64)),
            .period_start_ns = atomic.AtomicU64.init(0),
            .rx_bytes_period = atomic.AtomicU64.init(0),
            .tx_bytes_period = atomic.AtomicU64.init(0),
            .period_ns = 1_000_000_000,
        };
    }

    /// Check if receive is allowed
    pub fn allowReceive(self: *NetworkThrottle, bytes: u64, current_time_ns: u64) bool {
        self.resetPeriodIfNeeded(current_time_ns);

        const limit = self.rx_bps_limit.load(.Acquire);
        const current = self.rx_bytes_period.load(.Acquire);

        if (current + bytes > limit) return false;

        _ = self.rx_bytes_period.fetchAdd(bytes, .Release);
        return true;
    }

    /// Check if transmit is allowed
    pub fn allowTransmit(self: *NetworkThrottle, bytes: u64, current_time_ns: u64) bool {
        self.resetPeriodIfNeeded(current_time_ns);

        const limit = self.tx_bps_limit.load(.Acquire);
        const current = self.tx_bytes_period.load(.Acquire);

        if (current + bytes > limit) return false;

        _ = self.tx_bytes_period.fetchAdd(bytes, .Release);
        return true;
    }

    fn resetPeriodIfNeeded(self: *NetworkThrottle, current_time_ns: u64) void {
        const period_start = self.period_start_ns.load(.Acquire);

        if (current_time_ns - period_start >= self.period_ns) {
            self.period_start_ns.store(current_time_ns, .Release);
            self.rx_bytes_period.store(0, .Release);
            self.tx_bytes_period.store(0, .Release);
        }
    }

    pub fn setLimits(self: *NetworkThrottle, rx_bps: u64, tx_bps: u64) void {
        self.rx_bps_limit.store(rx_bps, .Release);
        self.tx_bps_limit.store(tx_bps, .Release);
    }
};

// ============================================================================
// Thread Limits
// ============================================================================

pub const ThreadLimit = struct {
    /// Maximum threads per process
    max_threads_per_process: atomic.AtomicU32,
    /// Maximum threads per UID
    max_threads_per_uid: atomic.AtomicU32,
    /// Maximum threads system-wide
    max_threads_global: atomic.AtomicU32,
    /// Current global thread count
    global_thread_count: atomic.AtomicU32,

    pub fn init() ThreadLimit {
        return .{
            .max_threads_per_process = atomic.AtomicU32.init(512),
            .max_threads_per_uid = atomic.AtomicU32.init(4096),
            .max_threads_global = atomic.AtomicU32.init(32768),
            .global_thread_count = atomic.AtomicU32.init(0),
        };
    }

    /// Check if thread creation is allowed
    pub fn allowThreadCreate(self: *ThreadLimit, process_threads: u32, uid_threads: u32) !void {
        const max_process = self.max_threads_per_process.load(.Acquire);
        const max_uid = self.max_threads_per_uid.load(.Acquire);
        const max_global = self.max_threads_global.load(.Acquire);
        const global_count = self.global_thread_count.load(.Acquire);

        if (process_threads >= max_process) {
            return error.ProcessThreadLimitExceeded;
        }

        if (uid_threads >= max_uid) {
            return error.UidThreadLimitExceeded;
        }

        if (global_count >= max_global) {
            return error.GlobalThreadLimitExceeded;
        }

        _ = self.global_thread_count.fetchAdd(1, .Release);
    }

    /// Thread destroyed
    pub fn threadDestroyed(self: *ThreadLimit) void {
        _ = self.global_thread_count.fetchSub(1, .Release);
    }
};

// ============================================================================
// Memory Locking Limits (mlock)
// ============================================================================

pub const MemlockLimit = struct {
    /// Maximum locked memory per process (bytes)
    max_per_process: atomic.AtomicU64,
    /// Maximum locked memory system-wide (bytes)
    max_global: atomic.AtomicU64,
    /// Current global locked memory
    global_locked: atomic.AtomicU64,

    pub fn init() MemlockLimit {
        return .{
            .max_per_process = atomic.AtomicU64.init(64 * 1024 * 1024), // 64MB default
            .max_global = atomic.AtomicU64.init(1024 * 1024 * 1024), // 1GB default
            .global_locked = atomic.AtomicU64.init(0),
        };
    }

    /// Try to lock memory
    pub fn lock(self: *MemlockLimit, amount: u64, process_locked: u64) !void {
        if (!capabilities.hasCapability(.CAP_IPC_LOCK)) {
            const max_process = self.max_per_process.load(.Acquire);
            if (process_locked + amount > max_process) {
                return error.MemlockLimitExceeded;
            }
        }

        const max_global = self.max_global.load(.Acquire);
        const global = self.global_locked.fetchAdd(amount, .Acquire);

        if (global + amount > max_global) {
            // Rollback
            _ = self.global_locked.fetchSub(amount, .Release);
            return error.GlobalMemlockLimitExceeded;
        }
    }

    /// Unlock memory
    pub fn unlock(self: *MemlockLimit, amount: u64) void {
        _ = self.global_locked.fetchSub(amount, .Release);
    }
};

// ============================================================================
// Real-Time Limits
// ============================================================================

pub const RtLimit = struct {
    /// Maximum real-time priority (0-99)
    max_rt_priority: atomic.AtomicU8,
    /// Maximum real-time CPU time per period (microseconds)
    max_rt_time_us: atomic.AtomicU64,
    /// RT period length (microseconds)
    rt_period_us: u64,

    pub fn init() RtLimit {
        return .{
            .max_rt_priority = atomic.AtomicU8.init(0), // No RT by default
            .max_rt_time_us = atomic.AtomicU64.init(950000), // 95% of 1 second
            .rt_period_us = 1_000_000, // 1 second
        };
    }

    /// Check if RT priority is allowed
    pub fn allowRtPriority(self: *RtLimit, priority: u8) !void {
        if (priority == 0) return; // Not RT

        if (!capabilities.hasCapability(.CAP_SYS_NICE)) {
            const max = self.max_rt_priority.load(.Acquire);
            if (priority > max) {
                return error.RtPriorityDenied;
            }
        }
    }

    /// Check if RT time is allowed
    pub fn allowRtTime(self: *RtLimit, used_time_us: u64) bool {
        const max = self.max_rt_time_us.load(.Acquire);
        return used_time_us < max;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "resource group memory charging" {
    var root = ResourceGroup.init(1, null);
    var child = ResourceGroup.init(2, &root);

    try root.setMemoryLimit(1000);
    try child.setMemoryLimit(500);

    try child.chargeMemory(100);
    try Basics.testing.expect(child.memory_usage.load(.Acquire) == 100);
    try Basics.testing.expect(root.memory_usage.load(.Acquire) == 100);

    // Should fail - exceeds child limit
    const result = child.chargeMemory(500);
    try Basics.testing.expect(result == error.MemoryLimitExceeded);
}

test "io throttle rate limiting" {
    var throttle = IoThrottle.init();
    throttle.setLimits(1000, 1000, 10, 10);

    // Should allow
    try Basics.testing.expect(throttle.allowRead(500, 1000));
    try Basics.testing.expect(throttle.allowRead(400, 1000));

    // Should deny - exceeds limit
    try Basics.testing.expect(!throttle.allowRead(200, 1000));
}

test "network throttle reset period" {
    var throttle = NetworkThrottle.init();
    throttle.setLimits(1000, 1000);

    try Basics.testing.expect(throttle.allowTransmit(1000, 1000));
    try Basics.testing.expect(!throttle.allowTransmit(1, 1000));

    // New period - should allow again
    try Basics.testing.expect(throttle.allowTransmit(1000, 2_000_000_000));
}

test "thread limit enforcement" {
    var limit = ThreadLimit.init();
    limit.max_threads_per_process.store(2, .Release);

    try limit.allowThreadCreate(0, 0);
    try limit.allowThreadCreate(1, 1);

    // Should fail - process limit
    const result = limit.allowThreadCreate(2, 2);
    try Basics.testing.expect(result == error.ProcessThreadLimitExceeded);
}

test "memlock limit" {
    var limit = MemlockLimit.init();
    limit.max_per_process.store(1000, .Release);

    try limit.lock(500, 0);
    try limit.lock(400, 500);

    // Should fail - exceeds process limit
    const result = limit.lock(200, 900);
    try Basics.testing.expect(result == error.MemlockLimitExceeded);
}

test "rt priority limit" {
    var limit = RtLimit.init();
    limit.max_rt_priority.store(10, .Release);

    try limit.allowRtPriority(5);
    try limit.allowRtPriority(10);

    // Should fail - exceeds max RT priority
    const result = limit.allowRtPriority(15);
    try Basics.testing.expect(result == error.RtPriorityDenied);
}
