//! Home `dataplane`: a native reverse-proxy hot path (`packages/dataplane/`).
//!
//! Sits behind a high-level control plane (e.g. rpx's TypeScript daemon) that
//! owns config, TLS issuance, routing, DNS and /etc/hosts — the dataplane just
//! moves bytes as fast as the kernel allows.
//!
//! Thesis: a runtime/JS proxy is body-bound because every byte is copied through
//! userspace + GC (~3x behind nginx on HTML). For *proxying*, nginx also copies
//! through userspace — so a no-GC, no-per-request-alloc native proxy should match
//! nginx, and `splice()` (kernel→kernel, zero-copy) goes *past* it, since we then
//! move bytes nginx still copies. A natural fit for Home's no-GC systems model.
//!
//! v0 is a transparent 1:1 TCP proxy (each client connection gets its own upstream
//! connection) on a single-threaded non-blocking `poll()` loop. Run one copy per
//! core with SO_REUSEPORT for multi-core (the kernel load-balances). It talks the
//! raw Linux syscall ABI directly (no hosted std net/posix layer) — the right,
//! churn-proof foundation for a dataplane, and where Home's own io_uring/splice
//! primitives slot in next.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
pub const fd_t = linux.fd_t;

comptime {
    if (builtin.os.tag != .linux)
        @compileError("dataplane targets Linux (its splice/io_uring data path is Linux-only)");
}

// Linux ABI constants (x86_64 / aarch64).
pub const AF_INET: u32 = 2;
pub const SOCK_STREAM: u32 = 1;
pub const SOCK_NONBLOCK: u32 = 0o4000;
const SOL_SOCKET: i32 = 1;
const SO_REUSEADDR: u32 = 2;
const SO_REUSEPORT: u32 = 15;
pub const IPPROTO_TCP: u32 = 6;
pub const TCP_NODELAY: u32 = 1;
const POLLIN: i16 = 0x001;
const POLLOUT: i16 = 0x004;
const POLLERR: i16 = 0x008;
const POLLHUP: i16 = 0x010;
pub const SHUT_WR: i32 = 1;
const SPLICE_F_MOVE: usize = 1;
const SPLICE_F_NONBLOCK: usize = 2;

pub const BUF_SIZE: usize = 64 * 1024;
const MAX_CONNS: usize = 4096;

pub const Sockaddr = extern struct {
    family: u16 = AF_INET,
    port: u16, // network byte order
    addr: u32, // network byte order
    zero: [8]u8 = @splat(0),
};

var upstream_sa: Sockaddr = undefined;

pub fn main(init: std.process.Init) !void {
    // Zig 0.17-dev passes args/env/io in via `Init` (no globals).
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]
    const a_port = it.next() orelse fatal("usage: dataplane <listenPort> <upstreamHost> <upstreamPort> [poll|uring]");
    const a_host = it.next() orelse fatal("missing upstream host");
    const a_up_port = it.next() orelse fatal("missing upstream port");
    const a_engine = it.next(); // optional: "poll" (default) | "uring"
    const a_debug = it.next(); // optional: "debug" — trace io_uring to stderr
    const listen_port = parsePort(a_port) orelse fatal("invalid listen port");
    const up_port = parsePort(a_up_port) orelse fatal("invalid upstream port");

    upstream_sa = .{ .port = byteSwap16(up_port), .addr = parseIp4(a_host) orelse fatal("upstream host must be an IPv4 literal") };

    const listen_fd = try openListener(listen_port);
    defer _ = linux.close(listen_fd);

    // Swappable io backend: `poll` is the validated default; `uring` is the
    // io_uring engine (a future Home-native io module is a third backend here).
    if (a_engine) |e| {
        if (std.mem.eql(u8, e, "uring"))
            return @import("engine_uring.zig").run(listen_fd, &upstream_sa, std.mem.eql(u8, a_debug orelse "", "debug"));
        if (!std.mem.eql(u8, e, "poll"))
            fatal("engine must be 'poll' or 'uring'");
    }
    try pollEngine(listen_fd);
}

fn parsePort(s: []const u8) ?u16 {
    return std.fmt.parseInt(u16, s, 10) catch null;
}

fn byteSwap16(v: u16) u16 {
    return if (builtin.cpu.arch.endian() == .little) @byteSwap(v) else v;
}

