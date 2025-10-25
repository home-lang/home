// Home Programming Language - System Call Handler Implementations
// Actual implementations of POSIX syscalls

const Basics = @import("basics");
const syscall = @import("syscall.zig");
const process = @import("process.zig");
const thread = @import("thread.zig");
const vfs = @import("../fs/src/vfs.zig");
const signal = @import("signal.zig");
const pipe = @import("pipe.zig");

// ============================================================================
// Error Handling
// ============================================================================

/// Convert Zig error to errno
fn errorToErrno(err: anyerror) u64 {
    return switch (err) {
        error.OutOfMemory => 12, // ENOMEM
        error.AccessDenied => 13, // EACCES
        error.InvalidArgument => 22, // EINVAL
        error.FileNotFound => 2, // ENOENT
        error.NotADirectory => 20, // ENOTDIR
        error.IsDirectory => 21, // EISDIR
        error.NotEmpty => 39, // ENOTEMPTY
        error.FileExists => 17, // EEXIST
        error.NoSpaceLeft => 28, // ENOSPC
        error.ReadOnlyFileSystem => 30, // EROFS
        error.BrokenPipe => 32, // EPIPE
        error.WouldBlock => 11, // EAGAIN/EWOULDBLOCK
        else => 5, // EIO (generic I/O error)
    };
}

/// Return error as negative errno
fn returnError(err: anyerror) u64 {
    return @as(u64, @bitCast(-@as(i64, @intCast(errorToErrno(err)))));
}

// ============================================================================
// Process Management Syscalls
// ============================================================================

export fn sys_getpid(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);
    return current.pid;
}

export fn sys_getppid(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);
    return current.parent_pid orelse 0;
}

export fn sys_getuid(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);
    return current.uid;
}

export fn sys_getgid(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);
    return current.gid;
}

export fn sys_geteuid(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);
    return current.euid;
}

export fn sys_getegid(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);
    return current.egid;
}

export fn sys_exit(args: syscall.SyscallArgs) callconv(.C) u64 {
    const exit_code = @as(i32, @truncate(@as(i64, @bitCast(args.arg1))));
    process.exitCurrentProcess(exit_code);
    unreachable; // Should never return
}

export fn sys_fork(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    const child_pid = process.forkCurrentProcess() catch |err| {
        return returnError(err);
    };
    return child_pid;
}

export fn sys_wait4(args: syscall.SyscallArgs) callconv(.C) u64 {
    const pid = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));
    const wstatus_ptr = args.arg2;
    const options = @as(i32, @bitCast(@as(u32, @truncate(args.arg3))));
    _ = options; // TODO: Use options

    const result = process.waitForProcess(pid) catch |err| {
        return returnError(err);
    };

    // Write status if pointer provided
    if (wstatus_ptr != 0) {
        const status_ptr: *i32 = @ptrFromInt(wstatus_ptr);
        status_ptr.* = result.status;
    }

    return @as(u64, @intCast(result.pid));
}

export fn sys_kill(args: syscall.SyscallArgs) callconv(.C) u64 {
    const pid = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));
    const sig = @as(i32, @bitCast(@as(u32, @truncate(args.arg2))));

    signal.sendSignal(pid, sig) catch |err| {
        return returnError(err);
    };

    return 0;
}

export fn sys_sched_yield(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    thread.yield();
    return 0;
}

// ============================================================================
// File I/O Syscalls
// ============================================================================

export fn sys_read(args: syscall.SyscallArgs) callconv(.C) u64 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));
    const buf_ptr = args.arg2;
    const count = args.arg3;

    if (buf_ptr == 0) return returnError(error.InvalidArgument);

    const buffer: [*]u8 = @ptrFromInt(buf_ptr);
    const slice = buffer[0..count];

    const bytes_read = vfs.read(fd, slice) catch |err| {
        return returnError(err);
    };

    return bytes_read;
}

export fn sys_write(args: syscall.SyscallArgs) callconv(.C) u64 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));
    const buf_ptr = args.arg2;
    const count = args.arg3;

    if (buf_ptr == 0) return returnError(error.InvalidArgument);

    const buffer: [*]const u8 = @ptrFromInt(buf_ptr);
    const slice = buffer[0..count];

    const bytes_written = vfs.write(fd, slice) catch |err| {
        return returnError(err);
    };

    return bytes_written;
}

export fn sys_open(args: syscall.SyscallArgs) callconv(.C) u64 {
    const pathname_ptr = args.arg1;
    const flags = @as(i32, @bitCast(@as(u32, @truncate(args.arg2))));
    const mode = @as(u32, @truncate(args.arg3));

    if (pathname_ptr == 0) return returnError(error.InvalidArgument);

    // TODO: Properly parse null-terminated string from userspace
    const pathname: [*:0]const u8 = @ptrFromInt(pathname_ptr);
    const path_slice = Basics.mem.sliceTo(pathname, 0);

    const fd = vfs.open(path_slice, flags, mode) catch |err| {
        return returnError(err);
    };

    return @as(u64, @bitCast(@as(i64, fd)));
}

export fn sys_close(args: syscall.SyscallArgs) callconv(.C) u64 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));

    vfs.close(fd) catch |err| {
        return returnError(err);
    };

    return 0;
}

