const std = @import("std");
const builtin = @import("builtin");

/// Process management utilities for Ion
/// Provides spawning, execution, and management of child processes

/// Process execution result
pub const ExecResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Execute a command and capture output
pub fn exec(allocator: std.mem.Allocator, argv: []const []const u8) !ExecResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stdout);

    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stderr);

    const term = try child.wait();

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .Exited => |code| @intCast(code),
            else => 1,
        },
        .allocator = allocator,
    };
}

/// Execute a command with input
pub fn execWithInput(allocator: std.mem.Allocator, argv: []const []const u8, stdin_input: []const u8) !ExecResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Write to stdin
    try child.stdin.?.writeAll(stdin_input);
    child.stdin.?.close();
    child.stdin = null;

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stdout);

    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stderr);

    const term = try child.wait();

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .Exited => |code| @intCast(code),
            else => 1,
        },
        .allocator = allocator,
    };
}

/// Execute a shell command (via sh -c on Unix, cmd /c on Windows)
pub fn shell(allocator: std.mem.Allocator, command: []const u8) !ExecResult {
    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", command }
    else
        &[_][]const u8{ "sh", "-c", command };
    return exec(allocator, argv);
}

/// Spawn a process without waiting
pub const SpawnedProcess = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, argv: []const []const u8) !SpawnedProcess {
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        return .{
            .child = child,
            .allocator = allocator,
        };
    }

    /// Wait for process to complete
    pub fn wait(self: *SpawnedProcess) !ExecResult {
        const stdout = try self.child.stdout.?.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024);
        errdefer self.allocator.free(stdout);

        const stderr = try self.child.stderr.?.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024);
        errdefer self.allocator.free(stderr);

        const term = try self.child.wait();

        return .{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = switch (term) {
                .Exited => |code| @intCast(code),
                else => 1,
            },
            .allocator = self.allocator,
        };
    }

    /// Kill the process
    pub fn kill(self: *SpawnedProcess) !void {
        try self.child.kill();
    }

    /// Get process ID
    pub fn pid(self: *SpawnedProcess) std.process.Child.Id {
        return self.child.id;
    }
};

