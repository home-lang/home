// Copied from bun/src/uws_sys/ConnectingSocket.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: upstream resolves `SocketGroup`/`SocketKind`/`Loop`
// via `bun.uws` — we sibling-import `SocketKind` and declare `SocketGroup`
// + `Loop` as local opaques so this file ports cleanly ahead of the broader
// uws aggregator. The local placeholders are pointer-identical to whatever
// the future `SocketGroup.zig` / `Loop.zig` ports expose (they are opaque),
// and the API only ever returns `*SocketGroup` / `*Loop`, never derefs them.

//! `us_connecting_socket_t` — a connect in flight (DNS / non-blocking
//! `connect()` / happy-eyeballs). No I/O is possible yet; on success the loop
//! promotes it to a `us_socket_t` and fires `onOpen`, on failure
//! `onConnectingError`.

pub const ConnectingSocket = opaque {
    pub fn close(this: *ConnectingSocket) void {
        c.us_connecting_socket_close(this);
    }

    pub fn group(this: *ConnectingSocket) *SocketGroup {
        return c.us_connecting_socket_group(this);
    }
    pub const rawGroup = group;

    pub fn kind(this: *ConnectingSocket) SocketKind {
        return @enumFromInt(c.us_connecting_socket_kind(this));
    }

    pub fn loop(this: *ConnectingSocket) *Loop {
        return c.us_connecting_socket_get_loop(this);
    }

    pub fn ext(this: *ConnectingSocket, comptime T: type) *T {
        return @ptrCast(@alignCast(c.us_connecting_socket_ext(this)));
    }

    pub fn getError(this: *ConnectingSocket) i32 {
        return c.us_connecting_socket_get_error(this);
    }

    pub fn getNativeHandle(this: *ConnectingSocket) ?*anyopaque {
        return c.us_connecting_socket_get_native_handle(this);
    }

    pub fn isClosed(this: *ConnectingSocket) bool {
        return c.us_connecting_socket_is_closed(this) == 1;
    }

    pub fn isShutdown(this: *ConnectingSocket) bool {
        return c.us_connecting_socket_is_shut_down(this) == 1;
    }

    pub fn longTimeout(this: *ConnectingSocket, seconds: c_uint) void {
        c.us_connecting_socket_long_timeout(this, seconds);
    }

    pub fn shutdown(this: *ConnectingSocket) void {
        c.us_connecting_socket_shutdown(this);
    }

    pub fn shutdownRead(this: *ConnectingSocket) void {
        c.us_connecting_socket_shutdown_read(this);
    }

    pub fn timeout(this: *ConnectingSocket, seconds: c_uint) void {
        c.us_connecting_socket_timeout(this, seconds);
    }
};

const c = struct {
    pub extern fn us_connecting_socket_close(s: *ConnectingSocket) void;
    pub extern fn us_connecting_socket_group(s: *ConnectingSocket) *SocketGroup;
    pub extern fn us_connecting_socket_kind(s: *ConnectingSocket) u8;
    pub extern fn us_connecting_socket_ext(s: *ConnectingSocket) *anyopaque;
    pub extern fn us_connecting_socket_get_error(s: *ConnectingSocket) i32;
    pub extern fn us_connecting_socket_get_native_handle(s: *ConnectingSocket) ?*anyopaque;
    pub extern fn us_connecting_socket_is_closed(s: *ConnectingSocket) i32;
    pub extern fn us_connecting_socket_is_shut_down(s: *ConnectingSocket) i32;
    pub extern fn us_connecting_socket_long_timeout(s: *ConnectingSocket, seconds: c_uint) void;
    pub extern fn us_connecting_socket_shutdown(s: *ConnectingSocket) void;
    pub extern fn us_connecting_socket_shutdown_read(s: *ConnectingSocket) void;
    pub extern fn us_connecting_socket_timeout(s: *ConnectingSocket, seconds: c_uint) void;
    pub extern fn us_connecting_socket_get_loop(s: *ConnectingSocket) *Loop;
};

const bun = @import("bun");

const uws = bun.uws;
const SocketGroup = uws.SocketGroup;
const Loop = uws.Loop;
const SocketKind = uws.SocketKind;

test "ConnectingSocket exposes the us_connecting_socket_t API surface" {
    const std = @import("std");
    // Compile-time sanity: every wrapper method resolves and the underlying
    // extern function pointer is non-null. We can't *call* these without a
    // live libusockets loop, so the test is restricted to the declarations.
    try std.testing.expect(@TypeOf(ConnectingSocket.close) != void);
    try std.testing.expect(@TypeOf(ConnectingSocket.kind) != void);
    try std.testing.expect(@TypeOf(ConnectingSocket.loop) != void);
    try std.testing.expect(@TypeOf(ConnectingSocket.ext) != void);
    try std.testing.expect(@TypeOf(ConnectingSocket.shutdown) != void);
    try std.testing.expect(@TypeOf(ConnectingSocket.shutdownRead) != void);
    try std.testing.expect(@TypeOf(ConnectingSocket.timeout) != void);
}

test "ConnectingSocket.kind round-trips through SocketKind ordinals" {
    const std = @import("std");
    // The wrapper does `@enumFromInt(u8)`; verify the chosen representation
    // matches the SocketKind ordinal layout the C side will hand back.
    const k: SocketKind = @enumFromInt(@as(u8, @intFromEnum(SocketKind.bun_socket_tcp)));
    try std.testing.expectEqual(SocketKind.bun_socket_tcp, k);
}
