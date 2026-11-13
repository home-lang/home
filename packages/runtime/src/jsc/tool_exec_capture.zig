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

pub const Stdio = enum { pipe, ignore, inherit };
pub const Options = struct {
    stdio: [3]Stdio = .{ .pipe, .pipe, .pipe },
    search_path: bool = false,
};

fn mode(value: Stdio) std.process.SpawnOptions.StdIo {
    return switch (value) {
        .pipe => .pipe,
        .ignore => .ignore,
        .inherit => .inherit,
    };
}

fn spawnPath(io: std.Io, path: []const u8, argv: []const []const u8, cwd: ?[]const u8, env: *const std.process.Environ.Map, options: Options) !std.process.Child {
    return std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = .cwd(), .path = path } },
        .argv = argv,
        .cwd = if (cwd) |path_name| .{ .path = path_name } else .inherit,
        .environ_map = env,
        .stdin = mode(options.stdio[0]),
        .stdout = mode(options.stdio[1]),
        .stderr = mode(options.stdio[2]),
    });
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, env: *const std.process.Environ.Map, input: []const u8, limit: usize) !Result {
    return runOptions(allocator, io, argv, cwd, env, input, limit, .{});
}

pub fn runOptions(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, env: *const std.process.Environ.Map, input: []const u8, limit: usize, options: Options) !Result {
    if (argv.len == 0 or input.len > max_bytes or limit > max_bytes) return error.UnsupportedCapture;
    var child = if (!options.search_path or std.mem.indexOfScalar(u8, argv[0], '/') != null)
        try spawnPath(io, argv[0], argv, cwd, env, options)
    else search: {
        // Node uses the supplied environment's PATH, or the POSIX default when
        // it is absent. Zig's .search uses the parent environment instead.
        var directories = std.mem.splitScalar(u8, env.get("PATH") orelse "/usr/bin:/bin", ':');
        var denied = false;
        while (directories.next()) |directory| {
            const candidate = try std.fs.path.join(allocator, &.{ if (directory.len == 0) "." else directory, argv[0] });
            defer allocator.free(candidate);
            if (spawnPath(io, candidate, argv, cwd, env, options)) |started| break :search started else |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                error.AccessDenied => denied = true,
                else => return err,
            }
        }
        return if (denied) error.AccessDenied else error.FileNotFound;
    };
    const pid = child.id.?;
    var group: std.Io.Group = .init;
    var stdout: Stream = .{ .allocator = allocator, .file = child.stdout orelse undefined, .pid = pid, .limit = limit };
    defer stdout.bytes.deinit(allocator);
    var stderr: Stream = .{ .allocator = allocator, .file = child.stderr orelse undefined, .pid = pid, .limit = limit };
    defer stderr.bytes.deinit(allocator);
    var stdin: Input = .{ .file = child.stdin orelse undefined, .pid = pid, .bytes = input };
    defer {
        if (child.id != null) stop(pid);
        group.cancel(io);
        child.kill(io);
    }

    // Transfer each descriptor only after its task is guaranteed to run.
    // On scheduling/OOM failure the child still owns every untransferred fd.
    if (options.stdio[1] == .pipe) {
        try group.concurrent(io, readPipe, .{ io, &stdout });
        child.stdout = null;
    }
    if (options.stdio[2] == .pipe) {
        try group.concurrent(io, readPipe, .{ io, &stderr });
        child.stderr = null;
    }
    if (options.stdio[0] == .pipe) {
        try group.concurrent(io, writePipe, .{ io, &stdin });
        child.stdin = null;
    }
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

test "PATH lookup uses supplied environment and ignored stdin is an actual character device" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PATH", "/bin");
    var result = try runOptions(allocator, threaded.io(), &.{ "sh", "-c", "test -c /dev/fd/0 && printf native-ignore" }, null, &env, "", 1024, .{ .stdio = .{ .ignore, .pipe, .ignore }, .search_path = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("native-ignore", result.stdout);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
    var status: c_int = 0;
    try std.testing.expect(std.c.waitpid(result.pid, &status, std.c.W.NOHANG) < 0 and std.posix.errno(-1) == .CHILD);
    try env.put("PATH", "/ecosystem-no-such-path");
    try std.testing.expectError(error.FileNotFound, runOptions(allocator, threaded.io(), &.{"sh"}, null, &env, "", 1024, .{ .search_path = true }));
}

test "ignored outputs stay native null devices and nonzero child exit is reaped" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var result = try runOptions(allocator, threaded.io(), &.{ "/bin/sh", "-c", "printf ignored-output; printf ignored-error >&2; exit 7" }, null, &env, "", 1024, .{ .stdio = .{ .ignore, .ignore, .ignore } });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 7), result.term.exited);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
    var status: c_int = 0;
    try std.testing.expect(std.c.waitpid(result.pid, &status, std.c.W.NOHANG) < 0 and std.posix.errno(-1) == .CHILD);
}
