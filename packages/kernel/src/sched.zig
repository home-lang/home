// Home Programming Language - Thread Scheduler
// Preemptive multitasking scheduler with priority support

const Basics = @import("basics");
const thread_mod = @import("thread.zig");
const cpu_context = @import("cpu_context.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");
const assembly = @import("asm.zig");

const Thread = thread_mod.Thread;
const ThreadState = thread_mod.ThreadState;
const Priority = thread_mod.Priority;

// ============================================================================
// Scheduler Configuration
// ============================================================================

/// Time slice duration in milliseconds
pub const TIME_SLICE_MS: u64 = 10;

/// Number of priority levels (0-255)
pub const PRIORITY_LEVELS: usize = 256;

/// Idle priority (lowest)
pub const IDLE_PRIORITY: u8 = 0;

/// Maximum priority (highest)
pub const MAX_PRIORITY: u8 = 255;

// ============================================================================
// Run Queue (per-priority level)
// ============================================================================

pub const RunQueue = struct {
    head: ?*Thread,
    tail: ?*Thread,
    count: atomic.AtomicUsize,

    pub fn init() RunQueue {
        return .{
            .head = null,
            .tail = null,
            .count = atomic.AtomicUsize.init(0),
        };
    }

    /// Add thread to tail of run queue
    pub fn enqueue(self: *RunQueue, thread: *Thread) void {
        thread.sched_next = null;
        thread.sched_prev = self.tail;

        if (self.tail) |tail| {
            tail.sched_next = thread;
        } else {
            self.head = thread;
        }
        self.tail = thread;

        _ = self.count.fetchAdd(1, .Release);
    }

    /// Remove thread from head of run queue
    pub fn dequeue(self: *RunQueue) ?*Thread {
        const thread = self.head orelse return null;

        self.head = thread.sched_next;
        if (self.head == null) {
            self.tail = null;
        } else if (self.head) |head| {
            head.sched_prev = null;
        }

        thread.sched_next = null;
        thread.sched_prev = null;

        _ = self.count.fetchSub(1, .Release);
        return thread;
    }

    /// Remove specific thread from queue
    pub fn remove(self: *RunQueue, thread: *Thread) void {
        if (thread.sched_prev) |prev| {
            prev.sched_next = thread.sched_next;
        } else {
            self.head = thread.sched_next;
        }

        if (thread.sched_next) |next| {
            next.sched_prev = thread.sched_prev;
        } else {
            self.tail = thread.sched_prev;
        }

        thread.sched_next = null;
        thread.sched_prev = null;

        _ = self.count.fetchSub(1, .Release);
    }

    /// Peek at head without removing
    pub fn peek(self: *const RunQueue) ?*Thread {
        return self.head;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *const RunQueue) bool {
        return self.head == null;
    }

    /// Get number of threads in queue
    pub fn len(self: *const RunQueue) usize {
        return self.count.load(.Acquire);
    }
};

// ============================================================================
// Per-CPU Scheduler State
// ============================================================================

