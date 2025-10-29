// Home Programming Language - Kernel Mode Code Generation
// Specialized codegen for kernel/OS development

const Basics = @import("basics");

// ============================================================================
// Kernel Codegen Configuration
// ============================================================================

pub const KernelCodegenOptions = struct {
    /// Disable red zone (required for interrupt handlers)
    disable_red_zone: bool = true,

    /// Disable floating point (unless explicitly saved)
    disable_fp: bool = true,

    /// Enable interrupt handler prologue/epilogue
    interrupt_handlers: bool = true,

    /// Disable standard library
    no_stdlib: bool = true,

    /// Stack alignment (16 bytes for x86-64)
    stack_alignment: usize = 16,

    /// Generate position-independent code
    pic: bool = false,

    /// Kernel code model (kernel runs in high half)
    code_model: CodeModel = .Kernel,

    pub const CodeModel = enum {
        Small, // Default
        Kernel, // -2GB to 0 (kernel space)
        Medium, // Data can be anywhere
        Large, // Everything can be anywhere
    };
};

// ============================================================================
// Function Attributes for Kernel
// ============================================================================

pub const FunctionAttributes = struct {
    /// Mark function as interrupt handler
    interrupt: bool = false,

    /// Mark function as naked (no prologue/epilogue)
    naked: bool = false,

    /// Mark function as never returning
    noreturn: bool = false,

    /// Mark function as inline
    inline_hint: InlineHint = .None,

    /// Calling convention
    calling_convention: CallingConvention = .C,

    /// Section to place function in
    section: ?[]const u8 = null,

    /// Alignment requirement
    alignment: ?usize = null,

    pub const InlineHint = enum {
        None,
        Inline,
        AlwaysInline,
        NoInline,
    };

    pub const CallingConvention = enum {
        C, // Standard C calling convention
        FastCall, // Register-based calling
        Interrupt, // Interrupt handler calling convention
        Naked, // No prologue/epilogue
        SysV, // System V AMD64 ABI
    };
};

// ============================================================================
// Interrupt Handler Codegen
// ============================================================================

pub const InterruptFrame = struct {
    /// Generate interrupt handler prologue
    pub fn generatePrologue(writer: anytype) !void {
        // Save all general purpose registers
        try writer.writeAll(
            \\    pushq %rax
            \\    pushq %rbx
            \\    pushq %rcx
            \\    pushq %rdx
            \\    pushq %rsi
            \\    pushq %rdi
            \\    pushq %rbp
            \\    pushq %r8
            \\    pushq %r9
            \\    pushq %r10
            \\    pushq %r11
            \\    pushq %r12
            \\    pushq %r13
            \\    pushq %r14
            \\    pushq %r15
            \\
        );

        // Set up frame pointer
        try writer.writeAll(
            \\    movq %rsp, %rbp
            \\
        );

        // Align stack to 16 bytes
        try writer.writeAll(
            \\    andq $-16, %rsp
            \\
        );
    }

    /// Generate interrupt handler epilogue
    pub fn generateEpilogue(writer: anytype) !void {
        // Restore stack pointer
        try writer.writeAll(
            \\    movq %rbp, %rsp
            \\
        );

        // Restore all general purpose registers
        try writer.writeAll(
            \\    popq %r15
            \\    popq %r14
            \\    popq %r13
            \\    popq %r12
            \\    popq %r11
            \\    popq %r10
            \\    popq %r9
            \\    popq %r8
            \\    popq %rbp
            \\    popq %rdi
            \\    popq %rsi
            \\    popq %rdx
            \\    popq %rcx
            \\    popq %rbx
            \\    popq %rax
            \\
        );

        // Return from interrupt
        try writer.writeAll(
            \\    iretq
            \\
        );
    }

    /// Generate interrupt handler with error code
    pub fn generateWithErrorCode(writer: anytype, handler_name: []const u8) !void {
        try writer.print(".global {s}\n", .{handler_name});
        try writer.print("{s}:\n", .{handler_name});

        // Error code is already pushed by CPU
        try generatePrologue(writer);

        // Call C handler
        try writer.print("    call {s}_handler\n", .{handler_name});

        try generateEpilogue(writer);
    }

    /// Generate interrupt handler without error code
    pub fn generateWithoutErrorCode(writer: anytype, handler_name: []const u8) !void {
        try writer.print(".global {s}\n", .{handler_name});
        try writer.print("{s}:\n", .{handler_name});

        // Push dummy error code
        try writer.writeAll("    pushq $0\n");

        try generatePrologue(writer);

        // Call C handler
        try writer.print("    call {s}_handler\n", .{handler_name});

        try generateEpilogue(writer);
    }
};

