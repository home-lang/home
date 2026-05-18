// Copied from bun/src/uws_sys/vtable.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Imports rewritten: upstream resolves `ConnectingSocket` / `us_socket_t` /
// `VTable` via `bun.uws`. Home's uws_sys aggregator only exposes the QUIC
// subtree today; `ConnectingSocket` is already ported as a sibling so we
// import it directly. `us_socket_t` and `us_bun_verify_error_t` are
// forward-declared as local opaques (same pattern as ConnectingSocket.zig
// uses for `SocketGroup` and `Loop`). The local `VTable` lives in
// `SocketGroup.zig` upstream; until that file lands here, we declare a
// pointer-identical mirror locally — `make()` returns `*const VTable` and
// callers only ever store/forward the pointer, so the opaque cohabits
// with the future `SocketGroup.VTable` export.

//! Comptime `us_socket_vtable_t` generator. Given a Zig handler type and the
//! ext payload type, emits a single static-const `VTable` whose entries are
//! `callconv(.c)` trampolines that recover the typed ext from the raw socket
//! and forward.
//!
//! This replaces `NewSocketHandler.configure`/`unsafeConfigure`/`wrapTLS`,
//! which did the same trampoline dance per-call at runtime via
//! `us_socket_context_on_*`. One handler type → one vtable in `.rodata`.
//!
//! Handler shape (any subset; missing methods → vtable entry left null):
//!   pub const Ext = *MySocket;                // what `us_socket_ext` holds
//!   pub fn onOpen(ext, *us_socket_t, is_client: bool, ip: []const u8) void
//!   pub fn onData(ext, *us_socket_t, data: []const u8) void
//!   pub fn onWritable(ext, *us_socket_t) void
//!   pub fn onClose(ext, *us_socket_t, code: i32, reason: ?*anyopaque) void
//!
//! `Ext` may be omitted entirely; handlers then take `(*us_socket_t, …)` and
//! recover their owner from `s.group().owner(T)` instead.
//!
//!   pub fn onTimeout(ext, *us_socket_t) void
//!   pub fn onLongTimeout(ext, *us_socket_t) void
//!   pub fn onEnd(ext, *us_socket_t) void
//!   pub fn onFd(ext, *us_socket_t, fd: c_int) void
//!   pub fn onConnectError(ext, *us_socket_t, code: i32) void
//!   pub fn onConnectingError(*ConnectingSocket, code: i32) void
//!   pub fn onHandshake(ext, *us_socket_t, ok: bool, err: us_bun_verify_error_t) void

/// Produce a `*const VTable` for `H`. The result is a comptime address into
/// `.rodata`; safe to store in any number of `SocketGroup`s.
pub fn make(comptime H: type) *const VTable {
    const T = Trampolines(H);
    return &(struct {
        pub const vt: VTable = .{
            .on_open = if (@hasDecl(H, "onOpen")) T.on_open else null,
            .on_data = if (@hasDecl(H, "onData")) T.on_data else null,
            .on_fd = if (@hasDecl(H, "onFd")) T.on_fd else null,
            .on_writable = if (@hasDecl(H, "onWritable")) T.on_writable else null,
            .on_close = if (@hasDecl(H, "onClose")) T.on_close else null,
            .on_timeout = if (@hasDecl(H, "onTimeout")) T.on_timeout else null,
            .on_long_timeout = if (@hasDecl(H, "onLongTimeout")) T.on_long_timeout else null,
            .on_end = if (@hasDecl(H, "onEnd")) T.on_end else null,
            .on_connect_error = if (@hasDecl(H, "onConnectError")) T.on_connect_error else null,
            .on_connecting_error = if (@hasDecl(H, "onConnectingError")) T.on_connecting_error else null,
            .on_handshake = if (@hasDecl(H, "onHandshake")) T.on_handshake else null,
        };
    }).vt;
}

/// The trampolines themselves, exposed so `dispatch.zig` can direct-call them
/// per-kind without going through the vtable pointer at all.
pub fn Trampolines(comptime H: type) type {
    // `Ext` is optional. Handlers that work entirely from `*us_socket_t` (e.g.
    // BunListener — owner comes from `s.group().owner(T)`) omit it and take
    // `(s, …)` instead of `(ext, s, …)`.
    const has_ext = @hasDecl(H, "Ext");
    const E = if (has_ext) H.Ext else void;

    return struct {
        inline fn call(s: *us_socket_t, comptime f: anytype, extra: anytype) void {
            if (comptime has_ext) {
                @call(.auto, f, .{s.ext(@typeInfo(E).pointer.child)} ++ .{s} ++ extra);
            } else {
                @call(.auto, f, .{s} ++ extra);
            }
        }

        pub fn on_open(s: *us_socket_t, is_client: c_int, ip: [*c]u8, ip_len: c_int) callconv(.c) ?*us_socket_t {
            call(s, H.onOpen, .{ is_client != 0, if (ip != null) ip[0..@intCast(ip_len)] else @as([]const u8, &.{}) });
            return s;
        }
        pub fn on_data(s: *us_socket_t, data: [*c]u8, len: c_int) callconv(.c) ?*us_socket_t {
            call(s, H.onData, .{data[0..@intCast(len)]});
            return s;
        }
        pub fn on_fd(s: *us_socket_t, fd: c_int) callconv(.c) ?*us_socket_t {
            call(s, H.onFd, .{fd});
            return s;
        }
        pub fn on_writable(s: *us_socket_t) callconv(.c) ?*us_socket_t {
            call(s, H.onWritable, .{});
            return s;
        }
        pub fn on_close(s: *us_socket_t, code: c_int, reason: ?*anyopaque) callconv(.c) ?*us_socket_t {
            call(s, H.onClose, .{ @as(i32, code), reason });
            return s;
        }
        pub fn on_timeout(s: *us_socket_t) callconv(.c) ?*us_socket_t {
            call(s, H.onTimeout, .{});
            return s;
        }
        pub fn on_long_timeout(s: *us_socket_t) callconv(.c) ?*us_socket_t {
            call(s, H.onLongTimeout, .{});
            return s;
        }
        pub fn on_end(s: *us_socket_t) callconv(.c) ?*us_socket_t {
            call(s, H.onEnd, .{});
            return s;
        }
        pub fn on_connect_error(s: *us_socket_t, code: c_int) callconv(.c) ?*us_socket_t {
            call(s, H.onConnectError, .{@as(i32, code)});
            return s;
        }
        pub fn on_connecting_error(cs: *ConnectingSocket, code: c_int) callconv(.c) ?*ConnectingSocket {
            H.onConnectingError(cs, code);
            return cs;
        }
        pub fn on_handshake(s: *us_socket_t, ok: c_int, err: us_bun_verify_error_t, _: ?*anyopaque) callconv(.c) void {
            call(s, H.onHandshake, .{ ok != 0, err });
        }
    };
}