pub const CpuScheduler = struct {
    /// CPU ID
    cpu_id: u8,

    /// Currently running thread
    current: ?*Thread,

    /// Idle thread (runs when no other threads are ready)
    idle_thread: ?*Thread,

    /// Run queues (one per priority level)
    run_queues: [PRIORITY_LEVELS]RunQueue,

    /// Bitmap of non-empty run queues (for fast lookup)
    /// Bit N is set if run_queues[N] is non-empty
    priority_bitmap: [4]u64, // 256 bits total

    /// Scheduler lock
    lock: sync.IrqSpinlock,

    /// Statistics
    total_switches: atomic.AtomicU64,
    total_ticks: atomic.AtomicU64,

    pub fn init(cpu_id: u8) CpuScheduler {
        var sched = CpuScheduler{
            .cpu_id = cpu_id,
            .current = null,
            .idle_thread = null,
            .run_queues = undefined,
            .priority_bitmap = [_]u64{0} ** 4,
            .lock = sync.IrqSpinlock.init(),
            .total_switches = atomic.AtomicU64.init(0),
            .total_ticks = atomic.AtomicU64.init(0),
        };

        // Initialize all run queues
        for (&sched.run_queues) |*rq| {
            rq.* = RunQueue.init();
        }

        return sched;
    }

    /// Add thread to scheduler
    pub fn addThread(self: *CpuScheduler, thread: *Thread) void {
        // LOCK-FREE FAST PATH: Same-CPU enqueue
        // If we're enqueueing to the current CPU from the current CPU,
        // we can use a lock-free approach since there's no contention
        const current_cpu = asm.getCpuId();
        if (current_cpu == self.cpu_id and !asm.interruptsEnabled()) {
            // Fast path: local enqueue without lock
            thread.markReady();
            const priority = thread.priority;
            self.run_queues[priority].enqueue(thread);

            // Set bit in priority bitmap (no lock needed, we're the only writer)
            const word_idx = priority / 64;
            const bit_idx: u6 = @intCast(priority % 64);
            self.priority_bitmap[word_idx] |= @as(u64, 1) << bit_idx;
            return;
        }

        // Slow path: cross-CPU or contended enqueue
        self.lock.acquire();
        defer self.lock.release();

        thread.markReady();
        const priority = thread.priority;
        self.run_queues[priority].enqueue(thread);

        // Set bit in priority bitmap
        const word_idx = priority / 64;
        const bit_idx: u6 = @intCast(priority % 64);
        self.priority_bitmap[word_idx] |= @as(u64, 1) << bit_idx;
    }

    /// Remove thread from scheduler
    pub fn removeThread(self: *CpuScheduler, thread: *Thread) void {
        // LOCK-FREE FAST PATH: Same-CPU dequeue
        // If we're removing from the current CPU on the current CPU,
        // we can use a lock-free approach since there's no contention
        const current_cpu = asm.getCpuId();
        if (current_cpu == self.cpu_id and !asm.interruptsEnabled()) {
            if (thread.state != .Ready and thread.state != .Running) {
                return;
            }

            // Fast path: local dequeue without lock
            const priority = thread.priority;
            self.run_queues[priority].remove(thread);

            // Clear bit if queue is now empty (no lock needed, we're the only writer)
            if (self.run_queues[priority].isEmpty()) {
                const word_idx = priority / 64;
                const bit_idx: u6 = @intCast(priority % 64);
                self.priority_bitmap[word_idx] &= ~(@as(u64, 1) << bit_idx);
            }
            return;
        }

        // Slow path: cross-CPU or contended dequeue
        self.lock.acquire();
        defer self.lock.release();

        if (thread.state != .Ready and thread.state != .Running) {
            return;
        }

        const priority = thread.priority;
        self.run_queues[priority].remove(thread);

        // Clear bit if queue is now empty
        if (self.run_queues[priority].isEmpty()) {
            const word_idx = priority / 64;
            const bit_idx: u6 = @intCast(priority % 64);
            self.priority_bitmap[word_idx] &= ~(@as(u64, 1) << bit_idx);
        }
    }

    /// Find highest priority non-empty run queue
    fn findHighestPriority(self: *const CpuScheduler) ?u8 {
        // Search from highest to lowest priority
        var word_idx: usize = 4;
        while (word_idx > 0) {
            word_idx -= 1;
            const word = self.priority_bitmap[word_idx];
            if (word != 0) {
                // Find highest bit set
                const bit_idx = 63 - @clz(word);
                return @intCast(word_idx * 64 + bit_idx);
            }
        }
        return null;
    }

    /// Pick next thread to run (must be called with lock held)
    fn pickNextLocked(self: *CpuScheduler) ?*Thread {
        const priority = self.findHighestPriority() orelse return self.idle_thread;

        const next = self.run_queues[priority].dequeue() orelse return self.idle_thread;

        // Clear bit if queue is now empty
        if (self.run_queues[priority].isEmpty()) {
            const word_idx = priority / 64;
            const bit_idx: u6 = @intCast(priority % 64);
            self.priority_bitmap[word_idx] &= ~(@as(u64, 1) << bit_idx);
        }

        return next;
    }

    /// Pick next thread to run
    pub fn pickNext(self: *CpuScheduler) ?*Thread {
        self.lock.acquire();
        defer self.lock.release();
        return self.pickNextLocked();
    }

    /// Schedule next thread (context switch)
    pub fn schedule(self: *CpuScheduler) void {
        self.lock.acquire();

        const prev = self.current;
        const next = self.pickNextLocked();

        if (next == prev) {
            // Same thread, just continue
            self.lock.release();
            return;
        }

        // Put previous thread back in run queue if still runnable
        if (prev) |p| {
            if (p.isRunnable()) {
                self.run_queues[p.priority].enqueue(p);

                // Set bit in priority bitmap
                const word_idx = p.priority / 64;
                const bit_idx: u6 = @intCast(p.priority % 64);
                self.priority_bitmap[word_idx] |= @as(u64, 1) << bit_idx;
            }
        }

        // Switch to next thread
        if (next) |n| {
            n.markRunning(self.cpu_id);
            n.time_slice = TIME_SLICE_MS;
            self.current = n;
            _ = self.total_switches.fetchAdd(1, .Monotonic);
        } else {
            self.current = null;
        }

        self.lock.release();

        // Perform actual context switch
        if (prev != next) {
            self.contextSwitch(prev, next);
        }
    }

    /// Perform context switch (save old, restore new)
    fn contextSwitch(self: *CpuScheduler, prev: ?*Thread, next: ?*Thread) void {
        _ = self;

        if (prev) |p| {
            p.saveContext();
        }

        if (next) |n| {
            n.restoreContext();
            thread_mod.setCurrentThread(n);

            // Switch to new address space
            n.process.address_space.activate();
        }
    }

    /// Timer tick handler (called on each timer interrupt)
    pub fn tick(self: *CpuScheduler) void {
        _ = self.total_ticks.fetchAdd(1, .Monotonic);

        if (self.current) |thread| {
            if (thread.time_slice > 0) {
                thread.time_slice -= 1;
                thread.cpu_time += 1;

                if (thread.time_slice == 0) {
                    // Time slice expired, reschedule
                    self.schedule();
                }
            }
        }
    }

    /// Yield CPU to another thread
    pub fn yield(self: *CpuScheduler) void {
        // Force reschedule
        if (self.current) |thread| {
            thread.time_slice = 0;
        }
        self.schedule();
    }

    /// Get number of runnable threads
    pub fn countRunnable(self: *const CpuScheduler) usize {
        var count: usize = 0;
        for (self.run_queues) |*rq| {
            count += rq.len();
        }
        return count;
    }

    /// Get scheduler statistics
    pub fn getStats(self: *const CpuScheduler) SchedulerStats {
        return .{
            .cpu_id = self.cpu_id,
            .runnable = self.countRunnable(),
            .total_switches = self.total_switches.load(.Monotonic),
            .total_ticks = self.total_ticks.load(.Monotonic),
        };
    }
};

