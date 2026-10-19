const std = @import("std");
const builtin = @import("builtin");

/// Process management utilities for Home
/// Provides spawning, execution, and management of child processes
/// Process execution result
pub const ExecResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Execute a command and capture output
/// Read both pipes concurrently so a child cannot block on a full stderr
/// pipe while its parent waits for stdout to reach EOF. The caller supplies
/// an I/O implementation capable of allocating during process creation.
pub fn exec(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !ExecResult {
    if (argv.len == 0) return error.NoCommand;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    return captureChild(allocator, io, &child);
}

fn captureChild(allocator: std.mem.Allocator, io: std.Io, child: *std.process.Child) !ExecResult {
    if (child.stdout) |stdout| {
        if (child.stderr) |stderr| return captureStreams(2, allocator, io, child, .{ stdout, stderr }, 0, 1);
        return captureStreams(1, allocator, io, child, .{stdout}, 0, null);
    }
    if (child.stderr) |stderr| return captureStreams(1, allocator, io, child, .{stderr}, null, 0);

    const term = try child.wait(io);
    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try allocator.alloc(u8, 0);
    return resultFromTerm(allocator, term, stdout, stderr);
}

fn captureStreams(
    comptime count: usize,
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    files: [count]std.Io.File,
    comptime stdout_index: ?usize,
    comptime stderr_index: ?usize,
) !ExecResult {
    var reader_buffer: std.Io.File.MultiReader.Buffer(count) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, reader_buffer.toStreams(), &files);
    defer multi_reader.deinit();

    const output_limit = 10 * 1024 * 1024;
    while (multi_reader.fill(64, .none)) |_| {
        for (0..count) |index| {
            if (multi_reader.reader(index).buffered().len > output_limit)
                return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = if (stdout_index) |index| try multi_reader.toOwnedSlice(index) else try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = if (stderr_index) |index| try multi_reader.toOwnedSlice(index) else try allocator.alloc(u8, 0);
    errdefer allocator.free(stderr);

    return resultFromTerm(allocator, term, stdout, stderr);
}

fn resultFromTerm(allocator: std.mem.Allocator, term: std.process.Child.Term, stdout: []u8, stderr: []u8) ExecResult {
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .exited => |code| @intCast(code),
            else => 1,
        },
        .allocator = allocator,
    };
}

fn writeChildInput(io: std.Io, file: std.Io.File, input: []const u8) anyerror!void {
    defer file.close(io);
    try file.writeStreamingAll(io, input);
}

/// Execute a command with input
pub fn execWithInput(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, stdin_input: []const u8) !ExecResult {
    if (argv.len == 0) return error.NoCommand;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    const stdin_file = child.stdin.?;
    child.stdin = null;
    if (stdin_input.len == 0) {
        stdin_file.close(io);
        defer child.kill(io);
        return captureChild(allocator, io, &child);
    }
    var write_future = std.Io.concurrent(io, writeChildInput, .{ io, stdin_file, stdin_input }) catch |err| {
        stdin_file.close(io);
        return err;
    };
    defer {
        // On an output/read failure, terminate the child before waiting for
        // a writer that may be blocked on the child's stdin pipe.
        child.kill(io);
        _ = write_future.cancel(io) catch {};
    }

    var result = try captureChild(allocator, io, &child);
    errdefer result.deinit();
    try write_future.await(io);
    return result;
}

/// Execute a shell command (via sh -c on Unix, cmd /c on Windows)
pub fn shell(allocator: std.mem.Allocator, io: std.Io, command: []const u8) !ExecResult {
    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", command }
    else
        &[_][]const u8{ "sh", "-c", command };
    return exec(allocator, io, argv);
}

