// Home Programming Language - Read-Write Locks
// Wrapper around Zig's std.Thread.RwLock

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const RwLock = struct {
    inner: std.Thread.RwLock,

    pub fn init() ThreadError!RwLock {
        return RwLock{ .inner = .{} };
    }

    pub fn deinit(self: *RwLock) void {
        _ = self;
    }

    pub fn lockRead(self: *RwLock) ThreadError!void {
        self.inner.lockShared();
    }

    pub fn lockWrite(self: *RwLock) ThreadError!void {
        self.inner.lock();
    }

    pub fn unlockRead(self: *RwLock) ThreadError!void {
        self.inner.unlockShared();
    }

    pub fn unlockWrite(self: *RwLock) ThreadError!void {
        self.inner.unlock();
    }
};

test "rwlock init" {
    var lock = try RwLock.init();
    defer lock.deinit();
}
