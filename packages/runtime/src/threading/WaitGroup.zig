// Copied from bun/src/threading/WaitGroup.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt").
// Rewrites:
//   * `bun.threading.Condition` / `.Mutex` → local
//     `@import("./Condition.zig")` / `@import("./Mutex.zig")`.
//
// This file contains code derived from the following source:
//   https://gist.github.com/kprotty/0d2dc3da4840341d6ff361b27bdac7dc#file-sync-zig
//
// That code contains the following license and copyright notice:
//   SPDX-License-Identifier: MIT
//   Copyright (c) 2015-2020 Zig Contributors
//   This file is part of [zig](https://ziglang.org/), which is MIT licensed.
//   The MIT license requires this copyright notice to be included in all copies
//   and substantial portions of the software.

const Self = @This();

raw_count: std.atomic.Value(usize) = .init(0),
mutex: Mutex = .{},
cond: Condition = .{},

pub fn init() Self {
    return .{};
}

pub fn initWithCount(count: usize) Self {
    return .{ .raw_count = .init(count) };
}

pub fn addUnsynchronized(self: *Self, n: usize) void {
    self.raw_count.raw += n;
}

pub fn add(self: *Self, n: usize) void {
    // Not .acquire because we don't need to synchronize with other tasks (each runs independently).
    // Not .release because there are no side effects that other threads depend on when they see
    // the *start* of a task (only finishing a task has such requirements).
    _ = self.raw_count.fetchAdd(n, .monotonic);
}

pub fn addOne(self: *Self) void {
    self.add(1);
}

pub fn finish(self: *Self) void {
    const old_count = self.raw_count.fetchSub(1, .acq_rel);
    if (old_count > 1) return;

    // This is the last task, so we need to signal the condition. If we were to call `cond.signal`
    // right now, a concurrent call to `wait` which has read a non-zero count (from before we
    // decremented it above) but which has not yet called `cond.wait` will miss the signal and
    // end up blocking forever. A thread in this state (in between reading the count and calling
    // `cond.wait`) is necessarily holding the mutex, so by locking and unlocking the mutex here,
    // we ensure that it reaches the call to `cond.wait` before we call `cond.signal`.
    self.mutex.lock();
    self.mutex.unlock();
    self.cond.signal();
}

pub fn wait(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    while (self.raw_count.load(.acquire) > 0)
        self.cond.wait(&self.mutex);
}

test "WaitGroup: wait() returns immediately when count is zero" {
    var wg: Self = .init();
    wg.wait();
}

test "WaitGroup: addUnsynchronized + finish drains to zero" {
    var wg: Self = .initWithCount(2);
    try std.testing.expectEqual(@as(usize, 2), wg.raw_count.load(.monotonic));
    wg.finish();
    try std.testing.expectEqual(@as(usize, 1), wg.raw_count.load(.monotonic));
    wg.finish();
    try std.testing.expectEqual(@as(usize, 0), wg.raw_count.load(.monotonic));
    wg.wait(); // should not block
}

const home_rt = @import("home_rt");
const std = @import("std");

const Condition = @import("./Condition.zig");
const Mutex = @import("./Mutex.zig");

// `home_rt` is imported to anchor the IP convention even when the source
// doesn't otherwise reference it. Keeps the banner promise honest.
comptime {
    _ = home_rt;
}
