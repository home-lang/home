// Home Programming Language - Resource Limits
// Process resource limit enforcement (RLIMIT_*) and OOM killer

const Basics = @import("basics");
const process = @import("process.zig");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// Resource Limit Types
// ============================================================================

/// Resource limit types (RLIMIT_*)
pub const ResourceType = enum(u32) {
    /// CPU time limit in seconds
    CPU = 0,
    /// Maximum file size
    FSIZE = 1,
    /// Maximum data segment size
    DATA = 2,
    /// Maximum stack size
    STACK = 3,
    /// Maximum core file size
    CORE = 4,
    /// Maximum resident set size (RSS)
    RSS = 5,
    /// Maximum number of processes
    NPROC = 6,
    /// Maximum number of open files
    NOFILE = 7,
    /// Maximum locked memory
    MEMLOCK = 8,
    /// Maximum address space
    AS = 9,
    /// Maximum number of file locks
    LOCKS = 10,
    /// Maximum number of pending signals
    SIGPENDING = 11,
    /// Maximum message queue bytes
    MSGQUEUE = 12,
    /// Maximum nice priority
    NICE = 13,
    /// Maximum realtime priority
    RTPRIO = 14,
    /// Maximum realtime timeout
    RTTIME = 15,
};

pub const RLIM_INFINITY: u64 = 0xFFFFFFFFFFFFFFFF;

/// Resource limit structure
pub const RLimit = struct {
    /// Soft limit (can be increased up to hard limit)
    soft: u64,
    /// Hard limit (maximum value, requires privilege to increase)
    hard: u64,

    pub fn init(soft: u64, hard: u64) RLimit {
        return .{ .soft = soft, .hard = hard };
    }

    pub fn unlimited() RLimit {
        return .{
            .soft = RLIM_INFINITY,
            .hard = RLIM_INFINITY,
        };
    }

    pub fn isUnlimited(self: RLimit) bool {
        return self.soft == RLIM_INFINITY;
    }
};

/// Default resource limits for new processes
pub const DEFAULT_LIMITS = [_]RLimit{
    // CPU: unlimited
    RLimit.unlimited(),
    // FSIZE: unlimited
    RLimit.unlimited(),
    // DATA: unlimited
    RLimit.unlimited(),
    // STACK: 8MB soft, unlimited hard
    RLimit.init(8 * 1024 * 1024, RLIM_INFINITY),
    // CORE: 0 (no core dumps by default)
    RLimit.init(0, RLIM_INFINITY),
    // RSS: unlimited
    RLimit.unlimited(),
    // NPROC: 4096 processes
    RLimit.init(4096, 8192),
    // NOFILE: 1024 soft, 4096 hard
    RLimit.init(1024, 4096),
    // MEMLOCK: 64KB
    RLimit.init(64 * 1024, 64 * 1024),
    // AS: unlimited
    RLimit.unlimited(),
    // LOCKS: unlimited
    RLimit.unlimited(),
    // SIGPENDING: 4096
    RLimit.init(4096, 8192),
    // MSGQUEUE: 800KB
    RLimit.init(800 * 1024, 1600 * 1024),
    // NICE: 0
    RLimit.init(0, 0),
    // RTPRIO: 0
    RLimit.init(0, 0),
    // RTTIME: unlimited
    RLimit.unlimited(),
};

// ============================================================================
// Process Resource Usage Tracking
// ============================================================================

/// Resource usage statistics
pub const ResourceUsage = struct {
    /// User CPU time used (microseconds)
    user_time_us: u64,
    /// System CPU time used (microseconds)
    system_time_us: u64,
    /// Maximum resident set size (bytes)
    max_rss: u64,
    /// Page faults not requiring I/O
    minor_faults: u64,
    /// Page faults requiring I/O
    major_faults: u64,
    /// Block input operations
    block_in: u64,
    /// Block output operations
    block_out: u64,
    /// Voluntary context switches
    vol_ctx_switches: u64,
    /// Involuntary context switches
    invol_ctx_switches: u64,

    pub fn init() ResourceUsage {
        return Basics.mem.zeroes(ResourceUsage);
    }

    pub fn addCpuTime(self: *ResourceUsage, user_us: u64, system_us: u64) void {
        _ = @atomicRmw(u64, &self.user_time_us, .Add, user_us, .Monotonic);
        _ = @atomicRmw(u64, &self.system_time_us, .Add, system_us, .Monotonic);
    }

    pub fn updateRss(self: *ResourceUsage, rss_bytes: u64) void {
        const current = @atomicLoad(u64, &self.max_rss, .Monotonic);
        if (rss_bytes > current) {
            _ = @cmpxchgStrong(u64, &self.max_rss, current, rss_bytes, .Monotonic, .Monotonic);
        }
    }

    pub fn recordFault(self: *ResourceUsage, major: bool) void {
        if (major) {
            _ = @atomicRmw(u64, &self.major_faults, .Add, 1, .Monotonic);
        } else {
            _ = @atomicRmw(u64, &self.minor_faults, .Add, 1, .Monotonic);
        }
    }

    pub fn recordContextSwitch(self: *ResourceUsage, voluntary: bool) void {
        if (voluntary) {
            _ = @atomicRmw(u64, &self.vol_ctx_switches, .Add, 1, .Monotonic);
        } else {
            _ = @atomicRmw(u64, &self.invol_ctx_switches, .Add, 1, .Monotonic);
        }
    }
};

