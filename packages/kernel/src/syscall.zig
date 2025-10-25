// Home Programming Language - System Call Interface
// Fast system call mechanism using SYSCALL/SYSRET

const Basics = @import("basics");
const asm = @import("asm.zig");

// ============================================================================
// MSR Constants for SYSCALL
// ============================================================================

pub const IA32_STAR: u32 = 0xC0000081;
pub const IA32_LSTAR: u32 = 0xC0000082;
pub const IA32_FMASK: u32 = 0xC0000084;
pub const IA32_EFER: u32 = 0xC0000080;

pub const EFER_SCE: u64 = 1 << 0; // System Call Extensions

// ============================================================================
// System Call Numbers (POSIX-compatible)
// ============================================================================

pub const SyscallNumber = enum(u64) {
    // File operations
    Read = 0,
    Write = 1,
    Open = 2,
    Close = 3,
    Stat = 4,
    Fstat = 5,
    Lstat = 6,
    Poll = 7,
    Lseek = 8,
    Mmap = 9,
    Mprotect = 10,
    Munmap = 11,
    Brk = 12,

    // Signal handling
    RtSigaction = 13,
    RtSigprocmask = 14,
    RtSigreturn = 15,
    Ioctl = 16,
    Pread64 = 17,
    Pwrite64 = 18,
    Readv = 19,
    Writev = 20,

    // Process operations
    Access = 21,
    Pipe = 22,
    Select = 23,
    Sched_yield = 24,
    Mremap = 25,
    Msync = 26,
    Mincore = 27,
    Madvise = 28,
    Shmget = 29,
    Shmat = 30,
    Shmctl = 31,
    Dup = 32,
    Dup2 = 33,
    Pause = 34,
    Nanosleep = 35,
    Getitimer = 36,
    Alarm = 37,
    Setitimer = 38,
    Getpid = 39,

    // Network operations
    Sendfile = 40,
    Socket = 41,
    Connect = 42,
    Accept = 43,
    Sendto = 44,
    Recvfrom = 45,
    Sendmsg = 46,
    Recvmsg = 47,
    Shutdown = 48,
    Bind = 49,
    Listen = 50,
    Getsockname = 51,
    Getpeername = 52,
    Socketpair = 53,
    Setsockopt = 54,
    Getsockopt = 55,

    // Process management
    Clone = 56,
    Fork = 57,
    Vfork = 58,
    Execve = 59,
    Exit = 60,
    Wait4 = 61,
    Kill = 62,
    Uname = 63,
    Semget = 64,
    Semop = 65,
    Semctl = 66,
    Shmdt = 67,
    Msgget = 68,
    Msgsnd = 69,
    Msgrcv = 70,
    Msgctl = 71,

    // File control
    Fcntl = 72,
    Flock = 73,
    Fsync = 74,
    Fdatasync = 75,
    Truncate = 76,
    Ftruncate = 77,
    Getdents = 78,
    Getcwd = 79,
    Chdir = 80,
    Fchdir = 81,
    Rename = 82,
    Mkdir = 83,
    Rmdir = 84,
    Creat = 85,
    Link = 86,
    Unlink = 87,
    Symlink = 88,
    Readlink = 89,
    Chmod = 90,
    Fchmod = 91,
    Chown = 92,
    Fchown = 93,
    Lchown = 94,
    Umask = 95,

    // Time operations
    Gettimeofday = 96,
    Getrlimit = 97,
    Getrusage = 98,
    Sysinfo = 99,
    Times = 100,
    Ptrace = 101,
    Getuid = 102,
    Syslog = 103,
    Getgid = 104,
    Setuid = 105,
    Setgid = 106,
    Geteuid = 107,
    Getegid = 108,
    Setpgid = 109,
    Getppid = 110,
    Getpgrp = 111,
    Setsid = 112,
    Setreuid = 113,
    Setregid = 114,
    Getgroups = 115,
    Setgroups = 116,
    Setresuid = 117,
    Getresuid = 118,
    Setresgid = 119,
    Getresgid = 120,
    Getpgid = 121,
    Setfsuid = 122,
    Setfsgid = 123,
    Getsid = 124,
    Capget = 125,
    Capset = 126,

    // Signal handling (continued)
    RtSigpending = 127,
    RtSigtimedwait = 128,
    RtSigqueueinfo = 129,
    RtSigsuspend = 130,
    Sigaltstack = 131,
    Utime = 132,
    Mknod = 133,
    Uselib = 134,
    Personality = 135,
    Ustat = 136,
    Statfs = 137,
    Fstatfs = 138,
    Sysfs = 139,
    Getpriority = 140,
    Setpriority = 141,
    Sched_setparam = 142,
    Sched_getparam = 143,
    Sched_setscheduler = 144,
    Sched_getscheduler = 145,
    Sched_get_priority_max = 146,
    Sched_get_priority_min = 147,
    Sched_rr_get_interval = 148,
    Mlock = 149,
    Munlock = 150,
    Mlockall = 151,
    Munlockall = 152,
    Vhangup = 153,
    Modify_ldt = 154,
    Pivot_root = 155,
    Prctl = 156,
    Arch_prctl = 157,
    Adjtimex = 158,
    Setrlimit = 159,
    Chroot = 160,
    Sync = 161,
    Acct = 162,
    Settimeofday = 163,
    Mount = 164,
    Umount2 = 165,
    Swapon = 166,
    Swapoff = 167,
    Reboot = 168,
    Sethostname = 169,
    Setdomainname = 170,
    Iopl = 171,
    Ioperm = 172,
    Create_module = 173,
    Init_module = 174,
    Delete_module = 175,
    Get_kernel_syms = 176,
    Query_module = 177,
    Quotactl = 178,
    Nfsservctl = 179,
    Getpmsg = 180,
    Putpmsg = 181,
    Afs_syscall = 182,
    Tuxcall = 183,
    Security = 184,
    Gettid = 185,
    Readahead = 186,

    // Extended attributes
    Setxattr = 187,
    Lsetxattr = 188,
    Fsetxattr = 189,
    Getxattr = 190,
    Lgetxattr = 191,
    Fgetxattr = 192,
    Listxattr = 193,
    Llistxattr = 194,
    Flistxattr = 195,
    Removexattr = 196,
    Lremovexattr = 197,
    Fremovexattr = 198,
    Tkill = 199,
    Time = 200,
    Futex = 201,
    Sched_setaffinity = 202,
    Sched_getaffinity = 203,
    Set_thread_area = 204,
    Io_setup = 205,
    Io_destroy = 206,
    Io_getevents = 207,
    Io_submit = 208,
    Io_cancel = 209,
    Get_thread_area = 210,
    Lookup_dcookie = 211,
    Epoll_create = 212,
    Epoll_ctl_old = 213,
    Epoll_wait_old = 214,
    Remap_file_pages = 215,
    Getdents64 = 216,
    Set_tid_address = 217,
    Restart_syscall = 218,
    Semtimedop = 219,
    Fadvise64 = 220,

    // Timer operations
    Timer_create = 221,
    Timer_settime = 222,
    Timer_gettime = 223,
    Timer_getoverrun = 224,
    Timer_delete = 225,
    Clock_settime = 226,
    Clock_gettime = 227,
    Clock_getres = 228,
    Clock_nanosleep = 229,

    // Group and exit operations
    Exit_group = 230,
    Epoll_wait = 231,
    Epoll_ctl = 232,
    Tgkill = 233,
    Utimes = 234,
    Vserver = 235,
    Mbind = 236,
    Set_mempolicy = 237,
    Get_mempolicy = 238,
    Mq_open = 239,
    Mq_unlink = 240,
    Mq_timedsend = 241,
    Mq_timedreceive = 242,
    Mq_notify = 243,
    Mq_getsetattr = 244,
    Kexec_load = 245,
    Waitid = 246,
    Add_key = 247,
    Request_key = 248,
    Keyctl = 249,
    Ioprio_set = 250,
    Ioprio_get = 251,
    Inotify_init = 252,
    Inotify_add_watch = 253,
    Inotify_rm_watch = 254,
    Migrate_pages = 255,
    Openat = 256,
    Mkdirat = 257,
    Mknodat = 258,
    Fchownat = 259,
    Futimesat = 260,
    Newfstatat = 261,
    Unlinkat = 262,
    Renameat = 263,
    Linkat = 264,
    Symlinkat = 265,
    Readlinkat = 266,
    Fchmodat = 267,
    Faccessat = 268,
    Pselect6 = 269,
    Ppoll = 270,
    Unshare = 271,
    Set_robust_list = 272,
    Get_robust_list = 273,
    Splice = 274,
    Tee = 275,
    Sync_file_range = 276,
    Vmsplice = 277,
    Move_pages = 278,
    Utimensat = 279,
    Epoll_pwait = 280,
    Signalfd = 281,
    Timerfd_create = 282,
    Eventfd = 283,
    Fallocate = 284,
    Timerfd_settime = 285,
    Timerfd_gettime = 286,
    Accept4 = 287,
    Signalfd4 = 288,
    Eventfd2 = 289,
    Epoll_create1 = 290,
    Dup3 = 291,
    Pipe2 = 292,
    Inotify_init1 = 293,
    Preadv = 294,
    Pwritev = 295,
    Rt_tgsigqueueinfo = 296,
    Perf_event_open = 297,
    Recvmmsg = 298,

    _,

    pub fn fromU64(val: u64) SyscallNumber {
        return @enumFromInt(val);
    }
};

