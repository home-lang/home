// Home OS Kernel - Process Accounting
// Tracks resource usage for billing, quotas, and statistics

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const process = @import("process.zig");

// ============================================================================
// Resource Usage Statistics
// ============================================================================

pub const ResourceUsage = struct {
    /// User CPU time (microseconds)
    utime: atomic.AtomicU64,
    /// System CPU time (microseconds)
    stime: atomic.AtomicU64,
    /// Maximum resident set size (bytes)
    maxrss: atomic.AtomicU64,
    /// Page faults without I/O
    minflt: atomic.AtomicU64,
    /// Page faults with I/O
    majflt: atomic.AtomicU64,
    /// Block input operations
    inblock: atomic.AtomicU64,
    /// Block output operations
    outblock: atomic.AtomicU64,
    /// Voluntary context switches
    nvcsw: atomic.AtomicU64,
    /// Involuntary context switches
    nivcsw: atomic.AtomicU64,

    pub fn init() ResourceUsage {
        return .{
            .utime = atomic.AtomicU64.init(0),
            .stime = atomic.AtomicU64.init(0),
            .maxrss = atomic.AtomicU64.init(0),
            .minflt = atomic.AtomicU64.init(0),
            .majflt = atomic.AtomicU64.init(0),
            .inblock = atomic.AtomicU64.init(0),
            .outblock = atomic.AtomicU64.init(0),
            .nvcsw = atomic.AtomicU64.init(0),
            .nivcsw = atomic.AtomicU64.init(0),
        };
    }

    /// Add CPU time (user mode)
    pub fn addUserTime(self: *ResourceUsage, micros: u64) void {
        _ = self.utime.fetchAdd(micros, .Monotonic);
    }

    /// Add CPU time (kernel mode)
    pub fn addSystemTime(self: *ResourceUsage, micros: u64) void {
        _ = self.stime.fetchAdd(micros, .Monotonic);
    }

    /// Update maximum RSS if current is higher
    pub fn updateMaxRss(self: *ResourceUsage, current_rss: u64) void {
        var max = self.maxrss.load(.Monotonic);
        while (current_rss > max) {
            _ = self.maxrss.compareAndSwap(max, current_rss, .Monotonic, .Monotonic) orelse break;
            max = self.maxrss.load(.Monotonic);
        }
    }

    /// Record page fault (minor)
    pub fn recordMinorFault(self: *ResourceUsage) void {
        _ = self.minflt.fetchAdd(1, .Monotonic);
    }

    /// Record page fault (major)
    pub fn recordMajorFault(self: *ResourceUsage) void {
        _ = self.majflt.fetchAdd(1, .Monotonic);
    }

    /// Record block I/O
    pub fn recordBlockRead(self: *ResourceUsage) void {
        _ = self.inblock.fetchAdd(1, .Monotonic);
    }

    pub fn recordBlockWrite(self: *ResourceUsage) void {
        _ = self.outblock.fetchAdd(1, .Monotonic);
    }

    /// Record context switch
    pub fn recordVoluntarySwitch(self: *ResourceUsage) void {
        _ = self.nvcsw.fetchAdd(1, .Monotonic);
    }

    pub fn recordInvoluntarySwitch(self: *ResourceUsage) void {
        _ = self.nivcsw.fetchAdd(1, .Monotonic);
    }

    /// Get total CPU time (user + system)
    pub fn getTotalCpuTime(self: *const ResourceUsage) u64 {
        return self.utime.load(.Monotonic) + self.stime.load(.Monotonic);
    }
};

// ============================================================================
// Process Accounting Record
// ============================================================================

