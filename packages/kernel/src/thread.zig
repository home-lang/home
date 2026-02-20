// Home Programming Language - Thread Management
// Thread control and scheduling primitives

const Basics = @import("basics");
const memory = @import("memory.zig");
const cpu_context = @import("cpu_context.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// Forward declaration to avoid circular dependency
const Process = @import("process.zig").Process;

// ============================================================================
// Thread ID Management
// ============================================================================

pub const Tid = u64;

pub const INVALID_TID: Tid = 0;

var next_tid = atomic.AtomicU64.init(1);

pub fn allocateTid() Tid {
    return next_tid.fetchAdd(1, .Monotonic);
}

// ============================================================================
// Thread State
// ============================================================================

pub const ThreadState = enum(u8) {
    /// Thread is being created
    Created,
    /// Thread is ready to run
    Ready,
    /// Thread is currently running
    Running,
    /// Thread is blocked (waiting for event)
    Blocked,
    /// Thread is sleeping
    Sleeping,
    /// Thread has exited
    Dead,
};

// ============================================================================
// Thread Priority
// ============================================================================

pub const Priority = enum(u8) {
    Idle = 0,
    Low = 64,
    Normal = 128,
    High = 192,
    Realtime = 255,

    pub fn toU8(self: Priority) u8 {
        return @intFromEnum(self);
    }
};

// ============================================================================
// Thread-Local Storage
// ============================================================================

const TLS_SIZE = 4096; // 4KB for TLS

pub const Tls = struct {
    data: [TLS_SIZE]u8 align(16),

    pub fn init() Tls {
        return .{
            .data = [_]u8{0} ** TLS_SIZE,
        };
    }

    pub fn getPtr(self: *Tls) *anyopaque {
        return &self.data;
    }

    pub fn get(self: *Tls, comptime T: type, offset: usize) *T {
        return @ptrCast(@alignCast(&self.data[offset]));
    }

    pub fn set(self: *Tls, comptime T: type, offset: usize, value: T) void {
        const ptr = self.get(T, offset);
        ptr.* = value;
    }
};

// ============================================================================
// Thread Control Block (TCB)
// ============================================================================

pub const Thread = struct {
    /// Thread ID
    tid: Tid,
    /// Parent process
    process: *Process,
    /// Thread name
    name: [64]u8,
    name_len: usize,

    /// Current state
    state: ThreadState,
    /// Priority (0-255, higher = more important)
    priority: u8,
    /// Original priority (before any priority inheritance boost)
    original_priority: u8,
    /// True if priority has been boosted via priority inheritance
    priority_boosted: bool,
    /// CPU affinity mask (which CPUs this thread can run on)
    cpu_affinity: u64,
    /// Current CPU (if running)
    current_cpu: u8,

    /// CPU context (registers, stack pointer, etc.)
    context: cpu_context.CpuContext,
    /// Kernel stack
    kernel_stack: []u8,
    /// User stack (if user thread)
    user_stack: ?[]u8,

    /// Thread-local storage
    tls: Tls,

    /// Time slice remaining (in ticks)
    time_slice: u64,
    /// Total CPU time used (in ticks)
    cpu_time: u64,

    /// Exit code (valid when state == Dead)
    exit_code: i32,

    /// Wait queue this thread is on (if any)
    wait_queue: ?*WaitQueue,

    /// Next/previous in scheduler queue
    sched_next: ?*Thread,
    sched_prev: ?*Thread,

    /// Thread lock
    lock: sync.Spinlock,

    /// Allocator
    allocator: Basics.Allocator,

    /// Create a new thread
    pub fn create(
        allocator: Basics.Allocator,
        process: *Process,
        entry_point: usize,
        arg: usize,
        name: []const u8,
    ) !*Thread {
        const thread = try allocator.create(Thread);
        errdefer allocator.destroy(thread);

        // Allocate kernel stack (8KB)
        const kernel_stack = try allocator.alloc(u8, 8192);
        errdefer allocator.free(kernel_stack);

        var thread_name: [64]u8 = undefined;
        const name_len = Basics.math.min(name.len, 63);
        @memcpy(thread_name[0..name_len], name[0..name_len]);

        const default_priority = Priority.Normal.toU8();
        thread.* = .{
            .tid = allocateTid(),
            .process = process,
            .name = thread_name,
            .name_len = name_len,
            .state = .Created,
            .priority = default_priority,
            .original_priority = default_priority,
            .priority_boosted = false,
            .cpu_affinity = 0xFFFFFFFFFFFFFFFF, // All CPUs
            .current_cpu = 0,
            .context = cpu_context.CpuContext.init(),
            .kernel_stack = kernel_stack,
            .user_stack = null,
            .tls = Tls.init(),
            .time_slice = 0,
            .cpu_time = 0,
            .exit_code = 0,
            .wait_queue = null,
            .sched_next = null,
            .sched_prev = null,
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };

        // Setup initial context
        thread.setupContext(entry_point, arg);

        return thread;
    }

    /// Setup thread context for first run
    fn setupContext(self: *Thread, entry_point: usize, arg: usize) void {
        // Initialize stack pointer to top of kernel stack
        const stack_top = @intFromPtr(self.kernel_stack.ptr) + self.kernel_stack.len;
        self.context.rsp = stack_top;
        self.context.rbp = stack_top;

        // Set instruction pointer to entry point
        self.context.rip = entry_point;

        // Set first argument in RDI (System V calling convention)
        self.context.rdi = arg;

        // Set initial RFLAGS (enable interrupts)
        self.context.rflags.interrupt_enable = true;

        // Setup segments for kernel mode
        self.context.cs = 0x08; // Kernel code segment
        self.context.ss = 0x10; // Kernel data segment
        self.context.ds = 0x10;
        self.context.es = 0x10;
    }

    /// Destroy thread and free resources
    pub fn destroy(self: *Thread) void {
        self.lock.acquire();
        defer self.lock.release();

        // Free stacks
        self.allocator.free(self.kernel_stack);
        if (self.user_stack) |stack| {
            self.allocator.free(stack);
        }

        // Free thread structure
        self.allocator.destroy(self);
    }

    /// Get thread name
    pub fn getName(self: *const Thread) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Set thread priority
    pub fn setPriority(self: *Thread, priority: Priority) void {
        self.lock.acquire();
        defer self.lock.release();
        const new_priority = priority.toU8();
        self.priority = new_priority;
        // Update original priority if not currently boosted
        if (!self.priority_boosted) {
            self.original_priority = new_priority;
        }
    }

    /// Boost thread priority for priority inheritance
    /// Returns true if priority was actually boosted (not already higher)
    pub fn boostPriority(self: *Thread, new_priority: u8) bool {
        self.lock.acquire();
        defer self.lock.release();

        // Only boost if new priority is higher than current
        if (new_priority > self.priority) {
            if (!self.priority_boosted) {
                self.original_priority = self.priority;
            }
            self.priority = new_priority;
            self.priority_boosted = true;
            return true;
        }
        return false;
    }

    /// Restore thread's original priority after priority inheritance
    pub fn restorePriority(self: *Thread) void {
        self.lock.acquire();
        defer self.lock.release();

        if (self.priority_boosted) {
            self.priority = self.original_priority;
            self.priority_boosted = false;
        }
    }

    /// Set CPU affinity
    pub fn setAffinity(self: *Thread, cpu_mask: u64) void {
        self.lock.acquire();
        defer self.lock.release();
        self.cpu_affinity = cpu_mask;
    }

    /// Pin thread to specific CPU
    pub fn pinToCpu(self: *Thread, cpu: u8) void {
        self.setAffinity(@as(u64, 1) << @intCast(cpu));
    }

    /// Mark thread as ready to run
    pub fn markReady(self: *Thread) void {
        self.lock.acquire();
        defer self.lock.release();
        self.state = .Ready;
    }

    /// Mark thread as running
    pub fn markRunning(self: *Thread, cpu: u8) void {
        self.lock.acquire();
        defer self.lock.release();
        self.state = .Running;
        self.current_cpu = cpu;
    }

    /// Mark thread as blocked
    pub fn markBlocked(self: *Thread) void {
        self.lock.acquire();
        defer self.lock.release();
        self.state = .Blocked;
    }

    /// Mark thread as dead
    pub fn markDead(self: *Thread, exit_code: i32) void {
        self.lock.acquire();
        defer self.lock.release();
        self.state = .Dead;
        self.exit_code = exit_code;
    }

    /// Check if thread can run
    pub fn isRunnable(self: *const Thread) bool {
        return self.state == .Ready or self.state == .Running;
    }

    /// Check if thread is alive
    pub fn isAlive(self: *const Thread) bool {
        return self.state != .Dead;
    }

    /// Can thread run on given CPU?
    pub fn canRunOnCpu(self: *const Thread, cpu: u8) bool {
        return (self.cpu_affinity & (@as(u64, 1) << @intCast(cpu))) != 0;
    }

    /// Save current CPU context
    pub fn saveContext(self: *Thread) void {
        // This would be called during context switch
        // For now, it's a placeholder
        _ = self;
    }

    /// Restore CPU context
    pub fn restoreContext(self: *Thread) void {
        // This would be called during context switch
        _ = self;
    }

    /// Format for printing
    pub fn format(
        self: Thread,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "Thread[{d}] '{s}' state={s} prio={d} cpu={d}",
            .{
                self.tid,
                self.getName(),
                @tagName(self.state),
                self.priority,
                self.current_cpu,
            },
        );
    }
};