// ============================================================================
// Syscall Entry Codegen
// ============================================================================

pub const SyscallEntry = struct {
    /// Generate syscall entry point
    pub fn generate(writer: anytype) !void {
        try writer.writeAll(
            \\.global syscall_entry
            \\syscall_entry:
            \\    // Save userspace stack pointer
            \\    movq %rsp, %gs:user_rsp
            \\
            \\    // Load kernel stack
            \\    movq %gs:kernel_rsp, %rsp
            \\
            \\    // Build SyscallArgs on stack
            \\    pushq %r9     // arg6
            \\    pushq %r8     // arg5
            \\    pushq %r10    // arg4
            \\    pushq %rdx    // arg3
            \\    pushq %rsi    // arg2
            \\    pushq %rdi    // arg1
            \\    pushq %rax    // number
            \\
            \\    // Save registers that might be clobbered
            \\    pushq %r11    // RFLAGS
            \\    pushq %rcx    // Return RIP
            \\    pushq %rbx
            \\    pushq %rbp
            \\    pushq %r12
            \\    pushq %r13
            \\    pushq %r14
            \\    pushq %r15
            \\
            \\    // Call dispatcher
            \\    movq %rsp, %rdi
            \\    call syscall_dispatcher
            \\
            \\    // Restore registers
            \\    popq %r15
            \\    popq %r14
            \\    popq %r13
            \\    popq %r12
            \\    popq %rbp
            \\    popq %rbx
            \\    popq %rcx
            \\    popq %r11
            \\
            \\    // Clean up syscall args
            \\    addq $56, %rsp
            \\
            \\    // Restore userspace stack
            \\    movq %gs:user_rsp, %rsp
            \\
            \\    // Return to userspace
            \\    sysretq
            \\
        );
    }
};

// ============================================================================
// Red Zone Management
// ============================================================================

pub const RedZone = struct {
    /// Size of red zone (128 bytes on x86-64)
    pub const SIZE = 128;

    /// Generate code to disable red zone
    pub fn disable(writer: anytype) !void {
        // Add to compiler flags: -mno-red-zone
        try writer.writeAll("# Red zone disabled via -mno-red-zone\n");
    }

    /// Check if red zone is safe to use
    pub fn isSafe(in_interrupt: bool) bool {
        return !in_interrupt;
    }
};

// ============================================================================
// Stack Management
// ============================================================================

pub const StackManagement = struct {
    /// Generate stack probe for large allocations
    pub fn generateStackProbe(writer: anytype, size: usize) !void {
        const PAGE_SIZE = 4096;

        if (size <= PAGE_SIZE) {
            // Small allocation, just subtract
            try writer.print("    subq ${d}, %rsp\n", .{size});
        } else {
            // Large allocation, probe each page
            var remaining = size;
            while (remaining > 0) {
                const probe_size = @min(remaining, PAGE_SIZE);
                try writer.print("    subq ${d}, %rsp\n", .{probe_size});
                try writer.writeAll("    movq $0, (%rsp)\n"); // Touch the page
                remaining -= probe_size;
            }
        }
    }

    /// Ensure stack alignment
    pub fn ensureAlignment(writer: anytype, alignment: usize) !void {
        const mask = ~(alignment - 1);
        try writer.print("    andq ${d}, %rsp\n", .{mask});
    }
};

