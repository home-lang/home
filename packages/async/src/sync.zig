const std = @import("std");
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const PollResult = future_mod.PollResult;
const Context = future_mod.Context;
const Waker = future_mod.Waker;

/// Async mutex for protecting shared data
///
/// Unlike std.Thread.Mutex which blocks threads, this async Mutex
/// yields control back to the executor when the lock is contended.
pub fn Mutex(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The protected data
        data: T,
        /// Is the mutex currently locked?
        locked: std.atomic.Value(bool),
        /// Queue of waiting tasks
        waiters: std.ArrayList(*Waker),
        /// Protects the waiter queue
        queue_mutex: std.Thread.Mutex,

        pub fn init(data: T, allocator: std.mem.Allocator) Self {
            return .{
                .data = data,
                .locked = std.atomic.Value(bool).init(false),
                .waiters = std.ArrayList(*Waker).init(allocator),
                .queue_mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            // Wake all waiters before cleanup
            self.queue_mutex.lock();
            for (self.waiters.items) |waker| {
                waker.drop();
            }
            self.queue_mutex.unlock();

            self.waiters.deinit();
        }

        /// Lock the mutex, returning a future that resolves to a guard
        pub fn lock(self: *Self) LockFuture(T) {
            return LockFuture(T){
                .mutex = self,
                .registered: false,
            };
        }

        /// Try to lock without blocking
        pub fn tryLock(self: *Self) ?MutexGuard(T) {
            if (self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                return MutexGuard(T){ .mutex = self };
            }
            return null;
        }

        fn unlock(self: *Self) void {
            self.locked.store(false, .release);

            // Wake one waiter
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();

            if (self.waiters.items.len > 0) {
                const waker = self.waiters.orderedRemove(0);
                waker.wake();
            }
        }
    };
}

/// Future for locking a mutex
fn LockFuture(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: *Mutex(T),
        registered: bool,

        pub fn poll(self: *Self, ctx: *Context) PollResult(*MutexGuard(T)) {
            // Try to acquire lock
            if (self.mutex.tryLock()) |guard| {
                return .{ .Ready = &guard };
            }

            // Register waker if not already registered
            if (!self.registered) {
                self.mutex.queue_mutex.lock();
                defer self.mutex.queue_mutex.unlock();

                self.mutex.waiters.append(&ctx.waker.*) catch {
                    return .Pending;
                };

                self.registered = true;
            }

            return .Pending;
        }
    };
}

/// RAII guard for mutex
pub fn MutexGuard(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: *Mutex(T),

        /// Access the protected data
        pub fn get(self: *Self) *T {
            return &self.mutex.data;
        }

        /// Release the lock (called automatically on deinit)
        pub fn unlock(self: *Self) void {
            self.mutex.unlock();
        }

        pub fn deinit(self: *Self) void {
            self.unlock();
        }
    };
}

