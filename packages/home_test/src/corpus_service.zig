//! Owned background services with bounded readiness and continuous pipe capture.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const child_wait = @import("corpus_child_wait.zig");

pub const Protocol = union(enum) { port_line, marker: []const u8 };
pub const Options = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    environment: ?*const std.process.Environ.Map = null,
    protocol: Protocol,
    startup_timeout_ms: i64,
    keep_stdin_open: bool = false,
};
pub const Result = struct {
    ready: bool = false,
    port: ?u16 = null,
    startup_timed_out: bool = false,
    invalid_readiness: bool = false,
    unexpected_exit: bool = false,
    stopped_by_owner: bool = false,
    output_complete: bool = false,
    term: ?std.process.Child.Term = null,
    failure: ?anyerror = null,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    pub fn successful(self: Result) bool {
        return self.ready and self.stopped_by_owner and self.term != null and !self.startup_timed_out and !self.invalid_readiness and !self.unexpected_exit and self.output_complete and self.failure == null;
    }
};

pub const Service = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    io: Io,
    options: Options,
    environment: ?std.process.Environ.Map,
    group: Io.Group = .init,
    ready_event: Io.Event = .unset,
    finished_event: Io.Event = .unset,
    stop_requested: std.atomic.Value(bool) = .init(false),
    // ready and port become immutable before ready_event is signaled. Read the
    // remaining result fields only after finish(), which joins the worker.
    result: Result = .{},

    pub fn start(allocator: Allocator, io: Io, options: Options) !*Service {
        if (options.argv.len == 0 or options.startup_timeout_ms <= 0) return error.InvalidServiceOptions;
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .io = io, .options = options, .environment = null };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        const argv = try arena.alloc([]const u8, options.argv.len);
        for (options.argv, argv) |arg, *owned| owned.* = try arena.dupe(u8, arg);
        self.options.argv = argv;
        if (options.cwd) |cwd| self.options.cwd = try arena.dupe(u8, cwd);
        if (options.protocol == .marker) self.options.protocol = .{ .marker = try arena.dupe(u8, options.protocol.marker) };
        if (options.environment) |env| self.environment = try env.clone(allocator);
        errdefer if (self.environment) |*env| env.deinit();
        self.options.environment = if (self.environment) |*env| env else null;
        errdefer {
            allocator.free(self.result.stdout);
            allocator.free(self.result.stderr);
        }
        try self.group.concurrent(io, worker, .{self});
        errdefer {
            self.stop_requested.store(true, .release);
            self.group.cancel(io);
        }
        try self.ready_event.wait(io);
        return self;
    }

    pub fn ready(self: *const Service) bool {
        return self.ready_event.isSet() and self.result.ready;
    }
    pub fn port(self: *const Service) ?u16 {
        return if (self.ready()) self.result.port else null;
    }
    pub fn finish(self: *Service) *const Result {
        self.stop_requested.store(true, .release);
        self.group.await(self.io) catch self.group.cancel(self.io);
        return &self.result;
    }
    pub fn deinit(self: *Service) void {
        _ = self.finish();
        const allocator = self.allocator;
        allocator.free(self.result.stdout);
        allocator.free(self.result.stderr);
        if (self.environment) |*env| env.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn worker(self: *Service) void {
        self.run() catch |err| {
            self.result.failure = err;
        };
        self.ready_event.set(self.io);
        self.finished_event.set(self.io);
    }
    fn observeReadiness(self: *Service, bytes: []const u8, eof: bool) void {
        if (self.ready_event.isSet()) return;
        switch (self.options.protocol) {
            .marker => |marker| {
                if (std.mem.indexOf(u8, bytes, marker) == null) return;
            },
            .port_line => {
                const end = std.mem.indexOfScalar(u8, bytes, '\n') orelse if (eof and bytes.len != 0) bytes.len else return;
                const line = std.mem.trim(u8, bytes[0..end], " \t\r");
                const parsed = std.fmt.parseInt(u16, line, 10) catch {
                    self.result.invalid_readiness = true;
                    self.ready_event.set(self.io);
                    return;
                };
                if (parsed == 0) {
                    self.result.invalid_readiness = true;
                    self.ready_event.set(self.io);
                    return;
                }
                self.result.port = parsed;
            },
        }
        self.result.ready = true;
        self.ready_event.set(self.io);
    }
    fn run(self: *Service) !void {
        const io = self.io;
        const process_group = builtin.os.tag != .windows;
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(self.options.startup_timeout_ms), .clock = .awake });
        var child = try std.process.spawn(io, .{
            .argv = self.options.argv,
            .cwd = if (self.options.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = self.options.environment,
            .stdin = if (self.options.keep_stdin_open) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (process_group) 0 else null,
        });
        defer if (child.id != null) {
            child_wait.forceTerminate(&child, process_group);
            child.kill(io);
        };
        var buffers: Io.File.MultiReader.Buffer(2) = undefined;
        var reader: Io.File.MultiReader = undefined;
        reader.init(self.allocator, io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer reader.deinit();
        var eof = false;
        while (true) {
            self.observeReadiness(reader.reader(0).buffered(), eof);
            if (try child_wait.hasExited(&child)) {
                self.result.unexpected_exit = true;
                break;
            }
            if (self.result.invalid_readiness) break;
            if (self.stop_requested.load(.acquire)) {
                self.result.stopped_by_owner = true;
                break;
            }
            const remaining = deadline.durationFromNow(io).raw.nanoseconds;
            if (!self.result.ready and remaining <= 0) {
                self.result.startup_timed_out = true;
                self.ready_event.set(io);
                break;
            }
            const interval = if (self.result.ready) 50 * std.time.ns_per_ms else @min(remaining, 50 * std.time.ns_per_ms);
            if (eof) {
                try Io.sleep(io, .fromNanoseconds(interval), .awake);
            } else {
                reader.fill(64, .{ .duration = .{ .raw = .fromNanoseconds(interval), .clock = .awake } }) catch |err| switch (err) {
                    error.EndOfStream => eof = true,
                    error.Timeout => {},
                    else => |e| return e,
                };
            }
        }
        self.ready_event.set(io);
        if (child.stdin) |stdin| {
            stdin.close(io);
            child.stdin = null;
            eof = try drain(&reader, io, 250);
        }
        if (!try child_wait.hasExited(&child)) child_wait.terminate(&child, process_group);
        eof = try drain(&reader, io, 500);
        child_wait.forceTerminate(&child, process_group);
        if (!eof) eof = try drain(&reader, io, 500);
        if (eof) try reader.checkAnyError() else reader.batch.cancel(io);
        self.result.term = try child.wait(io);
        self.result.stdout = try reader.toOwnedSlice(0);
        self.result.stderr = try reader.toOwnedSlice(1);
        self.result.output_complete = eof;
    }
};

