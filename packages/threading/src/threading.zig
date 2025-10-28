// Home Programming Language - Complete Threading System
// POSIX-compatible threading with modern features
//
// Features:
// - Full POSIX thread API
// - Thread-local storage (TLS)
// - Mutexes with priority inheritance
// - Semaphores (binary and counting)
// - Condition variables
// - Read-write locks
// - Thread barriers
// - CPU affinity
// - Scheduling policies
// - Once initialization

const std = @import("std");

// ============================================================================
// Public API Exports
// ============================================================================

pub const Thread = @import("thread.zig").Thread;
pub const ThreadAttr = @import("thread.zig").ThreadAttr;
pub const Mutex = @import("mutex.zig").Mutex;
pub const MutexAttr = @import("mutex.zig").MutexAttr;
pub const Semaphore = @import("semaphore.zig").Semaphore;
pub const CondVar = @import("condvar.zig").CondVar;
pub const RwLock = @import("rwlock.zig").RwLock;
pub const Barrier = @import("barrier.zig").Barrier;
pub const Once = @import("once.zig").Once;
pub const TLS = @import("tls.zig");

// Scheduling
pub const SchedPolicy = @import("sched.zig").SchedPolicy;
pub const SchedParam = @import("sched.zig").SchedParam;
pub const CpuSet = @import("sched.zig").CpuSet;

// Error types
pub const ThreadError = @import("errors.zig").ThreadError;

// ============================================================================
// Constants
// ============================================================================

pub const THREAD_STACK_MIN: usize = 16384; // 16KB minimum stack
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

test "constants defined" {
    const testing = std.testing;

    try testing.expect(THREAD_STACK_MIN > 0);
    try testing.expect(THREAD_STACK_DEFAULT >= THREAD_STACK_MIN);
    try testing.expect(MAX_THREADS > 0);
}
