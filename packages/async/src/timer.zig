const std = @import("std");
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const PollResult = future_mod.PollResult;
const Context = future_mod.Context;
const Waker = future_mod.Waker;

/// A timer entry in the timer wheel
const TimerEntry = struct {
    deadline: u64,  // Absolute nanosecond timestamp
    waker: *Waker,
    next: ?*TimerEntry,
};

/// Hierarchical timing wheel for efficient timer scheduling
///
/// Uses 4 wheels with different granularities:
/// - Wheel 0: 256 slots × 1ms  = 0-256ms
/// - Wheel 1: 256 slots × 256ms = 256ms-65s
/// - Wheel 2: 256 slots × 65s   = 65s-4.6h
/// - Wheel 3: 256 slots × 4.6h  = 4.6h-49 days
pub const TimerWheel = struct {
    const SLOTS_PER_WHEEL = 256;
    const NUM_WHEELS = 4;

    const WHEEL_DURATIONS = [NUM_WHEELS]u64{
        std.time.ns_per_ms,            // 1ms
        std.time.ns_per_ms * 256,      // 256ms
        std.time.ns_per_s * 65,        // 65s
        std.time.ns_per_hour * 4 + std.time.ns_per_min * 36, // 4.6h
    };

    allocator: std.mem.Allocator,
    /// 4 wheels, each with 256 slots
    wheels: [NUM_WHEELS][SLOTS_PER_WHEEL]?*TimerEntry,
    /// Current tick count for each wheel
    current_ticks: [NUM_WHEELS]u64,
    /// Start time (nanoseconds)
    start_time: u64,
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) TimerWheel {
        var wheel = TimerWheel{
            .allocator = allocator,
            .wheels = undefined,
            .current_ticks = [_]u64{0} ** NUM_WHEELS,
            .start_time = @intCast(@as(i64, @intCast((try std.time.Instant.now()).order(std.time.Instant{ .timestamp = if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .uefi) 0 else .{ .tv_sec = 0, .tv_nsec = 0 } }).compare(.gt)))),
            .mutex = .{},
        };

        // Initialize all slots to null
        for (&wheel.wheels) |*w| {
            for (w) |*slot| {
                slot.* = null;
            }
        }

        return wheel;
    }

    pub fn deinit(self: *TimerWheel) void {
        // Free all timer entries
        for (&self.wheels) |*wheel| {
            for (wheel) |*slot| {
                var current = slot.*;
                while (current) |entry| {
                    const next = entry.next;
                    entry.waker.drop();
                    self.allocator.destroy(entry);
                    current = next;
                }
            }
        }
    }

    /// Schedule a timer
    ///
    /// delay_ns: delay in nanoseconds from now
    /// waker: waker to call when timer expires
    pub fn schedule(self: *TimerWheel, delay_ns: u64, waker: *Waker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = @as(u64, @intCast(@as(i64, @intCast((try std.time.Instant.now()).order(std.time.Instant{ .timestamp = if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .uefi) 0 else .{ .tv_sec = 0, .tv_nsec = 0 } }).compare(.gt)))));
        const deadline = now + delay_ns;

        // Calculate which wheel and slot
        const ticks_from_now = delay_ns / WHEEL_DURATIONS[0];
        const wheel_idx = self.selectWheel(ticks_from_now);
        const slot_idx = self.calculateSlot(wheel_idx, ticks_from_now);

        // Create entry
        const entry = try self.allocator.create(TimerEntry);
        entry.* = .{
            .deadline = deadline,
            .waker = waker,
            .next = self.wheels[wheel_idx][slot_idx],
        };

        // Insert at head of slot list
        self.wheels[wheel_idx][slot_idx] = entry;
    }

    /// Advance the timer wheels and trigger expired timers
    ///
    /// Should be called periodically by the runtime
    pub fn advance(self: *TimerWheel) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = @as(u64, @intCast(@as(i64, @intCast((try std.time.Instant.now()).order(std.time.Instant{ .timestamp = if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .uefi) 0 else .{ .tv_sec = 0, .tv_nsec = 0 } }).compare(.gt)))));

        // Process wheel 0 (finest granularity)
        self.advanceWheel(0, now);

        // Check if we should cascade to next wheels
        if (self.current_ticks[0] % SLOTS_PER_WHEEL == 0) {
            self.advanceWheel(1, now);

            if (self.current_ticks[1] % SLOTS_PER_WHEEL == 0) {
                self.advanceWheel(2, now);

                if (self.current_ticks[2] % SLOTS_PER_WHEEL == 0) {
                    self.advanceWheel(3, now);
                }
            }
        }

        self.current_ticks[0] += 1;
    }

    fn advanceWheel(self: *TimerWheel, wheel_idx: usize, now: u64) void {
        const slot = self.current_ticks[wheel_idx] % SLOTS_PER_WHEEL;

        var current = self.wheels[wheel_idx][slot];
        var prev: ?*TimerEntry = null;

        while (current) |entry| {
            const next = entry.next;

            if (entry.deadline <= now) {
                // Timer expired - wake it
                entry.waker.wake();
                self.allocator.destroy(entry);

                // Remove from list
                if (prev) |p| {
                    p.next = next;
                } else {
                    self.wheels[wheel_idx][slot] = next;
                }
            } else if (wheel_idx > 0) {
                // Timer not yet expired, move to lower wheel
                const remaining = entry.deadline - now;
                const lower_wheel = wheel_idx - 1;
                const ticks = remaining / WHEEL_DURATIONS[lower_wheel];
                const lower_slot = self.calculateSlot(lower_wheel, ticks);

                // Remove from current list
                if (prev) |p| {
                    p.next = next;
                } else {
                    self.wheels[wheel_idx][slot] = next;
                }

                // Insert into lower wheel
                entry.next = self.wheels[lower_wheel][lower_slot];
                self.wheels[lower_wheel][lower_slot] = entry;
            } else {
                prev = entry;
            }

            current = next;
        }
    }

    fn selectWheel(self: *TimerWheel, ticks: u64) usize {
        _ = self;

        if (ticks < SLOTS_PER_WHEEL) return 0;
        if (ticks < SLOTS_PER_WHEEL * SLOTS_PER_WHEEL) return 1;
        if (ticks < SLOTS_PER_WHEEL * SLOTS_PER_WHEEL * SLOTS_PER_WHEEL) return 2;
        return 3;
    }

    fn calculateSlot(self: *TimerWheel, wheel_idx: usize, ticks: u64) usize {
        const offset = self.current_ticks[wheel_idx];
        const divisor = switch (wheel_idx) {
            0 => 1,
            1 => SLOTS_PER_WHEEL,
            2 => SLOTS_PER_WHEEL * SLOTS_PER_WHEEL,
            3 => SLOTS_PER_WHEEL * SLOTS_PER_WHEEL * SLOTS_PER_WHEEL,
            else => unreachable,
        };

        return @intCast((offset + ticks / divisor) % SLOTS_PER_WHEEL);
    }
};