// ============================================================================
// System Call Arguments
// ============================================================================

pub const SyscallArgs = struct {
    number: u64,  // rax
    arg1: u64,    // rdi
    arg2: u64,    // rsi
    arg3: u64,    // rdx
    arg4: u64,    // r10
    arg5: u64,    // r8
    arg6: u64,    // r9
};

// ============================================================================
// System Call Handler Type
// ============================================================================

pub const SyscallHandler = *const fn (SyscallArgs) callconv(.C) u64;

// ============================================================================
// System Call Table
// ============================================================================

pub const SyscallTable = struct {
    const MAX_SYSCALLS = 512;

    handlers: [MAX_SYSCALLS]?SyscallHandler,

    pub fn init() SyscallTable {
        return .{
            .handlers = [_]?SyscallHandler{null} ** MAX_SYSCALLS,
        };
    }

    pub fn register(self: *SyscallTable, number: SyscallNumber, handler: SyscallHandler) void {
        const idx = @intFromEnum(number);
        if (idx < MAX_SYSCALLS) {
            self.handlers[idx] = handler;
        }
    }

    pub fn unregister(self: *SyscallTable, number: SyscallNumber) void {
        const idx = @intFromEnum(number);
        if (idx < MAX_SYSCALLS) {
            self.handlers[idx] = null;
        }
    }

    pub fn get(self: *const SyscallTable, number: u64) ?SyscallHandler {
        if (number >= MAX_SYSCALLS) return null;
        return self.handlers[number];
    }
};