fn drain(reader: *Io.File.MultiReader, io: Io, milliseconds: i64) !bool {
    const deadline = (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } }).toDeadline(io);
    while (reader.fill(64, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => return true,
        error.Timeout => return false,
        else => |e| return e,
    }
}

test "service capture drains both pipes while the caller owns a ready service" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const service = try Service.start(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf '43210\\n'; i=0; while [ $i -lt 4000 ]; do printf 'out-%s\\n' $i; printf 'err-%s\\n' $i >&2; i=$((i+1)); done; cat >/dev/null" },
        .protocol = .port_line,
        .startup_timeout_ms = 5000,
        .keep_stdin_open = true,
    });
    defer service.deinit();
    try std.testing.expectEqual(@as(?u16, 43210), service.port());
    const result = service.finish();
    try std.testing.expect(result.successful());
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "out-3999") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "err-3999") != null);
}

test "service startup deadline remains active after output EOF and retains early exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const timed = try Service.start(std.testing.allocator, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "exec 1>&-; exec 2>&-; sleep 30" }, .protocol = .port_line, .startup_timeout_ms = 40 });
    defer timed.deinit();
    const timeout = timed.finish();
    try std.testing.expect(!timeout.ready and timeout.startup_timed_out and timeout.output_complete);
    const exited = try Service.start(std.testing.allocator, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" }, .protocol = .{ .marker = "COORDINATOR_READY" }, .startup_timeout_ms = 5000 });
    defer exited.deinit();
    const result = exited.finish();
    try std.testing.expect(!result.ready and result.unexpected_exit and result.output_complete);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, result.term.?);
}
