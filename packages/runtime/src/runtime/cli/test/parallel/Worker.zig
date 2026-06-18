// Copied from bun/src/runtime/cli/test/parallel/Worker.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//   - bun.* → home_rt.* namespace references

//! One spawned `bun test --test-worker --isolate` process plus its three
//! pipes. Tightly coupled with `Coordinator` (which owns the worker slice and
//! routes IPC frames); this file holds only the per-process state and the
//! spawn/dispatch/shutdown mechanics.

pub const Worker = @This();

coord: *Coordinator,
idx: u32,
process: ?*home_rt.spawn.Process = null,

/// Bidirectional IPC over fd 3. POSIX: usockets adopted from a socketpair.
/// Windows: `uv.Pipe` (the parent end of `.buffer` extra-fd, full-duplex).
/// Commands and results both flow through this channel; backpressure is
/// handled by the loop, so a busy worker writing thousands of `test_done`
/// frames never truncates and the coordinator never blocks.
ipc: Channel(Worker, "ipc") = .{},
out: WorkerPipe,
err: WorkerPipe,

/// Index into `Coordinator.files` currently running on this worker.
inflight: ?u32 = null,
/// Contiguous slice of `Coordinator.files` owned by this worker. `files`
/// is sorted lexicographically so adjacent indices share parent dirs (and
/// likely imports); each worker walks its range front-to-back. When the
/// range is empty the worker steals one file from the *end* of whichever
/// range has the most remaining — the end is furthest from that worker's
/// hot region.
range: FileRange = .{ .lo = 0, .hi = 0 },
/// `home_rt.milliTimestamp()` at the most recent dispatch; drives lazy
/// scale-up.
dispatched_at: i64 = 0,
/// Worker stdout+stderr since the last `test_done`. Flushed atomically
/// under the right file header so concurrent files don't interleave.
captured: std.ArrayListUnmanaged(u8) = .empty,
alive: bool = false,
/// Set when the process-exit notification arrives. Reaping waits for both
/// this and `ipc.done` so trailing IPC frames are decoded first.
exit_status: ?home_rt.spawn.Status = null,
extra_fd_stdio: [1]home_rt.spawn.SpawnOptions.Stdio = .{.ignore},