// ============================================================================
// System Call Dispatcher (called from assembly stub)
// ============================================================================

var syscall_table: SyscallTable = undefined;

export fn syscallDispatcher(args: SyscallArgs) callconv(.C) u64 {
    const handler = syscall_table.get(args.number) orelse {
        // Invalid syscall number
        return @as(u64, @bitCast(@as(i64, -1)));
    };

    return handler(args);
}

// ============================================================================
// System Call Entry Point (Assembly)
// ============================================================================

/// Assembly stub for SYSCALL entry
/// This is called when userspace executes SYSCALL instruction
export fn syscallEntry() callconv(.Naked) noreturn {
    // Save userspace registers
    asm volatile (
        \\// Save userspace stack pointer
        \\movq %%rsp, %%gs:user_rsp
        \\// Load kernel stack
        \\movq %%gs:kernel_rsp, %%rsp
        \\
        \\// Build SyscallArgs on stack
        \\pushq %%r9     // arg6
        \\pushq %%r8     // arg5
        \\pushq %%r10    // arg4
        \\pushq %%rdx    // arg3
        \\pushq %%rsi    // arg2
        \\pushq %%rdi    // arg1
        \\pushq %%rax    // number
        \\
        \\// Save other registers that might be clobbered
        \\pushq %%r11    // RFLAGS (saved by SYSCALL)
        \\pushq %%rcx    // Return RIP (saved by SYSCALL)
        \\pushq %%rbx
        \\pushq %%rbp
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        \\// Call dispatcher
        \\movq %%rsp, %%rdi
        \\call syscallDispatcher
        \\
        \\// Restore registers
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rbp
        \\popq %%rbx
        \\popq %%rcx    // Return RIP
        \\popq %%r11    // RFLAGS
        \\
        \\// Clean up syscall args
        \\addq $56, %%rsp
        \\
        \\// Restore userspace stack
        \\movq %%gs:user_rsp, %%rsp
        \\
        \\// Return to userspace
        \\sysretq
    );
    unreachable;
}

