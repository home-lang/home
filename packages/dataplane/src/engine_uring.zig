//! io_uring engine for the dataplane (opt-in: `dataplane … uring`).
//!
//! Same zero-copy splice data path as the poll engine, but completion-driven via
//! io_uring instead of readiness-driven via poll(): batched syscalls, multishot
//! accept, and `IORING_OP_SPLICE` ops. Each connection-half alternates one
//! read-splice (src→pipe) and write-splices (pipe→dst), driven by completions.
//!
//! Connection slots carry a generation counter so a completion for a freed slot
//! (reused by a new connection) is ignored, and an in-flight-op count so a slot
//! is only closed/freed once no SQE still references it.
const std = @import("std");
const linux = std.os.linux;
const dp = @import("dataplane.zig");
const fd_t = dp.fd_t;

const MAX_CONNS: usize = 4096;
const RING_ENTRIES: u16 = 8192;
/// splice offset for pipe/socket fds: -1 means "no offset, use the stream".
const NO_OFF: u64 = @bitCast(@as(i64, -1));
const ACCEPT_UD: u64 = std.math.maxInt(u64);

const Half = struct {
    src: fd_t,
    dst: fd_t,
    pipe_r: fd_t,
    pipe_w: fd_t,
    in_pipe: usize = 0,
    src_eof: bool = false,
    done: bool = false, // src EOF reached and pipe fully drained to dst
};

const Conn = struct {
    used: bool = false,
    closing: bool = false,
    gen: u32 = 0,
    in_flight: u32 = 0, // SQEs outstanding that reference this slot
    client: fd_t = -1,
    upstream: fd_t = -1,
    halves: [2]Half = undefined, // [0]=client→upstream, [1]=upstream→client
};

var ring: linux.IoUring = undefined;
var conns: [MAX_CONNS]Conn = undefined;
var dbg: bool = false;

fn dprint(comptime fmt: []const u8, args: anytype) void {
    if (dbg) std.debug.print("[uring] " ++ fmt ++ "\n", args);
}

fn encodeUD(slot: usize, gen: u32, dir: u1, op: u1) u64 {
    return (@as(u64, gen) << 18) | (@as(u64, slot) << 2) | (@as(u64, dir) << 1) | op;
}

const Decoded = struct { slot: usize, gen: u32, dir: u1, op: u1 };
fn decodeUD(ud: u64) Decoded {
    return .{
        .op = @intCast(ud & 1),
        .dir = @intCast((ud >> 1) & 1),
        .slot = @intCast((ud >> 2) & 0xFFFF),
        .gen = @intCast((ud >> 18) & 0xFFFFFFFF),
    };
}

/// Submit a splice SQE, flushing + retrying once if the submission queue is full.
fn submitSplice(ud: u64, fd_in: fd_t, fd_out: fd_t, len: usize) !void {
    _ = ring.splice(ud, fd_in, NO_OFF, fd_out, NO_OFF, len) catch |e| {
        if (e != error.SubmissionQueueFull) return e;
        _ = try ring.submit();
        _ = try ring.splice(ud, fd_in, NO_OFF, fd_out, NO_OFF, len);
    };
}

pub fn run(listen_fd: fd_t, upstream_sa: *const dp.Sockaddr, debug: bool) !void {
    dbg = debug;
    ring = try linux.IoUring.init(RING_ENTRIES, 0);
    defer ring.deinit();
    for (&conns) |*c| c.* = .{};
    dprint("ring up (entries={d}), accepting on fd={d}", .{ RING_ENTRIES, listen_fd });

    _ = try ring.accept(ACCEPT_UD, listen_fd, null, null, dp.SOCK_NONBLOCK);

    var cqes: [256]linux.io_uring_cqe = undefined;
    while (true) {
        // submit_and_wait flushes queued SQEs *and* waits for ≥1 completion in one
        // enter() — copy_cqes alone never submits (it enters with to_submit=0).
        const subd = ring.submit_and_wait(1) catch |e| {
            if (e == error.SignalInterrupt) continue;
            dprint("submit_and_wait err: {s}", .{@errorName(e)});
            return e;
        };
        const n = ring.copy_cqes(&cqes, 0) catch 0;
        dprint("woke: submitted={d} cqes={d}", .{ subd, n });
        for (cqes[0..n]) |cqe| try handle(cqe, listen_fd, upstream_sa);
    }
}

