// Copied from bun/src/event_loop/DeferredTaskQueue.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt").

//! Sometimes, you have work that will be scheduled, cancelled, and rescheduled multiple times
//! The order of that work may not particularly matter.
//!
//! An example of this is when writing to a file or network socket.
//!
//! You want to balance:
//!     1) Writing as much as possible to the file/socket in as few system calls as possible
//!     2) Writing to the file/socket as soon as possible
//!
//! That is a scheduling problem. How do you decide when to write to the file/socket? Developers
//! don't want to remember to call `flush` every time they write to a file/socket, but we don't
//! want them to have to think about buffering or not buffering either.
//!
//! Our answer to this is the DeferredTaskQueue.
//!
//! When you call write() when sending a streaming HTTP response, we don't actually write it immediately
//! by default. Instead, we wait until the end of the microtask queue to write it, unless either:
//!
//! - The buffer is full
//! - The developer calls `flush` manually
//!
//! But that means every time you call .write(), we have to check not only if the buffer is full, but also if
//! it previously had scheduled a write to the file/socket. So we use an ArrayHashMap to keep track of the
//! list of pointers which have a deferred task scheduled.
//!
//! The DeferredTaskQueue is drained after the microtask queue, but before other tasks are executed. This avoids re-entrancy
//! issues with the event loop.

const DeferredTaskQueue = @This();

pub const DeferredRepeatingTask = *const (fn (*anyopaque) bool);

map: std.AutoArrayHashMapUnmanaged(?*anyopaque, DeferredRepeatingTask) = .{},

pub fn postTask(this: *DeferredTaskQueue, ctx: ?*anyopaque, task: DeferredRepeatingTask) bool {
    const existing = home_rt.handleOom(this.map.getOrPutValue(home_rt.default_allocator, ctx, task));
    return existing.found_existing;
}

pub fn unregisterTask(this: *DeferredTaskQueue, ctx: ?*anyopaque) bool {
    return this.map.swapRemove(ctx);
}

pub fn run(this: *DeferredTaskQueue) void {
    var i: usize = 0;
    var last = this.map.count();
    while (i < last) {
        const key = this.map.keys()[i] orelse {
            this.map.swapRemoveAt(i);
            last = this.map.count();
            continue;
        };

        if (!this.map.values()[i](key)) {
            this.map.swapRemoveAt(i);
            last = this.map.count();
        } else {
            i += 1;
        }
    }
}

pub fn deinit(this: *DeferredTaskQueue) void {
    this.map.deinit(home_rt.default_allocator);
}

const home_rt = @import("home_rt");
const std = @import("std");

// ---- Inline tests -----------------------------------------------------
// Verifies the queue schedules, drains, and unregisters tasks correctly
// using the same Pointer-as-key contract as upstream Bun.

const testing = std.testing;

const TestCounter = struct {
    var instance: TestCounter = .{};

    runs: u32 = 0,
    keep_going_until: u32 = 0,

    fn reset(self: *TestCounter, keep_going_until: u32) void {
        self.runs = 0;
        self.keep_going_until = keep_going_until;
    }

    fn callback(ctx: *anyopaque) bool {
        const self: *TestCounter = @ptrCast(@alignCast(ctx));
        self.runs += 1;
        return self.runs < self.keep_going_until;
    }
};

test "DeferredTaskQueue: postTask schedules a task and run drains it" {
    var q: DeferredTaskQueue = .{};
    defer q.deinit();

    TestCounter.instance.reset(1);

    const found_existing = q.postTask(&TestCounter.instance, TestCounter.callback);
    try testing.expect(!found_existing);
    try testing.expectEqual(@as(usize, 1), q.map.count());

    q.run();
    try testing.expectEqual(@as(u32, 1), TestCounter.instance.runs);
    // Callback returned false after the first run, so the task should
    // have been removed.
    try testing.expectEqual(@as(usize, 0), q.map.count());
}

test "DeferredTaskQueue: repeating tasks stay queued until they return false" {
    var q: DeferredTaskQueue = .{};
    defer q.deinit();

    TestCounter.instance.reset(3);

    _ = q.postTask(&TestCounter.instance, TestCounter.callback);
    q.run();
    // 1 run, still queued
    try testing.expectEqual(@as(u32, 1), TestCounter.instance.runs);
    try testing.expectEqual(@as(usize, 1), q.map.count());

    q.run();
    try testing.expectEqual(@as(u32, 2), TestCounter.instance.runs);
    try testing.expectEqual(@as(usize, 1), q.map.count());

    q.run();
    // 3rd run returns false, queue should drain
    try testing.expectEqual(@as(u32, 3), TestCounter.instance.runs);
    try testing.expectEqual(@as(usize, 0), q.map.count());
}

test "DeferredTaskQueue: unregisterTask removes a pending task" {
    var q: DeferredTaskQueue = .{};
    defer q.deinit();

    TestCounter.instance.reset(99); // would loop forever if drained

    _ = q.postTask(&TestCounter.instance, TestCounter.callback);
    try testing.expectEqual(@as(usize, 1), q.map.count());

    const removed = q.unregisterTask(&TestCounter.instance);
    try testing.expect(removed);
    try testing.expectEqual(@as(usize, 0), q.map.count());

    // Run on the now-empty queue is a no-op.
    q.run();
    try testing.expectEqual(@as(u32, 0), TestCounter.instance.runs);
}

test "DeferredTaskQueue: postTask returns found_existing on duplicate ctx" {
    var q: DeferredTaskQueue = .{};
    defer q.deinit();

    TestCounter.instance.reset(1);

    const first = q.postTask(&TestCounter.instance, TestCounter.callback);
    try testing.expect(!first);
    const second = q.postTask(&TestCounter.instance, TestCounter.callback);
    try testing.expect(second);
    try testing.expectEqual(@as(usize, 1), q.map.count());
}
