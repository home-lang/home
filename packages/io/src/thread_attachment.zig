//! POSIX thread-exit ownership. Keep each Key and supplied Binding at a stable
//! address until detachment/destruction finishes. A runtime's worker "close"
//! notification is not an OS-thread retirement proof.
const std = @import("std");
const c = std.c;
pub const Binding = struct { key: ?*Key = null, value: ?*anyopaque = null };
pub const Key = struct {
    const closed: u64 = @as(u64, 1) << 63;
    const closing: u64 = @as(u64, 1) << 62;
    const count_mask: u64 = closing - 1;
    id: c.pthread_key_t,
    destroy: *const fn (*anyopaque) void,
    // Counts bindings, callbacks and in-flight key calls, not just live threads.
    state: std.atomic.Value(u64) = .init(0),
    pub fn init(destroy: *const fn (*anyopaque) void) !Key {
        var id: c.pthread_key_t = undefined;
        if (c.pthread_key_create(&id, threadExit) != .SUCCESS) return error.SystemIo;
        return .{ .id = id, .destroy = destroy };
    }
    fn acquire(self: *Key) !void {
        var value = self.state.load(.acquire);
        while (true) {
            if (value & (closed | closing) != 0) return error.Closed;
            if (value == count_mask) return error.ReferenceLimit;
            value = self.state.cmpxchgWeak(value, value + 1, .acq_rel, .acquire) orelse return;
        }
    }
    fn release(self: *Key) void {
        const before = self.state.fetchSub(1, .acq_rel);
        std.debug.assert(before != 0 and before <= count_mask);
    }
    pub fn attach(self: *Key, binding: *Binding, value: *anyopaque) !void {
        try self.acquire();
        errdefer self.release();
        if (binding.key != null or c.pthread_getspecific(self.id) != null) return error.AlreadyAttached;
        binding.* = .{ .key = self, .value = value };
        if (c.pthread_setspecific(self.id, binding) != 0) {
            binding.* = .{};
            return error.SystemIo;
        }
    }
    pub fn current(self: *Key) !?*anyopaque {
        try self.acquire();
        defer self.release();
        const raw = c.pthread_getspecific(self.id) orelse return null;
        const binding: *Binding = @ptrCast(@alignCast(raw));
        std.debug.assert(binding.key == self);
        return binding.value;
    }
    /// Clear TLS before invoking cleanup, so normal detach and OS-thread exit
    /// cannot retire the same attachment twice. Failure retains the binding.
    pub fn detach(self: *Key) !void {
        try self.acquire();
        defer self.release();
        const raw = c.pthread_getspecific(self.id) orelse return;
        if (c.pthread_setspecific(self.id, null) != 0) return error.SystemIo;
        finish(@ptrCast(@alignCast(raw)));
    }
    fn threadExit(raw: *anyopaque) callconv(.c) void {
        // POSIX clears this thread's key before entering its destructor.
        finish(@ptrCast(@alignCast(raw)));
    }
    fn finish(binding: *Binding) void {
        const key = binding.key.?;
        const value = binding.value.?;
        binding.* = .{};
        key.destroy(value);
        // Cleanup may destroy the enclosing Binding. Never touch it again.
        // Keep the Key counted until the callback itself has completely joined.
        key.release();
    }
    pub fn uses(self: *const Key) u64 {
        return self.state.load(.acquire) & count_mask;
    }
    /// Serialize final owner destruction with new calls. Concurrent attach/close
    /// is gated atomically; active bindings and callbacks return Busy.
    pub fn close(self: *Key) !void {
        if (self.state.cmpxchgStrong(0, closing, .acq_rel, .acquire)) |actual| {
            return if (actual == closed) {} else error.Busy;
        }
        if (c.pthread_key_delete(self.id) != .SUCCESS) {
            self.state.store(0, .release);
            return error.SystemIo;
        }
        self.state.store(closed, .release);
    }
};

test "explicit detach and actual pthread exit retire one stable attachment exactly once" {
    const Context = struct {
        key: *Key,
        binding: Binding = .{},
        entered: std.atomic.Value(bool) = .init(false),
        leave: std.atomic.Value(bool) = .init(false),
        calls: std.atomic.Value(u32) = .init(0),
        explicit: bool,
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(self.binding.key == null);
            std.debug.assert(self.key.uses() != 0);
            self.key.close() catch |failure| {
                std.debug.assert(failure == error.Busy);
            };
            _ = self.calls.fetchAdd(1, .acq_rel);
        }
        fn run(self: *@This()) void {
            self.key.attach(&self.binding, self) catch unreachable;
            std.debug.assert((self.key.current() catch unreachable) == @as(?*anyopaque, @ptrCast(self)));
            self.entered.store(true, .release);
            while (!self.leave.load(.acquire)) std.atomic.spinLoopHint();
            if (self.explicit) self.key.detach() catch unreachable;
        }
    };
    for ([_]bool{ false, true }) |explicit| {
        var key = try Key.init(Context.destroy);
        var context: Context = .{ .key = &key, .explicit = explicit };
        const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
        while (!context.entered.load(.acquire)) std.atomic.spinLoopHint();
        try std.testing.expectEqual(@as(u64, 1), key.uses());
        try std.testing.expectError(error.Busy, key.close());
        context.leave.store(true, .release);
        thread.join();
        try std.testing.expectEqual(@as(u32, 1), context.calls.load(.acquire));
        try std.testing.expectEqual(@as(u64, 0), key.uses());
        try std.testing.expect((try key.current()) == null);
        try key.detach();
        try key.close();
        try key.close();
        try std.testing.expectError(error.Closed, key.attach(&context.binding, &context));
    }
}
