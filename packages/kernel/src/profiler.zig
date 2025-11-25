// Home Programming Language - Kernel Profiler
// CPU profiling, memory profiling, and lock contention tracking

const Basics = @import("basics");
const sync = @import("sync.zig");
const timer = @import("timer.zig");
const process = @import("process.zig");
const thread = @import("thread.zig");

// ============================================================================
// Profiling Configuration
// ============================================================================

pub const ProfilerConfig = struct {
    enabled: bool = false,
    sample_frequency_hz: u32 = 100, // Sample 100 times per second
    stack_depth: u32 = 16,
    track_memory: bool = true,
    track_locks: bool = true,
};

// ============================================================================
// CPU Profiling
// ============================================================================

pub const CpuSample = struct {
    instruction_pointer: u64,
    stack_trace: [16]u64,
    stack_depth: u8,
    cpu_id: u8,
    process_id: u32,
    thread_id: u32,
    timestamp: u64,

    pub fn init(ip: u64, cpu: u8) CpuSample {
        return .{
            .instruction_pointer = ip,
            .stack_trace = [_]u64{0} ** 16,
            .stack_depth = 0,
            .cpu_id = cpu,
            .process_id = 0,
            .thread_id = 0,
            .timestamp = timer.getTimeNs(),
        };
    }
};

pub const CpuProfile = struct {
    samples: Basics.ArrayList(CpuSample),
    sample_count: u64,
    lost_samples: u64,
    lock: sync.RwLock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) CpuProfile {
        return .{
            .samples = Basics.ArrayList(CpuSample).init(allocator),
            .sample_count = 0,
            .lost_samples = 0,
            .lock = sync.RwLock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CpuProfile) void {
        self.samples.deinit();
    }

    pub fn addSample(self: *CpuProfile, sample: CpuSample) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        try self.samples.append(sample);
        self.sample_count += 1;
    }

    pub fn getSamples(self: *CpuProfile) []const CpuSample {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        return self.samples.items;
    }

    pub fn clear(self: *CpuProfile) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        self.samples.clearRetainingCapacity();
        self.sample_count = 0;
        self.lost_samples = 0;
    }

    pub fn getHotFunctions(self: *CpuProfile, allocator: Basics.Allocator, top_n: usize) ![]HotFunction {
        var function_counts = Basics.AutoHashMap(u64, u64).init(allocator);
        defer function_counts.deinit();

        // Count samples per function
        for (self.samples.items) |sample| {
            const count = function_counts.get(sample.instruction_pointer) orelse 0;
            try function_counts.put(sample.instruction_pointer, count + 1);
        }

        // Convert to array and sort
        var hot_functions = Basics.ArrayList(HotFunction).init(allocator);
        var it = function_counts.iterator();
        while (it.next()) |entry| {
            try hot_functions.append(.{
                .address = entry.key_ptr.*,
                .sample_count = entry.value_ptr.*,
                .percentage = @as(f64, @floatFromInt(entry.value_ptr.*)) / @as(f64, @floatFromInt(self.sample_count)) * 100.0,
            });
        }

        // Sort by sample count (descending)
        Basics.sort.pdq(HotFunction, hot_functions.items, {}, struct {
            fn lessThan(_: void, a: HotFunction, b: HotFunction) bool {
                return a.sample_count > b.sample_count;
            }
        }.lessThan);

        // Return top N
        const count = Basics.math.min(top_n, hot_functions.items.len);
        const result = try allocator.alloc(HotFunction, count);
        @memcpy(result, hot_functions.items[0..count]);

        return result;
    }
};

pub const HotFunction = struct {
    address: u64,
    sample_count: u64,
    percentage: f64,
};

// ============================================================================
// Memory Profiling
// ============================================================================

pub const MemoryAllocation = struct {
    address: u64,
    size: usize,
    timestamp: u64,
    stack_trace: [8]u64,
    stack_depth: u8,

    pub fn init(addr: u64, size: usize) MemoryAllocation {
        return .{
            .address = addr,
            .size = size,
            .timestamp = timer.getTimeNs(),
            .stack_trace = [_]u64{0} ** 8,
            .stack_depth = 0,
        };
    }
};

