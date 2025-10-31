// Home Programming Language - Latch
// Single-use countdown synchronization

const std = @import("std");

/// Latch - single-use countdown barrier
/// Once triggered, remains triggered forever
pub const Latch = struct {
    count: std.atomic.Value(u32),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    pub fn init(count: u32) Latch {
        return .{
            .count = std.atomic.Value(u32).init(count),
            .mutex = .{},
            .cond = .{},
        };
    }

    pub fn deinit(self: *Latch) void {
        _ = self;
    }

    /// Decrement count by 1
    /// If count reaches 0, wake all waiters
    pub fn countDown(self: *Latch) void {
        const old = self.count.fetchSub(1, .release);
        if (old == 1) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.broadcast();
        }
    }

    /// Wait until count reaches zero
    pub fn wait(self: *Latch) void {
        if (self.count.load(.acquire) == 0) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count.load(.acquire) > 0) {
            self.cond.wait(&self.mutex);
        }
    }

    /// Try to wait with timeout (nanoseconds)
    pub fn waitTimeout(self: *Latch, timeout_ns: u64) bool {
        if (self.count.load(.acquire) == 0) {
            return true;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count.load(.acquire) == 0) {
            return true;
        }

        self.cond.timedWait(&self.mutex, timeout_ns) catch {
            return false; // Timeout
        };

        return self.count.load(.acquire) == 0;
    }

    /// Check if latch has been triggered
    pub fn isReady(self: *const Latch) bool {
        return self.count.load(.acquire) == 0;
    }
};

test "latch" {
    const testing = std.testing;

    var latch = Latch.init(3);
    defer latch.deinit();

    try testing.expect(!latch.isReady());

    latch.countDown();
    try testing.expect(!latch.isReady());

    latch.countDown();
    try testing.expect(!latch.isReady());

    latch.countDown();
    try testing.expect(latch.isReady());

    latch.wait(); // Should return immediately
}
