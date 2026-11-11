//! Real three-pipe synchronous transport. Native IO tasks never execute JS.
const std = @import("std");
pub const max_bytes = 32 * 1024 * 1024;

pub const Result = struct {
    pid: std.posix.pid_t,
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    io_error: ?anyerror,
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const Stream = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    pid: std.posix.pid_t,
    limit: usize,
    bytes: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,
};
const Input = struct {
    file: std.Io.File,
    pid: std.posix.pid_t,
    bytes: []const u8,
    err: ?anyerror = null,
};
fn stop(pid: std.posix.pid_t) void {
    // The owner does not reap until all tasks join, so this immutable PID
    // cannot have been recycled, even when two streams fail concurrently.
    _ = std.c.kill(pid, .KILL);
}
fn readPipe(io: std.Io, stream: *Stream) std.Io.Cancelable!void {
    defer stream.file.close(io);
    var storage: [8192]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(stream.file, io, &.{});
    while (true) {
        const count = reader.interface.readSliceShort(&storage) catch |err| {
            stream.err = if (err == error.ReadFailed) reader.err orelse err else err;
            stop(stream.pid);
            return;
        };
        if (count == 0) return;
        stream.bytes.appendSlice(stream.allocator, storage[0..count]) catch |err| {
            stream.err = err;
            stop(stream.pid);
            return;
        };
        if (stream.bytes.items.len > stream.limit) {
            stream.err = error.CaptureLimit;
            stop(stream.pid);
            return;
        }
    }
}
fn writePipe(io: std.Io, input: *Input) std.Io.Cancelable!void {
    defer input.file.close(io);
    input.file.writeStreamingAll(io, input.bytes) catch |err| {
        input.err = err;
        // EPIPE records incomplete input, but the child may still produce its
        // final output and exit normally. Drain/reap it before reporting EPIPE.
        if (err != error.BrokenPipe) stop(input.pid);
    };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, env: *const std.process.Environ.Map, input: []const u8, limit: usize) !Result {
    if (argv.len == 0 or input.len > max_bytes or limit > max_bytes) return error.UnsupportedCapture;
    var child = try std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = .cwd(), .path = argv[0] } },
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const pid = child.id.?;
    var group: std.Io.Group = .init;
    var stdout: Stream = .{ .allocator = allocator, .file = child.stdout.?, .pid = pid, .limit = limit };
    defer stdout.bytes.deinit(allocator);
    var stderr: Stream = .{ .allocator = allocator, .file = child.stderr.?, .pid = pid, .limit = limit };
    defer stderr.bytes.deinit(allocator);
    var stdin: Input = .{ .file = child.stdin.?, .pid = pid, .bytes = input };
    defer {
        if (child.id != null) stop(pid);
        group.cancel(io);
        child.kill(io);
    }

    // Transfer each descriptor only after its task is guaranteed to run.
    // On scheduling/OOM failure the child still owns every untransferred fd.
    try group.concurrent(io, readPipe, .{ io, &stdout });
    child.stdout = null;
    try group.concurrent(io, readPipe, .{ io, &stderr });
    child.stderr = null;
    try group.concurrent(io, writePipe, .{ io, &stdin });
    child.stdin = null;
    try group.await(io);
    const term = try child.wait(io);
    const out = try stdout.bytes.toOwnedSlice(allocator);
    errdefer allocator.free(out);
    const err = try stderr.bytes.toOwnedSlice(allocator);
    const failure: ?anyerror = if (stdout.err) |e| e else if (stderr.err) |e| e else stdin.err;
    return .{ .pid = pid, .term = term, .stdout = out, .stderr = err, .io_error = failure };
}

test "captured pipes drain both outputs while feeding input and reap the child" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const input = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(input);
    @memset(input, 0xa5);
    var result = try run(allocator, threaded.io(), &.{ "/bin/sh", "-c", "/bin/dd if=/dev/zero bs=1024 count=256 2>/dev/null; /bin/dd if=/dev/zero bs=1024 count=256 1>&2 2>/dev/null; /bin/cat" }, null, &env, input, 1024 * 1024);
    defer result.deinit(allocator);
    try std.testing.expectEqual(null, result.io_error);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqual(@as(usize, 768 * 1024), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 256 * 1024), result.stderr.len);
    try std.testing.expect(std.mem.allEqual(u8, result.stdout[0 .. 256 * 1024], 0));
    try std.testing.expectEqualSlices(u8, input, result.stdout[256 * 1024 ..]);
    try std.testing.expect(std.mem.allEqual(u8, result.stderr, 0));
    var status: c_int = 0;
    try std.testing.expect(std.c.waitpid(result.pid, &status, std.c.W.NOHANG) < 0 and std.posix.errno(-1) == .CHILD);
}

test "capture limit kills and reaps real child without returning success" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var result = try run(allocator, threaded.io(), &.{ "/bin/sh", "-c", "/bin/dd if=/dev/zero bs=1024 count=256 2>/dev/null; exec /bin/sleep 30" }, null, &env, "", 128);
    defer result.deinit(allocator);
    try std.testing.expectEqual(error.CaptureLimit, result.io_error.?);
    try std.testing.expect(result.stdout.len > 128);
    try std.testing.expectEqual(std.posix.SIG.KILL, result.term.signal);
    var status: c_int = 0;
    try std.testing.expect(std.c.waitpid(result.pid, &status, std.c.W.NOHANG) < 0 and std.posix.errno(-1) == .CHILD);
}

test "partial IO scheduling failure cancels tasks before releasing their buffers" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    // The first reader blocks, forcing the second task to fail scheduling.
    // Cleanup must join that reader before freeing its stack/owned state.
    try std.testing.expectError(error.ConcurrencyUnavailable, run(allocator, threaded.io(), &.{ "/bin/sh", "-c", "read witness", "home-exec-scheduling-witness" }, null, &env, "", 128));
}

test "early stdin closure retains final output and normal exit before reporting EPIPE" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const input = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(input);
    @memset(input, 0xa5);
    var result = try run(allocator, threaded.io(), &.{ "/bin/sh", "-c", "exec 0<&-; /bin/sleep 0.02; printf done" }, null, &env, input, 1024);
    defer result.deinit(allocator);
    try std.testing.expectEqual(error.BrokenPipe, result.io_error.?);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("done", result.stdout);
}
