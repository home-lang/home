// Home Programming Language - Semaphore Primitives
// Simple atomic implementation for Zig 0.16 (std.Thread.Semaphore no longer exists)

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const Semaphore = struct {
    permits: std.atomic.Value(u32),

    pub fn init(initial_count: u32) ThreadError!Semaphore {
        return Semaphore{ .permits = std.atomic.Value(u32).init(initial_count) };
    }

    pub fn deinit(self: *Semaphore) void {
        _ = self;
    }

    pub fn wait(self: *Semaphore) ThreadError!void {
        while (true) {
            const current = self.permits.load(.acquire);
            if (current > 0) {
                if (self.permits.cmpxchgWeak(current, current - 1, .acq_rel, .acquire) == null) {
                    return;
                }
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn tryWait(self: *Semaphore) ThreadError!bool {
        var current = self.permits.load(.acquire);
        while (current > 0) {
            current = self.permits.cmpxchgWeak(current, current - 1, .acq_rel, .acquire) orelse
                return true;
        }
        return false;
    }

    pub fn post(self: *Semaphore) ThreadError!void {
        // Atomically increment, guarding against overflow with a CAS loop.
        while (true) {
            const current = self.permits.load(.monotonic);
            if (current == std.math.maxInt(u32)) return ThreadError.SemaphoreOverflow;
            if (self.permits.cmpxchgWeak(current, current + 1, .release, .monotonic) == null) return;
        }
    }

    pub fn getValue(self: *const Semaphore) ThreadError!i32 {
        const current = self.permits.load(.acquire);
        if (current > std.math.maxInt(i32)) return ThreadError.SemaphoreOverflow;
        return @intCast(current);
    }
};

pub const BinarySemaphore = struct {
    sem: Semaphore,

    pub fn init(initial: bool) ThreadError!BinarySemaphore {
        const count: u32 = if (initial) 1 else 0;
        return BinarySemaphore{
            .sem = try Semaphore.init(count),
        };
    }

    pub fn deinit(self: *BinarySemaphore) void {
        self.sem.deinit();
    }

    pub fn wait(self: *BinarySemaphore) ThreadError!void {
        return self.sem.wait();
    }

    pub fn tryWait(self: *BinarySemaphore) ThreadError!bool {
        return self.sem.tryWait();
    }

    pub fn signal(self: *BinarySemaphore) ThreadError!void {
        return self.sem.post();
    }
};

test "semaphore init" {
    var sem = try Semaphore.init(1);
    defer sem.deinit();

    try std.testing.expectEqual(@as(i32, 1), try sem.getValue());
}

test "tryWait consumes exactly one permit" {
    var sem = try Semaphore.init(2);
    defer sem.deinit();

    try std.testing.expect(try sem.tryWait());
    try std.testing.expectEqual(@as(i32, 1), try sem.getValue());
    try std.testing.expect(try sem.tryWait());
    try std.testing.expectEqual(@as(i32, 0), try sem.getValue());
    try std.testing.expect(!try sem.tryWait());
}

test "post restores a consumed permit" {
    var sem = try Semaphore.init(1);
    defer sem.deinit();

    try std.testing.expect(try sem.tryWait());
    try sem.post();
    try std.testing.expectEqual(@as(i32, 1), try sem.getValue());
}

test "semaphore reports values outside its public range" {
    var sem = try Semaphore.init(@as(u32, std.math.maxInt(i32)) + 1);
    defer sem.deinit();

    try std.testing.expectError(ThreadError.SemaphoreOverflow, sem.getValue());
}

test "semaphore rejects permit overflow" {
    var sem = try Semaphore.init(std.math.maxInt(u32));
    defer sem.deinit();

    try std.testing.expectError(ThreadError.SemaphoreOverflow, sem.post());
}