/// Spawn a process without waiting
pub const SpawnedProcess = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !SpawnedProcess {
        if (argv.len == 0) return error.NoCommand;
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        return .{
            .child = child,
            .allocator = allocator,
            .io = io,
        };
    }

    /// Wait for process to complete
    pub fn wait(self: *SpawnedProcess) !ExecResult {
        if (self.child.id == null) return error.ProcessAlreadyWaited;
        errdefer self.child.kill(self.io);
        if (self.child.stdin) |file| {
            file.close(self.io);
            self.child.stdin = null;
        }
        return captureChild(self.allocator, self.io, &self.child);
    }

    /// Kill the process
    pub fn kill(self: *SpawnedProcess) !void {
        self.child.kill(self.io);
    }

    pub fn deinit(self: *SpawnedProcess) void {
        self.child.kill(self.io);
    }

    /// Get process ID
    pub fn pid(self: *SpawnedProcess) ?std.process.Child.Id {
        return self.child.id;
    }
};

/// Process builder with configuration
pub const ProcessBuilder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: std.ArrayList([]const u8),
    env_map: std.process.Environ.Map,
    cwd: ?[]const u8,
    stdin_behavior: std.process.SpawnOptions.StdIo,
    stdout_behavior: std.process.SpawnOptions.StdIo,
    stderr_behavior: std.process.SpawnOptions.StdIo,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ProcessBuilder {
        return .{
            .allocator = allocator,
            .io = io,
            .argv = .empty,
            .env_map = std.process.Environ.Map.init(allocator),
            .cwd = null,
            .stdin_behavior = .inherit,
            .stdout_behavior = .pipe,
            .stderr_behavior = .pipe,
        };
    }

    pub fn deinit(self: *ProcessBuilder) void {
        self.argv.deinit(self.allocator);
        self.env_map.deinit();
    }

    /// Set command to execute
    pub fn command(self: *ProcessBuilder, cmd: []const u8) !*ProcessBuilder {
        try self.argv.append(self.allocator, cmd);
        return self;
    }

    /// Add argument
    pub fn arg(self: *ProcessBuilder, argument: []const u8) !*ProcessBuilder {
        try self.argv.append(self.allocator, argument);
        return self;
    }

    /// Add multiple arguments
    pub fn args(self: *ProcessBuilder, arguments: []const []const u8) !*ProcessBuilder {
        for (arguments) |argument| {
            try self.argv.append(self.allocator, argument);
        }
        return self;
    }

    /// Set environment variable
    pub fn env(self: *ProcessBuilder, key: []const u8, value: []const u8) !*ProcessBuilder {
        try self.env_map.put(key, value);
        return self;
    }

    /// Set working directory
    pub fn currentDir(self: *ProcessBuilder, dir: []const u8) !*ProcessBuilder {
        self.cwd = dir;
        return self;
    }

    /// Set stdin behavior
    pub fn stdin(self: *ProcessBuilder, behavior: std.process.SpawnOptions.StdIo) *ProcessBuilder {
        self.stdin_behavior = behavior;
        return self;
    }

    /// Set stdout behavior
    pub fn stdout(self: *ProcessBuilder, behavior: std.process.SpawnOptions.StdIo) *ProcessBuilder {
        self.stdout_behavior = behavior;
        return self;
    }

    /// Set stderr behavior
    pub fn stderr(self: *ProcessBuilder, behavior: std.process.SpawnOptions.StdIo) *ProcessBuilder {
        self.stderr_behavior = behavior;
        return self;
    }

    /// Spawn the process
    pub fn spawn(self: *ProcessBuilder) !SpawnedProcess {
        if (self.argv.items.len == 0) return error.NoCommand;

        const child = try std.process.spawn(self.io, .{
            .argv = self.argv.items,
            .cwd = if (self.cwd) |dir| .{ .path = dir } else .inherit,
            .environ_map = if (self.env_map.count() > 0) &self.env_map else null,
            .stdin = self.stdin_behavior,
            .stdout = self.stdout_behavior,
            .stderr = self.stderr_behavior,
        });

        return .{
            .child = child,
            .allocator = self.allocator,
            .io = self.io,
        };
    }

    /// Execute and wait for completion
    pub fn run(self: *ProcessBuilder) !ExecResult {
        var spawned = try self.spawn();
        defer spawned.deinit();
        return spawned.wait();
    }
};

