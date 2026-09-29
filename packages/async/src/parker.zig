const std = @import("std");
const builtin = @import("builtin");
const Futex = @import("threading_futex");

fn monotonicNowNs() u64 {
    if (comptime builtin.os.tag == .windows) {
        const ntdll = std.os.windows.ntdll;
        var counter: std.os.windows.LARGE_INTEGER = undefined;
        var frequency: std.os.windows.LARGE_INTEGER = undefined;
        std.debug.assert(ntdll.RtlQueryPerformanceCounter(&counter).toBool());
        std.debug.assert(ntdll.RtlQueryPerformanceFrequency(&frequency).toBool());
        return @intCast(@divFloor(
            @as(u128, @intCast(counter)) * std.time.ns_per_s,
            @as(u128, @intCast(frequency)),
        ));
    } else if (comptime builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    } else {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
}

/// Parker/Unparker for efficient thread parking and unparking.
///
/// This allows threads to sleep when there's no work available and be
/// woken up efficiently when work arrives. Based on Java's LockSupport
/// and Rust's thread::park.
///
/// The state word is also the futex address, so parking has no separate mutex
/// or semaphore and an early notification is retained as one binary permit.
pub const Parker = struct {
    /// State: 0 = empty, 1 = notified
    state: std.atomic.Value(u32),

    const EMPTY: u32 = 0;
    const NOTIFIED: u32 = 1;

    pub fn init() Parker {
        return .{
            .state = std.atomic.Value(u32).init(EMPTY),
        };
    }

    /// Park the current thread.
    ///
    /// The thread will block until unpark() is called, unless a spurious
    /// wakeup occurs. If unpark() was called before park(), park() returns
    /// immediately.
    pub fn park(self: *Parker) void {
        while (true) {
            if (self.state.cmpxchgStrong(NOTIFIED, EMPTY, .acquire, .monotonic) == null) return;
            Futex.waitForever(&self.state, EMPTY);
        }
    }

    /// Park with timeout.
    ///
    /// Returns true if unparked by another thread, false if timed out.
    pub fn parkTimeout(self: *Parker, timeout_ns: u64) bool {
        if (self.state.cmpxchgStrong(NOTIFIED, EMPTY, .acquire, .monotonic) == null) return true;
        if (timeout_ns == 0) return false;

        const start = monotonicNowNs();

        while (true) {
            if (self.state.cmpxchgStrong(NOTIFIED, EMPTY, .acquire, .monotonic) == null) return true;

            const elapsed = monotonicNowNs() - start;

            if (elapsed >= timeout_ns) return false;

            const remaining = timeout_ns - elapsed;
            Futex.wait(&self.state, EMPTY, remaining) catch {
                return self.state.cmpxchgStrong(NOTIFIED, EMPTY, .acquire, .monotonic) == null;
            };
        }
    }

    /// Unpark the thread.
    ///
    /// If the thread is currently parked, it will be woken up.
    /// If not, the next call to park() will return immediately.
    pub fn unpark(self: *Parker) void {
        if (self.state.swap(NOTIFIED, .release) == EMPTY) {
            Futex.wake(&self.state, 1);
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

    const start = monotonicNowNs();
    const timeout = 10 * std.time.ns_per_ms; // 10ms

    const unparked = parker.parkTimeout(timeout);
    const elapsed = monotonicNowNs() - start;

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
            ctx.parker.unpark();
        }
    }.run;

    var ctx = Context{ .parker = &parker };

    const thread = try std.Thread.spawn(.{}, unparker_fn, .{&ctx});

    const start = monotonicNowNs();
    parker.park();
    const elapsed = monotonicNowNs() - start;

    thread.join();

    // Should have been unparked, not timed out.
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
