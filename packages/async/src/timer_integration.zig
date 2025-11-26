const std = @import("std");
const timer_mod = @import("timer.zig");
const TimerWheel = timer_mod.TimerWheel;
const future_mod = @import("future.zig");
const Context = future_mod.Context;
const Waker = future_mod.Waker;

/// Runtime timer manager
/// Integrates TimerWheel with the async runtime
pub const RuntimeTimerManager = struct {
    allocator: std.mem.Allocator,
    timer_wheel: *TimerWheel,
    /// Thread for processing timer events
    timer_thread: ?std.Thread,
    /// Flag to stop timer thread
    shutdown: std.atomic.Value(bool),
    /// Wakers to notify when timers expire
    pending_wakers: std.ArrayList(PendingWaker),
    /// Mutex for pending_wakers
    mutex: std.Thread.Mutex,

    const PendingWaker = struct {
        waker: Waker,
        deadline_ns: i64,
    };

    pub fn init(allocator: std.mem.Allocator) !*RuntimeTimerManager {
        const manager = try allocator.create(RuntimeTimerManager);

        manager.* = .{
            .allocator = allocator,
            .timer_wheel = try TimerWheel.init(allocator),
            .timer_thread = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .pending_wakers = std.ArrayList(PendingWaker).init(allocator),
            .mutex = .{},
        };

        return manager;
    }

    pub fn deinit(self: *RuntimeTimerManager) void {
        self.shutdown.store(true, .release);

        if (self.timer_thread) |thread| {
            thread.join();
        }

        self.timer_wheel.deinit();
        self.pending_wakers.deinit();
        self.allocator.destroy(self);
    }

    /// Start the timer thread
    pub fn start(self: *RuntimeTimerManager) !void {
        self.timer_thread = try std.Thread.spawn(.{}, timerThreadMain, .{self});
    }

    /// Register a timer with a waker
    pub fn registerTimer(self: *RuntimeTimerManager, deadline_ns: i64, waker: Waker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pending_wakers.append(.{
            .waker = waker,
            .deadline_ns = deadline_ns,
        });

        // Register with timer wheel
        try self.timer_wheel.schedule(deadline_ns, waker);
    }

    /// Timer thread main loop
    fn timerThreadMain(self: *RuntimeTimerManager) void {
        while (!self.shutdown.load(.acquire)) {
            // Tick the timer wheel
            self.timer_wheel.tick();

            // Check for expired timers
            const now = std.time.nanoTimestamp();

            self.mutex.lock();
            var i: usize = 0;
            while (i < self.pending_wakers.items.len) {
                const pending = self.pending_wakers.items[i];

                if (now >= pending.deadline_ns) {
                    // Timer expired, wake the task
                    pending.waker.wake();

                    // Remove from pending list
                    _ = self.pending_wakers.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            self.mutex.unlock();

            // Sleep for a short duration (10ms tick rate)
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    /// Create a Context with this timer manager
    pub fn createContext(self: *RuntimeTimerManager, waker: Waker) Context {
        var ctx = Context.init(waker);
        ctx.timer_wheel = @ptrCast(self.timer_wheel);
        return ctx;
    }
};

/// Enhanced sleep function that properly integrates with runtime
pub fn sleep(duration_ns: u64, allocator: std.mem.Allocator) !future_mod.Future(void) {
    const State = struct {
        sleep_future: timer_mod.SleepFuture,
    };

    const state = try allocator.create(State);
    state.* = .{
        .sleep_future = timer_mod.SleepFuture{
            .duration_ns = duration_ns,
            .registered = false,
            .deadline_ns = 0,
        },
    };

    const poll_fn = struct {
        fn poll(ptr: *anyopaque, ctx: *Context) future_mod.PollResult(void) {
            const s = @as(*State, @ptrCast(@alignCast(ptr)));
            return s.sleep_future.poll(ctx);
        }
    }.poll;

    return future_mod.Future(void){
        .poll_fn = poll_fn,
        .state = @ptrCast(state),
    };
}

/// Sleep for milliseconds
pub fn sleepMs(ms: u64, allocator: std.mem.Allocator) !future_mod.Future(void) {
    return sleep(ms * std.time.ns_per_ms, allocator);
}

/// Sleep for seconds
pub fn sleepSec(seconds: u64, allocator: std.mem.Allocator) !future_mod.Future(void) {
    return sleep(seconds * std.time.ns_per_s, allocator);
}

/// Create a timeout future
pub fn timeout(comptime T: type, duration_ns: u64, future: future_mod.Future(T), allocator: std.mem.Allocator) !future_mod.Future(?T) {
    const State = struct {
        future: future_mod.Future(T),
        sleep_future: timer_mod.SleepFuture,
        completed: bool,
    };

    const state = try allocator.create(State);
    state.* = .{
        .future = future,
        .sleep_future = timer_mod.SleepFuture{
            .duration_ns = duration_ns,
            .registered = false,
            .deadline_ns = 0,
        },
        .completed = false,
    };

    const poll_fn = struct {
        fn poll(ptr: *anyopaque, ctx: *Context) future_mod.PollResult(?T) {
            const s = @as(*State, @ptrCast(@alignCast(ptr)));

            if (s.completed) {
                unreachable; // Polled after completion
            }

            // Check if timeout expired
            const timeout_result = s.sleep_future.poll(ctx);
            if (timeout_result == .Ready) {
                s.completed = true;
                return .{ .Ready = null }; // Timeout
            }

            // Try to complete the main future
            const result = s.future.poll(ctx);
            if (result == .Ready) {
                s.completed = true;
                return .{ .Ready = result.Ready };
            }

            return .Pending;
        }
    }.poll;

    return future_mod.Future(?T){
        .poll_fn = poll_fn,
        .state = @ptrCast(state),
    };
}

test "RuntimeTimerManager - basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try RuntimeTimerManager.init(allocator);
    defer manager.deinit();

    try manager.start();

    // Give timer thread time to start
    std.time.sleep(50 * std.time.ns_per_ms);
}

test "sleep functions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test that sleep futures can be created
    const sleep_future = try sleepMs(100, allocator);
    _ = sleep_future;

    const sleep_sec_future = try sleepSec(1, allocator);
    _ = sleep_sec_future;
}
