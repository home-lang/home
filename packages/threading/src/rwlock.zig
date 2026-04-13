// Home Programming Language - Read-Write Locks
// Allows multiple concurrent readers OR one exclusive writer.
// Uses a mutex to protect the reader counter and a write lock flag.

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

pub const RwLock = struct {
    mutex: std.atomic.Mutex,
    /// Number of active readers.  Protected by `mutex`.
    readers: std.atomic.Value(u32),
    /// True when a writer holds the lock.
    writing: std.atomic.Value(bool),

    pub fn init() ThreadError!RwLock {
        return RwLock{
            .mutex = .unlocked,
            .readers = std.atomic.Value(u32).init(0),
            .writing = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *RwLock) void {
        _ = self;
    }

    /// Acquire shared (read) access.  Multiple readers may hold this
    /// concurrently.  Blocks while a writer holds the lock.
    pub fn lockRead(self: *RwLock) ThreadError!void {
        while (true) {
            while (self.writing.load(.acquire)) {
                std.atomic.spinLoopHint();
            }
            _ = self.readers.fetchAdd(1, .acq_rel);
            // Double-check a writer didn't sneak in.
            if (self.writing.load(.acquire)) {
                _ = self.readers.fetchSub(1, .acq_rel);
                continue;
            }
            return;
        }
    }

    /// Acquire exclusive (write) access.  Blocks while any reader or
    /// another writer holds the lock.
    pub fn lockWrite(self: *RwLock) ThreadError!void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        self.writing.store(true, .release);
        // Wait for all readers to finish.
        while (self.readers.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockRead(self: *RwLock) ThreadError!void {
        _ = self.readers.fetchSub(1, .acq_rel);
    }

    pub fn unlockWrite(self: *RwLock) ThreadError!void {
        self.writing.store(false, .release);
        self.mutex.unlock();
    }
};

test "rwlock init" {
    var lock = try RwLock.init();
    defer lock.deinit();
}