// ============================================================================
// System Call Initialization
// ============================================================================

pub fn initSyscalls(kernel_cs: u16, user_cs: u16) void {
    syscall_table = SyscallTable.init();

    // Enable SYSCALL/SYSRET in EFER
    var efer = asm.rdmsr(IA32_EFER);
    efer |= EFER_SCE;
    asm.wrmsr(IA32_EFER, efer);

    // Setup STAR (segment selectors)
    // Bits 32-47: Kernel CS (SYSCALL loads CS with this)
    // Bits 48-63: User CS (SYSRET loads CS with this + 16)
    const star = (@as(u64, user_cs - 16) << 48) | (@as(u64, kernel_cs) << 32);
    asm.wrmsr(IA32_STAR, star);

    // Setup LSTAR (system call entry point)
    const entry_addr = @intFromPtr(&syscallEntry);
    asm.wrmsr(IA32_LSTAR, entry_addr);

    // Setup FMASK (flags to clear on SYSCALL)
    // Clear interrupt flag and other flags for security
    const fmask: u64 = 0x200; // Clear IF (interrupt flag)
    asm.wrmsr(IA32_FMASK, fmask);
}

// ============================================================================
// User-space System Call Wrapper
// ============================================================================

/// Make a system call from user space
pub inline fn syscall0(number: SyscallNumber) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (@intFromEnum(number)),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall1(number: SyscallNumber, arg1: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (@intFromEnum(number)),
          [arg1] "{rdi}" (arg1),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall2(number: SyscallNumber, arg1: u64, arg2: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (@intFromEnum(number)),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall3(number: SyscallNumber, arg1: u64, arg2: u64, arg3: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (@intFromEnum(number)),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall4(number: SyscallNumber, arg1: u64, arg2: u64, arg3: u64, arg4: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (@intFromEnum(number)),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall5(number: SyscallNumber, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (@intFromEnum(number)),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall6(
    number: SyscallNumber,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    arg6: u64,
) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (@intFromEnum(number)),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
          [arg6] "{r9}" (arg6),
        : "rcx", "r11", "memory"
    );
}

// ============================================================================
// System Call Implementations
// ============================================================================

const process = @import("process.zig");
const signal = @import("signal.zig");
const pipe = @import("pipe.zig");
const shm = @import("shm.zig");
const vfs = @import("vfs.zig");

// Convert syscall result to u64, handling errors
fn toSyscallResult(result: anytype) u64 {
    const ResultType = @TypeOf(result);
    const result_info = @typeInfo(ResultType);

    if (result_info == .ErrorUnion) {
        if (result) |val| {
            return toSyscallValue(val);
        } else |err| {
            // Return negative errno
            const errno = errorToErrno(err);
            return @bitCast(@as(i64, -@as(i64, @intCast(errno))));
        }
    } else {
        return toSyscallValue(result);
    }
}

fn toSyscallValue(value: anytype) u64 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .Int, .ComptimeInt => @intCast(value),
        .Pointer => @intFromPtr(value),
        .Void => 0,
        else => 0,
    };
}

fn errorToErrno(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => 12, // ENOMEM
        error.PermissionDenied => 13, // EACCES
        error.InvalidArgument => 22, // EINVAL
        error.NoSuchProcess => 3, // ESRCH
        error.NoSuchSegment => 2, // ENOENT
        error.AlreadyExists => 17, // EEXIST
        error.InvalidSegment => 22, // EINVAL
        error.StillAttached => 16, // EBUSY
        error.InvalidCommand => 22, // EINVAL
        error.BrokenPipe => 32, // EPIPE
        error.InvalidOperation => 95, // EOPNOTSUPP
        error.NoProcess => 3, // ESRCH
        else => 1, // EPERM (generic)
    };
}