/// Process builder with configuration
pub const ProcessBuilder = struct {
    allocator: std.mem.Allocator,
    argv: std.ArrayList([]const u8),
    env_map: std.process.EnvMap,
    cwd: ?[]const u8,
    stdin_behavior: std.process.Child.StdIo,
    stdout_behavior: std.process.Child.StdIo,
    stderr_behavior: std.process.Child.StdIo,

    pub fn init(allocator: std.mem.Allocator) ProcessBuilder {
        return .{
            .allocator = allocator,
            .argv = std.ArrayList([]const u8).init(allocator),
            .env_map = std.process.EnvMap.init(allocator),
            .cwd = null,
            .stdin_behavior = .Inherit,
            .stdout_behavior = .Pipe,
            .stderr_behavior = .Pipe,
        };
    }

    pub fn deinit(self: *ProcessBuilder) void {
        self.argv.deinit();
        self.env_map.deinit();
    }

    /// Set command to execute
    pub fn command(self: *ProcessBuilder, cmd: []const u8) !*ProcessBuilder {
        try self.argv.append(cmd);
        return self;
    }

    /// Add argument
    pub fn arg(self: *ProcessBuilder, argument: []const u8) !*ProcessBuilder {
        try self.argv.append(argument);
        return self;
    }

    /// Add multiple arguments
    pub fn args(self: *ProcessBuilder, arguments: []const []const u8) !*ProcessBuilder {
        for (arguments) |argument| {
            try self.argv.append(argument);
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
    pub fn stdin(self: *ProcessBuilder, behavior: std.process.Child.StdIo) *ProcessBuilder {
        self.stdin_behavior = behavior;
        return self;
    }

    /// Set stdout behavior
    pub fn stdout(self: *ProcessBuilder, behavior: std.process.Child.StdIo) *ProcessBuilder {
        self.stdout_behavior = behavior;
        return self;
    }

    /// Set stderr behavior
    pub fn stderr(self: *ProcessBuilder, behavior: std.process.Child.StdIo) *ProcessBuilder {
        self.stderr_behavior = behavior;
        return self;
    }

    /// Spawn the process
    pub fn spawn(self: *ProcessBuilder) !SpawnedProcess {
        if (self.argv.items.len == 0) return error.NoCommand;

        var child = std.process.Child.init(self.argv.items, self.allocator);
        child.stdin_behavior = self.stdin_behavior;
        child.stdout_behavior = self.stdout_behavior;
        child.stderr_behavior = self.stderr_behavior;

        if (self.cwd) |dir| {
            child.cwd = dir;
        }

        // Set environment variables
        if (self.env_map.count() > 0) {
            child.env_map = &self.env_map;
        }

        try child.spawn();

        return .{
            .child = child,
            .allocator = self.allocator,
        };
    }

    /// Execute and wait for completion
    pub fn run(self: *ProcessBuilder) !ExecResult {
        var spawned = try self.spawn();
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

/// Get environment variable
pub fn getEnv(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| {
        if (err == error.EnvironmentVariableNotFound) return null;
        return err;
    };
}

/// Set environment variable
pub fn setEnv(key: []const u8, value: []const u8) !void {
    try std.process.setEnvVar(key, value);
}

/// Unset environment variable
pub fn unsetEnv(key: []const u8) !void {
    try std.process.unsetEnvVar(key);
}

/// Get all environment variables
pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.EnvMap {
    return try std.process.getEnvMap(allocator);
}

/// Get current working directory
pub fn getCwd(allocator: std.mem.Allocator) ![]u8 {
    return try std.process.getCwdAlloc(allocator);
}

/// Change current working directory
pub fn setCwd(dir: []const u8) !void {
    try std.process.changeCurDir(dir);
}

/// Get command line arguments
pub fn getArgs(allocator: std.mem.Allocator) ![][]u8 {
    var args = std.ArrayList([]u8).init(allocator);

    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();

    while (iter.next()) |arg| {
        try args.append(try allocator.dupe(u8, arg));
    }

    return args.toOwnedSlice();
}

/// Check if a command exists in PATH
pub fn commandExists(allocator: std.mem.Allocator, command: []const u8) bool {
    // On Windows use "where", on Unix use "which"
    const check_cmd = if (builtin.os.tag == .windows) "where" else "which";
    const result = exec(allocator, &[_][]const u8{ check_cmd, command }) catch return false;
    defer {
        var mut_result = result;
        mut_result.deinit();
    }
    return result.exit_code == 0;
}

/// Pipe: connect stdout of one process to stdin of another
pub const Pipe = struct {
    processes: std.ArrayList(std.process.Child),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Pipe {
        return .{
            .processes = std.ArrayList(std.process.Child).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pipe) void {
        self.processes.deinit();
    }

    /// Add a process to the pipe chain
    pub fn add(self: *Pipe, argv: []const []const u8) !void {
        var child = std.process.Child.init(argv, self.allocator);

        if (self.processes.items.len > 0) {
            // Connect previous stdout to current stdin
            child.stdin_behavior = .Pipe;
        }

        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try self.processes.append(child);
    }

    /// Execute the pipe chain
    pub fn run(self: *Pipe) !ExecResult {
        if (self.processes.items.len == 0) return error.NoPipeline;

        // Spawn all processes
        for (self.processes.items, 0..) |*proc, i| {
            try proc.spawn();

            // Connect pipes
            if (i > 0) {
                const prev = &self.processes.items[i - 1];
                if (prev.stdout) |stdout| {
                    _ = try std.io.copy(proc.stdin.?, stdout.reader());
                    proc.stdin.?.close();
                    proc.stdin = null;
                }
            }
        }

        // Get output from last process
        const last = &self.processes.items[self.processes.items.len - 1];
        const stdout = try last.stdout.?.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024);

        // Wait for all processes
        for (self.processes.items) |*proc| {
            _ = try proc.wait();
        }

        return .{
            .stdout = stdout,
            .stderr = &[_]u8{},
            .exit_code = 0,
            .allocator = self.allocator,
        };
    }
};

/// Process signals (Unix-like systems)
/// Note: On Windows, only a subset of signals are supported via limited emulation
pub const Signal = enum(u32) {
    SIGTERM = 15,
    SIGKILL = 9,
    SIGINT = 2,
    SIGHUP = 1,
    SIGQUIT = 3,
    SIGUSR1 = 10,
    SIGUSR2 = 12,

    /// Send signal to process
    /// On Windows, this will attempt to terminate the process (SIGTERM/SIGKILL only)
    pub fn send(self: Signal, process_id: std.process.Child.Id) !void {
        if (builtin.os.tag == .windows) {
            // Windows doesn't support POSIX signals
            // SIGTERM and SIGKILL will terminate the process
            if (self == .SIGTERM or self == .SIGKILL) {
                const handle = std.os.windows.kernel32.OpenProcess(
                    std.os.windows.PROCESS_TERMINATE,
                    std.os.windows.FALSE,
                    process_id,
                );
                if (handle == null) return error.OpenProcessFailed;
                defer std.os.windows.CloseHandle(handle.?);

                const exit_code: u32 = if (self == .SIGKILL) 1 else 0;
                if (std.os.windows.kernel32.TerminateProcess(handle.?, exit_code) == 0) {
                    return error.TerminateProcessFailed;
                }
            } else {
                // Other signals not supported on Windows
                return error.UnsupportedSignal;
            }
        } else {
            _ = try std.os.kill(process_id, @intFromEnum(self));
        }
    }
};

/// Check if process is running
pub fn isRunning(process_id: std.process.Child.Id) bool {
    if (builtin.os.tag == .windows) {
        // On Windows, try to open the process handle
        const handle = std.os.windows.kernel32.OpenProcess(
            std.os.windows.PROCESS_QUERY_INFORMATION,
            std.os.windows.FALSE,
            process_id,
        );
        if (handle == null) return false;
        defer std.os.windows.CloseHandle(handle.?);

        // Check if process has exited
        var exit_code: u32 = undefined;
        if (std.os.windows.kernel32.GetExitCodeProcess(handle.?, &exit_code) == 0) {
            return false;
        }
        // STILL_ACTIVE = 259
        return exit_code == 259;
    } else {
        // Try to send signal 0 (null signal) to check if process exists
        std.os.kill(process_id, 0) catch return false;
        return true;
    }
}

/// Wait for a specific duration
pub fn sleep(milliseconds: u64) void {
    std.time.sleep(milliseconds * std.time.ns_per_ms);
}
