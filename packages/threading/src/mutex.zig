// Home Programming Language - Mutex Primitives
// Wrapper around Zig's std.Thread.Mutex

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const Mutex = struct {
    inner: std.Thread.Mutex,

    pub fn init() ThreadError!Mutex {
        return Mutex{ .inner = .{} };
    }

    pub fn initWithAttr(attr: MutexAttr) ThreadError!Mutex {
        _ = attr; // Recursive mutexes not directly supported yet
        return Mutex{ .inner = .{} };
    }

    pub fn deinit(self: *Mutex) void {
        _ = self;
    }

    pub fn lock(self: *Mutex) ThreadError!void {
        self.inner.lock();
    }

    pub fn tryLock(self: *Mutex) ThreadError!bool {
        return self.inner.tryLock();
    }

    pub fn unlock(self: *Mutex) ThreadError!void {
        self.inner.unlock();
    }

    pub const Guard = struct {
        mutex: *Mutex,

        pub fn deinit(self: Guard) void {
            self.mutex.unlock() catch {};
        }
    };

    pub fn lockGuard(self: *Mutex) ThreadError!Guard {
        try self.lock();
        return Guard{ .mutex = self };
    }
};

pub const MutexAttr = struct {
    recursive: bool = false,

    pub fn init() MutexAttr {
        return .{};
    }

    pub fn setRecursive(self: *MutexAttr, recursive: bool) void {
        self.recursive = recursive;
    }
};

test "mutex init and deinit" {
    var mutex = try Mutex.init();
    defer mutex.deinit();
}

test "mutex lock and unlock" {
    var mutex = try Mutex.init();
    defer mutex.deinit();

    try mutex.lock();
    try mutex.unlock();
}

test "mutex tryLock" {
    var mutex = try Mutex.init();
    defer mutex.deinit();

    const locked = try mutex.tryLock();
    const testing = std.testing;
    try testing.expect(locked);
    try mutex.unlock();
}