// File operations
fn sysRead(args: SyscallArgs) callconv(.C) u64 {
    const fd = args.arg1;
    const buf = @as([*]u8, @ptrFromInt(args.arg2));
    const count = args.arg3;

    const proc = process.current() orelse return toSyscallResult(error.NoProcess);
    const file = proc.getFile(@intCast(fd)) orelse return toSyscallResult(error.InvalidArgument);

    const result = file.read(buf[0..count]);
    return toSyscallResult(result);
}

fn sysWrite(args: SyscallArgs) callconv(.C) u64 {
    const fd = args.arg1;
    const buf = @as([*]const u8, @ptrFromInt(args.arg2));
    const count = args.arg3;

    const proc = process.current() orelse return toSyscallResult(error.NoProcess);
    const file = proc.getFile(@intCast(fd)) orelse return toSyscallResult(error.InvalidArgument);

    const result = file.write(buf[0..count]);
    return toSyscallResult(result);
}

fn sysOpen(args: SyscallArgs) callconv(.C) u64 {
    const path = @as([*:0]const u8, @ptrFromInt(args.arg1));
    const flags = @as(u32, @intCast(args.arg2));
    const mode = @as(u16, @intCast(args.arg3));

    _ = path;
    _ = flags;
    _ = mode;

    // TODO: Implement vfs.open
    return toSyscallResult(error.InvalidOperation);
}

fn sysClose(args: SyscallArgs) callconv(.C) u64 {
    const fd = @as(i32, @intCast(args.arg1));

    const proc = process.current() orelse return toSyscallResult(error.NoProcess);
    proc.removeFile(fd);
    return 0;
}

// Process operations
fn sysExit(args: SyscallArgs) callconv(.C) u64 {
    const exit_code = @as(i32, @intCast(args.arg1));
    const proc = process.current() orelse return 0;

    proc.exit_code = exit_code;
    proc.state = .Zombie;

    // TODO: Schedule next process
    return 0;
}

fn sysFork(args: SyscallArgs) callconv(.C) u64 {
    _ = args;
    const proc = process.current() orelse return toSyscallResult(error.NoProcess);
    const result = proc.fork();
    return toSyscallResult(result);
}

fn sysGetpid(args: SyscallArgs) callconv(.C) u64 {
    _ = args;
    const proc = process.current() orelse return 0;
    return proc.pid;
}

fn sysGetppid(args: SyscallArgs) callconv(.C) u64 {
    _ = args;
    const proc = process.current() orelse return 0;
    return if (proc.parent) |p| p.pid else 0;
}

fn sysGetuid(args: SyscallArgs) callconv(.C) u64 {
    _ = args;
    const proc = process.current() orelse return 0;
    return proc.uid;
}

fn sysGetgid(args: SyscallArgs) callconv(.C) u64 {
    _ = args;
    const proc = process.current() orelse return 0;
    return proc.gid;
}

// Signal operations
fn sysKill(args: SyscallArgs) callconv(.C) u64 {
    const pid = @as(i32, @intCast(args.arg1));
    const sig = @as(i32, @intCast(args.arg2));

    const result = signal.sysKill(pid, sig);
    return toSyscallResult(result);
}

