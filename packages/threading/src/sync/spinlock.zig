// Home Programming Language - Spinlocks
// Low-level busy-wait locks for short critical sections

const std = @import("std");

/// Spinlock - busy-wait mutual exclusion lock
/// Use for very short critical sections (< 100 instructions)
/// Wastes CPU cycles while waiting
pub const Spinlock = struct {
    locked: std.atomic.Value(bool),

    pub fn init() Spinlock {
        return .{
            .locked = std.atomic.Value(bool).init(false),
        };
    }

    pub fn lock(self: *Spinlock) void {
        while (self.locked.swap(true, .acquire)) {
            // Spin with hint to reduce power consumption
            while (self.locked.load(.monotonic)) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn tryLock(self: *Spinlock) bool {
        return self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *Spinlock) void {
        self.locked.store(false, .release);
    }

    pub fn isLocked(self: *const Spinlock) bool {
        return self.locked.load(.monotonic);
    }
};

/// Ticket spinlock - fair spinlock with FIFO ordering
/// Prevents starvation by serving threads in order
pub const TicketLock = struct {
    next_ticket: std.atomic.Value(u32),
    now_serving: std.atomic.Value(u32),

    pub fn init() TicketLock {
        return .{
            .next_ticket = std.atomic.Value(u32).init(0),
            .now_serving = std.atomic.Value(u32).init(0),
        };
    }

    pub fn lock(self: *TicketLock) void {
        const ticket = self.next_ticket.fetchAdd(1, .monotonic);

        while (self.now_serving.load(.acquire) != ticket) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *TicketLock) void {
        _ = self.now_serving.fetchAdd(1, .release);
    }
};

/// Read-Write Spinlock - multiple readers or single writer
pub const RwSpinlock = struct {
    state: std.atomic.Value(i32),

    const WRITER: i32 = -1;
    const UNLOCKED: i32 = 0;

    pub fn init() RwSpinlock {
        return .{
            .state = std.atomic.Value(i32).init(UNLOCKED),
        };
    }

    pub fn lockRead(self: *RwSpinlock) void {
        while (true) {
            const current = self.state.load(.monotonic);
            if (current >= UNLOCKED) {
                if (self.state.cmpxchgWeak(current, current + 1, .acquire, .monotonic) == null) {
                    return;
                }
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockRead(self: *RwSpinlock) void {
        _ = self.state.fetchSub(1, .release);
    }

    pub fn lockWrite(self: *RwSpinlock) void {
        while (self.state.cmpxchgStrong(UNLOCKED, WRITER, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockWrite(self: *RwSpinlock) void {
        self.state.store(UNLOCKED, .release);
    }
};

test "spinlock basic" {
    const testing = std.testing;

    var lock = Spinlock.init();

    lock.lock();
    try testing.expect(lock.isLocked());
    lock.unlock();
    try testing.expect(!lock.isLocked());
}

test "spinlock tryLock" {
    const testing = std.testing;

    var lock = Spinlock.init();

    try testing.expect(lock.tryLock());
    try testing.expect(!lock.tryLock());
    lock.unlock();
    try testing.expect(lock.tryLock());
    lock.unlock();
}

test "ticket lock" {
    var lock = TicketLock.init();

    lock.lock();
    lock.unlock();
}

test "rwspinlock" {
    var lock = RwSpinlock.init();

    lock.lockRead();
    lock.unlockRead();

    lock.lockWrite();
    lock.unlockWrite();
}
