// Home Programming Language - Latch
// Single-use countdown synchronization (spin-based for Zig 0.16)

const std = @import("std");

/// Latch - single-use countdown barrier
/// Once triggered, remains triggered forever
pub const Latch = struct {
    count: std.atomic.Value(u32),

    pub fn init(count: u32) Latch {
        return .{
            .count = std.atomic.Value(u32).init(count),
        };
    }

    pub fn deinit(self: *Latch) void {
        _ = self;
    }

    /// Decrement count by 1
    pub fn countDown(self: *Latch) void {
        _ = self.count.fetchSub(1, .release);
    }

    /// Wait until count reaches zero
    pub fn wait(self: *Latch) void {
        while (self.count.load(.acquire) > 0) {
            std.atomic.spinLoopHint();
        }
    }

    /// Try to wait with timeout (nanoseconds) - counter-based approximation
    pub fn waitTimeout(self: *Latch, timeout_ns: u64) bool {
        if (self.count.load(.acquire) == 0) {
            return true;
        }

        const max_iterations = timeout_ns / 50;
        var iterations: u64 = 0;

        while (self.count.load(.acquire) > 0) {
            iterations += 1;
            if (iterations >= max_iterations) {
                return false;
            }
            std.atomic.spinLoopHint();
        }

        return true;
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