pub const MemoryProfile = struct {
    allocations: Basics.AutoHashMap(u64, MemoryAllocation),
    total_allocated: u64,
    total_freed: u64,
    current_usage: u64,
    peak_usage: u64,
    allocation_count: u64,
    free_count: u64,
    lock: sync.RwLock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) MemoryProfile {
        return .{
            .allocations = Basics.AutoHashMap(u64, MemoryAllocation).init(allocator),
            .total_allocated = 0,
            .total_freed = 0,
            .current_usage = 0,
            .peak_usage = 0,
            .allocation_count = 0,
            .free_count = 0,
            .lock = sync.RwLock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryProfile) void {
        self.allocations.deinit();
    }

    pub fn trackAllocation(self: *MemoryProfile, address: u64, size: usize) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const alloc = MemoryAllocation.init(address, size);
        try self.allocations.put(address, alloc);

        self.total_allocated += size;
        self.current_usage += size;
        self.allocation_count += 1;

        if (self.current_usage > self.peak_usage) {
            self.peak_usage = self.current_usage;
        }
    }

    pub fn trackFree(self: *MemoryProfile, address: u64) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (self.allocations.fetchRemove(address)) |entry| {
            self.total_freed += entry.value.size;
            self.current_usage -= entry.value.size;
            self.free_count += 1;
        }
    }

    pub fn getStats(self: *MemoryProfile) MemoryStats {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        return .{
            .total_allocated = self.total_allocated,
            .total_freed = self.total_freed,
            .current_usage = self.current_usage,
            .peak_usage = self.peak_usage,
            .allocation_count = self.allocation_count,
            .free_count = self.free_count,
            .active_allocations = self.allocations.count(),
        };
    }

    pub fn detectLeaks(self: *MemoryProfile, allocator: Basics.Allocator) ![]MemoryAllocation {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        var leaks = Basics.ArrayList(MemoryAllocation).init(allocator);
        var it = self.allocations.valueIterator();

        while (it.next()) |alloc| {
            try leaks.append(alloc.*);
        }

        return leaks.toOwnedSlice();
    }
};

pub const MemoryStats = struct {
    total_allocated: u64,
    total_freed: u64,
    current_usage: u64,
    peak_usage: u64,
    allocation_count: u64,
    free_count: u64,
    active_allocations: usize,
};

// ============================================================================
// Lock Contention Tracking
// ============================================================================

pub const LockContention = struct {
    lock_address: u64,
    wait_time_ns: u64,
    hold_time_ns: u64,
    contention_count: u64,
    stack_trace: [8]u64,
    stack_depth: u8,

    pub fn init(addr: u64) LockContention {
        return .{
            .lock_address = addr,
            .wait_time_ns = 0,
            .hold_time_ns = 0,
            .contention_count = 0,
            .stack_trace = [_]u64{0} ** 8,
            .stack_depth = 0,
        };
    }
};

pub const LockProfile = struct {
    locks: Basics.AutoHashMap(u64, LockContention),
    lock: sync.RwLock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) LockProfile {
        return .{
            .locks = Basics.AutoHashMap(u64, LockContention).init(allocator),
            .lock = sync.RwLock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LockProfile) void {
        self.locks.deinit();
    }

    pub fn trackWait(self: *LockProfile, lock_addr: u64, wait_time: u64) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var entry = self.locks.getPtr(lock_addr) orelse blk: {
            try self.locks.put(lock_addr, LockContention.init(lock_addr));
            break :blk self.locks.getPtr(lock_addr).?;
        };

        entry.wait_time_ns += wait_time;
        entry.contention_count += 1;
    }

    pub fn trackHold(self: *LockProfile, lock_addr: u64, hold_time: u64) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var entry = self.locks.getPtr(lock_addr) orelse blk: {
            try self.locks.put(lock_addr, LockContention.init(lock_addr));
            break :blk self.locks.getPtr(lock_addr).?;
        };

        entry.hold_time_ns += hold_time;
    }

    pub fn getContentionList(self: *LockProfile, allocator: Basics.Allocator) ![]LockContention {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        var list = Basics.ArrayList(LockContention).init(allocator);
        var it = self.locks.valueIterator();

        while (it.next()) |contention| {
            try list.append(contention.*);
        }

        // Sort by wait time (descending)
        Basics.sort.pdq(LockContention, list.items, {}, struct {
            fn lessThan(_: void, a: LockContention, b: LockContention) bool {
                return a.wait_time_ns > b.wait_time_ns;
            }
        }.lessThan);

        return list.toOwnedSlice();
    }
};