// ============================================================================
// Global Scheduler
// ============================================================================

const MAX_CPUS = 256;

var cpu_schedulers: [MAX_CPUS]?CpuScheduler = [_]?CpuScheduler{null} ** MAX_CPUS;
var num_cpus: atomic.AtomicU8 = atomic.AtomicU8.init(0);
var scheduler_lock = sync.Spinlock.init();

/// Initialize scheduler for a CPU
pub fn initCpu(cpu_id: u8) void {
    scheduler_lock.acquire();
    defer scheduler_lock.release();

    cpu_schedulers[cpu_id] = CpuScheduler.init(cpu_id);

    const current_num = num_cpus.load(.Acquire);
    if (cpu_id >= current_num) {
        num_cpus.store(cpu_id + 1, .Release);
    }
}

/// Get scheduler for specific CPU
pub fn getCpuScheduler(cpu_id: u8) ?*CpuScheduler {
    if (cpu_id >= MAX_CPUS) return null;
    if (cpu_schedulers[cpu_id]) |*sched| {
        return sched;
    }
    return null;
}

/// Get current CPU's scheduler
pub fn getCurrentScheduler() ?*CpuScheduler {
    // Get actual CPU ID from SMP/APIC subsystem
    const smp = @import("smp.zig");
    const cpu_id: u8 = @intCast(smp.getCurrentCpuId());
    return getCpuScheduler(cpu_id);
}

