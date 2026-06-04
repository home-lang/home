// Copied from bun/src/uws_sys/Timer.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Imports rewritten: upstream resolves `Loop` via `bun.uws.Loop`. Home's
// uws_sys aggregator only exposes the QUIC subtree today; the `Loop`
// opaque is forward-declared locally (same trick as ConnectingSocket.zig
// uses for SocketGroup/Loop). It collapses to whatever the future
// `uws_sys/Loop.zig` port exports — both forms are opaque and only ever
// handed out as `*Loop`, never dereferenced here.
//
// `bun.Output.panic` and `bun.Output.scoped` are not yet wired up in
// Home's Output namespace, so the panic path routes through
// `std.debug.panic` and the debug logger is a release-stripped stub
// (matches the AltSvc.zig precedent).

/// **DEPRECATED**
/// **DO NOT USE IN NEW CODE!**
///
/// Use `JSC.EventLoopTimer` instead.
///
/// This code will be deleted eventually! It is very inefficient on POSIX. On
/// Linux, it holds an entire file descriptor for every single timer. On macOS,
/// it's several system calls.
pub const Timer = opaque {
    pub fn create(loop: *Loop, ptr: anytype) *Timer {
        const Type = @TypeOf(ptr);

        // never fallthrough poll
        // the problem is uSockets hardcodes it on the other end
        // so we can never free non-fallthrough polls
        return c.us_create_timer(loop, 0, @sizeOf(Type)) orelse std.debug.panic("us_create_timer: returned null: {d}", .{std.c._errno().*});
    }

    pub fn createFallthrough(loop: *Loop, ptr: anytype) *Timer {
        const Type = @TypeOf(ptr);

        // never fallthrough poll
        // the problem is uSockets hardcodes it on the other end
        // so we can never free non-fallthrough polls
        return c.us_create_timer(loop, 1, @sizeOf(Type)) orelse std.debug.panic("us_create_timer: returned null: {d}", .{std.c._errno().*});
    }

    pub fn set(this: *Timer, ptr: anytype, cb: ?*const fn (*Timer) callconv(.c) void, ms: i32, repeat_ms: i32) void {
        c.us_timer_set(this, cb, ms, repeat_ms);
        const value_ptr = c.us_timer_ext(this);
        @setRuntimeSafety(false);
        @as(*@TypeOf(ptr), @ptrCast(@alignCast(value_ptr))).* = ptr;
    }

    pub fn deinit(this: *Timer, comptime fallthrough: bool) void {
        debug("Timer.deinit()", .{});
        c.us_timer_close(this, @intFromBool(fallthrough));
    }

    pub fn ext(this: *Timer, comptime Type: type) ?*Type {
        return @as(*Type, @ptrCast(@alignCast(c.us_timer_ext(this).*.?)));
    }

    pub fn as(this: *Timer, comptime Type: type) Type {
        @setRuntimeSafety(false);
        return @as(*?Type, @ptrCast(@alignCast(c.us_timer_ext(this)))).*.?;
    }
};

const c = struct {
    pub extern fn us_create_timer(loop: ?*Loop, fallthrough: i32, ext_size: c_uint) ?*Timer;
    pub extern fn us_timer_ext(timer: ?*Timer) *?*anyopaque;
    pub extern fn us_timer_close(timer: ?*Timer, fallthrough: i32) void;
    pub extern fn us_timer_set(timer: ?*Timer, cb: ?*const fn (*Timer) callconv(.c) void, ms: i32, repeat_ms: i32) void;
    pub extern fn us_timer_loop(t: ?*Timer) ?*Loop;
};

/// `bun.Output.scoped(.uws, .visible)` stub. Home's Output namespace lacks
/// `scoped`/Visibility wiring; emit a release-build-stripped no-op for now
/// (mirrors `http/h3_client/AltSvc.zig`).
fn debug(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}

const std = @import("std");

pub const Loop = @import("./Loop.zig").Loop;

test "Timer exposes the us_timer_t API surface" {
    // Compile-time sanity: every wrapper method resolves. We can't *call*
    // these without a live libusockets loop, so the test is restricted to
    // the declarations.
    try std.testing.expect(@TypeOf(Timer.create) != void);
    try std.testing.expect(@TypeOf(Timer.createFallthrough) != void);
    try std.testing.expect(@TypeOf(Timer.set) != void);
    try std.testing.expect(@TypeOf(Timer.deinit) != void);
    try std.testing.expect(@TypeOf(Timer.ext) != void);
    try std.testing.expect(@TypeOf(Timer.as) != void);
}