/// Get current process ID
pub fn currentPid() std.process.Child.Id {
    if (builtin.os.tag == .windows) {
        return std.os.windows.kernel32.GetCurrentProcessId();
    } else if (builtin.os.tag == .linux) {
        return std.os.linux.getpid();
    } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd) {
        return std.c.getpid();
    } else {
        @compileError("currentPid() not supported on this platform");
    }
}

/// Get parent process ID
pub fn parentPid() std.process.Child.Id {
    if (builtin.os.tag == .windows) {
        // On Windows, we need to use Process Status API or NtQueryInformationProcess
        // For now, return 0 as a placeholder - full implementation would require WinAPI calls
        // This would typically use CreateToolhelp32Snapshot or NtQueryInformationProcess
        return 0;
    } else if (builtin.os.tag == .linux) {
        return std.os.linux.getppid();
    } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd) {
        return std.c.getppid();
    } else {
        @compileError("parentPid() not supported on this platform");
    }
}

/// Exit current process with code
pub fn exit(code: u8) noreturn {
    std.process.exit(code);
}

/// Read a value from the caller's process-environment snapshot.
/// The caller owns the returned copy.
pub fn getEnv(allocator: std.mem.Allocator, environ: std.process.Environ, key: []const u8) !?[]u8 {
    return environ.getAlloc(allocator, key) catch |err| {
        if (err == error.EnvironmentVariableMissing) return null;
        return err;
    };
}

/// Set a value in an explicitly owned environment map, for child processes.
pub fn setEnv(map: *std.process.Environ.Map, key: []const u8, value: []const u8) !void {
    if (!std.process.Environ.Map.validateKeyForPut(key)) return error.InvalidEnvironmentVariableName;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvironmentVariableValue;
    try map.put(key, value);
}

/// Remove a value from an explicitly owned environment map.
pub fn unsetEnv(map: *std.process.Environ.Map, key: []const u8) bool {
    return map.swapRemove(key);
}

/// Copy the caller's process-environment snapshot into an owned map.
pub fn getEnvMap(allocator: std.mem.Allocator, environ: std.process.Environ) !std.process.Environ.Map {
    return environ.createMap(allocator);
}

/// Get current working directory
pub fn getCwd(allocator: std.mem.Allocator, io: std.Io) ![:0]u8 {
    return std.process.currentPathAlloc(io, allocator);
}

/// Change current working directory
pub fn setCwd(io: std.Io, dir: []const u8) !void {
    try std.process.setCurrentPath(io, dir);
}

/// Copy command-line arguments from the caller's process-init snapshot.
pub fn getArgs(allocator: std.mem.Allocator, process_args: std.process.Args) ![][]u8 {
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    var iter = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer iter.deinit();

    while (iter.next()) |arg| {
        const copy = try allocator.dupe(u8, arg);
        args.append(allocator, copy) catch |err| {
            allocator.free(copy);
            return err;
        };
    }

    return args.toOwnedSlice(allocator);
}

/// Check if a command exists in PATH
pub fn commandExists(allocator: std.mem.Allocator, io: std.Io, command: []const u8) bool {
    // On Windows use "where", on Unix use "which"
    const check_cmd = if (builtin.os.tag == .windows) "where" else "which";
    const result = exec(allocator, io, &[_][]const u8{ check_cmd, command }) catch return false;
    defer {
        var mut_result = result;
        mut_result.deinit();
    }
    return result.exit_code == 0;
}

