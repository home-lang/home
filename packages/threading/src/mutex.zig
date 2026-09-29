// Home Programming Language - Mutex Primitives
// Blocking mutex built on Home's shared futex layer

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;
const Futex = @import("threading_futex");

pub const Mutex = struct {
    state: std.atomic.Value(u32),

    const unlocked: u32 = 0b00;
    const locked: u32 = 0b01;
    const contended: u32 = 0b11;

    pub fn init() ThreadError!Mutex {
        return Mutex{ .state = std.atomic.Value(u32).init(unlocked) };
    }

    pub fn initWithAttr(attr: MutexAttr) ThreadError!Mutex {
        if (attr.recursive) return ThreadError.OperationNotSupported;
        return init();
    }

    pub fn deinit(self: *Mutex) void {
        _ = self;
    }

    pub fn lock(self: *Mutex) ThreadError!void {
        if (try self.tryLock()) return;

        if (self.state.load(.monotonic) == contended) {
            Futex.waitForever(&self.state, contended);
        }
        while (self.state.swap(contended, .acquire) != unlocked) {
            Futex.waitForever(&self.state, contended);
        }
    }

    pub fn tryLock(self: *Mutex) ThreadError!bool {
        return self.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *Mutex) ThreadError!void {
        const previous = self.state.swap(unlocked, .release);
        if (previous == unlocked) return ThreadError.MutexUnlockFailed;
        if (previous == contended) Futex.wake(&self.state, 1);
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

/// Statically initialized, std-compatible facade for code whose lock API is
/// intentionally infallible. The underlying futex mutex reports programmer
/// misuse as `ThreadError`; this facade turns that impossible path into a
/// panic while preserving the familiar `lock`/`unlock` contract.
pub const StaticMutex = struct {
    inner: Mutex = .{ .state = .init(0) },

    pub fn lock(self: *StaticMutex) void {
        self.inner.lock() catch |err| std.debug.panic("mutex lock failed: {}", .{err});
    }

    pub fn tryLock(self: *StaticMutex) bool {
        return self.inner.tryLock() catch |err| std.debug.panic("mutex tryLock failed: {}", .{err});
    }

    pub fn unlock(self: *StaticMutex) void {
        self.inner.unlock() catch |err| std.debug.panic("mutex unlock failed: {}", .{err});
    }

    pub fn deinit(self: *StaticMutex) void {
        self.inner.deinit();
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

test "mutex rejects recursive attributes instead of ignoring them" {
    var attr = MutexAttr.init();
    attr.setRecursive(true);
    try std.testing.expectError(ThreadError.OperationNotSupported, Mutex.initWithAttr(attr));
}

test "static mutex supports infallible lock APIs" {
    var mutex: StaticMutex = .{};
    defer mutex.deinit();

    mutex.lock();
    mutex.unlock();
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

test "mutex protects a counter across eight threads" {
    const thread_count = 8;
    const increments_per_thread = 1_000;

    var mutex = try Mutex.init();
    defer mutex.deinit();
    var counter: usize = 0;

    const Context = struct {
        mutex: *Mutex,
        counter: *usize,
        failed: std.atomic.Value(bool) = .init(false),

        fn worker(context: *@This()) void {
            for (0..increments_per_thread) |_| {
                context.mutex.lock() catch {
                    context.failed.store(true, .release);
                    return;
                };
                context.counter.* += 1;
                context.mutex.unlock() catch {
                    context.failed.store(true, .release);
                    return;
                };
            }
        }
    };

    var context = Context{ .mutex = &mutex, .counter = &counter };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Context.worker, .{&context});
    }
    for (threads) |thread| thread.join();

    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, thread_count * increments_per_thread), counter);
}
