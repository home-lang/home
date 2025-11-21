const std = @import("std");
const Future = @import("async_runtime.zig").Future;

/// Async-safe channel for message passing between tasks
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        queue: std.ArrayList(T),
        mutex: std.Thread.Mutex,
        receivers_waiting: usize,
        closed: bool,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .queue = std.ArrayList(T){},
                .mutex = .{},
                .receivers_waiting = 0,
                .closed = false,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.deinit(self.allocator);
        }

        /// Send a value into the channel
        pub fn send(self: *Self, value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) {
                return error.ChannelClosed;
            }

            try self.queue.append(self.allocator, value);
        }

        /// Receive a value from the channel (blocking)
        pub fn recv(self: *Self) !?T {
            while (true) {
                self.mutex.lock();

                if (self.queue.items.len > 0) {
                    const value = self.queue.orderedRemove(0);
                    self.mutex.unlock();
                    return value;
                }

                if (self.closed) {
                    self.mutex.unlock();
                    return null;
                }

                self.mutex.unlock();
                std.posix.nanosleep(0, 100_000); // 0.1ms
            }
        }

        /// Try to receive without blocking
        pub fn try_recv(self: *Self) !?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.items.len > 0) {
                return self.queue.orderedRemove(0);
            }

            return null;
        }

        /// Close the channel
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
        }
    };
}

/// Async mutex for safe concurrent access
pub const AsyncMutex = struct {
    locked: bool,
    inner_mutex: std.Thread.Mutex,

    pub fn init() AsyncMutex {
        return .{
            .locked = false,
            .inner_mutex = .{},
        };
    }

    pub fn lock(self: *AsyncMutex) void {
        self.inner_mutex.lock();
        while (self.locked) {
            self.inner_mutex.unlock();
            std.posix.nanosleep(0, 100_000); // 0.1ms
            self.inner_mutex.lock();
        }
        self.locked = true;
        self.inner_mutex.unlock();
    }

    pub fn unlock(self: *AsyncMutex) void {
        self.inner_mutex.lock();
        defer self.inner_mutex.unlock();
        self.locked = false;
    }

    pub fn try_lock(self: *AsyncMutex) bool {
        self.inner_mutex.lock();
        defer self.inner_mutex.unlock();

        if (self.locked) {
            return false;
        }

        self.locked = true;
        return true;
    }
};

/// RwLock for multiple readers or single writer
pub const AsyncRwLock = struct {
    readers: usize,
    writer: bool,
    mutex: std.Thread.Mutex,

    pub fn init() AsyncRwLock {
        return .{
            .readers = 0,
            .writer = false,
            .mutex = .{},
        };
    }

    pub fn read_lock(self: *AsyncRwLock) void {
        while (true) {
            self.mutex.lock();

            if (!self.writer) {
                self.readers += 1;
                self.mutex.unlock();
                return;
            }

            self.mutex.unlock();
            std.posix.nanosleep(0, 100_000); // 0.1ms
        }
    }

    pub fn read_unlock(self: *AsyncRwLock) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.readers -= 1;
    }

    pub fn write_lock(self: *AsyncRwLock) void {
        while (true) {
            self.mutex.lock();

            if (!self.writer and self.readers == 0) {
                self.writer = true;
                self.mutex.unlock();
                return;
            }

            self.mutex.unlock();
            std.posix.nanosleep(0, 100_000); // 0.1ms
        }
    }

    pub fn write_unlock(self: *AsyncRwLock) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.writer = false;
    }
};

/// Semaphore for limiting concurrent access
pub const Semaphore = struct {
    permits: usize,
    max_permits: usize,
    mutex: std.Thread.Mutex,

    pub fn init(max_permits: usize) Semaphore {
        return .{
            .permits = max_permits,
            .max_permits = max_permits,
            .mutex = .{},
        };
    }

    pub fn acquire(self: *Semaphore) void {
        while (true) {
            self.mutex.lock();

            if (self.permits > 0) {
                self.permits -= 1;
                self.mutex.unlock();
                return;
            }

            self.mutex.unlock();
            std.posix.nanosleep(0, 100_000); // 0.1ms
        }
    }

    pub fn release(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.permits < self.max_permits) {
            self.permits += 1;
        }
    }

    pub fn try_acquire(self: *Semaphore) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.permits > 0) {
            self.permits -= 1;
            return true;
        }

        return false;
    }
};

/// Barrier for synchronizing multiple tasks
pub const Barrier = struct {
    num_tasks: usize,
    waiting: usize,
    generation: usize,
    mutex: std.Thread.Mutex,

    pub fn init(num_tasks: usize) Barrier {
        return .{
            .num_tasks = num_tasks,
            .waiting = 0,
            .generation = 0,
            .mutex = .{},
        };
    }

    pub fn wait(self: *Barrier) void {
        self.mutex.lock();
        const gen = self.generation;
        self.waiting += 1;

        if (self.waiting == self.num_tasks) {
            // Last task to arrive
            self.waiting = 0;
            self.generation += 1;
            self.mutex.unlock();
            return;
        }

        self.mutex.unlock();

        // Wait for generation to change
        while (true) {
            self.mutex.lock();
            if (gen != self.generation) {
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();
            std.posix.nanosleep(0, 100_000); // 0.1ms
        }
    }
};
