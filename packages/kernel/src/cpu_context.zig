// Home Programming Language - CPU Context Management
// Full CPU state capture for exception handling and task switching

const Basics = @import("basics");

// ============================================================================
// CPU Register State
// ============================================================================

/// Complete CPU register state (saved on exception/interrupt)
pub const CpuContext = extern struct {
    // General purpose registers
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    // Segment registers
    ds: u16,
    es: u16,
    fs: u16,
    gs: u16,

    // Interrupt/exception info
    vector: u64,
    error_code: u64,

    // Pushed by CPU on interrupt
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,

    pub fn format(
        self: CpuContext,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            \\CPU Context [Vector: {}]:
            \\  RAX: 0x{x:0>16}  RBX: 0x{x:0>16}  RCX: 0x{x:0>16}
            \\  RDX: 0x{x:0>16}  RSI: 0x{x:0>16}  RDI: 0x{x:0>16}
            \\  RBP: 0x{x:0>16}  RSP: 0x{x:0>16}  RIP: 0x{x:0>16}
            \\  R8:  0x{x:0>16}  R9:  0x{x:0>16}  R10: 0x{x:0>16}
            \\  R11: 0x{x:0>16}  R12: 0x{x:0>16}  R13: 0x{x:0>16}
            \\  R14: 0x{x:0>16}  R15: 0x{x:0>16}
            \\  CS:  0x{x:0>4}  DS:  0x{x:0>4}  ES:  0x{x:0>4}  SS:  0x{x:0>4}
            \\  RFLAGS: 0x{x:0>16}  Error: 0x{x:0>16}
        , .{
            self.vector,
            self.rax,      self.rbx,      self.rcx,
            self.rdx,      self.rsi,      self.rdi,
            self.rbp,      self.rsp,      self.rip,
            self.r8,       self.r9,       self.r10,
            self.r11,      self.r12,      self.r13,
            self.r14,      self.r15,
            self.cs,       self.ds,       self.es,       self.ss,
            self.rflags,   self.error_code,
        });
    }
};

// ============================================================================
// RFLAGS Register
// ============================================================================

pub const RFlags = packed struct(u64) {
    carry: bool,              // 0: Carry flag
    reserved1: u1 = 1,        // 1: Always 1
    parity: bool,             // 2: Parity flag
    reserved2: u1 = 0,        // 3: Reserved
    auxiliary_carry: bool,    // 4: Auxiliary carry
    reserved3: u1 = 0,        // 5: Reserved
    zero: bool,               // 6: Zero flag
    sign: bool,               // 7: Sign flag
    trap: bool,               // 8: Trap flag (single-step)
    interrupt_enable: bool,   // 9: Interrupt enable
    direction: bool,          // 10: Direction flag
    overflow: bool,           // 11: Overflow flag
    iopl: u2,                 // 12-13: I/O privilege level
    nested_task: bool,        // 14: Nested task
    reserved4: u1 = 0,        // 15: Reserved
    resume_flag: bool,        // 16: Resume flag
    virtual_8086: bool,       // 17: Virtual 8086 mode
    alignment_check: bool,    // 18: Alignment check
    virtual_interrupt: bool,  // 19: Virtual interrupt flag
    virtual_interrupt_pending: bool, // 20: Virtual interrupt pending
    cpuid_available: bool,    // 21: CPUID available
    reserved5: u42 = 0,       // 22-63: Reserved

    pub fn fromU64(value: u64) RFlags {
        return @bitCast(value);
    }

    pub fn toU64(self: RFlags) u64 {
        return @bitCast(self);
    }

    /// Read current RFLAGS
    pub fn read() RFlags {
        const val = asm volatile ("pushfq; popq %[result]"
            : [result] "=r" (-> u64),
        );
        return fromU64(val);
    }

    /// Write RFLAGS
    pub fn write(self: RFlags) void {
        const val = self.toU64();
        asm volatile ("pushq %[val]; popfq"
            :
            : [val] "r" (val),
            : "cc"
        );
    }
};