/// Future for sleeping
pub const SleepFuture = struct {
    duration_ns: u64,
    registered: bool,
    deadline_ns: u64,

    pub fn poll(self: *SleepFuture, ctx: *Context) PollResult(void) {
        if (!self.registered) {
            // Try to get timer wheel from context
            if (ctx.getTimerWheel()) |tw_opaque| {
                // Cast opaque pointer back to TimerWheel
                const tw: *TimerWheel = @ptrCast(@alignCast(tw_opaque));

                // Calculate absolute deadline
                self.deadline_ns = std.time.nanoTimestamp() + @as(i64, @intCast(self.duration_ns));

                // Register timer with the wheel
                tw.schedule(self.deadline_ns, ctx.waker) catch {
                    // If registration fails, fall back to blocking sleep
                    std.posix.nanosleep(0, self.duration_ns);
                    self.registered = true;
                    return .{ .Ready = {} };
                };

                self.registered = true;
                return .{ .Pending = {} };
            } else {
                // No timer wheel available, fall back to blocking sleep
                std.posix.nanosleep(0, self.duration_ns);
                self.registered = true;
                return .{ .Ready = {} };
            }
        }

        // Check if deadline has passed
        const now = std.time.nanoTimestamp();
        if (now >= self.deadline_ns) {
            return .{ .Ready = {} };
        }

        return .{ .Pending = {} };
    }
};

/// Sleep for a duration
pub fn sleep(duration_ns: u64) SleepFuture {
    return SleepFuture{
        .duration_ns = duration_ns,
        .registered = false,
        .deadline_ns = 0,
    };
}

/// Timeout error
pub const TimeoutError = error{Timeout};