fn sysRtSigaction(args: SyscallArgs) callconv(.C) u64 {
    const sig = @as(i32, @intCast(args.arg1));
    const act = @as(?*const signal.SigAction, @ptrFromInt(args.arg2));
    const oldact = @as(?*signal.SigAction, @ptrFromInt(args.arg3));

    const result = signal.sysSigaction(sig, act, oldact);
    return toSyscallResult(result);
}

fn sysRtSigprocmask(args: SyscallArgs) callconv(.C) u64 {
    const how = @as(i32, @intCast(args.arg1));
    const set = @as(?*const signal.SignalSet, @ptrFromInt(args.arg2));
    const oldset = @as(?*signal.SignalSet, @ptrFromInt(args.arg3));

    const result = signal.sysSigprocmask(how, set, oldset);
    return toSyscallResult(result);
}

fn sysRtSigpending(args: SyscallArgs) callconv(.C) u64 {
    const set = @as(*signal.SignalSet, @ptrFromInt(args.arg1));

    const result = signal.sysSigpending(set);
    return toSyscallResult(result);
}

// Pipe operations
fn sysPipe(args: SyscallArgs) callconv(.C) u64 {
    const pipefd = @as(*[2]i32, @ptrFromInt(args.arg1));

    const result = pipe.sysPipe(pipefd);
    return toSyscallResult(result);
}

fn sysPipe2(args: SyscallArgs) callconv(.C) u64 {
    const pipefd = @as(*[2]i32, @ptrFromInt(args.arg1));
    const flags = @as(u32, @intCast(args.arg2));

    const result = pipe.sysPipe2(pipefd, flags);
    return toSyscallResult(result);
}

// Shared memory operations
fn sysShmget(args: SyscallArgs) callconv(.C) u64 {
    const key = @as(i32, @intCast(args.arg1));
    const size = args.arg2;
    const flags = @as(i32, @intCast(args.arg3));

    const result = shm.sysShmget(key, size, flags);
    return toSyscallResult(result);
}

fn sysShmat(args: SyscallArgs) callconv(.C) u64 {
    const shmid = @as(i32, @intCast(args.arg1));
    const addr = if (args.arg2 == 0) null else @as(usize, args.arg2);
    const flags = @as(i32, @intCast(args.arg3));

    const result = shm.sysShmat(shmid, addr, flags);
    return toSyscallResult(result);
}

fn sysShmdt(args: SyscallArgs) callconv(.C) u64 {
    const addr = args.arg1;

    const result = shm.sysShmdt(addr);
    return toSyscallResult(result);
}

fn sysShmctl(args: SyscallArgs) callconv(.C) u64 {
    const shmid = @as(i32, @intCast(args.arg1));
    const cmd = @as(i32, @intCast(args.arg2));
    const buf = @as(?*anyopaque, @ptrFromInt(args.arg3));

    const result = shm.sysShmctl(shmid, cmd, buf);
    return toSyscallResult(result);
}

// Memory operations
fn sysBrk(args: SyscallArgs) callconv(.C) u64 {
    const addr = args.arg1;
    _ = addr;
    // TODO: Implement brk
    return 0;
}

fn sysMmap(args: SyscallArgs) callconv(.C) u64 {
    const addr = args.arg1;
    const length = args.arg2;
    const prot = @as(u32, @intCast(args.arg3));
    const flags = @as(u32, @intCast(args.arg4));
    const fd = @as(i32, @intCast(args.arg5));
    const offset = args.arg6;

    _ = addr;
    _ = length;
    _ = prot;
    _ = flags;
    _ = fd;
    _ = offset;

    // TODO: Implement mmap
    return toSyscallResult(error.InvalidOperation);
}

fn sysMunmap(args: SyscallArgs) callconv(.C) u64 {
    const addr = args.arg1;
    const length = args.arg2;

    _ = addr;
    _ = length;

    // TODO: Implement munmap
    return 0;
}

