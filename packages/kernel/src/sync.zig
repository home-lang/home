// Home Programming Language - Kernel Synchronization Primitives
// Type-safe locks and synchronization for OS development

const Basics = @import("basics");
const assembly = @import("asm.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// Spinlock
// ============================================================================

pub const Spinlock = struct {
    locked: atomic.AtomicFlag,

    pub fn init() Spinlock {
        return .{ .locked = atomic.AtomicFlag.init(false) };
    }

    /// Acquire the lock
    pub fn acquire(self: *Spinlock) void {
        while (self.locked.testAndSet(.Acquire)) {
            // Spin with pause to reduce power and improve SMT performance
            while (self.locked.test(.Relaxed)) {
                asm.pause();
            }
        }
    }

    /// Try to acquire the lock without blocking
    pub fn tryAcquire(self: *Spinlock) bool {
        return !self.locked.testAndSet(.Acquire);
    }

    /// Release the lock
    pub fn release(self: *Spinlock) void {
        self.locked.clear(.Release);
    }

    /// Execute a function while holding the lock
    pub fn withLock(self: *Spinlock, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
        self.acquire();
        defer self.release();
        return @call(.auto, func, args);
    }
};

// ============================================================================
// IRQ Spinlock (disables interrupts)
// ============================================================================

pub const IrqSpinlock = struct {
    locked: atomic.AtomicFlag,
    irq_state: bool,

    pub fn init() IrqSpinlock {
        return .{
            .locked = atomic.AtomicFlag.init(false),
            .irq_state = false,
        };
    }

    /// Acquire the lock and disable interrupts
    pub fn acquire(self: *IrqSpinlock) void {
        self.irq_state = asm.interruptsEnabled();
        asm.cli();

        while (self.locked.testAndSet(.Acquire)) {
            asm.sti(); // Re-enable interrupts while spinning
            while (self.locked.test(.Relaxed)) {
                asm.pause();
            }
            asm.cli();
        }
    }

    /// Try to acquire the lock
    pub fn tryAcquire(self: *IrqSpinlock) bool {
        self.irq_state = asm.interruptsEnabled();
        asm.cli();

        if (!self.locked.testAndSet(.Acquire)) {
            return true;
        }

        // Failed to acquire, restore interrupt state
        if (self.irq_state) {
            asm.sti();
        }
        return false;
    }

    /// Release the lock and restore interrupt state
    pub fn release(self: *IrqSpinlock) void {
        self.locked.clear(.Release);
        if (self.irq_state) {
            asm.sti();
        }
    }

    /// Execute a function while holding the lock
    pub fn withLock(self: *IrqSpinlock, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
        self.acquire();
        defer self.release();
        return @call(.auto, func, args);
    }
};

// ============================================================================
// Reader-Writer Spinlock
// ============================================================================

pub const RwSpinlock = struct {
    // High bit indicates writer, lower bits count readers
    state: atomic.AtomicU32,

    const WRITER_BIT: u32 = 1 << 31;
    const READER_MASK: u32 = WRITER_BIT - 1;

    pub fn init() RwSpinlock {
        return .{ .state = atomic.AtomicU32.init(0) };
    }

    /// Acquire read lock
    pub fn acquireRead(self: *RwSpinlock) void {
        while (true) {
            var current = self.state.load(.Acquire);

            // Wait if there's a writer
            if (current & WRITER_BIT != 0) {
                asm.pause();
                continue;
            }

            // Try to increment reader count
            const new_state = current + 1;
            if (self.state.compareExchange(current, new_state, .Acquire, .Acquire) == null) {
                break;
            }
        }
    }

    /// Try to acquire read lock
    pub fn tryAcquireRead(self: *RwSpinlock) bool {
        var current = self.state.load(.Acquire);

        if (current & WRITER_BIT != 0) {
            return false;
        }

        const new_state = current + 1;
        return self.state.compareExchange(current, new_state, .Acquire, .Acquire) == null;
    }

    /// Release read lock
    pub fn releaseRead(self: *RwSpinlock) void {
        _ = self.state.fetchSub(1, .Release);
    }

    /// Acquire write lock
    pub fn acquireWrite(self: *RwSpinlock) void {
        while (true) {
            var current = self.state.load(.Acquire);

            // Wait if there are any readers or writers
            if (current != 0) {
                asm.pause();
                continue;
            }

            // Try to set writer bit
            if (self.state.compareExchange(current, WRITER_BIT, .Acquire, .Acquire) == null) {
                break;
            }
        }
    }

    /// Try to acquire write lock
    pub fn tryAcquireWrite(self: *RwSpinlock) bool {
        const current = self.state.load(.Acquire);

        if (current != 0) {
            return false;
        }

        return self.state.compareExchange(current, WRITER_BIT, .Acquire, .Acquire) == null;
    }

    /// Release write lock
    pub fn releaseWrite(self: *RwSpinlock) void {
        self.state.store(0, .Release);
    }

    /// Execute a function while holding read lock
    pub fn withReadLock(self: *RwSpinlock, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
        self.acquireRead();
        defer self.releaseRead();
        return @call(.auto, func, args);
    }

    /// Execute a function while holding write lock
    pub fn withWriteLock(self: *RwSpinlock, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
        self.acquireWrite();
        defer self.releaseWrite();
        return @call(.auto, func, args);
    }
};

// ============================================================================
// Mutex (ticket-based spinlock for fairness with priority inheritance)
// ============================================================================

pub const Mutex = struct {
    next_ticket: atomic.AtomicU64,
    now_serving: atomic.AtomicU64,
    /// Current owner (for priority inheritance) - pointer to Thread
    owner: atomic.AtomicUsize,

    pub fn init() Mutex {
        return .{
            .next_ticket = atomic.AtomicU64.init(0),
            .now_serving = atomic.AtomicU64.init(0),
            .owner = atomic.AtomicUsize.init(0),
        };
    }

    /// Acquire the mutex (with priority inheritance support)
    pub fn acquire(self: *Mutex) void {
        const ticket = self.next_ticket.fetchAdd(1, .Relaxed);

        // Check if we need to wait
        if (self.now_serving.load(.Acquire) != ticket) {
            // We need to wait - implement priority inheritance
            const current_thread = @import("thread.zig").getCurrentThread();
            if (current_thread) |waiter| {
                const owner_addr = self.owner.load(.Acquire);
                if (owner_addr != 0) {
                    const Thread = @import("thread.zig").Thread;
                    const owner: *Thread = @ptrFromInt(owner_addr);
                    // Boost owner's priority if ours is higher
                    _ = owner.boostPriority(waiter.priority);
                }
            }

            // Wait for our turn
            while (self.now_serving.load(.Acquire) != ticket) {
                asm.pause();
            }
        }

        // We now own the mutex - record ownership
        const current_thread = @import("thread.zig").getCurrentThread();
        if (current_thread) |thread| {
            self.owner.store(@intFromPtr(thread), .Release);
        }
    }

    /// Try to acquire the mutex
    pub fn tryAcquire(self: *Mutex) bool {
        const ticket = self.next_ticket.load(.Relaxed);
        const serving = self.now_serving.load(.Acquire);

        if (ticket != serving) {
            return false;
        }

        if (self.next_ticket.compareExchange(ticket, ticket + 1, .Acquire, .Relaxed) == null) {
            // Successfully acquired - record ownership
            const current_thread = @import("thread.zig").getCurrentThread();
            if (current_thread) |thread| {
                self.owner.store(@intFromPtr(thread), .Release);
            }
            return true;
        }

        return false;
    }

    /// Release the mutex (restore priority if inherited)
    pub fn release(self: *Mutex) void {
        // Restore priority if we had boosted it
        const owner_addr = self.owner.load(.Acquire);
        if (owner_addr != 0) {
            const Thread = @import("thread.zig").Thread;
            const owner: *Thread = @ptrFromInt(owner_addr);
            owner.restorePriority();
        }

        // Clear ownership
        self.owner.store(0, .Release);

        // Release the mutex
        _ = self.now_serving.fetchAdd(1, .Release);
    }

    /// Execute a function while holding the mutex
    pub fn withLock(self: *Mutex, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
        self.acquire();
        defer self.release();
        return @call(.auto, func, args);
    }
};

// ============================================================================
// Semaphore
// ============================================================================

pub const Semaphore = struct {
    count: atomic.AtomicI64,

    pub fn init(initial: i64) Semaphore {
        return .{ .count = atomic.AtomicI64.init(initial) };
    }

    /// Wait (decrement counter, block if zero)
    pub fn wait(self: *Semaphore) void {
        while (true) {
            var current = self.count.load(.Acquire);

            if (current <= 0) {
                asm.pause();
                continue;
            }

            if (self.count.compareExchange(current, current - 1, .Acquire, .Acquire) == null) {
                break;
            }
        }
    }

    /// Try to wait without blocking
    pub fn tryWait(self: *Semaphore) bool {
        var current = self.count.load(.Acquire);

        if (current <= 0) {
            return false;
        }

        return self.count.compareExchange(current, current - 1, .Acquire, .Acquire) == null;
    }

    /// Signal (increment counter)
    pub fn signal(self: *Semaphore) void {
        _ = self.count.fetchAdd(1, .Release);
    }

    /// Get current count
    pub fn getCount(self: *const Semaphore) i64 {
        return self.count.load(.Acquire);
    }
};

// ============================================================================
// Barrier (synchronization point for multiple threads)
// ============================================================================

pub const SyncBarrier = struct {
    count: atomic.AtomicUsize,
    total: usize,
    generation: atomic.AtomicUsize,

    pub fn init(total: usize) SyncBarrier {
        return .{
            .count = atomic.AtomicUsize.init(total),
            .total = total,
            .generation = atomic.AtomicUsize.init(0),
        };
    }

    /// Wait at the barrier
    pub fn wait(self: *SyncBarrier) void {
        const gen = self.generation.load(.Acquire);
        const remaining = self.count.fetchSub(1, .AcqRel);

        if (remaining == 1) {
            // Last thread to arrive
            self.count.store(self.total, .Release);
            _ = self.generation.fetchAdd(1, .Release);
        } else {
            // Wait for all threads
            while (self.generation.load(.Acquire) == gen) {
                asm.pause();
            }
        }
    }
};

// ============================================================================
// Once (execute code exactly once)
// ============================================================================

pub const Once = struct {
    state: atomic.AtomicU8,

    const NOT_CALLED: u8 = 0;
    const IN_PROGRESS: u8 = 1;
    const COMPLETE: u8 = 2;

    pub fn init() Once {
        return .{ .state = atomic.AtomicU8.init(NOT_CALLED) };
    }

    /// Call the function exactly once
    pub fn call(self: *Once, comptime func: anytype, args: anytype) void {
        // Fast path: already complete
        if (self.state.load(.Acquire) == COMPLETE) {
            return;
        }

        // Try to claim execution
        if (self.state.compareExchange(NOT_CALLED, IN_PROGRESS, .Acquire, .Acquire) == null) {
            // We get to execute
            @call(.auto, func, args);
            self.state.store(COMPLETE, .Release);
        } else {
            // Wait for completion
            while (self.state.load(.Acquire) != COMPLETE) {
                asm.pause();
            }
        }
    }

    /// Check if already called
    pub fn isCalled(self: *const Once) bool {
        return self.state.load(.Acquire) == COMPLETE;
    }
};

// ============================================================================
// Lazy Initialization
// ============================================================================

pub fn Lazy(comptime T: type) type {
    return struct {
        const Self = @This();

        once: Once,
        value: ?T,

        pub fn init() Self {
            return .{
                .once = Once.init(),
                .value = null,
            };
        }

        pub fn get(self: *Self, comptime init_fn: fn () T) *T {
            self.once.call(struct {
                fn initialize(lazy: *Self) void {
                    lazy.value = init_fn();
                }
            }.initialize, .{self});

            return &self.value.?;
        }
    };
}

// ============================================================================
// Futex-like Wait/Wake
// ============================================================================

pub const WaitQueue = struct {
    state: atomic.AtomicU32,

    pub fn init() WaitQueue {
        return .{ .state = atomic.AtomicU32.init(0) };
    }

    /// Wait until state changes from expected value
    pub fn wait(self: *WaitQueue, expected: u32) void {
        while (self.state.load(.Acquire) == expected) {
            asm.pause();
        }
    }

    /// Wake all waiters by changing state
    pub fn wake(self: *WaitQueue) void {
        _ = self.state.fetchAdd(1, .Release);
    }

    /// Set specific state value
    pub fn setState(self: *WaitQueue, value: u32) void {
        self.state.store(value, .Release);
    }

    /// Get current state
    pub fn getState(self: *const WaitQueue) u32 {
        return self.state.load(.Acquire);
    }
};

// ============================================================================
// Lock Statistics (for debugging)
// ============================================================================

pub const LockStats = struct {
    acquisitions: atomic.AtomicU64,
    contentions: atomic.AtomicU64,
    total_wait_time: atomic.AtomicU64,

    pub fn init() LockStats {
        return .{
            .acquisitions = atomic.AtomicU64.init(0),
            .contentions = atomic.AtomicU64.init(0),
            .total_wait_time = atomic.AtomicU64.init(0),
        };
    }

    pub fn recordAcquisition(self: *LockStats, contested: bool, wait_time: u64) void {
        _ = self.acquisitions.fetchAdd(1, .Relaxed);
        if (contested) {
            _ = self.contentions.fetchAdd(1, .Relaxed);
            _ = self.total_wait_time.fetchAdd(wait_time, .Relaxed);
        }
    }

    pub fn getStats(self: *const LockStats) struct {
        acquisitions: u64,
        contentions: u64,
        avg_wait_time: u64,
    } {
        const acq = self.acquisitions.load(.Relaxed);
        const cont = self.contentions.load(.Relaxed);
        const total_wait = self.total_wait_time.load(.Relaxed);

        return .{
            .acquisitions = acq,
            .contentions = cont,
            .avg_wait_time = if (cont > 0) total_wait / cont else 0,
        };
    }

    pub fn reset(self: *LockStats) void {
        self.acquisitions.store(0, .Relaxed);
        self.contentions.store(0, .Relaxed);
        self.total_wait_time.store(0, .Relaxed);
    }
};

// Tests
test "spinlock basic" {
    var lock = Spinlock.init();

    lock.acquire();
    try Basics.testing.expect(lock.locked.test(.Relaxed));

    lock.release();
    try Basics.testing.expect(!lock.locked.test(.Relaxed));
}

test "spinlock try acquire" {
    var lock = Spinlock.init();

    try Basics.testing.expect(lock.tryAcquire());
    try Basics.testing.expect(!lock.tryAcquire());

    lock.release();
    try Basics.testing.expect(lock.tryAcquire());
    lock.release();
}

test "rwlock" {
    var lock = RwSpinlock.init();

    // Multiple readers
    lock.acquireRead();
    try Basics.testing.expect(lock.tryAcquireRead());
    lock.releaseRead();
    lock.releaseRead();

    // Single writer
    lock.acquireWrite();
    try Basics.testing.expect(!lock.tryAcquireRead());
    try Basics.testing.expect(!lock.tryAcquireWrite());
    lock.releaseWrite();
}

test "mutex" {
    var mutex = Mutex.init();

    mutex.acquire();
    try Basics.testing.expect(!mutex.tryAcquire());
    mutex.release();

    try Basics.testing.expect(mutex.tryAcquire());
    mutex.release();
}

test "semaphore" {
    var sem = Semaphore.init(2);

    try Basics.testing.expect(sem.tryWait());
    try Basics.testing.expectEqual(@as(i64, 1), sem.getCount());

    try Basics.testing.expect(sem.tryWait());
    try Basics.testing.expectEqual(@as(i64, 0), sem.getCount());

    try Basics.testing.expect(!sem.tryWait());

    sem.signal();
    try Basics.testing.expectEqual(@as(i64, 1), sem.getCount());
    try Basics.testing.expect(sem.tryWait());
}

test "once" {
    var once = Once.init();
    var counter: u32 = 0;

    const increment = struct {
        fn func(c: *u32) void {
            c.* += 1;
        }
    }.func;

    once.call(increment, .{&counter});
    once.call(increment, .{&counter});
    once.call(increment, .{&counter});

    try Basics.testing.expectEqual(@as(u32, 1), counter);
    try Basics.testing.expect(once.isCalled());
}

test "barrier" {
    var barrier = SyncBarrier.init(1);
    barrier.wait(); // Should not block with single thread
}

test "wait queue" {
    var wq = WaitQueue.init();
    try Basics.testing.expectEqual(@as(u32, 0), wq.getState());

    wq.setState(42);
    try Basics.testing.expectEqual(@as(u32, 42), wq.getState());

    wq.wake();
    try Basics.testing.expectEqual(@as(u32, 43), wq.getState());
}
