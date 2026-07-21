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

/// Minimal process status: enough for `Result.isOK()`.
pub const Status = union(enum) {
    exited: struct { code: u8 },
    signaled,
    err,

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

    const run_result = try std.process.run(bun.default_allocator, threaded.io(), .{
        .argv = options.argv,
        .cwd = if (options.cwd.len > 0) .{ .path = options.cwd } else .inherit,
        .environ_map = if (options.envp != null) &env_map else null,
    });

    var stdout = std.array_list.Managed(u8).init(bun.default_allocator);
    var stderr = std.array_list.Managed(u8).init(bun.default_allocator);

    if (options.stdout == .buffer) {
        stdout.items = run_result.stdout;
        stdout.capacity = run_result.stdout.len;
    } else {
        defer bun.default_allocator.free(run_result.stdout);
        if (options.stdout == .inherit and run_result.stdout.len > 0) {
            try bun.Output.writer().writeAll(run_result.stdout);
            bun.Output.flush();
        }
    }

    if (options.stderr == .buffer) {
        stderr.items = run_result.stderr;
        stderr.capacity = run_result.stderr.len;
    } else {
        defer bun.default_allocator.free(run_result.stderr);
        if (options.stderr == .inherit and run_result.stderr.len > 0) {
            try bun.Output.errorWriter().writeAll(run_result.stderr);
            bun.Output.flush();
        }
    }

    const status: Status = switch (run_result.term) {
        .exited => |code| .{ .exited = .{ .code = code } },
        .signal, .stopped => .signaled,
        .unknown => .err,
    };

    return .{ .result = .{
        .status = status,
        .stdout = stdout,
        .stderr = stderr,
    } };
}