// ============================================================================
// Resource Limit Enforcement
// ============================================================================

/// Check if a resource limit would be exceeded
pub fn checkLimit(proc: *process.Process, resource: ResourceType, amount: u64) bool {
    const limit_idx = @intFromEnum(resource);
    if (limit_idx >= proc.limits.len) return true;

    const limit = proc.limits[limit_idx];
    if (limit.isUnlimited()) return true;

    return amount <= limit.soft;
}

/// Enforce a resource limit, return error if exceeded
pub fn enforceLimit(proc: *process.Process, resource: ResourceType, amount: u64) !void {
    if (!checkLimit(proc, resource, amount)) {
        // Send SIGXCPU for CPU limits, otherwise fail the operation
        if (resource == .CPU) {
            const signal = @import("signal.zig");
            try signal.sendSignal(proc, .SIGXCPU, .{});
        }
        return error.ResourceLimitExceeded;
    }
}

/// Update current resource usage
pub fn updateUsage(proc: *process.Process, resource: ResourceType, current: u64) void {
    switch (resource) {
        .RSS => proc.rusage.updateRss(current),
        .CPU => {
            // CPU time is tracked separately in scheduler
        },
        else => {
            // Other resources tracked on-demand
        },
    }
}

/// Get current resource usage
pub fn getUsage(proc: *process.Process, resource: ResourceType) u64 {
    return switch (resource) {
        .CPU => proc.rusage.user_time_us + proc.rusage.system_time_us,
        .RSS => proc.rusage.max_rss,
        .NOFILE => proc.open_files.count(),
        .NPROC => countProcesses(proc.uid),
        else => 0,
    };
}

fn countProcesses(uid: u32) u64 {
    var count: u64 = 0;

    // Iterate all processes and count those owned by the specified UID
    var it = process.allProcesses();
    while (it.next()) |proc| {
        if (proc.uid == uid) {
            count += 1;
        }
    }

    return count;
}

// ============================================================================
// System Calls
// ============================================================================

/// Get resource limit (getrlimit syscall)
pub fn sysGetrlimit(resource: u32, rlim: *RLimit) !void {
    const current = process.getCurrent() orelse return error.NoCurrentProcess;

    if (resource >= current.limits.len) {
        return error.InvalidResource;
    }

    rlim.* = current.limits[resource];
}

/// Set resource limit (setrlimit syscall)
pub fn sysSetrlimit(resource: u32, rlim: *const RLimit) !void {
    const current = process.getCurrent() orelse return error.NoCurrentProcess;

    if (resource >= current.limits.len) {
        return error.InvalidResource;
    }

    // Check if user has permission to increase hard limit
    const old_limit = current.limits[resource];
    if (rlim.hard > old_limit.hard) {
        // Requires CAP_SYS_RESOURCE capability
        if (!current.hasCapability(.CAP_SYS_RESOURCE)) {
            return error.PermissionDenied;
        }
    }

    // Soft limit cannot exceed hard limit
    if (rlim.soft > rlim.hard) {
        return error.InvalidValue;
    }

    current.limits[resource] = rlim.*;
}

/// Get resource usage (getrusage syscall)
pub fn sysGetrusage(who: i32, rusage: *ResourceUsage) !void {
    const current = process.getCurrent() orelse return error.NoCurrentProcess;

    const target_rusage = switch (who) {
        0 => &current.rusage, // RUSAGE_SELF
        -1 => &current.children_rusage, // RUSAGE_CHILDREN
        else => return error.InvalidWho,
    };

    rusage.* = target_rusage.*;
}

// ============================================================================
// Out of Memory (OOM) Killer
// ============================================================================