/// Add thread to scheduler (picks best CPU)
pub fn addThread(thread: *Thread) void {
    const cpu_id = pickCpuForThread(thread);
    if (getCpuScheduler(cpu_id)) |sched| {
        sched.addThread(thread);
    }
}

/// Remove thread from scheduler
pub fn removeThread(thread: *Thread) void {
    if (thread.state == .Running) {
        if (getCpuScheduler(thread.current_cpu)) |sched| {
            sched.removeThread(thread);
        }
    }
}

/// Pick best CPU for thread based on affinity and load
fn pickCpuForThread(thread: *Thread) u8 {
    const n = num_cpus.load(.Acquire);
    var best_cpu: u8 = 0;
    var min_load: usize = Basics.math.maxInt(usize);

    for (0..n) |cpu| {
        const cpu_id: u8 = @intCast(cpu);

        // Check if thread can run on this CPU
        if (!thread.canRunOnCpu(cpu_id)) continue;

        if (getCpuScheduler(cpu_id)) |sched| {
            const load = sched.countRunnable();
            if (load < min_load) {
                min_load = load;
                best_cpu = cpu_id;
            }
        }
    }

    return best_cpu;
}

/// Schedule on current CPU
pub fn schedule() void {
    if (getCurrentScheduler()) |sched| {
        sched.schedule();
    }
}

/// Yield current thread
pub fn yield() void {
    if (getCurrentScheduler()) |sched| {
        sched.yield();
    }
}

/// Timer tick for current CPU
pub fn tick() void {
    if (getCurrentScheduler()) |sched| {
        sched.tick();
    }
}

// ============================================================================
// Idle Thread
// ============================================================================

fn idleThreadEntry(arg: usize) void {
    _ = arg;
    while (true) {
        // Halt until interrupt
        asm.hlt();
    }
}

/// Create idle thread for CPU
pub fn createIdleThread(allocator: Basics.Allocator, cpu_id: u8) !void {
    const Process = @import("process.zig").Process;

    // Get or create kernel process
    var kernel_proc = Process.findProcess(0) orelse {
        const proc = try Process.create(allocator, "kernel");
        try Process.registerProcess(proc);
        proc;
    };

    var name_buf: [32]u8 = undefined;
    const name = try Basics.fmt.bufPrint(&name_buf, "idle/{d}", .{cpu_id});

    const idle = try thread_mod.createKernelThread(
        allocator,
        kernel_proc,
        idleThreadEntry,
        0,
        name,
    );

    idle.setPriority(.Idle);
    idle.pinToCpu(cpu_id);

    if (getCpuScheduler(cpu_id)) |sched| {
        sched.idle_thread = idle;
    }
}

// ============================================================================
// Load Balancing
// ============================================================================

/// Balance load across CPUs
pub fn balanceLoad() void {
    const n = num_cpus.load(.Acquire);
    if (n < 2) return; // Nothing to balance

    // Calculate average load
    var total_runnable: usize = 0;
    for (0..n) |cpu| {
        if (getCpuScheduler(@intCast(cpu))) |sched| {
            total_runnable += sched.countRunnable();
        }
    }

    const avg_load = total_runnable / n;

    // Move threads from overloaded CPUs to underloaded ones
    for (0..n) |cpu| {
        const cpu_id: u8 = @intCast(cpu);
        if (getCpuScheduler(cpu_id)) |sched| {
            const load = sched.countRunnable();
            if (load > avg_load + 1) {
                // Overloaded, try to move a thread
                migrateTh readFromCpu(sched);
            }
        }
    }
}

