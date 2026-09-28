// Home Programming Language - Read-Write Locks
// Writer-preferring shared/exclusive lock with futex-backed blocking

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;
const Futex = @import("threading_futex");

pub const RwLock = struct {
    state: std.atomic.Value(u32),
    waiting_writers: std.atomic.Value(u32),

    const writer_bit: u32 = 1 << 31;
    const reader_mask: u32 = writer_bit - 1;

    pub fn init() ThreadError!RwLock {
        return RwLock{
            .state = std.atomic.Value(u32).init(0),
            .waiting_writers = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *RwLock) void {
        _ = self;
    }

    /// Acquire shared (read) access.  Multiple readers may hold this
    /// concurrently. New readers block while a writer holds or waits for the
    /// lock so a stream of readers cannot starve writers.
    pub fn lockRead(self: *RwLock) ThreadError!void {
        var state = self.state.load(.acquire);
        while (true) {
            if (state & writer_bit != 0 or self.waiting_writers.load(.acquire) != 0) {
                Futex.waitForever(&self.state, state);
                state = self.state.load(.acquire);
                continue;
            }

            if (state & reader_mask == reader_mask) return ThreadError.RwLockReadFailed;
            state = self.state.cmpxchgWeak(state, state + 1, .acquire, .monotonic) orelse return;
        }
    }

    /// Acquire exclusive (write) access.  Blocks while any reader or
    /// another writer holds the lock.
    pub fn lockWrite(self: *RwLock) ThreadError!void {
        var waiting = self.waiting_writers.load(.monotonic);
        while (true) {
            if (waiting == std.math.maxInt(u32)) return ThreadError.RwLockWriteFailed;
            waiting = self.waiting_writers.cmpxchgWeak(waiting, waiting + 1, .acq_rel, .monotonic) orelse break;
        }

        var state = self.state.load(.acquire);
        while (true) {
            if (state == 0) {
                state = self.state.cmpxchgWeak(0, writer_bit, .acquire, .monotonic) orelse {
                    _ = self.waiting_writers.fetchSub(1, .release);
                    return;
                };
                continue;
            }
            Futex.waitForever(&self.state, state);
            state = self.state.load(.acquire);
        }
    }

    pub fn unlockRead(self: *RwLock) ThreadError!void {
        var state = self.state.load(.monotonic);
        while (true) {
            if (state & writer_bit != 0 or state & reader_mask == 0) return ThreadError.RwLockUnlockFailed;
            const next = state - 1;
            state = self.state.cmpxchgWeak(state, next, .release, .monotonic) orelse {
                if (next == 0 and self.waiting_writers.load(.acquire) != 0) {
                    Futex.wake(&self.state, std.math.maxInt(u32));
                }
                return;
            };
        }
    }

    pub fn unlockWrite(self: *RwLock) ThreadError!void {
        if (self.state.cmpxchgStrong(writer_bit, 0, .release, .monotonic) != null) {
            return ThreadError.RwLockUnlockFailed;
        }
        Futex.wake(&self.state, std.math.maxInt(u32));
    }
};

test "rwlock init" {
    var lock = try RwLock.init();
    defer lock.deinit();
}

test "rwlock permits concurrent readers" {
    const thread_count = 8;
    var lock = try RwLock.init();
    defer lock.deinit();

    const Context = struct {
        lock: *RwLock,
        inside: std.atomic.Value(u32) = .init(0),
        release: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),

        fn reader(context: *@This()) void {
            context.lock.lockRead() catch {
                context.failed.store(true, .release);
                return;
            };
            _ = context.inside.fetchAdd(1, .release);
            while (!context.release.load(.acquire)) std.Thread.yield() catch {};
            context.lock.unlockRead() catch context.failed.store(true, .release);
        }
    };

    var context = Context{ .lock = &lock };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Context.reader, .{&context});
    }
    while (context.inside.load(.acquire) != thread_count) std.Thread.yield() catch {};
    context.release.store(true, .release);
    for (threads) |thread| thread.join();

    try std.testing.expect(!context.failed.load(.acquire));
}

test "rwlock serializes writers while readers observe protected state" {
    const writer_count = 4;
    const reader_count = 4;
    const increments_per_writer = 1_000;
    const reads_per_reader = 1_000;

    var lock = try RwLock.init();
    defer lock.deinit();
    var value: usize = 0;

    const Context = struct {
        lock: *RwLock,
        value: *usize,
        failed: std.atomic.Value(bool) = .init(false),

        fn writer(context: *@This()) void {
            for (0..increments_per_writer) |_| {
                context.lock.lockWrite() catch {
                    context.failed.store(true, .release);
                    return;
                };
                context.value.* += 1;
                context.lock.unlockWrite() catch {
                    context.failed.store(true, .release);
                    return;
                };
            }
        }

        fn reader(context: *@This()) void {
            for (0..reads_per_reader) |_| {
                context.lock.lockRead() catch {
                    context.failed.store(true, .release);
                    return;
                };
                std.mem.doNotOptimizeAway(context.value.*);
                context.lock.unlockRead() catch {
                    context.failed.store(true, .release);
                    return;
                };
            }
        }
    };

    var context = Context{ .lock = &lock, .value = &value };
    var writers: [writer_count]std.Thread = undefined;
    var readers: [reader_count]std.Thread = undefined;
    for (&writers) |*thread| thread.* = try std.Thread.spawn(.{}, Context.writer, .{&context});
    for (&readers) |*thread| thread.* = try std.Thread.spawn(.{}, Context.reader, .{&context});
    for (writers) |thread| thread.join();
    for (readers) |thread| thread.join();

    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, writer_count * increments_per_writer), value);
}
