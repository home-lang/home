// Home Programming Language - System Call Handler Implementations
// Actual implementations of POSIX syscalls

const Basics = @import("basics");
const syscall = @import("syscall.zig");
const process = @import("process.zig");
const thread = @import("thread.zig");
const vfs = @import("../fs/src/vfs.zig");
const signal = @import("signal.zig");
const pipe = @import("pipe.zig");
const vmm = @import("vmm.zig");
const capabilities = @import("capabilities.zig");
const limits = @import("limits.zig");
const namespaces = @import("namespaces.zig");
const audit = @import("audit.zig");

// ============================================================================
// Error Handling
// ============================================================================

/// Validate and return file descriptor entry
fn validateFd(fd: i32) !void {
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    // Check bounds
    if (fd < 0 or fd >= 256) {
        return error.BadFileDescriptor;
    }

    // Lock FD table
    current.fd_lock.acquire();
    defer current.fd_lock.release();

    // Check if FD exists
    const fd_entry = current.fd_table[@intCast(fd)] orelse {
        return error.BadFileDescriptor;
    };

    // FD is valid
    _ = fd_entry;
}

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

export fn sys_setuid(args: syscall.SyscallArgs) callconv(.C) u64 {
    const uid = @as(u32, @truncate(args.arg1));
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);

    current.lock.acquire();
    defer current.lock.release();

    // Process with CAP_SETUID can set to any UID
    if (capabilities.canSetUid()) {
        current.uid = uid;
        current.euid = uid;
        current.saved_uid = uid;
        current.fsuid = uid;
        return 0;
    }

    // Without CAP_SETUID, can only set to real, effective, or saved UID
    if (uid == current.uid or uid == current.euid or uid == current.saved_uid) {
        current.euid = uid;
        current.fsuid = uid;
        return 0;
    }

    return returnError(error.AccessDenied);
}

export fn sys_setgid(args: syscall.SyscallArgs) callconv(.C) u64 {
    const gid = @as(u32, @truncate(args.arg1));
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);

    current.lock.acquire();
    defer current.lock.release();

    // Process with CAP_SETGID can set to any GID
    if (capabilities.canSetGid()) {
        current.gid = gid;
        current.egid = gid;
        current.saved_gid = gid;
        current.fsgid = gid;
        return 0;
    }

    // Without CAP_SETGID, can only set to real, effective, or saved GID
    if (gid == current.gid or gid == current.egid or gid == current.saved_gid) {
        current.egid = gid;
        current.fsgid = gid;
        return 0;
    }

    return returnError(error.AccessDenied);
}

export fn sys_seteuid(args: syscall.SyscallArgs) callconv(.C) u64 {
    const euid = @as(u32, @truncate(args.arg1));
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);

    current.lock.acquire();
    defer current.lock.release();

    // Root can set to any effective UID
    if (current.euid == 0) {
        current.euid = euid;
        current.fsuid = euid;
        return 0;
    }

    // Non-root can only set to real, effective, or saved UID
    if (euid == current.uid or euid == current.euid or euid == current.saved_uid) {
        current.euid = euid;
        current.fsuid = euid;
        return 0;
    }

    return returnError(error.AccessDenied);
}

export fn sys_setegid(args: syscall.SyscallArgs) callconv(.C) u64 {
    const egid = @as(u32, @truncate(args.arg1));
    const current = process.getCurrentProcess() orelse return returnError(error.InvalidArgument);

    current.lock.acquire();
    defer current.lock.release();

    // Root can set to any effective GID
    if (current.euid == 0) {
        current.egid = egid;
        current.fsgid = egid;
        return 0;
    }

    // Non-root can only set to real, effective, or saved GID
    if (egid == current.gid or egid == current.egid or egid == current.saved_gid) {
        current.egid = egid;
        current.fsgid = egid;
        return 0;
    }

    return returnError(error.AccessDenied);
}

export fn sys_exit(args: syscall.SyscallArgs) callconv(.C) u64 {
    const exit_code = @as(i32, @truncate(@as(i64, @bitCast(args.arg1))));
    process.exitCurrentProcess(exit_code);
    unreachable; // Should never return
}

