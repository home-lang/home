// Home Programming Language - Threading System
// Portable facade over Zig's threading primitives
//
// Features:
// - Full POSIX thread API
// - Thread-local storage (TLS)
// - Blocking non-recursive mutexes
// - Semaphores (binary and counting)
// - Futex-backed condition variables
// - Writer-preferring futex-backed read-write locks
// - Thread barriers
// - Linux and Windows current-thread CPU affinity
// - Scheduling policy data types (priority application pending)
// - Once initialization

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Public API Exports
// ============================================================================

pub const Thread = @import("thread.zig").Thread;
pub const ThreadAttr = @import("thread.zig").ThreadAttr;
pub const Mutex = @import("mutex.zig").Mutex;
pub const MutexAttr = @import("mutex.zig").MutexAttr;
pub const Semaphore = @import("semaphore.zig").Semaphore;
pub const BinarySemaphore = @import("semaphore.zig").BinarySemaphore;
pub const CondVar = @import("condvar.zig").CondVar;
pub const RwLock = @import("rwlock.zig").RwLock;
pub const Barrier = @import("barrier.zig").Barrier;
pub const Once = @import("once.zig").Once;
pub const TLS = @import("tls.zig");

// Advanced synchronization primitives
pub const sync = @import("sync.zig");

// Scheduling
const sched = @import("sched.zig");
pub const SchedPolicy = sched.SchedPolicy;
pub const SchedParam = sched.SchedParam;
pub const CpuSet = sched.CpuSet;
pub const setAffinity = sched.setAffinity;
pub const getAffinity = sched.getAffinity;
pub const setPriority = sched.setPriority;
pub const getPriority = sched.getPriority;

// Error types
pub const ThreadError = @import("errors.zig").ThreadError;

// ============================================================================
// Constants
// ============================================================================

pub const THREAD_STACK_MIN: usize = ThreadAttr.minimum_stack_size;
pub const THREAD_STACK_DEFAULT: usize = 2 * 1024 * 1024; // 2MB default
pub const MAX_THREADS: usize = 4096;
pub const MAX_CPU_COUNT: usize = 256;

// ============================================================================
// Thread State
// ============================================================================

pub const ThreadState = enum(u8) {
    Created,
    Ready,
    Running,
    Blocked,
    Suspended,
    Terminated,
    Zombie,
};

// ============================================================================
// Thread Priority
// ============================================================================

pub const ThreadPriority = enum(i32) {
    Idle = 0,
    Lowest = 1,
    BelowNormal = 25,
    Normal = 50,
    AboveNormal = 75,
    Highest = 99,
    Realtime = 100,

    pub fn fromInt(val: i32) ThreadPriority {
        return @enumFromInt(std.math.clamp(val, 0, 100));
    }

    pub fn toInt(self: ThreadPriority) i32 {
        return @intFromEnum(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "threading module imports" {
    // Verify all modules are accessible
    _ = Thread;
    _ = Mutex;
    _ = Semaphore;
    _ = CondVar;
    _ = RwLock;
}

test "thread priority conversion" {
    const testing = std.testing;

    const p = ThreadPriority.Normal;
    try testing.expectEqual(@as(i32, 50), p.toInt());

    const p2 = ThreadPriority.fromInt(75);
    try testing.expectEqual(ThreadPriority.AboveNormal, p2);
}

test "public semaphore API tracks permits" {
    var semaphore = try Semaphore.init(2);
    defer semaphore.deinit();

    try std.testing.expectEqual(@as(i32, 2), try semaphore.getValue());
    try std.testing.expect(try semaphore.tryWait());
    try std.testing.expectEqual(@as(i32, 1), try semaphore.getValue());
}

test "public mutex API rejects unsupported recursive mode" {
    var attr = MutexAttr.init();
    attr.setRecursive(true);
    try std.testing.expectError(ThreadError.OperationNotSupported, Mutex.initWithAttr(attr));
}

test "public condition timeout returns with the mutex reacquired" {
    var mutex = try Mutex.init();
    defer mutex.deinit();
    var condvar = try CondVar.init();
    defer condvar.deinit();

    try mutex.lock();
    try std.testing.expect(!try condvar.waitTimeout(&mutex, 0));
    try mutex.unlock();
}

test "public read-write lock permits multiple readers" {
    var lock = try RwLock.init();
    defer lock.deinit();

    try lock.lockRead();
    try lock.lockRead();
    try lock.unlockRead();
    try lock.unlockRead();
}

test "constants defined" {
    const testing = std.testing;

    try testing.expect(THREAD_STACK_MIN > 0);
    try testing.expect(THREAD_STACK_DEFAULT >= THREAD_STACK_MIN);
    try testing.expect(MAX_THREADS > 0);
}

test "thread stack minimum follows ThreadAttr validation" {
    try std.testing.expectEqual(ThreadAttr.minimum_stack_size, THREAD_STACK_MIN);
}

test "public scheduling API exports affinity and priority operations" {
    _ = setAffinity;
    _ = getAffinity;
    _ = setPriority;
    _ = getPriority;
}

test "public affinity API reports unsupported platforms" {
    if (builtin.os.tag == .linux or builtin.os.tag == .windows) return error.SkipZigTest;

    var cpu_set = CpuSet.init();
    cpu_set.set(0);
    try std.testing.expectError(ThreadError.OperationNotSupported, setAffinity(&cpu_set));
    try std.testing.expectError(ThreadError.OperationNotSupported, getAffinity());
}
