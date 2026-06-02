// Copied from bun/src/uws_sys/quic/Context.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). The upstream
// The PendingConnect / Socket / Stream siblings already live in
// `home_rt.uws_sys.quic.*` so the references rewrite trivially. `Loop` is the
// real uWS loop type now that `uws_sys/Loop.zig` is ported, keeping H3 client
// context and pending-connect handles type-identical.

//! `us_quic_socket_context_t` — one lsquic engine + its event-loop wiring.
//! For the client there is exactly one of these per HTTP-thread loop and it
//! lives for the process; the server creates one per `Bun.serve({http3:true})`.

pub const Context = opaque {
    extern fn us_create_quic_client_context(loop: *Loop, ext_size: c_uint, conn_ext: c_uint, stream_ext: c_uint) ?*Context;
    pub const createClient = us_create_quic_client_context;

    extern fn us_quic_socket_context_loop(ctx: *Context) *Loop;
    pub const loop = us_quic_socket_context_loop;

    extern fn us_quic_socket_context_connect(ctx: *Context, host: [*:0]const u8, port: c_int, sni: [*:0]const u8, reject_unauthorized: c_int, out_qs: *?*Socket, out_pending: *?*PendingConnect, user: *anyopaque) c_int;

    pub const ConnectResult = union(enum) {
        /// IP literal or DNS-cache hit: handshake already in flight.
        socket: *Socket,
        /// DNS cache miss: caller must register a `Bun__addrinfo` callback on
        /// `pending.addrinfo()` and call `pending.resolved()` when it fires.
        pending: *PendingConnect,
        err,
    };

    pub fn connect(ctx: *Context, host: [*:0]const u8, port: u16, sni: [*:0]const u8, reject_unauthorized: bool, user: *anyopaque) ConnectResult {
        var qs: ?*Socket = null;
        var pc: ?*PendingConnect = null;
        return switch (us_quic_socket_context_connect(ctx, host, port, sni, @intFromBool(reject_unauthorized), &qs, &pc, user)) {
            1 => .{ .socket = qs.? },
            0 => .{ .pending = pc.? },
            else => .err,
        };
    }

    extern fn us_quic_socket_context_on_hsk_done(ctx: *Context, cb: *const fn (*Socket, c_int) callconv(.c) void) void;
    pub const onHskDone = us_quic_socket_context_on_hsk_done;
    extern fn us_quic_socket_context_on_goaway(ctx: *Context, cb: *const fn (*Socket) callconv(.c) void) void;
    pub const onGoaway = us_quic_socket_context_on_goaway;
    extern fn us_quic_socket_context_on_close(ctx: *Context, cb: *const fn (*Socket) callconv(.c) void) void;
    pub const onClose = us_quic_socket_context_on_close;
    extern fn us_quic_socket_context_on_stream_open(ctx: *Context, cb: *const fn (*Stream, c_int) callconv(.c) void) void;
    pub const onStreamOpen = us_quic_socket_context_on_stream_open;
    extern fn us_quic_socket_context_on_stream_headers(ctx: *Context, cb: *const fn (*Stream) callconv(.c) void) void;
    pub const onStreamHeaders = us_quic_socket_context_on_stream_headers;
    extern fn us_quic_socket_context_on_stream_data(ctx: *Context, cb: *const fn (*Stream, [*]const u8, c_uint, c_int) callconv(.c) void) void;
    pub const onStreamData = us_quic_socket_context_on_stream_data;
    extern fn us_quic_socket_context_on_stream_writable(ctx: *Context, cb: *const fn (*Stream) callconv(.c) void) void;
    pub const onStreamWritable = us_quic_socket_context_on_stream_writable;
    extern fn us_quic_socket_context_on_stream_close(ctx: *Context, cb: *const fn (*Stream) callconv(.c) void) void;
    pub const onStreamClose = us_quic_socket_context_on_stream_close;
};

const PendingConnect = @import("PendingConnect.zig").PendingConnect;
const Socket = @import("Socket.zig").Socket;
const Stream = @import("Stream.zig").Stream;

pub const Loop = @import("../Loop.zig").Loop;

test "quic.Context exposes the us_quic_socket_context_t API surface" {
    const std = @import("std");
    try std.testing.expect(@TypeOf(Context.createClient) != void);
    try std.testing.expect(@TypeOf(Context.loop) != void);
    try std.testing.expect(@TypeOf(Context.connect) != void);
    try std.testing.expect(@TypeOf(Context.onHskDone) != void);
    try std.testing.expect(@TypeOf(Context.onStreamOpen) != void);
}
