// Home Programming Language - Semaphore Primitives
// Wrapper around Zig's std.Thread.Semaphore

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const Semaphore = struct {
    inner: std.Thread.Semaphore,

    pub fn init(initial_count: u32) ThreadError!Semaphore {
        return Semaphore{ .inner = .{ .permits = initial_count } };
    }

    pub fn deinit(self: *Semaphore) void {
        _ = self;
    }

    pub fn wait(self: *Semaphore) ThreadError!void {
        self.inner.wait();
    }

    pub fn tryWait(self: *Semaphore) ThreadError!bool {
        return self.inner.tryWait();
    }

    pub fn post(self: *Semaphore) ThreadError!void {
        self.inner.post();
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