// ============================================================================
// Wait Queue (for blocking threads)
// ============================================================================

pub const WaitQueue = struct {
    head: ?*Thread,
    tail: ?*Thread,
    lock: sync.Spinlock,

    pub fn init() WaitQueue {
        return .{
            .head = null,
            .tail = null,
            .lock = sync.Spinlock.init(),
        };
    }

    /// Add thread to wait queue and block it
    pub fn wait(self: *WaitQueue, thread: *Thread) void {
        self.lock.acquire();
        defer self.lock.release();

        thread.markBlocked();
        thread.wait_queue = self;

        // Add to tail
        thread.sched_next = null;
        thread.sched_prev = self.tail;

        if (self.tail) |tail| {
            tail.sched_next = thread;
        } else {
            self.head = thread;
        }
        self.tail = thread;
    }

    /// Wake up one thread from queue
    pub fn wakeOne(self: *WaitQueue) ?*Thread {
        self.lock.acquire();
        defer self.lock.release();

        const thread = self.head orelse return null;

        // Remove from queue
        self.head = thread.sched_next;
        if (self.head == null) {
            self.tail = null;
        } else if (self.head) |head| {
            head.sched_prev = null;
        }

        thread.sched_next = null;
        thread.sched_prev = null;
        thread.wait_queue = null;
        thread.markReady();

        return thread;
    }

    /// Wake up all threads from queue
    pub fn wakeAll(self: *WaitQueue) void {
        while (self.wakeOne()) |_| {}
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *const WaitQueue) bool {
        return self.head == null;
    }
};

