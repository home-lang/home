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
// System Call Numbers
// ============================================================================

pub const SyscallNumber = enum(u64) {
    Exit = 0,
    Read = 1,
    Write = 2,
    Open = 3,
    Close = 4,
    Stat = 5,
    Fstat = 6,
    Lseek = 7,
    Mmap = 8,
    Mprotect = 9,
    Munmap = 10,
    Brk = 11,
    Fork = 12,
    Execve = 13,
    Wait4 = 14,
    Kill = 15,
    Getpid = 16,
    Socket = 17,
    Bind = 18,
    Listen = 19,
    Accept = 20,
    // ... more syscalls
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
// Common System Call Implementations (Examples)
// ============================================================================

fn sysExit(args: SyscallArgs) callconv(.C) u64 {
    const exit_code = args.arg1;
    Basics.debug.print("Process exiting with code: {}\n", .{exit_code});
    // Terminate current process
    return 0;
}

fn sysWrite(args: SyscallArgs) callconv(.C) u64 {
    const fd = args.arg1;
    const buf_ptr = args.arg2;
    const count = args.arg3;

    _ = fd;
    _ = buf_ptr;
    _ = count;

    // Implement write syscall
    // This would write to the file descriptor
    return 0;
}

fn sysGetpid(args: SyscallArgs) callconv(.C) u64 {
    _ = args;
    // Return current process ID
    return 1; // Placeholder
}

/// Register default system call handlers
pub fn registerDefaultHandlers(table: *SyscallTable) void {
    table.register(.Exit, sysExit);
    table.register(.Write, sysWrite);
    table.register(.Getpid, sysGetpid);
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