/// Timeout future - wraps another future with a timeout
pub fn TimeoutFuture(comptime T: type) type {
    return struct {
        const Self = @This();

        inner: Future(T),
        deadline_ns: u64,
        timer_registered: bool,
        start_time: ?u64,

        pub fn poll(self: *Self, ctx: *Context) PollResult(error{Timeout}!T) {
            // Initialize start time on first poll
            if (self.start_time == null) {
                self.start_time = @intCast(@as(i64, @intCast((try std.time.Instant.now()).order(std.time.Instant{ .timestamp = if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .uefi) 0 else .{ .tv_sec = 0, .tv_nsec = 0 } }).compare(.gt))));
            }

            // Check if timed out
            const now = @as(u64, @intCast(@as(i64, @intCast((try std.time.Instant.now()).order(std.time.Instant{ .timestamp = if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .uefi) 0 else .{ .tv_sec = 0, .tv_nsec = 0 } }).compare(.gt)))));
            if (now >= self.start_time.? + self.deadline_ns) {
                return .{ .Ready = TimeoutError.Timeout };
            }

            // Poll inner future
            const result = self.inner.poll(ctx);
            return switch (result) {
                .Ready => |val| .{ .Ready = val },
                .Pending => .Pending,
            };
        }
    };
}

/// Create a timeout future
pub fn timeout(
    comptime T: type,
    allocator: std.mem.Allocator,
    duration_ns: u64,
    fut: Future(T),
) !Future(error{Timeout}!T) {
    const State = TimeoutFuture(T);

    const state = try allocator.create(State);
    state.* = .{
        .inner = fut,
        .deadline_ns = duration_ns,
        .timer_registered = false,
        .start_time = null,
    };

    const poll_fn = struct {
        fn poll(ptr: *anyopaque, ctx: *Context) PollResult(error{Timeout}!T) {
            const s = @as(*State, @ptrCast(@alignCast(ptr)));
            return s.poll(ctx);
        }
    }.poll;

    return Future(error{Timeout}!T){
        .poll_fn = poll_fn,
        .state = @ptrCast(state),
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "TimerWheel - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var wheel = TimerWheel.init(allocator);
    defer wheel.deinit();

    try testing.expect(true);
}

test "TimerWheel - schedule and advance" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var wheel = TimerWheel.init(allocator);
    defer wheel.deinit();

    var wake_called = false;

    const wake_fn = struct {
        fn wake(ptr: *anyopaque) void {
            const called = @as(*bool, @ptrCast(@alignCast(ptr)));
            called.* = true;
        }
    }.wake;

    const waker_vtable = Waker.VTable{
        .wake = wake_fn,
        .wake_by_ref = wake_fn,
        .clone = struct {
            fn clone(ptr: *anyopaque) *anyopaque {
                return ptr;
            }
        }.clone,
        .drop = struct {
            fn drop(_: *anyopaque) void {}
        }.drop,
    };

    var waker = Waker{
        .data = @ptrCast(&wake_called),
        .vtable = &waker_vtable,
    };

    // Schedule a timer for 1ms from now
    try wheel.schedule(std.time.ns_per_ms, &waker);

    // Sleep for 2ms
    std.posix.nanosleep(0, 2 * std.time.ns_per_ms);

    // Advance the wheel
    wheel.advance();

    // Waker should have been called
    try testing.expect(wake_called);
}

test "sleep - basic" {
    const testing = std.testing;

    const start = @as(i64, @intCast((try std.time.Instant.now()).order(std.time.Instant{ .timestamp = if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .uefi) 0 else .{ .tv_sec = 0, .tv_nsec = 0 } }).compare(.gt)));
    var sleep_fut = sleep(10 * std.time.ns_per_ms);

    const waker = Waker{
        .data = undefined,
        .vtable = &.{
            .wake = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .wake_by_ref = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .clone = struct {
                fn clone(ptr: *anyopaque) *anyopaque {
                    return ptr;
                }
            }.clone,
            .drop = struct {
                fn drop(_: *anyopaque) void {}
            }.drop,
        },
    };

    var ctx = Context.init(waker);
    const result = sleep_fut.poll(&ctx);

    const elapsed = @as(i64, @intCast((try std.time.Instant.now()).order(std.time.Instant{ .timestamp = if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .uefi) 0 else .{ .tv_sec = 0, .tv_nsec = 0 } }).compare(.gt))) - start;

    try testing.expect(result.isReady());
    try testing.expect(elapsed >= 9 * std.time.ns_per_ms); // Allow some slack
}
