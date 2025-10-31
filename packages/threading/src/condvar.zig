// Home Programming Language - Condition Variables
// Wrapper around Zig's std.Thread.Condition

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;
const Mutex = @import("mutex.zig").Mutex;

pub const CondVar = struct {
    inner: std.Thread.Condition,

    pub fn init() ThreadError!CondVar {
        return CondVar{ .inner = .{} };
    }

    pub fn deinit(self: *CondVar) void {
        _ = self;
    }

    pub fn wait(self: *CondVar, mutex: *Mutex) ThreadError!void {
        self.inner.wait(&mutex.inner);
    }

    pub fn waitTimeout(self: *CondVar, mutex: *Mutex, timeout_ns: u64) ThreadError!bool {
        const result = self.inner.timedWait(&mutex.inner, timeout_ns) catch {
            return false; // Timeout
        };
        _ = result;
        return true; // Signaled
    }

    pub fn signal(self: *CondVar) ThreadError!void {
        self.inner.signal();
    }

    pub fn broadcast(self: *CondVar) ThreadError!void {
        self.inner.broadcast();
    }
};

test "condvar init" {
    var cv = try CondVar.init();
    defer cv.deinit();
}

test "condvar signal" {
    var cv = try CondVar.init();
    defer cv.deinit();
    try cv.signal();
    try cv.broadcast();
}
