// Home Programming Language - Events
// Windows-style synchronization events

const std = @import("std");

/// Manual-reset event - stays signaled until manually reset
pub const ManualResetEvent = struct {
    signaled: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn init(initial_state: bool) ManualResetEvent {
        return .{
            .signaled = std.atomic.Value(bool).init(initial_state),
            .mutex = .{},
            .cond = .{},
        };
    }

    pub fn deinit(self: *ManualResetEvent) void {
        _ = self;
    }

    /// Set event to signaled state
    pub fn set(self: *ManualResetEvent) void {
        self.signaled.store(true, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cond.broadcast();
    }

    /// Reset event to non-signaled state
    pub fn reset(self: *ManualResetEvent) void {
        self.signaled.store(false, .release);
    }

    /// Wait for event to be signaled
    pub fn wait(self: *ManualResetEvent) void {
        if (self.signaled.load(.acquire)) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        while (!self.signaled.load(.acquire)) {
            self.cond.wait(&self.mutex);
        }
    }

    /// Wait with timeout (nanoseconds)
    pub fn waitTimeout(self: *ManualResetEvent, timeout_ns: u64) bool {
        if (self.signaled.load(.acquire)) {
            return true;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.signaled.load(.acquire)) {
            return true;
        }

        self.cond.timedWait(&self.mutex, timeout_ns) catch {
            return false; // Timeout
        };

        return self.signaled.load(.acquire);
    }

    pub fn isSignaled(self: *const ManualResetEvent) bool {
        return self.signaled.load(.acquire);
    }
};

/// Auto-reset event - automatically resets after one waiter is released
pub const AutoResetEvent = struct {
    signaled: bool,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn init(initial_state: bool) AutoResetEvent {
        return .{
            .signaled = initial_state,
            .mutex = .{},
            .cond = .{},
        };
    }

    pub fn deinit(self: *AutoResetEvent) void {
        _ = self;
    }

    /// Set event to signaled state (releases one waiter)
    pub fn set(self: *AutoResetEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.signaled = true;
        self.cond.signal(); // Wake one waiter
    }

    /// Wait for event and automatically reset
    pub fn wait(self: *AutoResetEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (!self.signaled) {
            self.cond.wait(&self.mutex);
        }

        self.signaled = false; // Auto-reset
    }

    /// Wait with timeout (nanoseconds)
    pub fn waitTimeout(self: *AutoResetEvent, timeout_ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.signaled) {
            self.signaled = false;
            return true;
        }

        self.cond.timedWait(&self.mutex, timeout_ns) catch {
            return false; // Timeout
        };

        if (self.signaled) {
            self.signaled = false;
            return true;
        }

        return false;
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
