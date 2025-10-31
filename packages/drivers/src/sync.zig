// Home Programming Language - Synchronization Primitives
// Synchronization primitives for driver coordination

const std = @import("std");
const atomic = @import("atomic.zig");

/// Simple spinlock for driver synchronization
pub const SpinLock = struct {
    locked: atomic.AtomicFlag,

    pub fn init() SpinLock {
        return .{
            .locked = atomic.AtomicFlag.init(false),
        };
    }

    pub fn lock(self: *SpinLock) void {
        while (self.locked.testAndSet(.acquire)) {
            // Spin
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.locked.clear(.release);
    }

    pub fn tryLock(self: *SpinLock) bool {
        return !self.locked.testAndSet(.acquire);
    }

    // Convenience method aliases
    pub fn acquire(self: *SpinLock) void {
        self.lock();
    }

    pub fn release(self: *SpinLock) void {
        self.unlock();
    }
};

/// Alias for compatibility
pub const Spinlock = SpinLock;

/// Mutex for driver synchronization
pub const Mutex = struct {
    locked: atomic.AtomicFlag,

    pub fn init() Mutex {
        return .{
            .locked = atomic.AtomicFlag.init(false),
        };
    }

    pub fn lock(self: *Mutex) void {
        while (self.locked.testAndSet(.acquire)) {
            // Could yield here in a real implementation
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.locked.clear(.release);
    }

    pub fn tryLock(self: *Mutex) bool {
        return !self.locked.testAndSet(.acquire);
    }
};

/// Semaphore for resource counting
pub const Semaphore = struct {
    count: atomic.AtomicCounter,

    pub fn init(initial_count: u64) Semaphore {
        return .{
            .count = atomic.AtomicCounter.init(initial_count),
        };
    }

    pub fn wait(self: *Semaphore) void {
        while (true) {
            const current = self.count.load(.acquire);
            if (current > 0) {
                const old = self.count.fetchSub(1, .acquire);
                if (old > 0) break;
                // Race condition, retry
                _ = self.count.increment();
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn signal(self: *Semaphore) void {
        _ = self.count.increment();
    }

    pub fn tryWait(self: *Semaphore) bool {
        const current = self.count.load(.acquire);
        if (current > 0) {
            const old = self.count.fetchSub(1, .acquire);
            if (old > 0) return true;
            // Race condition, restore and fail
            _ = self.count.increment();
        }
        return false;
    }
};

/// Read-Write lock for concurrent access
pub const RwLock = struct {
    readers: atomic.AtomicCounter,
    writers: atomic.AtomicCounter,
    write_lock: atomic.AtomicFlag,

    pub fn init() RwLock {
        return .{
            .readers = atomic.AtomicCounter.init(0),
            .writers = atomic.AtomicCounter.init(0),
            .write_lock = atomic.AtomicFlag.init(false),
        };
    }

    pub fn lockRead(self: *RwLock) void {
        while (true) {
            // Wait for writers to finish
            while (self.writers.load(.acquire) > 0) {
                std.atomic.spinLoopHint();
            }

            _ = self.readers.increment();

            // Double-check no writer started
            if (self.writers.load(.acquire) == 0) break;

            // Writer started, back off
            _ = self.readers.decrement();
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockRead(self: *RwLock) void {
        _ = self.readers.decrement();
    }

    pub fn lockWrite(self: *RwLock) void {
        _ = self.writers.increment();

        // Acquire exclusive write lock
        while (self.write_lock.testAndSet(.acquire)) {
            std.atomic.spinLoopHint();
        }

        // Wait for all readers to finish
        while (self.readers.load(.acquire) > 0) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockWrite(self: *RwLock) void {
        self.write_lock.clear(.release);
        _ = self.writers.decrement();
    }
};

test "spinlock basic operations" {
    var lock = SpinLock.init();

    lock.lock();
    lock.unlock();

    try std.testing.expect(lock.tryLock());
    lock.unlock();
}

test "semaphore basic operations" {
    var sem = Semaphore.init(2);

    sem.wait();
    try std.testing.expectEqual(@as(u64, 1), sem.count.load(.seq_cst));

    sem.wait();
    try std.testing.expectEqual(@as(u64, 0), sem.count.load(.seq_cst));

    sem.signal();
    try std.testing.expectEqual(@as(u64, 1), sem.count.load(.seq_cst));
}