pub fn start(this: *Worker) !void {
    home_rt.assert(!this.alive);
    const coord = this.coord;

    this.out.reader.setParent(&this.out);
    this.err.reader.setParent(&this.err);

    // All resource cleanup on any error return — including watchOrReap
    // failure below. Each guard checks for null/unstarted so the order in
    // which fields are populated doesn't matter.
    errdefer {
        if (this.process) |p| {
            p.exit_handler = .{};
            if (!p.hasExited()) _ = p.kill(9);
            p.close();
            this.process = null;
        }
        // Reset to fresh state after deinit so reapWorker's `!respawned`
        // cleanup (which can't tell whether start() ran) doesn't deinit on
        // undefined ArrayList memory.
        this.ipc.deinit();
        this.ipc = .{};
        this.out.deinit();
        this.out = .{ .role = .stdout, .worker = this };
        this.err.deinit();
        this.err = .{ .role = .stderr, .worker = this };
    }

    if (Environment.isPosix) {
        // `.buffer` extra_fd creates an AF_UNIX socketpair; the parent end is
        // adopted into a usockets `Channel`.
        this.extra_fd_stdio = .{.buffer};
        const options: home_rt.spawn.SpawnOptions = .{
            .stdin = .ignore,
            .stdout = .buffer,
            .stderr = .buffer,
            .extra_fds = &this.extra_fd_stdio,
            .cwd = coord.cwd,
            .stream = true,
            // Own pgrp so abortAll can kill(-pid, SIGTERM) the worker and
            // anything it spawned. PDEATHSIG is the SIGKILL safety net on
            // Linux for the worker itself.
            .new_process_group = true,
            .linux_pdeathsig = if (Environment.isLinux) std.posix.SIG.KILL else null,
        };
        var spawned = try (try home_rt.spawn.spawnProcess(&options, coord.argv.ptr, coord.envps[this.idx].ptr)).unwrap();
        defer spawned.extra_pipes.deinit();
        this.process = spawned.toProcess(coord.vm.eventLoop(), false);
        if (spawned.stdout) |fd| try this.out.reader.start(fd, true).unwrap();
        if (spawned.stderr) |fd| try this.err.reader.start(fd, true).unwrap();
        if (spawned.extra_pipes.items.len > 0) {
            if (!this.ipc.adopt(coord.vm, spawned.extra_pipes.items[0].fd())) return error.ChannelAdoptFailed;
        } else {
            this.ipc.done = true;
        }
    } else {
        // Windows: `.ipc` extra_fd creates a duplex `uv.Pipe` (named pipe
        // under the hood, UV_READABLE | UV_WRITABLE | UV_OVERLAPPED) and
        // initialises the parent end with uv_pipe_init(loop, ipc=1) — the
        // same dance Bun.spawn({ipc}) / process.send() use. The child opens
        // CRT fd 3 with uv_pipe_init(ipc=1) + uv_pipe_open in Channel.adopt.
        // Both ends agreeing on the libuv IPC framing is what matters; our
        // own [u32 len][u8 kind] frames ride inside it unchanged.
        const uv = home_rt.windows.libuv;

        const ipc_pipe = home_rt.new(uv.Pipe, std.mem.zeroes(uv.Pipe));
        errdefer if (this.ipc.backend.pipe == null) ipc_pipe.closeAndDestroy();

        this.extra_fd_stdio = .{.{ .ipc = ipc_pipe }};
        const options: home_rt.spawn.SpawnOptions = .{
            .stdin = .ignore,
            .stdout = .{ .buffer = home_rt.new(uv.Pipe, std.mem.zeroes(uv.Pipe)) },
            .stderr = .{ .buffer = home_rt.new(uv.Pipe, std.mem.zeroes(uv.Pipe)) },
            .extra_fds = &this.extra_fd_stdio,
            .cwd = coord.cwd,
            .windows = .{ .loop = jsc.EventLoopHandle.init(coord.vm) },
            .stream = true,
        };
        var spawned = try (try home_rt.spawn.spawnProcess(&options, coord.argv.ptr, coord.envps[this.idx].ptr)).unwrap();
        defer spawned.extra_pipes.deinit();
        this.process = spawned.toProcess(coord.vm.eventLoop(), false);

        if (spawned.stdout == .buffer) try this.out.reader.startWithPipe(spawned.stdout.buffer).unwrap();
        if (spawned.stderr == .buffer) try this.err.reader.startWithPipe(spawned.stderr.buffer).unwrap();
        if (!this.ipc.adoptPipe(coord.vm, ipc_pipe)) return error.ChannelAdoptFailed;
    }

    const process = this.process.?;
    if (Environment.isWindows) {
        if (coord.windows_job) |job| {
            if (process.poller == .uv) {
                _ = home_rt.windows.AssignProcessToJobObject(job, process.poller.uv.process_handle);
            }
        }
    }
    this.alive = true;
    coord.live_workers += 1;
    process.setExitHandler(this);
    switch (process.watchOrReap()) {
        .result => {},
        .err => |e| {
            // Surface to the caller (spawnWorker / onWorkerExit) instead of
            // synchronously firing onExit() — that would re-enter
            // onWorkerExit() → start(), which under persistent EMFILE
            // recurses unboundedly while spawning real processes each frame.
            // Resource cleanup is handled by the function-scope errdefer.
            this.alive = false;
            coord.live_workers -= 1;
            Output.err(e, "watchOrReap failed for test worker", .{});
            return error.ProcessWatchFailed;
        },
    }
}

