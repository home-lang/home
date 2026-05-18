// Copied from bun/src/uws_sys/quic/PendingConnect.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt"). Bun upstream
// imports `uws.quic.Socket` through the `bun.uws` aggregator; we use
// the sibling Socket directly since `uws.quic` doesn't exist in home_rt
// until Phase 12 brings the rest of the uws bindings across.

//! `us_quic_pending_connect_s` — DNS-pending client connect. Created when
//! `Context.connect` returns 0 (cache miss); holds the
//! `Bun__addrinfo` request that the caller registers a callback on.
//! Consumed by exactly one of `resolved()` or `cancel()`.

pub const PendingConnect = opaque {
    extern fn us_quic_pending_connect_addrinfo(pc: *PendingConnect) *anyopaque;
    pub const addrinfo = us_quic_pending_connect_addrinfo;

    extern fn us_quic_pending_connect_resolved(pc: *PendingConnect) ?*Socket;
    pub const resolved = us_quic_pending_connect_resolved;

    extern fn us_quic_pending_connect_cancel(pc: *PendingConnect) void;
    pub const cancel = us_quic_pending_connect_cancel;
};

const Socket = @import("./Socket.zig").Socket;