const OOM_SCORE_ADJ_MIN: i16 = -1000;
const OOM_SCORE_ADJ_MAX: i16 = 1000;

/// Calculate OOM score for a process (higher score = more likely to be killed)
pub fn calculateOomScore(proc: *process.Process) i32 {
    // Base score: percentage of total RAM used
    const total_ram = memory.getTotalMemory();
    const proc_rss = proc.rusage.max_rss;
    var score: i32 = @intCast((proc_rss * 1000) / total_ram);

    // Adjust by user preference (oom_score_adj)
    score += proc.oom_score_adj;

    // Clamp to valid range
    if (score < 0) score = 0;
    if (score > 1000) score = 1000;

    return score;
}

/// Select a process to kill when out of memory
pub fn selectOomVictim() ?*process.Process {
    var highest_score: i32 = -1;
    var victim: ?*process.Process = null;

    // Iterate all processes and find the one with highest OOM score
    var it = process.allProcesses();
    while (it.next()) |proc| {
        // Skip kernel threads and init process
        if (proc.pid == 0 or proc.pid == 1) continue;

        // Skip processes with oom_score_adj = OOM_SCORE_ADJ_MIN (protected)
        if (proc.oom_score_adj == OOM_SCORE_ADJ_MIN) continue;

        const score = calculateOomScore(proc);
        if (score > highest_score) {
            highest_score = score;
            victim = proc;
        }
    }

    return victim;
}

/// Kill a process due to OOM condition
pub fn oomKill(proc: *process.Process) void {
    Basics.debug.print("OOM: Killing process {} ({s}) with score {}\n", .{
        proc.pid,
        proc.name,
        calculateOomScore(proc),
    });

    // Send SIGKILL
    const signal = @import("signal.zig");
    signal.sendSignal(proc, .SIGKILL, .{}) catch |err| {
        Basics.debug.print("OOM: Failed to send SIGKILL: {}\n", .{err});
    };
}

/// Handle out-of-memory condition
pub fn handleOom() void {
    Basics.debug.print("OOM: System is out of memory, selecting victim\n", .{});

    if (selectOomVictim()) |victim| {
        oomKill(victim);
    } else {
        Basics.debug.print("OOM: No suitable victim found, system may be unstable\n", .{});
        @panic("Out of memory and no process can be killed");
    }
}

// ============================================================================
// Tests
// ============================================================================

test "resource limits - default values" {
    const testing = Basics.testing;

    // Check default stack limit
    try testing.expectEqual(@as(u64, 8 * 1024 * 1024), DEFAULT_LIMITS[@intFromEnum(ResourceType.STACK)].soft);

    // Check unlimited resources
    try testing.expect(DEFAULT_LIMITS[@intFromEnum(ResourceType.CPU)].isUnlimited());
}

test "resource limits - enforcement" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    // Create a test process
    var proc = try process.Process.init(allocator, 1, "test");
    defer proc.deinit();

    // Set a file descriptor limit
    proc.limits[@intFromEnum(ResourceType.NOFILE)] = RLimit.init(10, 20);

    // Should succeed with 5 files
    try testing.expect(checkLimit(&proc, .NOFILE, 5));

    // Should fail with 15 files
    try testing.expect(!checkLimit(&proc, .NOFILE, 15));
}

test "resource usage - tracking" {
    const testing = Basics.testing;

    var usage = ResourceUsage.init();

    // Add CPU time
    usage.addCpuTime(1000, 500);
    try testing.expectEqual(@as(u64, 1000), usage.user_time_us);
    try testing.expectEqual(@as(u64, 500), usage.system_time_us);

    // Update RSS
    usage.updateRss(1024 * 1024);
    try testing.expectEqual(@as(u64, 1024 * 1024), usage.max_rss);

    // Record faults
    usage.recordFault(false);
    usage.recordFault(true);
    try testing.expectEqual(@as(u64, 1), usage.minor_faults);
    try testing.expectEqual(@as(u64, 1), usage.major_faults);
}

test "oom score calculation" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    var proc = try process.Process.init(allocator, 1, "test");
    defer proc.deinit();

    // Set RSS to 10% of total memory
    const total_mem = memory.getTotalMemory();
    proc.rusage.max_rss = total_mem / 10;

    // Score should be around 100 (10% * 1000)
    const score = calculateOomScore(&proc);
    try testing.expect(score >= 90 and score <= 110);

    // Adjust OOM score
    proc.oom_score_adj = 500;
    const adjusted_score = calculateOomScore(&proc);
    try testing.expect(adjusted_score >= score + 450 and adjusted_score <= score + 550);
}