fn handle(cqe: linux.io_uring_cqe, listen_fd: fd_t, upstream_sa: *const dp.Sockaddr) !void {
    if (cqe.user_data == ACCEPT_UD) {
        dprint("accept cqe res={d}", .{cqe.res});
        if (cqe.res >= 0)
            onAccept(@intCast(cqe.res), upstream_sa);
        _ = ring.accept(ACCEPT_UD, listen_fd, null, null, dp.SOCK_NONBLOCK) catch {}; // re-arm (single-shot)
        return;
    }

    const d = decodeUD(cqe.user_data);
    dprint("splice cqe slot={d} gen={d} dir={d} op={d} res={d}", .{ d.slot, d.gen, d.dir, d.op, cqe.res });
    const c = &conns[d.slot];
    if (!c.used or c.gen != d.gen) return; // stale completion for a freed slot
    c.in_flight -= 1;
    const h = &c.halves[d.dir];

    if (!c.closing) {
        if (d.op == 0) onReadDone(c, h, d, cqe.res) else onWriteDone(c, h, d, cqe.res);
    }

    if ((c.closing or (c.halves[0].done and c.halves[1].done)) and c.in_flight == 0)
        freeConn(c);
}

/// A new client connection: dial the upstream, make a pipe per direction, and
/// kick off the initial read-splice on both halves.
fn onAccept(client_fd: fd_t, upstream_sa: *const dp.Sockaddr) void {
    var slot: usize = 0;
    while (slot < MAX_CONNS and conns[slot].used) : (slot += 1) {}
    if (slot == MAX_CONNS) {
        _ = linux.close(client_fd);
        return;
    }
    const c = &conns[slot];
    const up_fd = dp.dialUpstreamBlocking(upstream_sa) catch |e| {
        dprint("dial upstream failed: {s}", .{@errorName(e)});
        _ = linux.close(client_fd);
        return;
    };
    dprint("accepted client_fd={d} -> upstream_fd={d} slot={d}", .{ client_fd, up_fd, slot });
    const p_c2u = dp.makePipe() catch {
        _ = linux.close(client_fd);
        _ = linux.close(up_fd);
        return;
    };
    const p_u2c = dp.makePipe() catch {
        _ = linux.close(client_fd);
        _ = linux.close(up_fd);
        _ = linux.close(p_c2u[0]);
        _ = linux.close(p_c2u[1]);
        return;
    };
    dp.setIntSockOpt(client_fd, dp.IPPROTO_TCP, dp.TCP_NODELAY, 1);

    c.* = .{
        .used = true,
        .gen = c.gen +% 1,
        .client = client_fd,
        .upstream = up_fd,
    };
    c.halves[0] = .{ .src = client_fd, .dst = up_fd, .pipe_r = p_c2u[0], .pipe_w = p_c2u[1] };
    c.halves[1] = .{ .src = up_fd, .dst = client_fd, .pipe_r = p_u2c[0], .pipe_w = p_u2c[1] };

    startRead(c, slot, 0);
    startRead(c, slot, 1);
}

fn startRead(c: *Conn, slot: usize, dir: u1) void {
    const h = &c.halves[dir];
    submitSplice(encodeUD(slot, c.gen, dir, 0), h.src, h.pipe_w, dp.BUF_SIZE) catch {
        c.closing = true;
        return;
    };
    c.in_flight += 1;
}

fn startWrite(c: *Conn, slot: usize, dir: u1) void {
    const h = &c.halves[dir];
    submitSplice(encodeUD(slot, c.gen, dir, 1), h.pipe_r, h.dst, h.in_pipe) catch {
        c.closing = true;
        return;
    };
    c.in_flight += 1;
}

fn onReadDone(c: *Conn, h: *Half, d: Decoded, res: i32) void {
    if (res <= 0) {
        // 0 = upstream/client closed its send side; <0 = error.
        h.src_eof = true;
        if (res < 0) {
            c.closing = true;
            return;
        }
        if (h.in_pipe == 0 and !h.done) {
            h.done = true;
            _ = linux.shutdown(h.dst, dp.SHUT_WR);
        }
        return;
    }
    h.in_pipe += @intCast(res);
    startWrite(c, d.slot, d.dir); // drain the pipe before reading more
}

fn onWriteDone(c: *Conn, h: *Half, d: Decoded, res: i32) void {
    if (res < 0) {
        c.closing = true;
        return;
    }
    h.in_pipe -= @intCast(res);
    if (h.in_pipe > 0) {
        startWrite(c, d.slot, d.dir); // more buffered — keep draining
    } else if (h.src_eof) {
        if (!h.done) {
            h.done = true;
            _ = linux.shutdown(h.dst, dp.SHUT_WR);
        }
    } else {
        startRead(c, d.slot, d.dir); // pipe empty — read the next chunk
    }
}

fn freeConn(c: *Conn) void {
    _ = linux.close(c.client);
    _ = linux.close(c.upstream);
    for (&c.halves) |*h| {
        _ = linux.close(h.pipe_r);
        _ = linux.close(h.pipe_w);
    }
    c.used = false;
    c.closing = false;
}
