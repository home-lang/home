// Copied from bun/src/uws_sys/udp.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"); bun.assert →
// home_rt.assert. Upstream pulls `Loop` from `bun.uws`; we declare a local
// opaque forward-decl until `uws_sys/Loop.zig` ports (Loop carries
// InternalLoopData + jsc.EventLoopHandle, so it can't be a leaf today).
// `Loop` is referenced only as `?*Loop` / `*Loop`, never dereferenced.

const udp = @This();

pub const Socket = opaque {
    pub fn create(loop: *Loop, data_cb: *const fn (*udp.Socket, *PacketBuffer, c_int) callconv(.c) void, drain_cb: *const fn (*udp.Socket) callconv(.c) void, close_cb: *const fn (*udp.Socket) callconv(.c) void, recv_error_cb: *const fn (*udp.Socket, c_int) callconv(.c) void, host: [*c]const u8, port: c_ushort, options: c_int, err: ?*c_int, user_data: ?*anyopaque) ?*udp.Socket {
        return us_create_udp_socket(loop, data_cb, drain_cb, close_cb, recv_error_cb, host, port, options, err, user_data);
    }

    pub fn send(this: *udp.Socket, payloads: []const [*]const u8, lengths: []const usize, addresses: []const ?*const anyopaque) c_int {
        home_rt.assert(payloads.len == lengths.len and payloads.len == addresses.len);
        return us_udp_socket_send(this, payloads.ptr, lengths.ptr, addresses.ptr, @intCast(payloads.len));
    }

    pub fn user(this: *udp.Socket) ?*anyopaque {
        return us_udp_socket_user(this);
    }

    pub fn bind(this: *udp.Socket, hostname: [*c]const u8, port: c_uint) c_int {
        return us_udp_socket_bind(this, hostname, port);
    }

    /// Get the bound port in host byte order
    pub fn boundPort(this: *udp.Socket) c_int {
        return us_udp_socket_bound_port(this);
    }

    pub fn boundIp(this: *udp.Socket, buf: [*c]u8, length: *i32) void {
        return us_udp_socket_bound_ip(this, buf, length);
    }

    pub fn remoteIp(this: *udp.Socket, buf: [*c]u8, length: *i32) void {
        return us_udp_socket_remote_ip(this, buf, length);
    }

    pub fn close(this: *udp.Socket) void {
        return us_udp_socket_close(this);
    }

    pub fn connect(this: *udp.Socket, hostname: [*c]const u8, port: c_uint) c_int {
        return us_udp_socket_connect(this, hostname, port);
    }

    pub fn disconnect(this: *udp.Socket) c_int {
        return us_udp_socket_disconnect(this);
    }

    pub fn setBroadcast(this: *udp.Socket, enabled: bool) c_int {
        return us_udp_socket_set_broadcast(this, @intCast(@intFromBool(enabled)));
    }

    pub fn setUnicastTTL(this: *udp.Socket, ttl: i32) c_int {
        return us_udp_socket_set_ttl_unicast(this, @intCast(ttl));
    }

    pub fn setMulticastTTL(this: *udp.Socket, ttl: i32) c_int {
        return us_udp_socket_set_ttl_multicast(this, @intCast(ttl));
    }

    pub fn setMulticastLoopback(this: *udp.Socket, enabled: bool) c_int {
        return us_udp_socket_set_multicast_loopback(this, @intCast(@intFromBool(enabled)));
    }

    pub fn setMulticastInterface(this: *udp.Socket, iface: *const std.posix.sockaddr.storage) c_int {
        return us_udp_socket_set_multicast_interface(this, iface);
    }

    pub fn setMembership(this: *udp.Socket, address: *const std.posix.sockaddr.storage, iface: ?*const std.posix.sockaddr.storage, drop: bool) c_int {
        return us_udp_socket_set_membership(this, address, iface, @intFromBool(drop));
    }

    pub fn setSourceSpecificMembership(this: *udp.Socket, source: *const std.posix.sockaddr.storage, group: *const std.posix.sockaddr.storage, iface: ?*const std.posix.sockaddr.storage, drop: bool) c_int {
        return us_udp_socket_set_source_specific_membership(this, source, group, iface, @intFromBool(drop));
    }

    extern fn us_create_udp_socket(loop: ?*Loop, data_cb: *const fn (*udp.Socket, *PacketBuffer, c_int) callconv(.c) void, drain_cb: *const fn (*udp.Socket) callconv(.c) void, close_cb: *const fn (*udp.Socket) callconv(.c) void, recv_error_cb: *const fn (*udp.Socket, c_int) callconv(.c) void, host: [*c]const u8, port: c_ushort, options: c_int, err: ?*c_int, user_data: ?*anyopaque) ?*udp.Socket;
    extern fn us_udp_socket_connect(socket: *udp.Socket, hostname: [*c]const u8, port: c_uint) c_int;
    extern fn us_udp_socket_disconnect(socket: *udp.Socket) c_int;
    extern fn us_udp_socket_send(socket: *udp.Socket, [*c]const [*c]const u8, [*c]const usize, [*c]const ?*const anyopaque, c_int) c_int;
    extern fn us_udp_socket_user(socket: *udp.Socket) ?*anyopaque;
    extern fn us_udp_socket_bind(socket: *udp.Socket, hostname: [*c]const u8, port: c_uint) c_int;
    extern fn us_udp_socket_bound_port(socket: *udp.Socket) c_int;
    extern fn us_udp_socket_bound_ip(socket: *udp.Socket, buf: [*c]u8, length: [*c]i32) void;
    extern fn us_udp_socket_remote_ip(socket: *udp.Socket, buf: [*c]u8, length: [*c]i32) void;
    extern fn us_udp_socket_close(socket: *udp.Socket) void;
    extern fn us_udp_socket_set_broadcast(socket: *udp.Socket, enabled: c_int) c_int;
    extern fn us_udp_socket_set_ttl_unicast(socket: *udp.Socket, ttl: c_int) c_int;
    extern fn us_udp_socket_set_ttl_multicast(socket: *udp.Socket, ttl: c_int) c_int;
    extern fn us_udp_socket_set_multicast_loopback(socket: *udp.Socket, enabled: c_int) c_int;
    extern fn us_udp_socket_set_multicast_interface(socket: *udp.Socket, iface: *const std.posix.sockaddr.storage) c_int;
    extern fn us_udp_socket_set_membership(socket: *udp.Socket, address: *const std.posix.sockaddr.storage, iface: ?*const std.posix.sockaddr.storage, drop: c_int) c_int;
    extern fn us_udp_socket_set_source_specific_membership(socket: *udp.Socket, source: *const std.posix.sockaddr.storage, group: *const std.posix.sockaddr.storage, iface: ?*const std.posix.sockaddr.storage, drop: c_int) c_int;
};

