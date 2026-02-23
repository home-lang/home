// Home Programming Language - Read-Write Locks
// Simple implementation using std.atomic.Mutex (Zig 0.16)
// Uses a single mutex for both read and write locks (not optimal but functional)

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const RwLock = struct {
    mutex: std.atomic.Mutex,

    pub fn init() ThreadError!RwLock {
        return RwLock{ .mutex = .unlocked };
    }

    pub fn deinit(self: *RwLock) void {
        _ = self;
    }

    pub fn lockRead(self: *RwLock) ThreadError!void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn lockWrite(self: *RwLock) ThreadError!void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlockRead(self: *RwLock) ThreadError!void {
        self.mutex.unlock();
    }

    pub fn unlockWrite(self: *RwLock) ThreadError!void {
        self.mutex.unlock();
    }
};

test "rwlock init" {
    var lock = try RwLock.init();
    defer lock.deinit();
}