// ============================================================================
// Floating Point Management
// ============================================================================

pub const FloatingPoint = struct {
    /// Save FPU/SSE state
    pub fn saveState(writer: anytype) !void {
        // Allocate space for FPU state (512 bytes for FXSAVE)
        try writer.writeAll(
            \\    subq $512, %rsp
            \\    fxsave (%rsp)
            \\
        );
    }

    /// Restore FPU/SSE state
    pub fn restoreState(writer: anytype) !void {
        try writer.writeAll(
            \\    fxrstor (%rsp)
            \\    addq $512, %rsp
            \\
        );
    }

    /// Disable FPU/SSE in kernel
    pub fn disable(writer: anytype) !void {
        try writer.writeAll(
            \\    movq %cr0, %rax
            \\    orq $0x6, %rax  // Set EM and MP bits
            \\    movq %rax, %cr0
            \\
        );
    }

    /// Enable FPU/SSE
    pub fn enable(writer: anytype) !void {
        try writer.writeAll(
            \\    movq %cr0, %rax
            \\    andq $~0x6, %rax  // Clear EM and MP bits
            \\    movq %rax, %cr0
            \\
        );
    }
};

// ============================================================================
// Code Generation Context
// ============================================================================

pub const CodegenContext = struct {
    options: KernelCodegenOptions,
    allocator: Basics.Allocator,
    output: Basics.ArrayList(u8),

    pub fn init(allocator: Basics.Allocator, options: KernelCodegenOptions) CodegenContext {
        return .{
            .options = options,
            .allocator = allocator,
            .output = Basics.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *CodegenContext) void {
        self.output.deinit();
    }

    pub fn generateFunction(
        self: *CodegenContext,
        name: []const u8,
        attrs: FunctionAttributes,
        body: []const u8,
    ) !void {
        const writer = self.output.writer();

        // Section directive
        if (attrs.section) |section| {
            try writer.print(".section {s}\n", .{section});
        }

        // Alignment
        if (attrs.alignment) |alignment_val| {
            try writer.print(".align {d}\n", .{alignment_val});
        }

        // Function declaration
        try writer.print(".global {s}\n", .{name});
        try writer.print(".type {s}, @function\n", .{name});
        try writer.print("{s}:\n", .{name});

        // Prologue (unless naked or interrupt)
        if (!attrs.naked and !attrs.interrupt) {
            try writer.writeAll("    pushq %rbp\n");
            try writer.writeAll("    movq %rsp, %rbp\n");

            if (self.options.disable_red_zone) {
                try writer.writeAll("    # Red zone disabled\n");
            }
        }

        if (attrs.interrupt) {
            try InterruptFrame.generatePrologue(writer);
        }

        // Function body
        try writer.writeAll(body);

        // Epilogue (unless naked or interrupt)
        if (!attrs.naked and !attrs.interrupt) {
            try writer.writeAll("    movq %rbp, %rsp\n");
            try writer.writeAll("    popq %rbp\n");
            try writer.writeAll("    ret\n");
        }

        if (attrs.interrupt) {
            try InterruptFrame.generateEpilogue(writer);
        }

        try writer.print(".size {s}, .-{s}\n", .{ name, name });
    }

    pub fn getOutput(self: *CodegenContext) []const u8 {
        return self.output.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "interrupt frame codegen" {
    const allocator = Basics.testing.allocator;
    var buffer = Basics.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const writer = buffer.writer();
    try InterruptFrame.generatePrologue(writer);
    try InterruptFrame.generateEpilogue(writer);

    try Basics.testing.expect(buffer.items.len > 0);
}

test "codegen context" {
    const allocator = Basics.testing.allocator;
    const options = KernelCodegenOptions{};

    var ctx = CodegenContext.init(allocator, options);
    defer ctx.deinit();

    const attrs = FunctionAttributes{};
    try ctx.generateFunction("test_func", attrs, "    nop\n");

    const output = ctx.getOutput();
    try Basics.testing.expect(output.len > 0);
}