// ============================================================================
// Thread Sleep Support
// ============================================================================

/// Sleep for specified milliseconds
pub fn sleep(thread: *Thread, milliseconds: u64) void {
    const sched = @import("sched.zig");
    const timer_mod = @import("timer.zig");

    // Calculate wake time
    thread.wake_time = timer_mod.getTicks() + milliseconds;

    // Set thread to sleeping state
    thread.lock.acquire();
    thread.state = .Sleeping;
    thread.lock.release();

    // Yield to scheduler to let other threads run
    sched.yield();
}

/// Wake up a sleeping thread
pub fn wake(thread: *Thread) void {
    const sched = @import("sched.zig");

    thread.lock.acquire();
    defer thread.lock.release();

    if (thread.state == .Sleeping) {
        thread.state = .Ready;
        // Add back to scheduler run queue
        sched.addThread(thread);
    }
}

// ============================================================================
// Thread Exit
// ============================================================================

/// Exit current thread with exit code
pub fn exit(thread: *Thread, exit_code: i32) void {
    const sched = @import("sched.zig");

    thread.markDead(exit_code);

    // Remove from process thread list
    thread.process.removeThread(thread);

    // Remove from scheduler run queue
    sched.removeThread(thread);

    // Wake up any threads waiting to join this thread
    thread.join_waiters.wakeAll();

    // Schedule next thread (thread resources cleaned up when joined or GC'd)
    sched.schedule();
}

/// Join thread (wait for it to finish)
pub fn join(target: *Thread) i32 {
    const sched = @import("sched.zig");

    // Block until target thread is dead
    while (target.isAlive()) {
        // Add current thread to join waiters and yield
        target.join_waiters.add(getCurrentThread() orelse break);
        sched.yield();
    }

    return target.exit_code;
}

// ============================================================================
// Kernel Thread Creation
// ============================================================================

/// Create a kernel thread (runs in kernel space only)
pub fn createKernelThread(
    allocator: Basics.Allocator,
    process: *Process,
    entry: fn (arg: usize) void,
    arg: usize,
    name: []const u8,
) !*Thread {
    const entry_addr = @intFromPtr(entry);
    const thread = try Thread.create(allocator, process, entry_addr, arg, name);
    try process.addThread(thread);
    thread.markReady();
    return thread;
}