const ConnectingSocket = @import("./ConnectingSocket.zig").ConnectingSocket;

/// Placeholder forward-declaration. Replaced when `uws_sys/us_socket_t.zig`
/// ports (it pulls in the full SocketKind switch + jsc.EventLoopHandle).
/// Trampolines only ever take/return `*us_socket_t` — the actual
/// `ext`/`group`/`localAddress` methods are not used in this file, so the
/// opaque is sufficient for compiling `vtable.make`. Once the full
/// `us_socket_t.zig` lands, this placeholder collapses (same opaque ABI).
pub const us_socket_t = opaque {
    /// Trampolines call `s.ext(T)` to recover the typed payload. Mirrors the
    /// future `us_socket_t.ext(comptime T: type) *T` accessor; until that
    /// lands we forward to the upstream `us_socket_ext` extern so handler
    /// trampolines can still typecheck and (with a live loop) execute.
    pub fn ext(this: *us_socket_t, comptime T: type) *T {
        return @ptrCast(@alignCast(c.us_socket_ext(0, this).?));
    }
};

/// Placeholder forward-declaration. Replaced when the broader TLS surface
/// lands (`us_bun_verify_error_t` lives alongside `us_bun_ssl_options` in
/// upstream `libusockets.h`). Field-compatible with the C struct — handlers
/// only read it as an opaque payload here.
pub const us_bun_verify_error_t = extern struct {
    error_no: c_int = 0,
    code: [*:0]const u8 = "",
    reason: [*:0]const u8 = "",
};

/// Layout-compatible mirror of `us_socket_vtable_t` in libusockets.h. Will
/// be re-exported from `uws_sys/SocketGroup.zig` once that file ports;
/// `make()` and `Trampolines(H)` reference it through the local alias so
/// callers can swap to `SocketGroup.VTable` without source churn.
pub const VTable = extern struct {
    on_open: ?*const fn (*us_socket_t, c_int, [*c]u8, c_int) callconv(.c) ?*us_socket_t = null,
    on_data: ?*const fn (*us_socket_t, [*c]u8, c_int) callconv(.c) ?*us_socket_t = null,
    on_fd: ?*const fn (*us_socket_t, c_int) callconv(.c) ?*us_socket_t = null,
    on_writable: ?*const fn (*us_socket_t) callconv(.c) ?*us_socket_t = null,
    on_close: ?*const fn (*us_socket_t, c_int, ?*anyopaque) callconv(.c) ?*us_socket_t = null,
    on_timeout: ?*const fn (*us_socket_t) callconv(.c) ?*us_socket_t = null,
    on_long_timeout: ?*const fn (*us_socket_t) callconv(.c) ?*us_socket_t = null,
    on_end: ?*const fn (*us_socket_t) callconv(.c) ?*us_socket_t = null,
    on_connect_error: ?*const fn (*us_socket_t, c_int) callconv(.c) ?*us_socket_t = null,
    on_connecting_error: ?*const fn (*ConnectingSocket, c_int) callconv(.c) ?*ConnectingSocket = null,
    on_handshake: ?*const fn (*us_socket_t, c_int, us_bun_verify_error_t, ?*anyopaque) callconv(.c) void = null,
};

const c = struct {
    extern fn us_socket_ext(ssl: c_int, s: *us_socket_t) ?*anyopaque;
};

test "vtable.make synthesises a const VTable from a handler type" {
    const std = @import("std");

    // Handler with a single hook — every other slot must be null, proving the
    // `@hasDecl` filter works.
    const H = struct {
        pub fn onOpen(_: *us_socket_t, _: bool, _: []const u8) void {}
    };

    const vt: *const VTable = make(H);
    try std.testing.expect(vt.on_open != null);
    try std.testing.expect(vt.on_data == null);
    try std.testing.expect(vt.on_close == null);
    try std.testing.expect(vt.on_handshake == null);
    try std.testing.expect(vt.on_connecting_error == null);
}

test "vtable.make returns the same pointer for the same handler type" {
    const std = @import("std");

    const H = struct {
        pub fn onClose(_: *us_socket_t, _: i32, _: ?*anyopaque) void {}
    };
    const a = make(H);
    const b = make(H);
    // Two calls to `make(H)` resolve to the same .rodata address — the
    // comptime struct is unique per type, so this also doubles as a sanity
    // check that the produced VTable is in fact rodata.
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a.on_close != null);
}

test "VTable layout matches us_socket_vtable_t" {
    const std = @import("std");
    // 11 function pointers. Layout-locked to the C side via `extern struct`.
    try std.testing.expectEqual(@as(usize, 11 * @sizeOf(*anyopaque)), @sizeOf(VTable));
}