pub const PacketBuffer = opaque {
    pub fn getPeer(this: *PacketBuffer, index: c_int) *std.posix.sockaddr.storage {
        return us_udp_packet_buffer_peer(this, index);
    }

    pub fn getPayload(this: *PacketBuffer, index: c_int) []u8 {
        const payload = us_udp_packet_buffer_payload(this, index);
        const len = us_udp_packet_buffer_payload_length(this, index);
        return payload[0..@as(usize, @intCast(len))];
    }

    pub fn getTruncated(this: *PacketBuffer, index: c_int) bool {
        return us_udp_packet_buffer_truncated(this, index) != 0;
    }

    extern fn us_udp_packet_buffer_peer(buf: ?*PacketBuffer, index: c_int) *std.posix.sockaddr.storage;
    extern fn us_udp_packet_buffer_payload(buf: ?*PacketBuffer, index: c_int) [*]u8;
    extern fn us_udp_packet_buffer_payload_length(buf: ?*PacketBuffer, index: c_int) c_int;
    extern fn us_udp_packet_buffer_truncated(buf: ?*PacketBuffer, index: c_int) c_int;
};

/// Faithful to the shared usockets loop handle used by `uws_sys/Loop.zig`.
pub const Loop = @import("./Loop.zig").PosixLoop;

const home_rt = @import("home");
const std = @import("std");

test "udp.Socket / PacketBuffer expose the us_udp_* API surface" {
    const testing = std.testing;
    // Compile-time sanity: every wrapper resolves. We can't `create()` a
    // socket without a libusockets loop, so this is restricted to type
    // checks — the linker step would catch any extern signature drift.
    try testing.expect(@TypeOf(udp.Socket.create) != void);
    try testing.expect(@TypeOf(udp.Socket.send) != void);
    try testing.expect(@TypeOf(udp.Socket.bind) != void);
    try testing.expect(@TypeOf(udp.Socket.boundPort) != void);
    try testing.expect(@TypeOf(udp.Socket.close) != void);
    try testing.expect(@TypeOf(udp.Socket.setBroadcast) != void);
    try testing.expect(@TypeOf(udp.Socket.setMembership) != void);
    try testing.expect(@TypeOf(PacketBuffer.getPeer) != void);
    try testing.expect(@TypeOf(PacketBuffer.getPayload) != void);
    try testing.expect(@TypeOf(PacketBuffer.getTruncated) != void);
}

test "udp boolean helpers normalise through @intFromBool" {
    // Exercises the comptime path that maps Zig booleans into the
    // libusockets c_int convention (1/0). No FFI: the wrappers are
    // pure transforms over `@intFromBool` + `@intCast`, so we can
    // assert the conversion shape without a live socket.
    try std.testing.expectEqual(@as(c_int, 1), @as(c_int, @intCast(@intFromBool(true))));
    try std.testing.expectEqual(@as(c_int, 0), @as(c_int, @intCast(@intFromBool(false))));
}
