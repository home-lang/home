// Copied from bun/src/http/h3_client/PendingConnect.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Naming convention (2026-05-18): `BunXxx` → `Xxx`, `bun` enum tag → `home`.
// Imports rewritten: @import("bun") → @import("home").
//   - `bun.uws.{Loop, quic}` → the ported `home_rt.uws` aggregator.
//   - `bun.Mutex` → `home_rt.threading.Mutex`.
//   - `bun.http.H3.ClientSession` and `bun.http.H3.ClientContext` now share
//     the real sibling types used by ClientContext/callbacks/encode.
//   - `bun.dns.internal.registerQuic` (the DNS-cache hand-off) is shimmed
//     as a no-op extern reference guarded by `is_test`; the real DNS path
//     lands once the dns subtree is ported.
//   - `bun.new` / `bun.destroy` shim through `home_rt.default_allocator`.

//! DNS-pending QUIC connect. Created when `quic.Context.connect` returns
//! `.pending` (cache miss); the global DNS cache notifies via
//! `onDNSResolved[Threadsafe]`, at which point the resolved address is
//! handed to lsquic and the resulting `quic.Socket` bound to the waiting
//! `ClientSession`.
//!
//! Lifetime: holds one ref on `session` from `register` until
//! `onDNSResolved` runs. The `quic.PendingConnect` C handle is consumed by
//! exactly one of `resolved()` or `cancel()`.

const PendingConnect = @This();

session: *ClientSession,
pc: *quic.PendingConnect,
loop_ptr: *uws.Loop,
next: ?*PendingConnect = null,

pub fn register(session: *ClientSession, pc: *quic.PendingConnect, l: *uws.Loop) void {
    const self = newPendingConnect(.{ .session = session, .pc = pc, .loop_ptr = l });
    session.ref();
    dns.internal.registerQuic(@ptrCast(@alignCast(addrinfoFor(pc))), self);
}

pub fn loop(this: *PendingConnect) *uws.Loop {
    return this.loop_ptr;
}

pub fn onDNSResolved(this: *PendingConnect) void {
    const session = this.session;
    defer {
        session.deref();
        destroy(this);
    }
    if (session.closed or session.pending.items.len == 0) {
        // Every waiter was aborted while DNS was in flight; don't open a
        // connection nobody will use.
        cancelPC(this.pc);
        if (!session.closed) failSession(session, error.Aborted);
        return;
    }
    const qs = resolvePC(this.pc) orelse {
        failSession(session, error.DNSResolutionFailed);
        return;
    };
    session.qsocket = qs;
    sessionExt(qs).* = session;
}

/// DNS worker may call from off the HTTP thread; mirror
/// us_internal_dns_callback_threadsafe: push onto a mutex-protected list and
/// wake the loop. `drainResolved` runs from `HTTPThread.drainEvents` on the
/// next loop iteration after the wakeup.
pub fn onDNSResolvedThreadsafe(this: *PendingConnect) void {
    resolved_mutex.lock();
    this.next = resolved_head;
    resolved_head = this;
    resolved_mutex.unlock();
    wakeupLoop(this.loop_ptr);
}

pub fn drainResolved() void {
    resolved_mutex.lock();
    var head = resolved_head;
    resolved_head = null;
    resolved_mutex.unlock();
    while (head) |pc| {
        const next = pc.next;
        pc.onDNSResolved();
        head = next;
    }
}

pub fn failSession(session: *ClientSession, err: anyerror) void {
    session.closed = true;
    if (H3.ClientContext.get()) |ctx| ctx.unregister(session);
    while (session.pending.items.len > 0) {
        const stream = session.pending.items[0];
        const cl = stream.client;
        session.detach(stream);
        if (cl) |cl_| cl_.failFromH2(err);
    }
    _ = H3.live_sessions.fetchSub(1, .monotonic);
    session.deref();
}