pub fn onProcessExit(this: *Worker, _: *home_rt.spawn.Process, status: home_rt.spawn.Status, _: *const home_rt.spawn.Rusage) void {
    this.alive = false;
    this.coord.onWorkerExit(this, status);
}

pub fn eventLoop(this: *Worker) *jsc.EventLoop {
    return this.coord.vm.eventLoop();
}
pub fn loop(this: *Worker) *home_rt.Async.Loop {
    return this.coord.vm.uvLoop();
}

pub fn dispatch(this: *Worker, file_idx: u32, file: []const u8) void {
    const f = &this.coord.frame;
    f.begin(.run);
    f.u32_(file_idx);
    f.str(file);
    this.ipc.send(f.finish());
    this.inflight = file_idx;
    this.dispatched_at = home_rt.milliTimestamp();
}

pub fn shutdown(this: *Worker) void {
    const f = &this.coord.frame;
    f.begin(.shutdown);
    this.ipc.send(f.finish());
    // Leave the channel open so the reader drains trailing
    // repeat_bufs/junit_file/coverage_file frames; the worker exits on
    // `.shutdown` and its exit closes the peer end.
}

/// `Channel` owner callback: a decoded frame arrived.
pub fn onChannelFrame(this: *Worker, kind: Frame.Kind, rd: *Frame.Reader) void {
    this.coord.onFrame(this, kind, rd);
}

/// `Channel` owner callback: peer closed, errored, or sent a corrupt frame.
/// Gates `tryReap` so kernel-buffered frames written just before exit() are
/// decoded before the worker slot is torn down.
pub fn onChannelDone(this: *Worker) void {
    if (this.ipc.isAttached()) {
        // Corrupt frame path — kill the worker so onWorkerExit accounts for
        // the in-flight file and the slot can respawn.
        if (this.process) |p| _ = p.kill(9);
    }
    this.coord.tryReap(this);
}

/// Reads worker stdout/stderr. Accumulates into the worker's `captured` buffer
/// and flushes atomically with the next test result so console output from
/// concurrent files never interleaves.
pub const WorkerPipe = struct {
    reader: home_rt.io.BufferedReader = home_rt.io.BufferedReader.init(WorkerPipe),
    worker: *Worker,
    role: enum { stdout, stderr },
    /// EOF or error observed.
    done: bool = false,

    pub fn deinit(this: *WorkerPipe) void {
        this.reader.deinit();
    }

    pub fn onReadChunk(this: *WorkerPipe, chunk: []const u8, _: home_rt.io.ReadState) bool {
        home_rt.handleOom(this.worker.captured.appendSlice(home_rt.default_allocator, chunk));
        return true;
    }
    pub fn onReaderDone(this: *WorkerPipe) void {
        this.done = true;
    }
    pub fn onReaderError(this: *WorkerPipe, _: home_rt.sys.Error) void {
        this.done = true;
    }
    pub fn eventLoop(this: *WorkerPipe) *jsc.EventLoop {
        return this.worker.coord.vm.eventLoop();
    }
    pub fn loop(this: *WorkerPipe) *home_rt.Async.Loop {
        return this.worker.coord.vm.uvLoop();
    }
};

const FileRange = @import("./FileRange.zig");
const Frame = @import("./Frame.zig");
const std = @import("std");
const Channel = @import("./Channel.zig").Channel;
const Coordinator = @import("./Coordinator.zig").Coordinator;

const home_rt = @import("home");
const Environment = home_rt.Environment;
const Output = home_rt.Output;
const jsc = home_rt.jsc;

test "Worker exposes process lifecycle entrypoints" {
    try std.testing.expect(@hasDecl(Worker, "start"));
    try std.testing.expect(@hasDecl(Worker, "dispatch"));
    try std.testing.expect(@hasDecl(Worker, "shutdown"));
    try std.testing.expect(@hasDecl(WorkerPipe, "onReadChunk"));
}