/// Async reader-writer lock
///
/// Allows multiple concurrent readers or one exclusive writer.
pub fn RwLock(comptime T: type) type {
    return struct {
        const Self = @This();

        const State = enum {
            Unlocked,
            ReadLocked,
            WriteLocked,
        };

        data: T,
        state: std.atomic.Value(u8), // 0=unlocked, >0=readers, 255=writer
        read_waiters: std.ArrayList(*Waker),
        write_waiters: std.ArrayList(*Waker),
        queue_mutex: std.Thread.Mutex,

        pub fn init(data: T, allocator: std.mem.Allocator) Self {
            return .{
                .data = data,
                .state = std.atomic.Value(u8).init(0),
                .read_waiters = std.ArrayList(*Waker).init(allocator),
                .write_waiters = std.ArrayList(*Waker).init(allocator),
                .queue_mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue_mutex.lock();
            for (self.read_waiters.items) |waker| {
                waker.drop();
            }
            for (self.write_waiters.items) |waker| {
                waker.drop();
            }
            self.queue_mutex.unlock();

            self.read_waiters.deinit();
            self.write_waiters.deinit();
        }

        /// Acquire read lock
        pub fn read(self: *Self) ReadLockFuture(T) {
            return ReadLockFuture(T){
                .rwlock = self,
                .registered = false,
            };
        }

        /// Acquire write lock
        pub fn write(self: *Self) WriteLockFuture(T) {
            return WriteLockFuture(T){
                .rwlock = self,
                .registered = false,
            };
        }

        /// Try to acquire read lock
        pub fn tryRead(self: *Self) ?ReadGuard(T) {
            while (true) {
                const current = self.state.load(.acquire);

                // Can't read if there's a writer
                if (current == 255) return null;

                // Try to increment reader count
                if (self.state.cmpxchgWeak(
                    current,
                    current + 1,
                    .acquire,
                    .monotonic,
                ) == null) {
                    return ReadGuard(T){ .rwlock = self };
                }
            }
        }

        /// Try to acquire write lock
        pub fn tryWrite(self: *Self) ?WriteGuard(T) {
            if (self.state.cmpxchgStrong(0, 255, .acquire, .monotonic) == null) {
                return WriteGuard(T){ .rwlock = self };
            }
            return null;
        }

        fn unlockRead(self: *Self) void {
            const prev = self.state.fetchSub(1, .release);

            // If we were the last reader, wake a writer
            if (prev == 1) {
                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();

                if (self.write_waiters.items.len > 0) {
                    const waker = self.write_waiters.orderedRemove(0);
                    waker.wake();
                }
            }
        }

        fn unlockWrite(self: *Self) void {
            self.state.store(0, .release);

            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();

            // Wake all readers or one writer
            if (self.read_waiters.items.len > 0) {
                for (self.read_waiters.items) |waker| {
                    waker.wake();
                }
                self.read_waiters.clearRetainingCapacity();
            } else if (self.write_waiters.items.len > 0) {
                const waker = self.write_waiters.orderedRemove(0);
                waker.wake();
            }
        }
    };
}

fn ReadLockFuture(comptime T: type) type {
    return struct {
        const Self = @This();

        rwlock: *RwLock(T),
        registered: bool,

        pub fn poll(self: *Self, ctx: *Context) PollResult(*ReadGuard(T)) {
            if (self.rwlock.tryRead()) |guard| {
                return .{ .Ready = &guard };
            }

            if (!self.registered) {
                self.rwlock.queue_mutex.lock();
                defer self.rwlock.queue_mutex.unlock();

                self.rwlock.read_waiters.append(&ctx.waker.*) catch {
                    return .Pending;
                };

                self.registered = true;
            }

            return .Pending;
        }
    };
}

fn WriteLockFuture(comptime T: type) type {
    return struct {
        const Self = @This();

        rwlock: *RwLock(T),
        registered: bool,

        pub fn poll(self: *Self, ctx: *Context) PollResult(*WriteGuard(T)) {
            if (self.rwlock.tryWrite()) |guard| {
                return .{ .Ready = &guard };
            }

            if (!self.registered) {
                self.rwlock.queue_mutex.lock();
                defer self.rwlock.queue_mutex.unlock();

                self.rwlock.write_waiters.append(&ctx.waker.*) catch {
                    return .Pending;
                };

                self.registered = true;
            }

            return .Pending;
        }
    };
}

pub fn ReadGuard(comptime T: type) type {
    return struct {
        const Self = @This();

        rwlock: *RwLock(T),

        pub fn get(self: *const Self) *const T {
            return &self.rwlock.data;
        }

        pub fn deinit(self: *Self) void {
            self.rwlock.unlockRead();
        }
    };
}

pub fn WriteGuard(comptime T: type) type {
    return struct {
        const Self = @This();

        rwlock: *RwLock(T),

        pub fn get(self: *Self) *T {
            return &self.rwlock.data;
        }

        pub fn deinit(self: *Self) void {
            self.rwlock.unlockWrite();
        }
    };
}

/// Async semaphore for limiting concurrent access
pub const Semaphore = struct {
    permits: std.atomic.Value(usize),
    waiters: std.ArrayList(*Waker),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, permits: usize) Semaphore {
        return .{
            .permits = std.atomic.Value(usize).init(permits),
            .waiters = std.ArrayList(*Waker).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Semaphore) void {
        self.mutex.lock();
        for (self.waiters.items) |waker| {
            waker.drop();
        }
        self.mutex.unlock();

        self.waiters.deinit();
    }

    pub fn acquire(self: *Semaphore) AcquireFuture {
        return AcquireFuture{
            .semaphore = self,
            .registered = false,
        };
    }

    pub fn tryAcquire(self: *Semaphore) bool {
        while (true) {
            const current = self.permits.load(.acquire);
            if (current == 0) return false;

            if (self.permits.cmpxchgWeak(
                current,
                current - 1,
                .acquire,
                .monotonic,
            ) == null) {
                return true;
            }
        }
    }

    pub fn release(self: *Semaphore) void {
        _ = self.permits.fetchAdd(1, .release);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.waiters.items.len > 0) {
            const waker = self.waiters.orderedRemove(0);
            waker.wake();
        }
    }

    const AcquireFuture = struct {
        semaphore: *Semaphore,
        registered: bool,

        pub fn poll(self: *@This(), ctx: *Context) PollResult(void) {
            if (self.semaphore.tryAcquire()) {
                return .{ .Ready = {} };
            }

            if (!self.registered) {
                self.semaphore.mutex.lock();
                defer self.semaphore.mutex.unlock();

                self.semaphore.waiters.append(&ctx.waker.*) catch {
                    return .Pending;
                };

                self.registered = true;
            }

            return .Pending;
        }
    };
};