// Upstream uses `bun.Mutex` (= `home_rt.threading.Mutex`, the Bun-flavoured
// futex wrapper). The Home substrate's `threading/Mutex.zig` self-imports
// the `home_rt` module which trips an "already in this module" diagnostic
// when *this* file is the test root. Zig 0.17 also removed the public
// `std.Thread.Mutex` export, so neither candidate links cleanly here. A
// trivial atomic-CAS Mutex covers the LIFO push/drain critical section
// exactly the same way (single-byte lock, no waiter queueing — the
// critical section is just three pointer writes); the production build
// will land on `home_rt.threading.Mutex` once that self-import is
// resolved.
const Mutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.swap(1, .acquire) != 0) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

var resolved_mutex: Mutex = .{};
var resolved_head: ?*PendingConnect = null;

/// `bun.dns.internal` — global DNS resolver cache. The only callsite needs
/// `registerQuic(*anyopaque, *PendingConnect)` for the hand-off. The real
/// impl lives behind a libusockets thread; stub it out in test builds.
const dns = struct {
    pub const internal = struct {
        pub fn registerQuic(addrinfo_ptr: *anyopaque, pc: *PendingConnect) void {
            if (comptime @import("builtin").is_test) return;
            // Forward-declared upstream as
            //   extern fn Bun__dns_internal_registerQuic(*anyopaque, *anyopaque) void;
            // Until the dns subtree ports, the symbol is provided by the
            // linked C side; this branch only compiles in non-test builds.
            return Bun__dns_internal_registerQuic(addrinfo_ptr, pc);
        }
    };
};

extern fn Bun__dns_internal_registerQuic(addrinfo_ptr: *anyopaque, pc: *anyopaque) void;

/// `qs.cancel()` / `qs.resolved()` / `qs.addrinfo()` indirections —
/// upstream calls these inline on the `*quic.PendingConnect` opaque. The
/// quic.PendingConnect upstream methods aren't on the home_rt opaque yet,
/// so wrap each in a guarded extern that test builds can link without
/// pulling in the C runtime. The bodies branch on `@import("builtin").is_test`
/// at comptime so the extern callee never makes it into the test object.
inline fn cancelPC(pc: *quic.PendingConnect) void {
    if (comptime @import("builtin").is_test) return;
    pc.cancel();
}
inline fn resolvePC(pc: *quic.PendingConnect) ?*quic.Socket {
    if (comptime @import("builtin").is_test) return null;
    return pc.resolved();
}
inline fn addrinfoFor(pc: *quic.PendingConnect) *anyopaque {
    if (comptime @import("builtin").is_test) return @ptrCast(pc);
    return pc.addrinfo();
}

/// `qs.ext(ClientSession)` indirection — the lsquic socket carries one
/// `*ClientSession` pointer in its ext slot. Opaque in test builds.
inline fn sessionExt(qs: *quic.Socket) *?*ClientSession {
    if (comptime @import("builtin").is_test) {
        const Holder = struct {
            var slot: ?*ClientSession = null;
        };
        return &Holder.slot;
    }
    return qs.ext(ClientSession);
}

/// `loop.wakeup()` indirection — extern in non-test builds, no-op in tests.
inline fn wakeupLoop(l: *uws.Loop) void {
    if (comptime @import("builtin").is_test) return;
    l.wakeup();
}

/// `bun.new(T, value)` / `bun.destroy(ptr)` shims through
/// `home_rt.default_allocator`.
fn newPendingConnect(value: PendingConnect) *PendingConnect {
    const ptr = home_rt.default_allocator.create(PendingConnect) catch
        @panic("OOM in PendingConnect.register");
    ptr.* = value;
    return ptr;
}
fn destroy(ptr: anytype) void {
    home_rt.default_allocator.destroy(ptr);
}

const quic = home_rt.uws_sys.quic;
const H3 = home_rt.http.H3;
const ClientSession = H3.ClientSession;
const Stream = H3.Stream;
const uws = home_rt.uws;
const std = @import("std");
const home_rt = @import("home");