export fn sys_lseek(args: syscall.SyscallArgs) callconv(.C) u64 {
    const fd = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));
    const offset = @as(i64, @bitCast(args.arg2));
    const whence = @as(i32, @bitCast(@as(u32, @truncate(args.arg3))));

    const new_offset = vfs.lseek(fd, offset, whence) catch |err| {
        return returnError(err);
    };

    return @as(u64, @bitCast(new_offset));
}

// ============================================================================
// Memory Management Syscalls
// ============================================================================

export fn sys_brk(args: syscall.SyscallArgs) callconv(.C) u64 {
    const addr = args.arg1;

    const new_brk = process.setBrk(addr) catch |err| {
        return returnError(err);
    };

    return new_brk;
}

export fn sys_mmap(args: syscall.SyscallArgs) callconv(.C) u64 {
    const addr = args.arg1;
    const length = args.arg2;
    const prot = @as(i32, @bitCast(@as(u32, @truncate(args.arg3))));
    const flags = @as(i32, @bitCast(@as(u32, @truncate(args.arg4))));
    const fd = @as(i32, @bitCast(@as(u32, @truncate(args.arg5))));
    const offset = args.arg6;

    const mapped_addr = process.mmap(addr, length, prot, flags, fd, offset) catch |err| {
        return returnError(err);
    };

    return mapped_addr;
}

export fn sys_munmap(args: syscall.SyscallArgs) callconv(.C) u64 {
    const addr = args.arg1;
    const length = args.arg2;

    process.munmap(addr, length) catch |err| {
        return returnError(err);
    };

    return 0;
}

export fn sys_mprotect(args: syscall.SyscallArgs) callconv(.C) u64 {
    const addr = args.arg1;
    const length = args.arg2;
    const prot = @as(i32, @bitCast(@as(u32, @truncate(args.arg3))));

    process.mprotect(addr, length, prot) catch |err| {
        return returnError(err);
    };

    return 0;
}

// ============================================================================
// IPC Syscalls
// ============================================================================

export fn sys_pipe(args: syscall.SyscallArgs) callconv(.C) u64 {
    const pipefd_ptr = args.arg1;

    if (pipefd_ptr == 0) return returnError(error.InvalidArgument);

    const pipefd: *[2]i32 = @ptrFromInt(pipefd_ptr);

    const fds = pipe.createPipe() catch |err| {
        return returnError(err);
    };

    pipefd[0] = fds[0];
    pipefd[1] = fds[1];

    return 0;
}

export fn sys_pipe2(args: syscall.SyscallArgs) callconv(.C) u64 {
    const pipefd_ptr = args.arg1;
    const flags = @as(i32, @bitCast(@as(u32, @truncate(args.arg2))));

    if (pipefd_ptr == 0) return returnError(error.InvalidArgument);

    const pipefd: *[2]i32 = @ptrFromInt(pipefd_ptr);

    const fds = pipe.createPipe2(flags) catch |err| {
        return returnError(err);
    };

    pipefd[0] = fds[0];
    pipefd[1] = fds[1];

    return 0;
}

// ============================================================================
// Signal Syscalls
// ============================================================================

export fn sys_rt_sigaction(args: syscall.SyscallArgs) callconv(.C) u64 {
    const sig = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));
    const act_ptr = args.arg2;
    const oldact_ptr = args.arg3;

    signal.sigaction(sig, act_ptr, oldact_ptr) catch |err| {
        return returnError(err);
    };

    return 0;
}

export fn sys_rt_sigprocmask(args: syscall.SyscallArgs) callconv(.C) u64 {
    const how = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));
    const set_ptr = args.arg2;
    const oldset_ptr = args.arg3;

    signal.sigprocmask(how, set_ptr, oldset_ptr) catch |err| {
        return returnError(err);
    };

    return 0;
}

// ============================================================================
// Time Syscalls
// ============================================================================

export fn sys_nanosleep(args: syscall.SyscallArgs) callconv(.C) u64 {
    const req_ptr = args.arg1;
    const rem_ptr = args.arg2;

    if (req_ptr == 0) return returnError(error.InvalidArgument);

    // TODO: Implement actual sleep
    _ = rem_ptr;

    return 0;
}

// ============================================================================
// Syscall Registration
// ============================================================================

pub fn registerAllSyscalls(table: *syscall.SyscallTable) void {
    // Process management
    table.register(.Getpid, sys_getpid);
    table.register(.Getppid, sys_getppid);
    table.register(.Getuid, sys_getuid);
    table.register(.Getgid, sys_getgid);
    table.register(.Geteuid, sys_geteuid);
    table.register(.Getegid, sys_getegid);
    table.register(.Exit, sys_exit);
    table.register(.Fork, sys_fork);
    table.register(.Wait4, sys_wait4);
    table.register(.Kill, sys_kill);
    table.register(.Sched_yield, sys_sched_yield);

    // File I/O
    table.register(.Read, sys_read);
    table.register(.Write, sys_write);
    table.register(.Open, sys_open);
    table.register(.Close, sys_close);
    table.register(.Lseek, sys_lseek);

    // Memory management
    table.register(.Brk, sys_brk);
    table.register(.Mmap, sys_mmap);
    table.register(.Munmap, sys_munmap);
    table.register(.Mprotect, sys_mprotect);

    // IPC
    table.register(.Pipe, sys_pipe);
    table.register(.Pipe2, sys_pipe2);

    // Signals
    table.register(.RtSigaction, sys_rt_sigaction);
    table.register(.RtSigprocmask, sys_rt_sigprocmask);

    // Time
    table.register(.Nanosleep, sys_nanosleep);
}
