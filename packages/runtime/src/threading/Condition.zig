// Copied from bun/src/threading/Condition.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt").
// Rewrites:
//   * `bun.Futex` / `bun.Mutex` → local `@import("./Futex.zig")` /
//     `@import("./Mutex.zig")`.
//   * `bun.assert` → `home_rt.assert`.
//   * The FutexImpl `wait()` body upstream calls `Futex.Deadline.init(...)`
//     for `timedWait`. `Deadline` requires `std.time.Timer` (removed in Zig
//     0.17.0-dev), so the deadline path is short-circuited: `timedWait` with
//     a non-null timeout immediately returns `error.Timeout` after racing the
//     state once. `wait()` (infinite) still works correctly because it goes
//     through `Futex.waitForever`. Re-attach a real deadline implementation
//     when home_rt grows a Timer adapter.
//
//! Copy of std.Thread.Condition, but uses Home's Mutex and Futex.
//! Synchronized with std as of Zig 0.14.1.

const Condition = @This();

impl: Impl = .{},

/// Atomically releases the Mutex, blocks the caller thread, then re-acquires the Mutex on return.
pub fn wait(self: *Condition, mutex: *Mutex) void {
    self.impl.wait(mutex, null) catch |err| switch (err) {
        error.Timeout => unreachable, // no timeout provided so we shouldn't have timed-out
    };
}

/// Atomically releases the Mutex, blocks the caller thread, then re-acquires the Mutex on return.
pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
    return self.impl.wait(mutex, timeout_ns);
}

/// Unblocks at least one thread blocked in a call to `wait()` or `timedWait()` with a given Mutex.
pub fn signal(self: *Condition) void {
    self.impl.wake(.one);
}

/// Unblocks all threads currently blocked in a call to `wait()` or `timedWait()` with a given Mutex.
pub fn broadcast(self: *Condition) void {
    self.impl.wake(.all);
}

const Impl = if (builtin.os.tag == .windows)
    WindowsImpl
else
    FutexImpl;

const Notify = enum {
    one, // wake up only one thread
    all, // wake up all threads
};

const WindowsImpl = struct {
    condition: os.windows.CONDITION_VARIABLE = .{},

    fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {
        var timeout_overflowed = false;
        var timeout_ms: os.windows.DWORD = os.windows.INFINITE;

        if (timeout) |timeout_ns| {
            // Round the nanoseconds to the nearest millisecond,
            // then saturating cast it to windows DWORD for use in kernel32 call.
            const ms = (timeout_ns +| (std.time.ns_per_ms / 2)) / std.time.ns_per_ms;
            timeout_ms = std.math.cast(os.windows.DWORD, ms) orelse std.math.maxInt(os.windows.DWORD);

            // Track if the timeout overflowed into INFINITE and make sure not to wait forever.
            if (timeout_ms == os.windows.INFINITE) {
                timeout_overflowed = true;
                timeout_ms -= 1;
            }
        }

        if (builtin.mode == .Debug) {
            // The internal state of the DebugMutex needs to be handled here as well.
            mutex.impl.locking_thread.store(0, .unordered);
        }
        const rc = os.windows.kernel32.SleepConditionVariableSRW(
            &self.condition,
            if (builtin.mode == .Debug) &mutex.impl.impl.srwlock else &mutex.impl.srwlock,
            timeout_ms,
            0, // the srwlock was assumed to acquired in exclusive mode not shared
        );
        if (builtin.mode == .Debug) {
            // The internal state of the DebugMutex needs to be handled here as well.
            mutex.impl.locking_thread.store(std.Thread.getCurrentId(), .unordered);
        }

        // Return error.Timeout if we know the timeout elapsed correctly.
        if (rc == os.windows.FALSE) {
            assert(os.windows.GetLastError() == .TIMEOUT);
            if (!timeout_overflowed) return error.Timeout;
        }
    }

    fn wake(self: *Impl, comptime notify: Notify) void {
        switch (notify) {
            .one => os.windows.kernel32.WakeConditionVariable(&self.condition),
            .all => os.windows.kernel32.WakeAllConditionVariable(&self.condition),
        }
    }
};