// ============================================================================
// Global Profiler
// ============================================================================

pub const Profiler = struct {
    config: ProfilerConfig,
    cpu_profile: CpuProfile,
    memory_profile: MemoryProfile,
    lock_profile: LockProfile,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, config: ProfilerConfig) Profiler {
        return .{
            .config = config,
            .cpu_profile = CpuProfile.init(allocator),
            .memory_profile = MemoryProfile.init(allocator),
            .lock_profile = LockProfile.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Profiler) void {
        self.cpu_profile.deinit();
        self.memory_profile.deinit();
        self.lock_profile.deinit();
    }

    pub fn start(self: *Profiler) void {
        self.config.enabled = true;
        // Setup timer interrupt for sampling using Local APIC timer
        const apic = @import("apic.zig");
        if (apic.getLocalApic()) |local_apic| {
            // Configure APIC timer for periodic sampling at sampling_interval
            local_apic.setupPeriodicTimer(self.config.sampling_interval, 0xF0);
        }
    }

    pub fn stop(self: *Profiler) void {
        self.config.enabled = false;
        // Disable timer interrupt by stopping the Local APIC timer
        const apic = @import("apic.zig");
        if (apic.getLocalApic()) |local_apic| {
            local_apic.stopTimer();
        }
    }

    pub fn handleTimerInterrupt(self: *Profiler, ip: u64, cpu: u8) !void {
        if (!self.config.enabled) return;

        var sample = CpuSample.init(ip, cpu);

        if (process.current()) |proc| {
            sample.process_id = proc.pid;
        }

        if (thread.current()) |thr| {
            sample.thread_id = thr.tid;
        }

        // Capture stack trace by walking frame pointers
        // Stack frames: [rbp] -> [prev rbp, return addr, ...]
        // Limited to 8 frames for sample storage
        const stack = @import("stack_trace.zig");
        sample.stack_depth = stack.captureStackTrace(&sample.stack_trace, 8);

        try self.cpu_profile.addSample(sample);
    }

    pub fn printReport(self: *Profiler) !void {
        Basics.debug.print("\n=== Profiler Report ===\n\n", .{});

        // CPU Profile
        Basics.debug.print("CPU Profile:\n", .{});
        Basics.debug.print("  Total samples: {d}\n", .{self.cpu_profile.sample_count});
        Basics.debug.print("  Lost samples: {d}\n", .{self.cpu_profile.lost_samples});

        const hot_functions = try self.cpu_profile.getHotFunctions(self.allocator, 10);
        defer self.allocator.free(hot_functions);

        Basics.debug.print("\n  Top 10 Hot Functions:\n", .{});
        for (hot_functions, 0..) |func, i| {
            Basics.debug.print("    {d}. 0x{x:0>16} - {d} samples ({d:.2}%)\n", .{
                i + 1,
                func.address,
                func.sample_count,
                func.percentage,
            });
        }

        // Memory Profile
        const mem_stats = self.memory_profile.getStats();
        Basics.debug.print("\nMemory Profile:\n", .{});
        Basics.debug.print("  Total allocated: {d} bytes\n", .{mem_stats.total_allocated});
        Basics.debug.print("  Total freed: {d} bytes\n", .{mem_stats.total_freed});
        Basics.debug.print("  Current usage: {d} bytes\n", .{mem_stats.current_usage});
        Basics.debug.print("  Peak usage: {d} bytes\n", .{mem_stats.peak_usage});
        Basics.debug.print("  Allocations: {d}\n", .{mem_stats.allocation_count});
        Basics.debug.print("  Frees: {d}\n", .{mem_stats.free_count});
        Basics.debug.print("  Active allocations: {d}\n", .{mem_stats.active_allocations});

        // Lock Contention
        const contentions = try self.lock_profile.getContentionList(self.allocator);
        defer self.allocator.free(contentions);

        Basics.debug.print("\nLock Contention (Top 5):\n", .{});
        const lock_count = Basics.math.min(5, contentions.len);
        for (contentions[0..lock_count], 0..) |contention, i| {
            Basics.debug.print("  {d}. Lock 0x{x:0>16}\n", .{ i + 1, contention.lock_address });
            Basics.debug.print("     Wait time: {d} ns\n", .{contention.wait_time_ns});
            Basics.debug.print("     Hold time: {d} ns\n", .{contention.hold_time_ns});
            Basics.debug.print("     Contentions: {d}\n", .{contention.contention_count});
        }
    }
};