/// Parse `a.b.c.d` into a network-byte-order u32 (the in_addr layout).
fn parseIp4(s: []const u8) ?u32 {
    var bytes: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        bytes[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (i != 4) return null;
    return @bitCast(bytes); // bytes already in network order in memory
}

fn fatal(comptime msg: []const u8) noreturn {
    std.debug.print("dataplane: {s}\n", .{msg});
    std.process.exit(1);
}

pub fn setIntSockOpt(fd: fd_t, level: i32, optname: u32, value: c_int) void {
    var v = value;
    _ = linux.setsockopt(fd, level, optname, std.mem.asBytes(&v), @sizeOf(c_int));
}

/// Open a non-blocking TCP socket to `sa` (TCP_NODELAY on). A localhost connect
/// completes ~immediately; EINPROGRESS/EAGAIN are fine. Shared by both engines.
pub fn dialUpstream(sa: *const Sockaddr) !fd_t {
    const rc = linux.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, IPPROTO_TCP);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(rc);
    setIntSockOpt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
    switch (linux.errno(linux.connect(fd, @ptrCast(sa), @sizeOf(Sockaddr)))) {
        .SUCCESS, .INPROGRESS, .AGAIN => return fd,
        else => {
            _ = linux.close(fd);
            return error.ConnectFailed;
        },
    }
}

/// Open a TCP socket to `sa` with a *blocking* connect, then return it (the fd
/// stays blocking — io_uring drives I/O on it async). Used by the io_uring engine
/// so a splice is never issued against a still-connecting upstream (ENOTCONN).
/// Fine for a localhost upstream where connect is ~instant.
pub fn dialUpstreamBlocking(sa: *const Sockaddr) !fd_t {
    const rc = linux.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(rc);
    setIntSockOpt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
    if (linux.errno(linux.connect(fd, @ptrCast(sa), @sizeOf(Sockaddr))) != .SUCCESS) {
        _ = linux.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

/// Create a non-blocking pipe (the splice intermediary). Shared by both engines.
pub fn makePipe() ![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true })) != .SUCCESS) return error.PipeFailed;
    return fds;
}

fn openListener(port: u16) !fd_t {
    const rc = linux.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, IPPROTO_TCP);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(rc);
    setIntSockOpt(fd, SOL_SOCKET, SO_REUSEADDR, 1);
    // SO_REUSEPORT: the kernel load-balances accepted connections across the N
    // copies run for multi-core (the same model nginx/rpx use).
    setIntSockOpt(fd, SOL_SOCKET, SO_REUSEPORT, 1);
    var sa = Sockaddr{ .port = byteSwap16(port), .addr = parseIp4("127.0.0.1").? };
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(Sockaddr))) != .SUCCESS) return error.BindFailed;
    if (linux.errno(linux.listen(fd, 1024)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

/// One half of a connection: move bytes `src`→`dst` via a pipe + `splice()`
/// (kernel→kernel, zero-copy). `pending`/`in_pipe` is what's buffered in the
/// kernel pipe waiting to be written to `dst`.
const Direction = struct {
    src: fd_t,
    dst: fd_t,
    pipe_r: fd_t = -1,
    pipe_w: fd_t = -1,
    in_pipe: usize = 0,
    src_eof: bool = false,
    done: bool = false,

    fn init(self: *Direction) !void {
        var fds: [2]fd_t = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true })) != .SUCCESS) return error.PipeFailed;
        self.pipe_r = fds[0];
        self.pipe_w = fds[1];
    }

    fn deinit(self: *Direction) void {
        if (self.pipe_r != -1) _ = linux.close(self.pipe_r);
        if (self.pipe_w != -1) _ = linux.close(self.pipe_w);
    }

    fn wantRead(self: *const Direction) bool {
        return !self.src_eof and self.in_pipe == 0;
    }

    fn wantWrite(self: *const Direction) bool {
        return self.in_pipe > 0;
    }

    fn onReadable(self: *Direction) bool {
        const n = splice(self.src, self.pipe_w, BUF_SIZE) catch |e| return e == error.WouldBlock;
        if (n == 0) self.markEof() else self.in_pipe += n;
        return true;
    }

    fn onWritable(self: *Direction) bool {
        const n = splice(self.pipe_r, self.dst, self.in_pipe) catch |e| return e == error.WouldBlock;
        self.in_pipe -= n;
        // Source already hit EOF and we've drained the pipe → propagate the
        // half-close so the peer sees the end of the response.
        if (self.src_eof and self.in_pipe == 0 and !self.done) {
            self.done = true;
            _ = linux.shutdown(self.dst, SHUT_WR);
        }
        return true;
    }

    fn markEof(self: *Direction) void {
        self.src_eof = true;
        if (self.in_pipe == 0 and !self.done) {
            self.done = true;
            _ = linux.shutdown(self.dst, SHUT_WR);
        }
    }
};

const Conn = struct {
    client: fd_t,
    upstream: fd_t,
    c2u: Direction,
    u2c: Direction,

    fn finished(self: *const Conn) bool {
        return self.c2u.done and self.u2c.done;
    }
};

pub fn splice(from: fd_t, to: fd_t, max: usize) !usize {
    const rc = linux.syscall6(
        .splice,
        @as(usize, @bitCast(@as(isize, from))),
        0,
        @as(usize, @bitCast(@as(isize, to))),
        0,
        max,
        SPLICE_F_MOVE | SPLICE_F_NONBLOCK,
    );
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN => error.WouldBlock,
        else => error.SpliceFailed,
    };
}