fn migrateThreadFromCpu(from_sched: *CpuScheduler) void {
    // Find a thread to migrate
    for (from_sched.run_queues) |*rq| {
        if (rq.peek()) |thread| {
            // Check if thread can run on other CPUs
            const n = num_cpus.load(.Acquire);
            for (0..n) |cpu| {
                const cpu_id: u8 = @intCast(cpu);
                if (cpu_id == from_sched.cpu_id) continue;
                if (!thread.canRunOnCpu(cpu_id)) continue;

                if (getCpuScheduler(cpu_id)) |to_sched| {
                    if (to_sched.countRunnable() < from_sched.countRunnable() - 1) {
                        // Migrate thread
                        from_sched.removeThread(thread);
                        to_sched.addThread(thread);
                        return;
                    }
                }
            }
        }
    }
}

// ============================================================================
// Statistics
// ============================================================================

pub const SchedulerStats = struct {
    cpu_id: u8,
    runnable: usize,
    total_switches: u64,
    total_ticks: u64,

    pub fn switchesPerSecond(self: SchedulerStats, ticks_per_second: u64) f64 {
        if (self.total_ticks == 0) return 0.0;
        const seconds: f64 = @as(f64, @floatFromInt(self.total_ticks)) / @as(f64, @floatFromInt(ticks_per_second));
        return @as(f64, @floatFromInt(self.total_switches)) / seconds;
    }
};

/// Get global scheduler statistics
pub fn getGlobalStats(allocator: Basics.Allocator) ![]SchedulerStats {
    const n = num_cpus.load(.Acquire);
    const stats = try allocator.alloc(SchedulerStats, n);

    for (0..n) |cpu| {
        if (getCpuScheduler(@intCast(cpu))) |sched| {
            stats[cpu] = sched.getStats();
        }
    }

    return stats;
}

// ============================================================================
// Tests
// ============================================================================

test "run queue" {
    const allocator = Basics.testing.allocator;

    const Process = @import("process.zig").Process;
    const proc = try Process.create(allocator, "test");
    defer proc.destroy();

    var rq = RunQueue.init();
    try Basics.testing.expect(rq.isEmpty());

    const t1 = try Thread.create(allocator, proc, 0x1000, 0, "t1");
    defer t1.destroy();
    const t2 = try Thread.create(allocator, proc, 0x1000, 0, "t2");
    defer t2.destroy();

    rq.enqueue(t1);
    try Basics.testing.expectEqual(@as(usize, 1), rq.len());
    try Basics.testing.expect(!rq.isEmpty());

    rq.enqueue(t2);
    try Basics.testing.expectEqual(@as(usize, 2), rq.len());

    const first = rq.dequeue().?;
    try Basics.testing.expectEqual(t1, first);
    try Basics.testing.expectEqual(@as(usize, 1), rq.len());

    const second = rq.dequeue().?;
    try Basics.testing.expectEqual(t2, second);
    try Basics.testing.expect(rq.isEmpty());
}

test "cpu scheduler" {
    const allocator = Basics.testing.allocator;

    const Process = @import("process.zig").Process;
    const proc = try Process.create(allocator, "test");
    defer proc.destroy();

    var sched = CpuScheduler.init(0);

    const t1 = try Thread.create(allocator, proc, 0x1000, 0, "t1");
    defer t1.destroy();
    t1.setPriority(.High);

    const t2 = try Thread.create(allocator, proc, 0x1000, 0, "t2");
    defer t2.destroy();
    t2.setPriority(.Low);

    sched.addThread(t1);
    sched.addThread(t2);

    try Basics.testing.expectEqual(@as(usize, 2), sched.countRunnable());

    // Should pick t1 (higher priority)
    const next = sched.pickNext().?;
    try Basics.testing.expectEqual(t1, next);
}

test "global scheduler init" {
    initCpu(0);
    initCpu(1);

    try Basics.testing.expectEqual(@as(u8, 2), num_cpus.load(.Acquire));

    const sched0 = getCpuScheduler(0);
    try Basics.testing.expect(sched0 != null);
    try Basics.testing.expectEqual(@as(u8, 0), sched0.?.cpu_id);

    const sched1 = getCpuScheduler(1);
    try Basics.testing.expect(sched1 != null);
    try Basics.testing.expectEqual(@as(u8, 1), sched1.?.cpu_id);
}
