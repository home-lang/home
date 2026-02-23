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
        const current = self.permits.load(.acquire);
        if (current > 0) {
            if (self.permits.cmpxchgWeak(current, current - 1, .acq_rel, .acquire) == null) {
                return true;
            }
        }
        return false;
    }

    pub fn post(self: *Semaphore) ThreadError!void {
        _ = self.permits.fetchAdd(1, .release);
    }

    pub fn getValue(self: *Semaphore) ThreadError!i32 {
        _ = self;
        return ThreadError.NotSupported;
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
}
