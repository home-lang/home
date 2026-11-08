//! Owner-thread timer queue. JavaScript only registers/cancels tasks; the host
//! waits on real kernel timer events after the current script/jobs complete.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");
const evaluate = @import("evaluate.zig");
const rejections = @import("tool_rejections.zig");

// Per owner thread, scoped to runSource; never shared with another JS thread.
// Callbacks also verify their context before touching the active queue.
threadlocal var active: ?*Loop = null;

fn now() !u64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0 or ts.sec < 0) return error.TimerClockFailed;
    return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
}

const Kernel = struct {
    fd: c_int,

    fn init() !Kernel {
        if (builtin.os.tag == .macos) {
            const fd = std.c.kqueue();
            if (fd < 0) return error.TimerQueueFailed;
            if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) {
                _ = std.c.close(fd);
                return error.TimerQueueFailed;
            }
            return .{ .fd = fd };
        } else if (builtin.os.tag == .linux) {
            const flags: std.c.TFD = .{ .CLOEXEC = true, .NONBLOCK = true };
            const fd = std.c.timerfd_create(.MONOTONIC, @bitCast(flags));
            if (fd < 0) return error.TimerQueueFailed;
            return .{ .fd = fd };
        } else return error.TimerBackendUnsupported;
    }

    fn waitUntil(self: Kernel, deadline: u64) !void {
        const current = try now();
        if (current >= deadline) return;
        if (builtin.os.tag == .macos) {
            const change: std.c.Kevent = .{ .ident = 1, .filter = std.c.EVFILT.TIMER, .flags = std.c.EV.ADD | std.c.EV.ONESHOT, .fflags = std.c.NOTE.NSECONDS, .data = @intCast(deadline - current), .udata = 0 };
            var event: std.c.Kevent = undefined;
            const result = std.c.kevent(self.fd, @ptrCast(&change), 1, @ptrCast(&event), 1, null);
            if (result < 0 and std.posix.errno(result) == .INTR) return;
            if (result != 1 or event.flags & std.c.EV.ERROR != 0) return error.TimerWaitFailed;
        } else if (builtin.os.tag == .linux) {
            const specification: std.c.itimerspec = .{
                .it_interval = .{ .sec = 0, .nsec = 0 },
                .it_value = .{ .sec = @intCast(deadline / std.time.ns_per_s), .nsec = @intCast(deadline % std.time.ns_per_s) },
            };
            // timerfd uses the same monotonic clock as registration. A real
            // descriptor event wakes the host; no JS callback sleeps or spins.
            const flags: std.c.TFD.TIMER = .{ .ABSTIME = true };
            if (std.c.timerfd_settime(self.fd, @bitCast(flags), &specification, null) != 0) return error.TimerWaitFailed;
            var descriptor: std.c.pollfd = .{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 };
            const result = std.c.poll(@ptrCast(&descriptor), 1, -1);
            if (result < 0 and std.posix.errno(result) == .INTR) return;
            if (result != 1 or descriptor.revents & std.c.POLL.IN == 0) return error.TimerWaitFailed;
            var expirations: u64 = 0;
            const count = std.c.read(self.fd, @ptrCast(&expirations), @sizeOf(u64));
            if (count < 0 and std.posix.errno(count) == .INTR) return;
            if (count != @sizeOf(u64)) return error.TimerWaitFailed;
        }
    }
};

const Task = struct {
    id: u64,
    deadline: u64,
    function: *types.JSObject,
    referenced: bool,
    interval_ns: u64,
};