/// Create a user thread (can run in user space)
pub fn createUserThread(
    allocator: Basics.Allocator,
    process: *Process,
    entry_point: usize,
    arg: usize,
    name: []const u8,
) !*Thread {
    const thread = try Thread.create(allocator, process, entry_point, arg, name);
    errdefer thread.destroy();

    // Allocate user stack (8KB)
    thread.user_stack = try allocator.alloc(u8, 8192);

    // Setup user mode context
    thread.context.cs = 0x1B; // User code segment (ring 3)
    thread.context.ss = 0x23; // User data segment (ring 3)
    thread.context.rflags.interrupt_enable = true;

    const user_stack_top = @intFromPtr(thread.user_stack.?.ptr) + thread.user_stack.?.len;
    thread.context.rsp = user_stack_top;
    thread.context.rbp = user_stack_top;

    try process.addThread(thread);
    thread.markReady();

    return thread;
}

// ============================================================================
// Global Current Thread (Per-CPU)
// ============================================================================

// In a real implementation, this would be per-CPU
var current_thread: ?*Thread = null;
var current_thread_lock = sync.Spinlock.init();

/// Get current running thread
pub fn getCurrentThread() ?*Thread {
    current_thread_lock.acquire();
    defer current_thread_lock.release();
    return current_thread;
}

/// Set current running thread
pub fn setCurrentThread(thread: ?*Thread) void {
    current_thread_lock.acquire();
    defer current_thread_lock.release();
    current_thread = thread;
}

// ============================================================================
// Tests
// ============================================================================

test "thread creation" {
    const allocator = Basics.testing.allocator;

    // Need a process first
    const Process_impl = @import("process.zig");
    const proc = try Process_impl.Process.create(allocator, "test");
    defer proc.destroy();

    const thread = try Thread.create(allocator, proc, 0x1000, 0, "test_thread");
    defer thread.destroy();

    try Basics.testing.expect(thread.tid > 0);
    try Basics.testing.expectEqualStrings("test_thread", thread.getName());
    try Basics.testing.expectEqual(ThreadState.Created, thread.state);
}

test "thread priority" {
    const allocator = Basics.testing.allocator;

    const Process_impl = @import("process.zig");
    const proc = try Process_impl.Process.create(allocator, "test");
    defer proc.destroy();

    const thread = try Thread.create(allocator, proc, 0x1000, 0, "test");
    defer thread.destroy();

    try Basics.testing.expectEqual(Priority.Normal.toU8(), thread.priority);

    thread.setPriority(.High);
    try Basics.testing.expectEqual(Priority.High.toU8(), thread.priority);
}

test "thread affinity" {
    const allocator = Basics.testing.allocator;

    const Process_impl = @import("process.zig");
    const proc = try Process_impl.Process.create(allocator, "test");
    defer proc.destroy();

    const thread = try Thread.create(allocator, proc, 0x1000, 0, "test");
    defer thread.destroy();

    // Default: can run on all CPUs
    try Basics.testing.expect(thread.canRunOnCpu(0));
    try Basics.testing.expect(thread.canRunOnCpu(1));

    // Pin to CPU 2
    thread.pinToCpu(2);
    try Basics.testing.expect(!thread.canRunOnCpu(0));
    try Basics.testing.expect(!thread.canRunOnCpu(1));
    try Basics.testing.expect(thread.canRunOnCpu(2));
}

test "wait queue" {
    const allocator = Basics.testing.allocator;

    const Process_impl = @import("process.zig");
    const proc = try Process_impl.Process.create(allocator, "test");
    defer proc.destroy();

    var wq = WaitQueue.init();

    const t1 = try Thread.create(allocator, proc, 0x1000, 0, "t1");
    defer t1.destroy();
    const t2 = try Thread.create(allocator, proc, 0x1000, 0, "t2");
    defer t2.destroy();

    try Basics.testing.expect(wq.isEmpty());

    wq.wait(t1);
    try Basics.testing.expect(!wq.isEmpty());
    try Basics.testing.expectEqual(ThreadState.Blocked, t1.state);

    wq.wait(t2);
    try Basics.testing.expectEqual(ThreadState.Blocked, t2.state);

    const woken = wq.wakeOne().?;
    try Basics.testing.expectEqual(t1, woken);
    try Basics.testing.expectEqual(ThreadState.Ready, woken.state);

    wq.wakeAll();
    try Basics.testing.expect(wq.isEmpty());
}

test "TLS" {
    var tls = Tls.init();

    tls.set(u64, 0, 0x123456789ABCDEF0);
    try Basics.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), tls.get(u64, 0).*);

    tls.set(u32, 8, 0xDEADBEEF);
    try Basics.testing.expectEqual(@as(u32, 0xDEADBEEF), tls.get(u32, 8).*);
}