// Scheduling operations
fn sysSchedYield(args: SyscallArgs) callconv(.C) u64 {
    _ = args;
    // TODO: Yield to scheduler
    return 0;
}

fn sysNanosleep(args: SyscallArgs) callconv(.C) u64 {
    const req = @as(*const anyopaque, @ptrFromInt(args.arg1));
    const rem = @as(?*anyopaque, @ptrFromInt(args.arg2));

    _ = req;
    _ = rem;

    // TODO: Implement nanosleep
    return 0;
}

// Time operations
fn sysGettimeofday(args: SyscallArgs) callconv(.C) u64 {
    const tv = @as(?*anyopaque, @ptrFromInt(args.arg1));
    const tz = @as(?*anyopaque, @ptrFromInt(args.arg2));

    _ = tv;
    _ = tz;

    // TODO: Implement gettimeofday
    return 0;
}

fn sysClockGettime(args: SyscallArgs) callconv(.C) u64 {
    const clock_id = @as(i32, @intCast(args.arg1));
    const tp = @as(*anyopaque, @ptrFromInt(args.arg2));

    _ = clock_id;
    _ = tp;

    // TODO: Implement clock_gettime
    return 0;
}

/// Register all system call handlers
pub fn registerAllHandlers(table: *SyscallTable) void {
    // File operations
    table.register(.Read, sysRead);
    table.register(.Write, sysWrite);
    table.register(.Open, sysOpen);
    table.register(.Close, sysClose);

    // Process operations
    table.register(.Exit, sysExit);
    table.register(.Fork, sysFork);
    table.register(.Getpid, sysGetpid);
    table.register(.Getppid, sysGetppid);
    table.register(.Getuid, sysGetuid);
    table.register(.Getgid, sysGetgid);

    // Signal operations
    table.register(.Kill, sysKill);
    table.register(.RtSigaction, sysRtSigaction);
    table.register(.RtSigprocmask, sysRtSigprocmask);
    table.register(.RtSigpending, sysRtSigpending);

    // Pipe operations
    table.register(.Pipe, sysPipe);
    table.register(.Pipe2, sysPipe2);

    // Shared memory operations
    table.register(.Shmget, sysShmget);
    table.register(.Shmat, sysShmat);
    table.register(.Shmdt, sysShmdt);
    table.register(.Shmctl, sysShmctl);

    // Memory operations
    table.register(.Brk, sysBrk);
    table.register(.Mmap, sysMmap);
    table.register(.Munmap, sysMunmap);

    // Scheduling
    table.register(.Sched_yield, sysSchedYield);
    table.register(.Nanosleep, sysNanosleep);

    // Time operations
    table.register(.Gettimeofday, sysGettimeofday);
    table.register(.Clock_gettime, sysClockGettime);
}

/// Register default system call handlers (deprecated - use registerAllHandlers)
pub fn registerDefaultHandlers(table: *SyscallTable) void {
    registerAllHandlers(table);
}

// ============================================================================
// Per-CPU System Call State
// ============================================================================

pub const SyscallState = struct {
    kernel_rsp: u64,
    user_rsp: u64,

    pub fn init(kernel_stack: u64) SyscallState {
        return .{
            .kernel_rsp = kernel_stack,
            .user_rsp = 0,
        };
    }

    /// Load syscall state into GS segment
    pub fn load(self: *const SyscallState) void {
        // This would use WRGSBASE to set GS base to point to this structure
        // For now, just a placeholder
        _ = self;
    }
};

// Tests
test "syscall number conversion" {
    const num = SyscallNumber.Write;
    try Basics.testing.expectEqual(@as(u64, 2), @intFromEnum(num));
}

test "syscall table" {
    var table = SyscallTable.init();

    table.register(.Exit, sysExit);

    const handler = table.get(@intFromEnum(SyscallNumber.Exit));
    try Basics.testing.expect(handler != null);

    table.unregister(.Exit);
    const handler2 = table.get(@intFromEnum(SyscallNumber.Exit));
    try Basics.testing.expect(handler2 == null);
}
