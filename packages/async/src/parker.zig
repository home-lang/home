const std = @import("std");

/// Parker/Unparker for efficient thread parking and unparking.
///
/// This allows threads to sleep when there's no work available and be
/// woken up efficiently when work arrives. Based on Java's LockSupport
/// and Rust's thread::park.
///
/// The implementation uses a semaphore-based approach with atomic operations
/// to minimize syscalls in the common case.
pub const Parker = struct {
    /// State: 0 = empty, 1 = notified
    state: std.atomic.Value(u32),
    /// Semaphore for actual blocking
    semaphore: std.Thread.Semaphore,

    const EMPTY: u32 = 0;
    const NOTIFIED: u32 = 1;

    pub fn init() Parker {
        return .{
            .state = std.atomic.Value(u32).init(EMPTY),
            .semaphore = .{},
        };
    }

    /// Park the current thread.
    ///
    /// The thread will block until unpark() is called, unless a spurious
    /// wakeup occurs. If unpark() was called before park(), park() returns
    /// immediately.
    pub fn park(self: *Parker) void {
        // If we're already notified, consume the notification and return
        if (self.state.swap(EMPTY, .acquire) == NOTIFIED) {
            return;
        }

        // Wait on semaphore
        while (true) {
            self.semaphore.wait();

            // Check if we were actually notified
            if (self.state.swap(EMPTY, .acquire) == NOTIFIED) {
                return;
            }

            // Spurious wakeup, continue waiting
        }
    }

    /// Park with timeout.
    ///
    /// Returns true if unparked by another thread, false if timed out.
    pub fn parkTimeout(self: *Parker, timeout_ns: u64) bool {
        // If we're already notified, consume the notification and return
        if (self.state.swap(EMPTY, .acquire) == NOTIFIED) {
            return true;
        }

        const start = blk: { const instant = std.time.Instant.now() catch break :blk 0; break :blk @as(i64, @intCast(@as(u64, @bitCast(instant.timestamp)))); };
        const deadline = start + @as(i128, timeout_ns);

        while (true) {
            const now = blk: { const instant = std.time.Instant.now() catch break :blk 0; break :blk @as(i64, @intCast(@as(u64, @bitCast(instant.timestamp)))); };
            if (now >= deadline) {
                // Timed out
                return false;
            }

            const remaining = @as(u64, @intCast(deadline - now));

            // Wait with timeout
            self.semaphore.timedWait(remaining) catch {
                // Timeout
                return false;
            };

            // Check if we were actually notified
            if (self.state.swap(EMPTY, .acquire) == NOTIFIED) {
                return true;
            }

            // Spurious wakeup, continue if time remains
        }
    }

    /// Unpark the thread.
    ///
    /// If the thread is currently parked, it will be woken up.
    /// If not, the next call to park() will return immediately.
    pub fn unpark(self: *Parker) void {
        // Set notified state
        if (self.state.swap(NOTIFIED, .release) == EMPTY) {
            // Thread might be waiting, signal semaphore
            self.semaphore.post();
        }
    }

    /// Unpark by reference (for use through pointers)
    pub fn unparkByRef(self: *const Parker) void {
        const mutable_self = @constCast(self);
        mutable_self.unpark();
    }
};

/// Unparker handle that can be cloned and sent to other threads.
pub const Unparker = struct {
    parker: *Parker,

    pub fn unpark(self: Unparker) void {
        self.parker.unpark();
    }
};

// =================================================================================
//                                    TESTS
// =================================================================================

test "Parker - basic park and unpark" {
    const testing = std.testing;

    var parker = Parker.init();

    // Unpark before park - park should return immediately
    parker.unpark();
    parker.park();

    // Should not block
    try testing.expect(true);
}

test "Parker - park timeout" {
    const testing = std.testing;

    var parker = Parker.init();

    const start = blk: { const instant = std.time.Instant.now() catch break :blk 0; break :blk @as(i64, @intCast(@as(u64, @bitCast(instant.timestamp)))); };
    const timeout = 10 * std.time.ns_per_ms; // 10ms

    const unparked = parker.parkTimeout(timeout);
    const elapsed = blk: { const instant = std.time.Instant.now() catch break :blk 0; break :blk @as(i64, @intCast(@as(u64, @bitCast(instant.timestamp)))); } - start;

    // Should have timed out
    try testing.expect(!unparked);

    // Should have waited approximately the timeout duration
    try testing.expect(elapsed >= timeout);
    try testing.expect(elapsed < timeout * 2); // Allow some slack
}

test "Parker - concurrent unpark" {
    const testing = std.testing;

    var parker = Parker.init();

    const Context = struct {
        parker: *Parker,
    };

    const unparker_fn = struct {
        fn run(ctx: *Context) void {
            // Wait a bit before unparking
            std.posix.nanosleep(0, 5 * std.time.ns_per_ms); // 5ms
            ctx.parker.unpark();
        }
    }.run;

    var ctx = Context{ .parker = &parker };

    const thread = try std.Thread.spawn(.{}, unparker_fn, .{&ctx});

    const start = blk: { const instant = std.time.Instant.now() catch break :blk 0; break :blk @as(i64, @intCast(@as(u64, @bitCast(instant.timestamp)))); };
    parker.park();
    const elapsed = blk: { const instant = std.time.Instant.now() catch break :blk 0; break :blk @as(i64, @intCast(@as(u64, @bitCast(instant.timestamp)))); } - start;

    thread.join();

    // Should have been unparked, not timed out
    // Elapsed should be around 5ms (with some tolerance)
    try testing.expect(elapsed >= 4 * std.time.ns_per_ms);
    try testing.expect(elapsed < 100 * std.time.ns_per_ms);
}

test "Parker - multiple unparks" {
    const testing = std.testing;

    var parker = Parker.init();

    // Multiple unparks should only consume one park
    parker.unpark();
    parker.unpark();
    parker.unpark();

    // First park returns immediately (consumes one notification)
    parker.park();

    // Second park with timeout should timeout (no notification left)
    const unparked = parker.parkTimeout(5 * std.time.ns_per_ms);
    try testing.expect(!unparked);
}

test "Parker - unparker handle" {
    const testing = std.testing;

    var parker = Parker.init();
    const unparker = Unparker{ .parker = &parker };

    const Context = struct {
        unparker: Unparker,
    };

    const unparker_fn = struct {
        fn run(ctx: *Context) void {
            std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
            ctx.unparker.unpark();
        }
    }.run;

    var ctx = Context{ .unparker = unparker };

    const thread = try std.Thread.spawn(.{}, unparker_fn, .{&ctx});

    parker.park();

    thread.join();

    // If we reach here, unparking worked
    try testing.expect(true);
}