test "PendingConnect linked-list push order is LIFO via onDNSResolvedThreadsafe" {
    // Reset state so a parallel test doesn't see stale entries.
    defer {
        resolved_mutex.lock();
        resolved_head = null;
        resolved_mutex.unlock();
    }

    var session_a: ClientSession = undefined;
    var session_b: ClientSession = undefined;
    var loop_storage: u8 align(@alignOf(uws.Loop)) = 0;
    const fake_loop: *uws.Loop = @ptrCast(&loop_storage);
    var fake_pc_storage: u8 = 0;
    const fake_pc: *quic.PendingConnect = @ptrCast(&fake_pc_storage);

    var pc_a: PendingConnect = .{
        .session = &session_a,
        .pc = fake_pc,
        .loop_ptr = fake_loop,
    };
    var pc_b: PendingConnect = .{
        .session = &session_b,
        .pc = fake_pc,
        .loop_ptr = fake_loop,
    };

    pc_a.onDNSResolvedThreadsafe();
    pc_b.onDNSResolvedThreadsafe();

    // Head is the most recently pushed entry (B), then A.
    try std.testing.expectEqual(@as(?*PendingConnect, &pc_b), resolved_head);
    try std.testing.expectEqual(@as(?*PendingConnect, &pc_a), pc_b.next);
    try std.testing.expectEqual(@as(?*PendingConnect, null), pc_a.next);
}

test "PendingConnect.loop returns the registered loop pointer" {
    var session: ClientSession = undefined;
    var loop_storage: u8 align(@alignOf(uws.Loop)) = 0;
    const fake_loop: *uws.Loop = @ptrCast(&loop_storage);
    var fake_pc_storage: u8 = 0;
    const fake_pc: *quic.PendingConnect = @ptrCast(&fake_pc_storage);

    var pc: PendingConnect = .{
        .session = &session,
        .pc = fake_pc,
        .loop_ptr = fake_loop,
    };
    try std.testing.expectEqual(fake_loop, pc.loop());
}

test "ClientSession.detach removes the matching pending entry" {
    const hostname = try home_rt.default_allocator.dupe(u8, "example.com");
    const session = ClientSession.new(.{
        .qsocket = null,
        .hostname = hostname,
        .port = 443,
        .reject_unauthorized = true,
    });
    session.ref();

    const stream_a = Stream.new(.{ .session = session, .client = null });
    const stream_b = Stream.new(.{ .session = session, .client = null });
    _ = H3.live_streams.fetchAdd(2, .monotonic);

    try session.pending.append(home_rt.default_allocator, stream_a);
    try session.pending.append(home_rt.default_allocator, stream_b);
    try std.testing.expectEqual(@as(usize, 2), session.pending.items.len);

    session.detach(stream_a);
    try std.testing.expectEqual(@as(usize, 1), session.pending.items.len);
    try std.testing.expectEqual(stream_b, session.pending.items[0]);

    session.detach(stream_b);
    session.deref();
}

test "failSession: empties pending and decrements live_sessions" {
    const hostname = try home_rt.default_allocator.dupe(u8, "example.com");
    const session = ClientSession.new(.{
        .qsocket = null,
        .hostname = hostname,
        .port = 443,
        .reject_unauthorized = true,
    });
    session.ref();
    session.ref();

    const stream = Stream.new(.{ .session = session, .client = null });
    _ = H3.live_streams.fetchAdd(1, .monotonic);
    try session.pending.append(home_rt.default_allocator, stream);

    // failSession decrements live_sessions; pre-bump so we don't underflow.
    _ = H3.live_sessions.fetchAdd(1, .monotonic);
    const before = H3.live_sessions.load(.monotonic);

    failSession(session, error.Aborted);

    try std.testing.expect(session.closed);
    try std.testing.expectEqual(@as(usize, 0), session.pending.items.len);
    try std.testing.expectEqual(before - 1, H3.live_sessions.load(.monotonic));

    session.deref();
}