/// Pipe: connect stdout of one process to stdin of another
pub const Pipe = struct {
    commands: std.ArrayList([]const []const u8),
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Pipe {
        return .{
            .commands = .empty,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Pipe) void {
        self.commands.deinit(self.allocator);
    }

    /// Add a process to the pipe chain
    pub fn add(self: *Pipe, argv: []const []const u8) !void {
        if (argv.len == 0) return error.NoCommand;
        try self.commands.append(self.allocator, argv);
    }

    /// Execute the pipe chain
    pub fn run(self: *Pipe) !ExecResult {
        if (self.commands.items.len == 0) return error.NoPipeline;

        var children: std.ArrayList(std.process.Child) = .empty;
        defer {
            for (children.items) |*child| child.kill(self.io);
            children.deinit(self.allocator);
        }

        for (self.commands.items) |argv| {
            const previous_stdout = if (children.items.len > 0) children.items[children.items.len - 1].stdout else null;
            var child = try std.process.spawn(self.io, .{
                .argv = argv,
                .stdin = if (previous_stdout) |file| .{ .file = file } else .inherit,
                .stdout = .pipe,
                .stderr = .inherit,
            });
            children.append(self.allocator, child) catch |err| {
                child.kill(self.io);
                return err;
            };
            if (previous_stdout) |file| {
                file.close(self.io);
                children.items[children.items.len - 2].stdout = null;
            }
        }

        var result = try captureChild(self.allocator, self.io, &children.items[children.items.len - 1]);
        errdefer result.deinit();
        for (children.items[0 .. children.items.len - 1]) |*child| {
            _ = try child.wait(self.io);
        }
        return result;
    }
};

/// Process signals (Unix-like systems)
/// Note: On Windows, only a subset of signals are supported via limited emulation
pub const Signal = enum(u32) {
    SIGTERM = if (builtin.os.tag == .windows) 15 else @backingInt(std.posix.SIG.TERM),
    SIGKILL = if (builtin.os.tag == .windows) 9 else @backingInt(std.posix.SIG.KILL),
    SIGINT = if (builtin.os.tag == .windows) 2 else @backingInt(std.posix.SIG.INT),
    SIGHUP = if (builtin.os.tag == .windows) 1 else @backingInt(std.posix.SIG.HUP),
    SIGQUIT = if (builtin.os.tag == .windows) 3 else @backingInt(std.posix.SIG.QUIT),
    SIGUSR1 = if (builtin.os.tag == .windows) 10 else @backingInt(std.posix.SIG.USR1),
    SIGUSR2 = if (builtin.os.tag == .windows) 12 else @backingInt(std.posix.SIG.USR2),

    /// Send signal to process
    /// On Windows, this will attempt to terminate the process (SIGTERM/SIGKILL only)
    pub fn send(self: Signal, process_id: std.process.Child.Id) !void {
        if (builtin.os.tag == .windows) {
            if (self != .SIGTERM and self != .SIGKILL) return error.UnsupportedSignal;
            // Child.Id is a process HANDLE on Windows, not a numeric PID.
            // The caller retains ownership so it can still wait and reap.
            const exit_code: u32 = if (self == .SIGKILL) 1 else 0;
            return switch (std.os.windows.ntdll.NtTerminateProcess(process_id, @fromBackingInt(exit_code))) {
                .SUCCESS, .PROCESS_IS_TERMINATING => {},
                else => error.TerminateProcessFailed,
            };
        } else {
            if (process_id <= 0) return error.InvalidProcessId;
            try std.posix.kill(process_id, @fromBackingInt(@intCast(@backingInt(self))));
        }
    }
};

/// Check if process is running
pub fn isRunning(process_id: std.process.Child.Id) bool {
    if (builtin.os.tag == .windows) {
        const zero_timeout: std.os.windows.LARGE_INTEGER = 0;
        return std.os.windows.ntdll.NtWaitForSingleObject(process_id, .FALSE, &zero_timeout) == .TIMEOUT;
    } else {
        if (process_id <= 0) return false;
        std.posix.kill(process_id, @fromBackingInt(0)) catch |err| return switch (err) {
            error.PermissionDenied => true,
            else => false,
        };
        return true;
    }
}

/// Wait for a specific duration
pub fn sleep(io: std.Io, milliseconds: u64) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromNanoseconds(@as(i96, milliseconds) * std.time.ns_per_ms), .awake);
}