// ============================================================================
// Global Profiler Instance
// ============================================================================

var global_profiler: ?Profiler = null;
var profiler_lock = sync.Spinlock.init();

pub fn getProfiler() *Profiler {
    profiler_lock.acquire();
    defer profiler_lock.release();

    if (global_profiler == null) {
        const config = ProfilerConfig{};
        global_profiler = Profiler.init(Basics.heap.page_allocator, config);
    }

    return &global_profiler.?;
}

// ============================================================================
// Convenience Functions
// ============================================================================

pub fn startProfiling() void {
    const profiler = getProfiler();
    profiler.start();
}

pub fn stopProfiling() void {
    const profiler = getProfiler();
    profiler.stop();
}

pub fn printProfilingReport() !void {
    const profiler = getProfiler();
    try profiler.printReport();
}

// ============================================================================
// Tests
// ============================================================================

test "cpu profiling" {
    const allocator = Basics.testing.allocator;
    var profile = CpuProfile.init(allocator);
    defer profile.deinit();

    var sample = CpuSample.init(0x1000, 0);
    try profile.addSample(sample);

    try Basics.testing.expectEqual(@as(u64, 1), profile.sample_count);
}

test "memory profiling" {
    const allocator = Basics.testing.allocator;
    var profile = MemoryProfile.init(allocator);
    defer profile.deinit();

    try profile.trackAllocation(0x1000, 100);
    try profile.trackAllocation(0x2000, 200);

    var stats = profile.getStats();
    try Basics.testing.expectEqual(@as(u64, 300), stats.total_allocated);
    try Basics.testing.expectEqual(@as(u64, 300), stats.current_usage);
    try Basics.testing.expectEqual(@as(usize, 2), stats.active_allocations);

    profile.trackFree(0x1000);
    stats = profile.getStats();
    try Basics.testing.expectEqual(@as(u64, 200), stats.current_usage);
    try Basics.testing.expectEqual(@as(usize, 1), stats.active_allocations);
}

test "lock contention tracking" {
    const allocator = Basics.testing.allocator;
    var profile = LockProfile.init(allocator);
    defer profile.deinit();

    try profile.trackWait(0x1000, 1000);
    try profile.trackWait(0x1000, 2000);
    try profile.trackHold(0x1000, 500);

    const contentions = try profile.getContentionList(allocator);
    defer allocator.free(contentions);

    try Basics.testing.expectEqual(@as(usize, 1), contentions.len);
    try Basics.testing.expectEqual(@as(u64, 3000), contentions[0].wait_time_ns);
    try Basics.testing.expectEqual(@as(u64, 2), contentions[0].contention_count);
}