pub const AccountingRecord = struct {
    /// Process ID
    pid: u32,
    /// Parent PID
    ppid: u32,
    /// User ID
    uid: u32,
    /// Group ID
    gid: u32,
    /// Start time
    start_time: u64,
    /// End time
    end_time: u64,
    /// Exit code
    exit_code: i32,
    /// Resource usage
    usage: ResourceUsage,
    /// Command name
    command: [16]u8,
    command_len: usize,

    pub fn init(proc: *const process.Process) AccountingRecord {
        var record: AccountingRecord = undefined;

        record.pid = proc.pid;
        record.ppid = proc.ppid;
        record.uid = proc.uid;
        record.gid = proc.gid;
        record.start_time = 0; // TODO: Get actual start time
        record.end_time = 0;
        record.exit_code = proc.exit_code;
        record.usage = ResourceUsage.init();

        // Copy command name
        const name = proc.getName();
        const copy_len = Basics.math.min(name.len, 15);
        @memcpy(record.command[0..copy_len], name[0..copy_len]);
        record.command_len = copy_len;

        return record;
    }

    pub fn getCommand(self: *const AccountingRecord) []const u8 {
        return self.command[0..self.command_len];
    }
};

// ============================================================================
// Accounting Log
// ============================================================================

const ACCT_LOG_SIZE = 1024;

pub const AccountingLog = struct {
    records: [ACCT_LOG_SIZE]AccountingRecord,
    head: usize,
    tail: usize,
    lock: sync.Spinlock,
    enabled: bool,

    pub fn init() AccountingLog {
        return .{
            .records = undefined,
            .head = 0,
            .tail = 0,
            .lock = sync.Spinlock.init(),
            .enabled = false,
        };
    }

    /// Enable accounting
    pub fn enable(self: *AccountingLog) void {
        self.lock.acquire();
        defer self.lock.release();

        self.enabled = true;
    }

    /// Disable accounting
    pub fn disable(self: *AccountingLog) void {
        self.lock.acquire();
        defer self.lock.release();

        self.enabled = false;
    }

    /// Log process exit
    pub fn logExit(self: *AccountingLog, record: AccountingRecord) void {
        self.lock.acquire();
        defer self.lock.release();

        if (!self.enabled) return;

        // Add to ring buffer
        self.records[self.head] = record;
        self.head = (self.head + 1) % ACCT_LOG_SIZE;

        // Move tail if full
        if (self.head == self.tail) {
            self.tail = (self.tail + 1) % ACCT_LOG_SIZE;
        }
    }

    /// Get accounting records
    pub fn getRecords(self: *AccountingLog, out: []AccountingRecord) usize {
        self.lock.acquire();
        defer self.lock.release();

        var count: usize = 0;
        var idx = self.tail;

        while (idx != self.head and count < out.len) {
            out[count] = self.records[idx];
            count += 1;
            idx = (idx + 1) % ACCT_LOG_SIZE;
        }

        return count;
    }
};

var global_accounting_log: AccountingLog = undefined;
var accounting_initialized = false;

/// Initialize process accounting
pub fn init() void {
    if (accounting_initialized) return;

    global_accounting_log = AccountingLog.init();
    accounting_initialized = true;
}

/// Enable process accounting
pub fn enableAccounting() void {
    if (!accounting_initialized) init();
    global_accounting_log.enable();
}

/// Disable process accounting
pub fn disableAccounting() void {
    if (!accounting_initialized) return;
    global_accounting_log.disable();
}

/// Log process exit for accounting
pub fn logProcessExit(proc: *const process.Process) void {
    if (!accounting_initialized) return;

    var record = AccountingRecord.init(proc);
    record.end_time = 0; // TODO: Get current time

    global_accounting_log.logExit(record);
}

// ============================================================================
// Per-UID Resource Quotas
// ============================================================================

