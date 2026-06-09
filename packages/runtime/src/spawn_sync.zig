// Minimal `bun.spawnSync` (upstream `bun.spawn.sync.spawn`, a thin synchronous
// process-spawn-and-capture). Bun's full implementation
// (src/runtime/api/bun/process.zig `pub const sync`) drags the whole Process /
// SpawnOptions / Windows-uv-pipe machinery; Home doesn't have that substrate
// yet, and the forked std uses a reworked `std.Io`-based `std.process.Child`.
//
// The ONLY current caller is `ChangedFilesFilter` (`bun test --changed`), which
// is imported unconditionally by `test_command.zig` but only invoked for
// `--changed`. So this provides the faithful Options/Result/Status TYPES (so the
// call site + `switch (proc) { .err, .result }` compile) and a spawn() that
// returns `error.SpawnSyncUnsupported` — the caller's `catch` degrades to a
// graceful "spawn failed" (so `--changed` reports cleanly instead of crashing),
// and every other test path is unaffected. Replace spawn()'s body with a real
// std.process.Child (Io) implementation to enable `--changed` natively.

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
    _ = options;
    // `bun test --changed` is the only caller; not yet wired to the forked
    // std.Io process API. The caller's `catch` handles this gracefully.
    return error.SpawnSyncUnsupported;
}
