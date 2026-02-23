// Home Programming Language - Events
// Windows-style synchronization events (spin-based for Zig 0.16)

const std = @import("std");

/// Manual-reset event - stays signaled until manually reset
pub const ManualResetEvent = struct {
    signaled: std.atomic.Value(bool),

    pub fn init(initial_state: bool) ManualResetEvent {
        return .{
            .signaled = std.atomic.Value(bool).init(initial_state),
        };
    }

    pub fn deinit(self: *ManualResetEvent) void {
        _ = self;
    }

    /// Set event to signaled state
    pub fn set(self: *ManualResetEvent) void {
        self.signaled.store(true, .release);
    }

    /// Reset event to non-signaled state
    pub fn reset(self: *ManualResetEvent) void {
        self.signaled.store(false, .release);
    }

    /// Wait for event to be signaled
    pub fn wait(self: *ManualResetEvent) void {
        while (!self.signaled.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    /// Wait with timeout (nanoseconds) - counter-based approximation
    pub fn waitTimeout(self: *ManualResetEvent, timeout_ns: u64) bool {
        if (self.signaled.load(.acquire)) {
            return true;
        }

        const max_iterations = timeout_ns / 50;
        var iterations: u64 = 0;

        while (!self.signaled.load(.acquire)) {
            iterations += 1;
            if (iterations >= max_iterations) {
                return false;
            }
            std.atomic.spinLoopHint();
        }

        return true;
    }

    pub fn isSignaled(self: *const ManualResetEvent) bool {
        return self.signaled.load(.acquire);
    }
};

/// Auto-reset event - automatically resets after one waiter is released
pub const AutoResetEvent = struct {
    signaled: std.atomic.Value(bool),

    pub fn init(initial_state: bool) AutoResetEvent {
        return .{
            .signaled = std.atomic.Value(bool).init(initial_state),
        };
    }

    pub fn deinit(self: *AutoResetEvent) void {
        _ = self;
    }

    /// Set event to signaled state (releases one waiter)
    pub fn set(self: *AutoResetEvent) void {
        self.signaled.store(true, .release);
    }

    /// Wait for event and automatically reset
    pub fn wait(self: *AutoResetEvent) void {
        while (true) {
            if (self.signaled.cmpxchgWeak(true, false, .acquire, .monotonic) == null) {
                return; // Got the signal, auto-reset done
            }
            std.atomic.spinLoopHint();
        }
    }

    /// Wait with timeout (nanoseconds) - counter-based approximation
    pub fn waitTimeout(self: *AutoResetEvent, timeout_ns: u64) bool {
        const max_iterations = timeout_ns / 50;
        var iterations: u64 = 0;

        while (true) {
            if (self.signaled.cmpxchgWeak(true, false, .acquire, .monotonic) == null) {
                return true;
            }
            iterations += 1;
            if (iterations >= max_iterations) {
                return false;
            }
            std.atomic.spinLoopHint();
        }
    }
};

test "manual reset event" {
    const testing = std.testing;

    var event = ManualResetEvent.init(false);
    defer event.deinit();

    try testing.expect(!event.isSignaled());

    event.set();
    try testing.expect(event.isSignaled());

    event.wait(); // Should return immediately

    event.reset();
    try testing.expect(!event.isSignaled());
}

test "auto reset event" {
    var event = AutoResetEvent.init(false);
    defer event.deinit();

    event.set();
    event.wait(); // Should consume the signal
}
