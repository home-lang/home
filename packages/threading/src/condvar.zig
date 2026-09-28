// Home Programming Language - Condition Variables
// Futex-backed condition variable with monotonic relative timeouts

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;
const Mutex = @import("mutex.zig").Mutex;
const Futex = @import("threading_futex");

pub const CondVar = struct {
    epoch: std.atomic.Value(u32),

    pub fn init() ThreadError!CondVar {
        return CondVar{ .epoch = std.atomic.Value(u32).init(0) };
    }

    pub fn deinit(self: *CondVar) void {
        _ = self;
    }

    pub fn wait(self: *CondVar, mutex: *Mutex) ThreadError!void {
        const observed = self.epoch.load(.acquire);
        try mutex.unlock();
        Futex.waitForever(&self.epoch, observed);
        try mutex.lock();
    }

    pub fn waitTimeout(self: *CondVar, mutex: *Mutex, timeout_ns: u64) ThreadError!bool {
        const observed = self.epoch.load(.acquire);
        try mutex.unlock();
        Futex.wait(&self.epoch, observed, timeout_ns) catch {
            try mutex.lock();
            return false;
        };
        try mutex.lock();
        return true;
    }

    pub fn signal(self: *CondVar) ThreadError!void {
        _ = self.epoch.fetchAdd(1, .release);
        Futex.wake(&self.epoch, 1);
    }

    pub fn broadcast(self: *CondVar) ThreadError!void {
        _ = self.epoch.fetchAdd(1, .release);
        Futex.wake(&self.epoch, std.math.maxInt(u32));
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

test "condvar does not remember signals and reacquires after timeout" {
    var mutex = try Mutex.init();
    defer mutex.deinit();
    var cv = try CondVar.init();
    defer cv.deinit();

    try cv.signal();
    try mutex.lock();
    try std.testing.expect(!try cv.waitTimeout(&mutex, std.time.ns_per_ms));
    try mutex.unlock();
}

test "condvar signal wakes eight waiters one at a time" {
    const thread_count = 8;
    var mutex = try Mutex.init();
    defer mutex.deinit();
    var cv = try CondVar.init();
    defer cv.deinit();

    const Context = struct {
        mutex: *Mutex,
        condvar: *CondVar,
        waiting: std.atomic.Value(u32) = .init(0),
        completed: std.atomic.Value(u32) = .init(0),
        tickets: u32 = 0,
        failed: std.atomic.Value(bool) = .init(false),

        fn worker(context: *@This()) void {
            context.mutex.lock() catch {
                context.failed.store(true, .release);
                return;
            };
            _ = context.waiting.fetchAdd(1, .release);
            while (context.tickets == 0) {
                context.condvar.wait(context.mutex) catch {
                    context.failed.store(true, .release);
                    context.mutex.unlock() catch {};
                    return;
                };
            }
            context.tickets -= 1;
            _ = context.completed.fetchAdd(1, .release);
            context.mutex.unlock() catch context.failed.store(true, .release);
        }
    };

    var context = Context{ .mutex = &mutex, .condvar = &cv };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Context.worker, .{&context});
    }
    while (context.waiting.load(.acquire) != thread_count) std.Thread.yield() catch {};

    for (1..thread_count + 1) |expected_completed| {
        try mutex.lock();
        context.tickets += 1;
        try cv.signal();
        try mutex.unlock();
        while (context.completed.load(.acquire) != expected_completed) std.Thread.yield() catch {};
    }
    for (threads) |thread| thread.join();

    try std.testing.expect(!context.failed.load(.acquire));
}

test "condvar broadcast wakes eight waiters" {
    const thread_count = 8;
    var mutex = try Mutex.init();
    defer mutex.deinit();
    var cv = try CondVar.init();
    defer cv.deinit();

    const Context = struct {
        mutex: *Mutex,
        condvar: *CondVar,
        waiting: std.atomic.Value(u32) = .init(0),
        completed: std.atomic.Value(u32) = .init(0),
        released: bool = false,
        failed: std.atomic.Value(bool) = .init(false),

        fn worker(context: *@This()) void {
            context.mutex.lock() catch {
                context.failed.store(true, .release);
                return;
            };
            _ = context.waiting.fetchAdd(1, .release);
            while (!context.released) {
                context.condvar.wait(context.mutex) catch {
                    context.failed.store(true, .release);
                    context.mutex.unlock() catch {};
                    return;
                };
            }
            _ = context.completed.fetchAdd(1, .release);
            context.mutex.unlock() catch context.failed.store(true, .release);
        }
    };

    var context = Context{ .mutex = &mutex, .condvar = &cv };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Context.worker, .{&context});
    }
    while (context.waiting.load(.acquire) != thread_count) std.Thread.yield() catch {};

    try mutex.lock();
    context.released = true;
    try cv.broadcast();
    try mutex.unlock();
    for (threads) |thread| thread.join();

    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expectEqual(@as(u32, thread_count), context.completed.load(.acquire));
}