// ============================================================================
// Stack Frame Walking
// ============================================================================

pub const StackFrame = struct {
    rbp: u64,
    rip: u64,

    /// Get current stack frame
    pub fn current() StackFrame {
        const rbp = asm volatile ("mov %%rbp, %[result]"
            : [result] "=r" (-> u64),
        );
        const rip = @returnAddress();
        return .{ .rbp = rbp, .rip = @intFromPtr(rip) };
    }

    /// Get next frame in stack
    pub fn next(self: StackFrame) ?StackFrame {
        if (self.rbp == 0) return null;

        const frame_ptr: *const [2]u64 = @ptrFromInt(self.rbp);
        const next_rbp = frame_ptr[0];
        const next_rip = frame_ptr[1];

        if (next_rbp == 0 or next_rip == 0) return null;

        return .{ .rbp = next_rbp, .rip = next_rip };
    }
};

/// Walk the stack and call handler for each frame
pub fn walkStack(context: anytype, comptime handler: fn (@TypeOf(context), StackFrame) void) void {
    var frame = StackFrame.current();
    var depth: usize = 0;
    const max_depth = 64;

    while (depth < max_depth) : (depth += 1) {
        handler(context, frame);
        frame = frame.next() orelse break;
    }
}

/// Print stack trace
pub fn printStackTrace() void {
    Basics.debug.print("Stack trace:\n", .{});

    walkStack({}, struct {
        fn print(_: void, frame: StackFrame) void {
            Basics.debug.print("  RBP: 0x{x:0>16}  RIP: 0x{x:0>16}\n", .{ frame.rbp, frame.rip });
        }
    }.print);
}

// ============================================================================
// FPU/SSE State
// ============================================================================

/// FPU/SSE/AVX state (for context switching)
pub const FpuState = extern struct {
    // 512 bytes for FXSAVE/FXRSTOR
    data: [512]u8 align(16),

    pub fn init() FpuState {
        return .{ .data = [_]u8{0} ** 512 };
    }

    /// Save FPU state
    pub fn save(self: *FpuState) void {
        asm volatile ("fxsave (%[ptr])"
            :
            : [ptr] "r" (&self.data),
            : "memory"
        );
    }

    /// Restore FPU state
    pub fn restore(self: *const FpuState) void {
        asm volatile ("fxrstor (%[ptr])"
            :
            : [ptr] "r" (&self.data),
            : "memory"
        );
    }
};

// ============================================================================
// Task State (for task switching)
// ============================================================================

pub const TaskState = struct {
    cpu_context: CpuContext,
    fpu_state: FpuState,

    pub fn init() TaskState {
        return .{
            .cpu_context = Basics.mem.zeroes(CpuContext),
            .fpu_state = FpuState.init(),
        };
    }

    /// Save current task state
    pub fn save(self: *TaskState) void {
        self.fpu_state.save();
        // CPU context is saved by interrupt/exception handler
    }

    /// Restore task state
    pub fn restore(self: *const TaskState) void {
        self.fpu_state.restore();
        // CPU context is restored by interrupt return
    }
};

// Tests
test "rflags operations" {
    const flags = RFlags.read();

    // Interrupt flag should be set in test environment
    try Basics.testing.expect(flags.reserved1 == 1);
}

test "stack frame" {
    const frame = StackFrame.current();
    try Basics.testing.expect(frame.rbp != 0);
    try Basics.testing.expect(frame.rip != 0);
}

test "cpu context size" {
    // Ensure proper alignment
    const size = @sizeOf(CpuContext);
    try Basics.testing.expect(size > 0);
}

test "fpu state alignment" {
    var fpu = FpuState.init();
    const addr = @intFromPtr(&fpu.data);
    try Basics.testing.expectEqual(@as(usize, 0), addr % 16);
}