fn pollEngine(listen_fd: fd_t) !void {
    const alloc = std.heap.page_allocator;
    var conns: [MAX_CONNS]?*Conn = std.mem.zeroes([MAX_CONNS]?*Conn); // all null
    var n_conns: usize = 0;

    var pollfds: [1 + MAX_CONNS * 2]linux.pollfd = undefined;
    var slot_conn: [MAX_CONNS * 2]usize = undefined;
    var slot_is_client: [MAX_CONNS * 2]bool = undefined;

    while (true) {
        pollfds[0] = .{ .fd = listen_fd, .events = POLLIN, .revents = 0 };
        var nfds: usize = 1;
        for (conns, 0..) |maybe, ci| {
            const c = maybe orelse continue;
            var cev: i16 = 0;
            var uev: i16 = 0;
            if (c.c2u.wantRead()) cev |= POLLIN; // read from client
            if (c.u2c.wantWrite()) cev |= POLLOUT; // write to client
            if (c.u2c.wantRead()) uev |= POLLIN; // read from upstream
            if (c.c2u.wantWrite()) uev |= POLLOUT; // write to upstream
            if (cev != 0) {
                pollfds[nfds] = .{ .fd = c.client, .events = cev, .revents = 0 };
                slot_conn[nfds - 1] = ci;
                slot_is_client[nfds - 1] = true;
                nfds += 1;
            }
            if (uev != 0) {
                pollfds[nfds] = .{ .fd = c.upstream, .events = uev, .revents = 0 };
                slot_conn[nfds - 1] = ci;
                slot_is_client[nfds - 1] = false;
                nfds += 1;
            }
        }

        const prc = linux.poll(&pollfds, @intCast(nfds), -1);
        if (linux.errno(prc) != .SUCCESS) continue; // EINTR etc. — rebuild + retry

        if (pollfds[0].revents & POLLIN != 0) {
            while (n_conns < MAX_CONNS) {
                const arc = linux.accept4(listen_fd, null, null, SOCK_NONBLOCK);
                if (linux.errno(arc) != .SUCCESS) break; // EAGAIN — drained
                const cfd: fd_t = @intCast(arc);
                const conn = acceptConn(alloc, cfd) catch {
                    _ = linux.close(cfd);
                    continue;
                };
                for (&conns) |*slot| {
                    if (slot.* == null) {
                        slot.* = conn;
                        n_conns += 1;
                        break;
                    }
                }
            }
        }

        var i: usize = 1;
        while (i < nfds) : (i += 1) {
            const re = pollfds[i].revents;
            if (re == 0) continue;
            const ci = slot_conn[i - 1];
            const c = conns[ci] orelse continue;
            const is_client = slot_is_client[i - 1];
            var ok = true;
            if (re & (POLLIN | POLLHUP) != 0)
                ok = if (is_client) c.c2u.onReadable() else c.u2c.onReadable();
            if (ok and re & POLLOUT != 0)
                ok = if (is_client) c.u2c.onWritable() else c.c2u.onWritable();
            if (!ok or re & POLLERR != 0) {
                closeConn(alloc, &conns, ci, &n_conns);
                continue;
            }
            if (c.finished())
                closeConn(alloc, &conns, ci, &n_conns);
        }
    }
}

fn acceptConn(alloc: std.mem.Allocator, client_fd: fd_t) !*Conn {
    const urc = linux.socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, IPPROTO_TCP);
    if (linux.errno(urc) != .SUCCESS) return error.SocketFailed;
    const up_fd: fd_t = @intCast(urc);
    setIntSockOpt(client_fd, IPPROTO_TCP, TCP_NODELAY, 1);
    setIntSockOpt(up_fd, IPPROTO_TCP, TCP_NODELAY, 1);
    // Non-blocking connect to a localhost upstream completes ~immediately;
    // EINPROGRESS is fine (poll surfaces real failures as POLLERR).
    switch (linux.errno(linux.connect(up_fd, @ptrCast(&upstream_sa), @sizeOf(Sockaddr)))) {
        .SUCCESS, .INPROGRESS, .AGAIN => {},
        else => {
            _ = linux.close(up_fd);
            return error.ConnectFailed;
        },
    }

    const conn = try alloc.create(Conn);
    errdefer alloc.destroy(conn);
    conn.* = .{
        .client = client_fd,
        .upstream = up_fd,
        .c2u = .{ .src = client_fd, .dst = up_fd },
        .u2c = .{ .src = up_fd, .dst = client_fd },
    };
    try conn.c2u.init();
    errdefer conn.c2u.deinit();
    try conn.u2c.init();
    return conn;
}

fn closeConn(alloc: std.mem.Allocator, conns: *[MAX_CONNS]?*Conn, ci: usize, n_conns: *usize) void {
    const c = conns[ci] orelse return;
    _ = linux.close(c.client);
    _ = linux.close(c.upstream);
    c.c2u.deinit();
    c.u2c.deinit();
    alloc.destroy(c);
    conns[ci] = null;
    n_conns.* -= 1;
}