pub const ResourceQuota = struct {
    /// Maximum CPU time (microseconds)
    max_cpu_time: u64,
    /// Maximum memory (bytes)
    max_memory: u64,
    /// Maximum disk usage (bytes)
    max_disk: u64,
    /// Maximum processes
    max_processes: u32,

    /// Current usage
    used_cpu_time: atomic.AtomicU64,
    used_memory: atomic.AtomicU64,
    used_disk: atomic.AtomicU64,
    used_processes: atomic.AtomicU32,

    pub fn init(max_cpu: u64, max_mem: u64, max_disk: u64, max_proc: u32) ResourceQuota {
        return .{
            .max_cpu_time = max_cpu,
            .max_memory = max_mem,
            .max_disk = max_disk,
            .max_processes = max_proc,
            .used_cpu_time = atomic.AtomicU64.init(0),
            .used_memory = atomic.AtomicU64.init(0),
            .used_disk = atomic.AtomicU64.init(0),
            .used_processes = atomic.AtomicU32.init(0),
        };
    }

    /// Check if CPU quota would be exceeded
    pub fn checkCpuQuota(self: *ResourceQuota, additional: u64) bool {
        const current = self.used_cpu_time.load(.Monotonic);
        return (current + additional) <= self.max_cpu_time;
    }

    /// Check if memory quota would be exceeded
    pub fn checkMemoryQuota(self: *ResourceQuota, additional: u64) bool {
        const current = self.used_memory.load(.Monotonic);
        return (current + additional) <= self.max_memory;
    }

    /// Add CPU usage
    pub fn addCpuUsage(self: *ResourceQuota, micros: u64) void {
        _ = self.used_cpu_time.fetchAdd(micros, .Monotonic);
    }

    /// Add memory usage
    pub fn addMemoryUsage(self: *ResourceQuota, bytes: u64) void {
        _ = self.used_memory.fetchAdd(bytes, .Monotonic);
    }

    /// Remove memory usage
    pub fn removeMemoryUsage(self: *ResourceQuota, bytes: u64) void {
        _ = self.used_memory.fetchSub(bytes, .Monotonic);
    }
};

const MAX_UIDS = 1024;

var uid_quotas: [MAX_UIDS]?ResourceQuota = [_]?ResourceQuota{null} ** MAX_UIDS;
var quota_lock = sync.RwLock.init();

/// Set quota for UID
pub fn setQuota(uid: u32, quota: ResourceQuota) !void {
    if (uid >= MAX_UIDS) return error.UidTooHigh;

    quota_lock.acquireWrite();
    defer quota_lock.releaseWrite();

    uid_quotas[uid] = quota;
}

/// Check if operation would exceed quota
pub fn checkQuota(uid: u32, cpu: u64, memory: u64) !void {
    if (uid >= MAX_UIDS) return;

    quota_lock.acquireRead();
    defer quota_lock.releaseRead();

    if (uid_quotas[uid]) |*quota| {
        if (!quota.checkCpuQuota(cpu)) {
            return error.CpuQuotaExceeded;
        }

        if (!quota.checkMemoryQuota(memory)) {
            return error.MemoryQuotaExceeded;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "resource usage initialization" {
    const usage = ResourceUsage.init();

    try Basics.testing.expect(usage.utime.load(.Monotonic) == 0);
    try Basics.testing.expect(usage.stime.load(.Monotonic) == 0);
}

test "resource usage tracking" {
    var usage = ResourceUsage.init();

    usage.addUserTime(1000);
    usage.addSystemTime(500);

    try Basics.testing.expect(usage.utime.load(.Monotonic) == 1000);
    try Basics.testing.expect(usage.stime.load(.Monotonic) == 500);
    try Basics.testing.expect(usage.getTotalCpuTime() == 1500);
}

test "max RSS tracking" {
    var usage = ResourceUsage.init();

    usage.updateMaxRss(1024);
    try Basics.testing.expect(usage.maxrss.load(.Monotonic) == 1024);

    usage.updateMaxRss(512); // Should not update (smaller)
    try Basics.testing.expect(usage.maxrss.load(.Monotonic) == 1024);

    usage.updateMaxRss(2048); // Should update (larger)
    try Basics.testing.expect(usage.maxrss.load(.Monotonic) == 2048);
}

test "accounting log" {
    var log = AccountingLog.init();
    log.enable();

    try Basics.testing.expect(log.enabled);
}

test "resource quota" {
    var quota = ResourceQuota.init(10000, 1024 * 1024, 1024 * 1024 * 1024, 100);

    try Basics.testing.expect(quota.checkCpuQuota(5000));
    try Basics.testing.expect(quota.checkMemoryQuota(512 * 1024));

    quota.addCpuUsage(5000);
    quota.addMemoryUsage(512 * 1024);

    try Basics.testing.expect(quota.checkCpuQuota(5000));
    try Basics.testing.expect(!quota.checkCpuQuota(6000)); // Would exceed
}