// =================================================================================
//                                    TESTS
// =================================================================================

test "Mutex - basic lock and unlock" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mutex = Mutex(i32).init(42, allocator);
    defer mutex.deinit();

    // Try lock should succeed
    var guard = mutex.tryLock().?;
    try testing.expectEqual(@as(i32, 42), guard.get().*);

    guard.get().* = 100;
    try testing.expectEqual(@as(i32, 100), guard.get().*);

    guard.unlock();

    // Should be unlocked now
    var guard2 = mutex.tryLock().?;
    try testing.expectEqual(@as(i32, 100), guard2.get().*);
    guard2.unlock();
}

test "Mutex - contention" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mutex = Mutex(i32).init(0, allocator);
    defer mutex.deinit();

    var guard = mutex.tryLock().?;

    // Second try should fail
    try testing.expect(mutex.tryLock() == null);

    guard.unlock();

    // Now should succeed
    try testing.expect(mutex.tryLock() != null);
}

test "RwLock - multiple readers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var rwlock = RwLock(i32).init(42, allocator);
    defer rwlock.deinit();

    var guard1 = rwlock.tryRead().?;
    var guard2 = rwlock.tryRead().?;

    try testing.expectEqual(@as(i32, 42), guard1.get().*);
    try testing.expectEqual(@as(i32, 42), guard2.get().*);

    guard1.deinit();
    guard2.deinit();
}

test "RwLock - exclusive writer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var rwlock = RwLock(i32).init(42, allocator);
    defer rwlock.deinit();

    var write_guard = rwlock.tryWrite().?;

    // Can't get another write lock
    try testing.expect(rwlock.tryWrite() == null);

    // Can't get read lock while writing
    try testing.expect(rwlock.tryRead() == null);

    write_guard.get().* = 100;
    write_guard.deinit();

    // Now can read
    var read_guard = rwlock.tryRead().?;
    try testing.expectEqual(@as(i32, 100), read_guard.get().*);
    read_guard.deinit();
}

test "Semaphore - basic acquire and release" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var sem = Semaphore.init(allocator, 2);
    defer sem.deinit();

    try testing.expect(sem.tryAcquire());
    try testing.expect(sem.tryAcquire());
    try testing.expect(!sem.tryAcquire()); // Out of permits

    sem.release();
    try testing.expect(sem.tryAcquire()); // Now available
}