pub const Loop = struct {
    allocator: std.mem.Allocator,
    ctx: *types.JSContextRef,
    kernel: Kernel,
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    next_id: u64 = 1,
    previous: ?*Loop = null,

    pub fn init(allocator: std.mem.Allocator, ctx: *types.JSContextRef) !Loop {
        return .{ .allocator = allocator, .ctx = ctx, .kernel = try Kernel.init() };
    }

    pub fn install(self: *Loop, global: *types.JSGlobalObject) void {
        self.previous = active;
        active = self;
        callback.registerCallback(self.ctx, global, "__home_tool_timer_schedule", schedule);
        callback.registerCallback(self.ctx, global, "__home_tool_timer_control", control);
    }

    fn release(self: *Loop, task: Task) void {
        api.JSValueUnprotect(self.ctx, @ptrCast(task.function));
    }

    pub fn deinit(self: *Loop) void {
        if (active == self) active = self.previous;
        for (self.tasks.items) |task| self.release(task);
        self.tasks.deinit(self.allocator);
        _ = std.c.close(self.kernel.fd);
    }

    fn enqueue(self: *Loop, function: *types.JSObject, milliseconds: u64, referenced: bool, repeat: bool) !u64 {
        if (self.next_id >= 0x1fffffffffffff) return error.TimerIdExhausted;
        const deadline = std.math.add(u64, try now(), milliseconds * std.time.ns_per_ms) catch return error.TimerClockOverflow;
        const id = self.next_id;
        try self.tasks.append(self.allocator, .{ .id = id, .deadline = deadline, .function = function, .referenced = referenced, .interval_ns = if (repeat) milliseconds * std.time.ns_per_ms else 0 });
        api.JSValueProtect(self.ctx, @ptrCast(function));
        self.next_id += 1;
        return id;
    }

    fn invoke(self: *Loop, function: *types.JSObject, handler: *types.JSValue) !?[]u8 {
        var exception: ?*types.JSValue = null;
        const handler_argument = [_]?*types.JSValue{handler};
        const result = api.JSObjectCallAsFunction(self.ctx, function, null, 1, &handler_argument, &exception);
        if (exception) |thrown| {
            api.JSValueProtect(self.ctx, thrown);
            defer api.JSValueUnprotect(self.ctx, thrown);
            const uncaught = api.JSValueToObject(self.ctx, handler, null) orelse return error.InvalidUncaughtHandler;
            const arguments = [_]?*types.JSValue{thrown};
            exception = null;
            const handled = api.JSObjectCallAsFunction(self.ctx, uncaught, null, 1, &arguments, &exception);
            if (exception) |failure| return try evaluate.valueToUtf8(self.allocator, self.ctx, failure);
            if (handled == null) return error.TimerDispatchFailed;
        } else if (result == null) return error.TimerCallbackFailed;
        return null;
    }

    fn checkpoint(self: *Loop, handler: *types.JSValue) !?[]u8 {
        const jobs = try evaluate.evaluateUtf8Detailed(self.allocator, self.ctx, "", "home:timer-checkpoint", 1);
        defer jobs.deinit(self.allocator);
        if (jobs.exception) |thrown| return try evaluate.valueToUtf8(self.allocator, self.ctx, thrown);
        if (comptime options.use_zig_js) return rejections.checkpoint(self.allocator, self.ctx, handler);
        return null;
    }

    pub fn drain(self: *Loop, handler: *types.JSValue) !?[]u8 {
        if (try self.checkpoint(handler)) |diagnostic| return diagnostic;
        while (true) {
            var referenced = false;
            var earliest: ?usize = null;
            for (self.tasks.items, 0..) |task, index| {
                referenced = referenced or task.referenced;
                if (earliest == null or task.deadline < self.tasks.items[earliest.?].deadline or
                    (task.deadline == self.tasks.items[earliest.?].deadline and task.id < self.tasks.items[earliest.?].id)) earliest = index;
            }
            if (!referenced) return null;
            const index = earliest orelse return null;
            const deadline = self.tasks.items[index].deadline;
            if (try now() < deadline) {
                try self.kernel.waitUntil(deadline);
                continue;
            }
            const task = self.tasks.swapRemove(index);
            defer self.release(task);
            if (task.interval_ns != 0) {
                // Reinsert before invocation so cancellation/ref changes made
                // by the callback affect this same id. Keep a separate root
                // for the in-flight call even if it cancels its own record.
                var repeated = task;
                repeated.deadline = try std.math.add(u64, try now(), task.interval_ns);
                try self.tasks.append(self.allocator, repeated);
                api.JSValueProtect(self.ctx, @ptrCast(repeated.function));
            }
            if (try self.invoke(task.function, handler)) |diagnostic| return diagnostic;
            if (try self.checkpoint(handler)) |diagnostic| return diagnostic;
        }
    }
};

fn owner(ctx: *types.JSContextRef) ?*Loop {
    const loop = active orelse return null;
    return if (loop.ctx == ctx) loop else null;
}

fn schedule(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    const c = ctx orelse return null;
    const loop = owner(c) orelse return api.JSValueMakeNumber(c, -1);
    if (count != 4) return api.JSValueMakeNumber(c, -1);
    const callback_object = api.JSValueToObject(c, args[0], exception) orelse return null;
    if (!api.JSObjectIsFunction(c, callback_object)) return api.JSValueMakeNumber(c, -1);
    const milliseconds = api.JSValueToNumber(c, args[1], exception);
    if (!std.math.isFinite(milliseconds) or milliseconds < 1 or milliseconds > 2147483647 or @floor(milliseconds) != milliseconds) return api.JSValueMakeNumber(c, -1);
    const id = loop.enqueue(callback_object, @intFromFloat(milliseconds), api.JSValueToBoolean(c, args[2]), api.JSValueToBoolean(c, args[3])) catch return api.JSValueMakeNumber(c, -1);
    return api.JSValueMakeNumber(c, @floatFromInt(id));
}

fn control(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    const c = ctx orelse return null;
    const loop = owner(c) orelse return api.JSValueMakeBoolean(c, false);
    if (count < 2) return api.JSValueMakeBoolean(c, false);
    const number = api.JSValueToNumber(c, args[1], exception);
    if (!std.math.isFinite(number) or number < 1 or number > 0x1fffffffffffff or @floor(number) != number) return api.JSValueMakeBoolean(c, false);
    const id: u64 = @intFromFloat(number);
    for (loop.tasks.items, 0..) |*task, index| {
        if (task.id != id) continue;
        if (api.JSValueToBoolean(c, args[0])) {
            task.referenced = count > 2 and api.JSValueToBoolean(c, args[2]);
        } else {
            const removed = loop.tasks.swapRemove(index);
            loop.release(removed);
        }
        return api.JSValueMakeBoolean(c, true);
    }
    return api.JSValueMakeBoolean(c, false);
}
