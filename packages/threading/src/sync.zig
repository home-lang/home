// Home Programming Language - Advanced Synchronization Primitives
// Additional thread synchronization beyond basic mutexes

const std = @import("std");

// ============================================================================
// Public API Exports
// ============================================================================

// Low-level locks
pub const Spinlock = @import("sync/spinlock.zig").Spinlock;
pub const TicketLock = @import("sync/spinlock.zig").TicketLock;
pub const RwSpinlock = @import("sync/spinlock.zig").RwSpinlock;

// High-level synchronization
pub const WaitGroup = @import("sync/waitgroup.zig").WaitGroup;
pub const Latch = @import("sync/latch.zig").Latch;

// Events
pub const ManualResetEvent = @import("sync/event.zig").ManualResetEvent;
pub const AutoResetEvent = @import("sync/event.zig").AutoResetEvent;

// Atomic operations
pub const AtomicCounter = @import("sync/atomic.zig").AtomicCounter;
pub const AtomicFlag = @import("sync/atomic.zig").AtomicFlag;
pub const AtomicTaggedPtr = @import("sync/atomic.zig").AtomicTaggedPtr;

// ============================================================================
// Tests
// ============================================================================

test "sync module imports" {
    _ = Spinlock;
    _ = TicketLock;
    _ = RwSpinlock;
    _ = WaitGroup;
    _ = Latch;
    _ = ManualResetEvent;
    _ = AutoResetEvent;
    _ = AtomicCounter;
    _ = AtomicFlag;
    _ = AtomicTaggedPtr;
}