const FutexImpl = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const one_waiter = 1;
    const waiter_mask = 0xffff;

    const one_signal = 1 << 16;
    const signal_mask = 0xffff << 16;

    fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {
        // Observe the epoch, then check the state again to see if we should wake up.
        // The epoch must be observed before we check the state or we could potentially miss a wake() and deadlock:
        //
        // - T1: s = LOAD(&state)
        // - T2: UPDATE(&s, signal)
        // - T2: UPDATE(&epoch, 1) + FUTEX_WAKE(&epoch)
        // - T1: e = LOAD(&epoch) (was reordered after the state load)
        // - T1: s & signals == 0 -> FUTEX_WAIT(&epoch, e) (missed the state update + the epoch change)
        //
        // Acquire barrier to ensure the epoch load happens before the state load.
        var epoch = self.epoch.load(.acquire);
        var state = self.state.fetchAdd(one_waiter, .monotonic);
        assert(state & waiter_mask != waiter_mask);
        state += one_waiter;

        mutex.unlock();
        defer mutex.lock();

        while (true) {
            // Zig-0.17 fork: `Futex.Deadline` requires `std.time.Timer` which
            // was removed. For an infinite wait we still get the correct
            // behavior via `waitForever`. For a `timedWait` we collapse the
            // call to a `0`-timeout race so callers do not block forever;
            // they get an `error.Timeout` on the first iteration unless the
            // state already shows a pending signal.
            if (timeout == null) {
                Futex.waitForever(&self.epoch, epoch);
            } else {
                Futex.wait(&self.epoch, epoch, 0) catch |err| switch (err) {
                    // On timeout, we must decrement the waiter we added above.
                    error.Timeout => {
                        while (true) {
                            // If there's a signal when we're timing out, consume it and report being woken up instead.
                            // Acquire barrier ensures code before the wake() which added the signal happens before we decrement it and return.
                            while (state & signal_mask != 0) {
                                const new_state = state - one_waiter - one_signal;
                                state = self.state.cmpxchgWeak(state, new_state, .acquire, .monotonic) orelse return;
                            }

                            // Remove the waiter we added and officially return timed out.
                            const new_state = state - one_waiter;
                            state = self.state.cmpxchgWeak(state, new_state, .monotonic, .monotonic) orelse return err;
                        }
                    },
                };
            }

            epoch = self.epoch.load(.acquire);
            state = self.state.load(.monotonic);

            // Try to wake up by consuming a signal and decremented the waiter we added previously.
            // Acquire barrier ensures code before the wake() which added the signal happens before we decrement it and return.
            while (state & signal_mask != 0) {
                const new_state = state - one_waiter - one_signal;
                state = self.state.cmpxchgWeak(state, new_state, .acquire, .monotonic) orelse return;
            }
        }
    }

    fn wake(self: *Impl, comptime notify: Notify) void {
        var state = self.state.load(.monotonic);
        while (true) {
            const waiters = (state & waiter_mask) / one_waiter;
            const signals = (state & signal_mask) / one_signal;

            // Reserves which waiters to wake up by incrementing the signals count.
            // Therefore, the signals count is always less than or equal to the waiters count.
            // We don't need to Futex.wake if there's nothing to wake up or if other wake() threads have reserved to wake up the current waiters.
            const wakeable = waiters - signals;
            if (wakeable == 0) {
                return;
            }

            const to_wake = switch (notify) {
                .one => 1,
                .all => wakeable,
            };

            // Reserve the amount of waiters to wake by incrementing the signals count.
            // Release barrier ensures code before the wake() happens before the signal it posted and consumed by the wait() threads.
            const new_state = state + (one_signal * to_wake);
            state = self.state.cmpxchgWeak(state, new_state, .release, .monotonic) orelse {
                // Wake up the waiting threads we reserved above by changing the epoch value.
                _ = self.epoch.fetchAdd(1, .release);
                Futex.wake(&self.epoch, to_wake);
                return;
            };
        }
    }
};

test "Condition: signal with no waiters is a no-op" {
    var c: Condition = .{};
    c.signal();
    c.broadcast();
}

test "Condition: timedWait returns Timeout when nothing wakes us" {
    var m: Mutex = .{};
    var c: Condition = .{};
    m.lock();
    defer m.unlock();
    try std.testing.expectError(error.Timeout, c.timedWait(&m, 1));
}

const builtin = @import("builtin");

const home_rt = @import("home_rt");
const Futex = @import("./Futex.zig");
const Mutex = @import("./Mutex.zig");
const assert = home_rt.assert;

const std = @import("std");
const os = std.os;
