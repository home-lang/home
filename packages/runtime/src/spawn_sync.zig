// Synchronous process spawning and output capture, implemented on Home's
// forked std.Io process API.

const std = @import("std");
const bun = @import("home");
const Environment = bun.Environment;

pub const Stdio = enum { inherit, ignore, buffer };

const WindowsOptions = struct { loop: ?*anyopaque = null };

pub const Options = struct {
    stdin: Stdio = .ignore,
    stdout: Stdio = .inherit,
    stderr: Stdio = .inherit,
    ipc: ?bun.FD = null,
    cwd: []const u8 = "",
    detached: bool = false,

    argv: []const []const u8,
    /// null = inherit parent env
    envp: ?[*:null]?[*:0]const u8 = null,

    use_execve_on_macos: bool = false,
    argv0: ?[*:0]const u8 = null,

    windows: if (Environment.isWindows) WindowsOptions else void = if (Environment.isWindows) .{} else {},
};

/// Retain exit and signal details for native command dispatch.
pub const Status = union(enum) {
    exited: struct { code: u8, signal: bun.SignalCode = @fromBackingInt(@intCast(0)) },
    signaled: bun.SignalCode,
    err: bun.sys.Error,

    pub fn isOK(this: *const Status) bool {
        return switch (this.*) {
            .exited => |e| e.code == 0,
            else => false,
        };
    }
};

pub const Result = struct {
    status: Status,
    stdout: std.array_list.Managed(u8) = .{ .items = &.{}, .allocator = bun.default_allocator, .capacity = 0 },
    stderr: std.array_list.Managed(u8) = .{ .items = &.{}, .allocator = bun.default_allocator, .capacity = 0 },

    pub fn isOK(this: *const Result) bool {
        return this.status.isOK();
    }

    pub fn deinit(this: *const Result) void {
        this.stderr.deinit();
        this.stdout.deinit();
    }
};

pub fn spawn(options: *const Options) !bun.sys.Maybe(Result) {
    var threaded = std.Io.Threaded.init(bun.default_allocator, .{});
    defer threaded.deinit();

    var env_map = std.process.Environ.Map.init(bun.default_allocator);
    defer env_map.deinit();
    if (options.envp) |envp| {
        var index: usize = 0;
        while (envp[index]) |entry| : (index += 1) {
            const pair = std.mem.span(entry);
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            try env_map.put(pair[0..equals], pair[equals + 1 ..]);
        }
    }

    // Inherited streams must remain the actual descriptors: capturing and
    // replaying them loses stdin, TTY identity and live output ordering.
    if (options.stdin == .buffer) return error.UnsupportedStdinBuffer;
    if (options.ipc != null) return error.UnsupportedIpcDescriptor;
    if (options.detached) return error.UnsupportedDetachedSpawn;
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = if (options.cwd.len > 0) .{ .path = options.cwd } else .inherit,
        .environ_map = if (options.envp != null) &env_map else null,
        .stdin = if (options.stdin == .inherit) .inherit else .ignore,
        .stdout = switch (options.stdout) {
            .inherit => .inherit,
            .ignore => .ignore,
            .buffer => .pipe,
        },
        .stderr = switch (options.stderr) {
            .inherit => .inherit,
            .ignore => .ignore,
            .buffer => .pipe,
        },
    });
    defer child.kill(io);

    var stdout = std.array_list.Managed(u8).init(bun.default_allocator);
    errdefer stdout.deinit();
    var stderr = std.array_list.Managed(u8).init(bun.default_allocator);
    errdefer stderr.deinit();
    var files: [2]std.Io.File = undefined;
    var count: u32 = 0;
    if (child.stdout) |file| {
        files[count] = file;
        count += 1;
    }
    if (child.stderr) |file| {
        files[count] = file;
        count += 1;
    }
    if (count > 0) {
        var storage: std.Io.File.MultiReader.Buffer(2) = undefined;
        const streams = storage.toStreams();
        streams.len = count;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(bun.default_allocator, io, streams, files[0..count]);
        defer reader.deinit();
        while (reader.fill(4096, .none)) |_| {} else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        try reader.checkAnyError();
        if (child.stdout != null) {
            stdout.items = try reader.toOwnedSlice(0);
            stdout.capacity = stdout.items.len;
        }
        if (child.stderr != null) {
            stderr.items = try reader.toOwnedSlice(if (child.stdout != null) 1 else 0);
            stderr.capacity = stderr.items.len;
        }
    }
    const status: Status = switch (try child.wait(io)) {
        .exited => |code| .{ .exited = .{ .code = code } },
        .signal, .stopped => |signal| .{ .signaled = @fromBackingInt(@intCast(@backingInt(signal))) },
        .unknown => return error.UnknownChildStatus,
    };
    return .{ .result = .{ .status = status, .stdout = stdout, .stderr = stderr } };
}
