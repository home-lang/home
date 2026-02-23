// Home Programming Language - Condition Variables
// Stub implementation for Zig 0.16 (std.Thread.Condition no longer exists)

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;
const Mutex = @import("mutex.zig").Mutex;

pub const CondVar = struct {
    signaled: bool,

    pub fn init() ThreadError!CondVar {
        return CondVar{ .signaled = false };
    }

    pub fn deinit(self: *CondVar) void {
        _ = self;
    }

    pub fn wait(self: *CondVar, mutex: *Mutex) ThreadError!void {
        // Release the mutex, spin until signaled, then re-acquire
        try mutex.unlock();
        while (!self.signaled) {
            std.atomic.spinLoopHint();
        }
        self.signaled = false;
        try mutex.lock();
    }

    pub fn waitTimeout(self: *CondVar, mutex: *Mutex, timeout_ns: u64) ThreadError!bool {
        // Release the mutex, spin with counter-based timeout, then re-acquire
        try mutex.unlock();

        // Approximate timeout using spin iterations
        // Each iteration ~10-100ns depending on CPU, so divide by ~50ns
        const max_iterations = timeout_ns / 50;
        var iterations: u64 = 0;

        while (!self.signaled) {
            iterations += 1;
            if (iterations >= max_iterations) {
                try mutex.lock();
                return false; // Timeout
            }
            std.atomic.spinLoopHint();
        }
        self.signaled = false;
        try mutex.lock();
        return true; // Signaled
    }

    pub fn signal(self: *CondVar) ThreadError!void {
        self.signaled = true;
    }

    pub fn broadcast(self: *CondVar) ThreadError!void {
        self.signaled = true;
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