export fn sys_fork(args: syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;

    // Check resource limits (fork bomb prevention)
    limits.checkCanFork() catch |err| {
        return returnError(err);
    };

    // Check fork rate limit
    limits.checkForkRateLimit() catch |err| {
        return returnError(err);
    };

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

    // Validate status pointer if provided
    if (wstatus_ptr != 0) {
        vmm.validateUserPointer(wstatus_ptr, @sizeOf(i32), true) catch |err| {
            return returnError(err);
        };
    }

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
    const sig_num = @as(i32, @bitCast(@as(u32, @truncate(args.arg2))));

    // Validate signal number
    if (sig_num < 1 or sig_num > signal.MAX_SIGNALS) {
        return returnError(error.InvalidArgument);
    }

    const sig: signal.Signal = @enumFromInt(@as(u8, @intCast(sig_num)));
    const current = process.getCurrentProcess() orelse return returnError(error.NoProcess);

    // Acquire process table lock for atomicity
    process.process_table_lock.acquire();
    defer process.process_table_lock.release();

    // Find target process (this must happen while holding the lock)
    const target = process.findProcessById(pid) catch |err| {
        return returnError(err);
    };

    // Check if process is still alive (prevent race condition)
    if (target.state == .Dead or target.state == .Zombie) {
        return returnError(error.NoSuchProcess);
    }

    // Check signal permission (root can signal anyone)
    if (current.euid != 0) {
        // Non-root can only signal processes with same uid/euid
        if (target.uid != current.euid and target.euid != current.euid) {
            return returnError(error.AccessDenied);
        }
    }

    // Create signal info
    const sig_info = signal.SigInfo{
        .signal = sig,
        .code = 0, // SI_USER
        .errno = 0,
        .pid = @intCast(current.pid),
        .uid = current.uid,
        .addr = null,
        .value = 0,
    };

    // Send signal (process lock is held, safe from race)
    signal.sendSignal(target, sig, sig_info) catch |err| {
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

    // Validate file descriptor
    validateFd(fd) catch |err| {
        return returnError(err);
    };

    // Validate buffer size
    if (count > vmm.MAX_READ_SIZE) {
        return returnError(error.InvalidArgument);
    }

    // Validate user pointer
    vmm.validateUserPointer(buf_ptr, count, true) catch |err| {
        return returnError(err);
    };

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

    // Validate file descriptor
    validateFd(fd) catch |err| {
        return returnError(err);
    };

    // Validate buffer size
    if (count > vmm.MAX_WRITE_SIZE) {
        return returnError(error.InvalidArgument);
    }

    // Validate user pointer
    vmm.validateUserPointer(buf_ptr, count, false) catch |err| {
        return returnError(err);
    };

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

    // Validate path pointer
    vmm.validateUserPointer(pathname_ptr, vmm.MAX_PATH_LEN, false) catch |err| {
        return returnError(err);
    };

    const pathname: [*:0]const u8 = @ptrFromInt(pathname_ptr);
    const path_slice = Basics.mem.sliceTo(pathname, 0);

    // Sanitize path to prevent directory traversal
    vmm.sanitizePath(path_slice) catch |err| {
        return returnError(err);
    };

    const fd = vfs.open(path_slice, flags, mode) catch |err| {
        // Log file access denials for security monitoring
        if (err == error.AccessDenied or err == error.PermissionDenied) {
            audit.logFileAccess(path_slice, true);
        }
        // Log symlink-related errors for TOCTOU detection
        if (err == error.SymlinkNotAllowed or err == error.TooManySymlinks) {
            audit.logSecurityViolation("Symlink attack attempt detected");
        }
        return returnError(err);
    };

    // Log successful file access (if configured)
    audit.logFileAccess(path_slice, false);

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

    // Read timespec from user memory
    // struct timespec { time_t tv_sec; long tv_nsec; }
    const req: *const extern struct { tv_sec: i64, tv_nsec: i64 } = @ptrFromInt(req_ptr);

    // Calculate total sleep time in milliseconds
    const sleep_ms: u64 = @intCast(@max(0, req.tv_sec) * 1000 + @divFloor(@max(0, req.tv_nsec), 1_000_000));

    if (sleep_ms > 0) {
        // Use timer ticks to wait (1 tick = 1ms)
        const timer_mod = @import("timer.zig");
        const start_ticks = timer_mod.getTicks();
        const end_ticks = start_ticks + sleep_ms;

        // Busy-wait or yield until time is up
        // In a full implementation, this would block the thread
        const sched = @import("sched.zig");
        while (timer_mod.getTicks() < end_ticks) {
            sched.yield();
        }
    }

    // If rem_ptr is provided, set remaining time to 0 (we completed the full sleep)
    if (rem_ptr != 0) {
        const rem: *extern struct { tv_sec: i64, tv_nsec: i64 } = @ptrFromInt(rem_ptr);
        rem.tv_sec = 0;
        rem.tv_nsec = 0;
    }

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

    // Namespaces
    // table.register(.Unshare, sys_unshare);
    // table.register(.Setns, sys_setns);
}

// ============================================================================
// Namespace System Calls
// ============================================================================

/// unshare - create new namespaces for current process
export fn sys_unshare(args: syscall.SyscallArgs) callconv(.C) u64 {
    const flags = @as(u32, @truncate(args.arg1));

    const current = process.getCurrentProcess() orelse return returnError(error.NoProcess);

    // Check if user has permission to create namespaces
    if (!namespaces.canCreateNamespace()) {
        audit.logSecurityViolation("Unprivileged namespace creation attempt");
        return returnError(error.PermissionDenied);
    }

    // Create new namespace set with specified flags
    if (current.namespaces) |old_ns| {
        const new_ns = old_ns.clone(current.allocator, flags) catch |err| {
            return returnError(err);
        };

        // Release old namespaces
        old_ns.release();

        // Set new namespaces
        current.namespaces = new_ns;

        // Log namespace creation
        audit.logSecurityViolation("Namespace created via unshare");
    }

    return 0;
}

/// setns - join an existing namespace
export fn sys_setns(args: syscall.SyscallArgs) callconv(.C) u64 {
    const ns_fd = @as(i32, @bitCast(@as(u32, @truncate(args.arg1))));
    const ns_type = @as(u32, @truncate(args.arg2));

    _ = ns_fd;
    _ = ns_type;

    // Check permission
    if (!namespaces.canEnterNamespace(0)) {
        audit.logSecurityViolation("Unprivileged setns attempt");
        return returnError(error.PermissionDenied);
    }

    // TODO: Implement namespace file descriptor lookup and joining
    // For now, just return ENOSYS (not implemented)
    return returnError(error.NotImplemented);
}

/// clone - create child process with namespace flags
export fn sys_clone(args: syscall.SyscallArgs) callconv(.C) u64 {
    const flags = @as(u32, @truncate(args.arg1));
    // arg2 = child_stack (not used in basic implementation)
    // arg3 = parent_tid ptr
    // arg4 = child_tid ptr
    // arg5 = tls

    const current = process.getCurrentProcess() orelse return returnError(error.NoProcess);

    // Check fork rate limit
    limits.checkCanFork() catch |err| {
        audit.logRateLimitExceeded("fork");
        return returnError(err);
    };

    limits.checkForkRateLimit() catch |err| {
        audit.logRateLimitExceeded("fork");
        return returnError(err);
    };

    // Create child with namespace flags
    const child = process.forkWithFlags(current, current.allocator, flags) catch |err| {
        return returnError(err);
    };

    // Log process creation
    audit.logProcessCreate(child.pid);

    // Log namespace creation if flags were specified
    if (flags & (@intFromEnum(namespaces.NamespaceType.CLONE_NEWPID) |
        @intFromEnum(namespaces.NamespaceType.CLONE_NEWNS) |
        @intFromEnum(namespaces.NamespaceType.CLONE_NEWNET) |
        @intFromEnum(namespaces.NamespaceType.CLONE_NEWIPC) |
        @intFromEnum(namespaces.NamespaceType.CLONE_NEWUTS)) != 0)
    {
        audit.logSecurityViolation("Namespace created via clone");
    }

    // Return child PID to parent
    return child.pid;
}
