// Home Programming Language - Kernel Interrupt Handling
// Type-safe interrupt and exception management for OS development

const Basics = @import("basics");
const assembly = @import("asm.zig");

// ============================================================================
// IDT (Interrupt Descriptor Table) Structure
// ============================================================================

/// IDT Gate Type
pub const GateType = enum(u4) {
    TaskGate32 = 0x5,
    InterruptGate16 = 0x6,
    TrapGate16 = 0x7,
    InterruptGate32 = 0xE,
    TrapGate32 = 0xF,
};

/// IDT Entry (Gate Descriptor)
pub const IdtEntry = packed struct(u128) {
    offset_low: u16,      // Offset bits 0-15
    selector: u16,        // Code segment selector
    ist: u3,              // Interrupt Stack Table offset (0-7)
    reserved1: u5,        // Must be zero
    gate_type: u4,        // Gate type
    zero: u1,             // Must be zero
    dpl: u2,              // Descriptor Privilege Level
    present: u1,          // Present flag
    offset_middle: u16,   // Offset bits 16-31
    offset_high: u32,     // Offset bits 32-63
    reserved2: u32,       // Must be zero

    /// Create an interrupt gate entry
    pub fn interrupt(handler: usize, selector: u16, dpl: u2, ist: u3) IdtEntry {
        return .{
            .offset_low = @truncate(handler),
            .offset_middle = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
            .selector = selector,
            .ist = ist,
            .reserved1 = 0,
            .gate_type = @intFromEnum(GateType.InterruptGate32),
            .zero = 0,
            .dpl = dpl,
            .present = 1,
            .reserved2 = 0,
        };
    }

    /// Create a trap gate entry
    pub fn trap(handler: usize, selector: u16, dpl: u2, ist: u3) IdtEntry {
        return .{
            .offset_low = @truncate(handler),
            .offset_middle = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
            .selector = selector,
            .ist = ist,
            .reserved1 = 0,
            .gate_type = @intFromEnum(GateType.TrapGate32),
            .zero = 0,
            .dpl = dpl,
            .present = 1,
            .reserved2 = 0,
        };
    }

    /// Set handler address
    pub fn setHandler(self: *IdtEntry, handler: usize) void {
        self.offset_low = @truncate(handler);
        self.offset_middle = @truncate(handler >> 16);
        self.offset_high = @truncate(handler >> 32);
    }

    /// Get handler address
    pub fn getHandler(self: IdtEntry) usize {
        return @as(usize, self.offset_low) |
            (@as(usize, self.offset_middle) << 16) |
            (@as(usize, self.offset_high) << 32);
    }
};

comptime {
    if (@sizeOf(IdtEntry) != 16) {
        @compileError("IdtEntry must be 16 bytes");
    }
    if (@bitSizeOf(IdtEntry) != 128) {
        @compileError("IdtEntry must be 128 bits");
    }
}

/// IDT Pointer structure for LIDT instruction
pub const IdtPointer = packed struct {
    limit: u16,
    base: u64,

    pub fn init(idt: []IdtEntry) IdtPointer {
        return .{
            .limit = @as(u16, @intCast(idt.len * @sizeOf(IdtEntry) - 1)),
            .base = @intFromPtr(idt.ptr),
        };
    }
};

/// Load IDT
pub fn loadIdt(pointer: *const IdtPointer) void {
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (pointer),
        : "memory"
    );
}

/// Get current IDT
pub fn storeIdt() IdtPointer {
    var pointer: IdtPointer = undefined;
    asm volatile ("sidt (%[ptr])"
        :
        : [ptr] "r" (&pointer),
        : "memory"
    );
    return pointer;
}

// ============================================================================
// Exception Numbers
// ============================================================================

pub const Exception = enum(u8) {
    DivideByZero = 0,
    Debug = 1,
    NonMaskableInterrupt = 2,
    Breakpoint = 3,
    Overflow = 4,
    BoundRangeExceeded = 5,
    InvalidOpcode = 6,
    DeviceNotAvailable = 7,
    DoubleFault = 8,
    CoprocessorSegmentOverrun = 9,
    InvalidTSS = 10,
    SegmentNotPresent = 11,
    StackSegmentFault = 12,
    GeneralProtectionFault = 13,
    PageFault = 14,
    Reserved15 = 15,
    x87FloatingPoint = 16,
    AlignmentCheck = 17,
    MachineCheck = 18,
    SIMDFloatingPoint = 19,
    Virtualization = 20,
    ControlProtection = 21,
    Reserved22 = 22,
    Reserved23 = 23,
    Reserved24 = 24,
    Reserved25 = 25,
    Reserved26 = 26,
    Reserved27 = 27,
    HypervisorInjection = 28,
    VMMCommunication = 29,
    Security = 30,
    Reserved31 = 31,

    pub fn hasErrorCode(self: Exception) bool {
        return switch (self) {
            .DoubleFault,
            .InvalidTSS,
            .SegmentNotPresent,
            .StackSegmentFault,
            .GeneralProtectionFault,
            .PageFault,
            .AlignmentCheck,
            .ControlProtection,
            .Security,
            => true,
            else => false,
        };
    }
};

// ============================================================================
// Interrupt Frame
// ============================================================================

/// Interrupt stack frame (pushed by CPU)
pub const InterruptFrame = extern struct {
    instruction_pointer: u64,
    code_segment: u64,
    cpu_flags: u64,
    stack_pointer: u64,
    stack_segment: u64,

    pub fn format(
        self: InterruptFrame,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            \\InterruptFrame {{
            \\  RIP: 0x{x:0>16}
            \\  CS:  0x{x:0>16}
            \\  RFLAGS: 0x{x:0>16}
            \\  RSP: 0x{x:0>16}
            \\  SS:  0x{x:0>16}
            \\}}
        , .{
            self.instruction_pointer,
            self.code_segment,
            self.cpu_flags,
            self.stack_pointer,
            self.stack_segment,
        });
    }
};

/// Interrupt frame with error code
pub const InterruptFrameWithError = extern struct {
    error_code: u64,
    frame: InterruptFrame,
};

// ============================================================================
// Page Fault Error Code
// ============================================================================

pub const PageFaultError = packed struct(u64) {
    present: bool,           // 0 = not present, 1 = protection violation
    write: bool,             // 0 = read, 1 = write
    user: bool,              // 0 = kernel, 1 = user
    reserved_write: bool,    // Reserved bit was set
    instruction_fetch: bool, // Caused by instruction fetch
    protection_key: bool,    // Protection key violation
    shadow_stack: bool,      // Shadow stack access
    software_guard: bool,    // SGX violation
    _reserved: u56,

    pub fn format(
        self: PageFaultError,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.writeAll("PageFault(");
        if (self.present) try writer.writeAll("protection-violation ")
        else try writer.writeAll("not-present ");
        if (self.write) try writer.writeAll("write ")
        else try writer.writeAll("read ");
        if (self.user) try writer.writeAll("user-mode ")
        else try writer.writeAll("kernel-mode ");
        if (self.instruction_fetch) try writer.writeAll("instruction-fetch ");
        if (self.reserved_write) try writer.writeAll("reserved-bit ");
        try writer.writeAll(")");
    }
};

// ============================================================================
// Interrupt Handler Types
// ============================================================================

pub const ExceptionHandler = *const fn (*InterruptFrame) callconv(.Interrupt) void;
pub const ExceptionHandlerWithError = *const fn (*InterruptFrameWithError) callconv(.Interrupt) void;
pub const IrqHandler = *const fn (*InterruptFrame) callconv(.Interrupt) void;

// ============================================================================
// IDT Manager
// ============================================================================

pub const Idt = struct {
    const NUM_ENTRIES = 256;

    entries: [NUM_ENTRIES]IdtEntry,
    pointer: IdtPointer,

    /// Initialize IDT with all entries set to default handler
    pub fn init() Idt {
        var idt = Idt{
            .entries = [_]IdtEntry{Basics.mem.zeroes(IdtEntry)} ** NUM_ENTRIES,
            .pointer = undefined,
        };

        // Set default handler for all entries
        for (&idt.entries, 0..) |*entry, i| {
            const handler_addr = @intFromPtr(&defaultHandler);
            entry.* = IdtEntry.interrupt(handler_addr, 0x08, 0, 0);
            _ = i;
        }

        idt.pointer = IdtPointer.init(&idt.entries);
        return idt;
    }

    /// Set exception handler (no error code)
    pub fn setException(self: *Idt, exception: Exception, handler: ExceptionHandler) void {
        const vector: u8 = @intFromEnum(exception);
        const handler_addr = @intFromPtr(handler);
        self.entries[vector] = IdtEntry.interrupt(handler_addr, 0x08, 0, 0);
    }

    /// Set exception handler (with error code)
    pub fn setExceptionWithError(self: *Idt, exception: Exception, handler: ExceptionHandlerWithError) void {
        const vector: u8 = @intFromEnum(exception);
        const handler_addr = @intFromPtr(handler);
        self.entries[vector] = IdtEntry.interrupt(handler_addr, 0x08, 0, 0);
    }

    /// Set IRQ handler
    pub fn setIrq(self: *Idt, irq: u8, handler: IrqHandler) void {
        comptime {
            if (irq >= 16) {
                @compileError("IRQ must be 0-15");
            }
        }
        const vector = 32 + irq; // IRQs start at vector 32
        const handler_addr = @intFromPtr(handler);
        self.entries[vector] = IdtEntry.interrupt(handler_addr, 0x08, 0, 0);
    }

    /// Set custom interrupt handler
    pub fn setInterrupt(self: *Idt, vector: u8, handler: IrqHandler, dpl: u2) void {
        const handler_addr = @intFromPtr(handler);
        self.entries[vector] = IdtEntry.interrupt(handler_addr, 0x08, dpl, 0);
    }

    /// Load this IDT
    pub fn load(self: *Idt) void {
        self.pointer = IdtPointer.init(&self.entries);
        loadIdt(&self.pointer);
    }
};

// ============================================================================
// Default Handlers
// ============================================================================

fn defaultHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    _ = frame;
    // Default handler - just return
}

// ============================================================================
// Common Exception Handlers
// ============================================================================

/// Divide by zero handler
pub fn divideByZeroHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Divide by Zero at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
    @panic("Divide by zero");
}

/// Debug exception handler
pub fn debugHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Debug at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
}

/// Breakpoint handler
pub fn breakpointHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Breakpoint at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
}

/// Invalid opcode handler
pub fn invalidOpcodeHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Invalid Opcode at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
    @panic("Invalid opcode");
}

/// Double fault handler
pub fn doubleFaultHandler(frame_with_error: *InterruptFrameWithError) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Double Fault (error code: 0x{x})\n", .{frame_with_error.error_code});
    Basics.debug.print("{}\n", .{frame_with_error.frame});
    @panic("Double fault");
}

/// General protection fault handler
pub fn generalProtectionFaultHandler(frame_with_error: *InterruptFrameWithError) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: General Protection Fault (error code: 0x{x})\n", .{frame_with_error.error_code});
    Basics.debug.print("{}\n", .{frame_with_error.frame});
    @panic("General protection fault");
}

/// Page fault handler
pub fn pageFaultHandler(frame_with_error: *InterruptFrameWithError) callconv(.Interrupt) void {
    const error_code: PageFaultError = @bitCast(frame_with_error.error_code);
    const faulting_address = asm.readCr2();

    // Check if this might be a COW fault
    if (error_code.protection_violation and error_code.write) {
        // This could be a COW page fault
        // In a full implementation, we'd get the current process's COW handler here
        // For now, we'll just document what should happen:

        // var cow_handler = getCurrentProcess().cow_handler;
        // if (cow_handler.handleFault(faulting_address, true)) {
        //     return; // COW fault handled, resume execution
        // }

        // If COW handler returns false, it's a real protection fault
    }

    Basics.debug.print("EXCEPTION: Page Fault at address 0x{x}\n", .{faulting_address});
    Basics.debug.print("  Error: {}\n", .{error_code});
    Basics.debug.print("{}\n", .{frame_with_error.frame});
    @panic("Page fault");
}

/// Stack segment fault handler
pub fn stackSegmentFaultHandler(frame_with_error: *InterruptFrameWithError) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Stack Segment Fault (error code: 0x{x})\n", .{frame_with_error.error_code});
    Basics.debug.print("{}\n", .{frame_with_error.frame});
    @panic("Stack segment fault");
}

/// Overflow handler
pub fn overflowHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Overflow at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
    @panic("Overflow");
}

/// Bound range exceeded handler
pub fn boundRangeExceededHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Bound Range Exceeded at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
    @panic("Bound range exceeded");
}

/// Device not available handler (FPU/SSE)
pub fn deviceNotAvailableHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Device Not Available at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
    @panic("Device not available");
}

/// Invalid TSS handler
pub fn invalidTssHandler(frame_with_error: *InterruptFrameWithError) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Invalid TSS (error code: 0x{x})\n", .{frame_with_error.error_code});
    Basics.debug.print("{}\n", .{frame_with_error.frame});
    @panic("Invalid TSS");
}

/// Segment not present handler
pub fn segmentNotPresentHandler(frame_with_error: *InterruptFrameWithError) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Segment Not Present (error code: 0x{x})\n", .{frame_with_error.error_code});
    Basics.debug.print("{}\n", .{frame_with_error.frame});
    @panic("Segment not present");
}

/// x87 Floating-Point Exception handler
pub fn x87FloatingPointHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: x87 Floating-Point Exception at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
    @panic("x87 floating-point exception");
}

/// Alignment Check handler
pub fn alignmentCheckHandler(frame_with_error: *InterruptFrameWithError) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Alignment Check (error code: 0x{x})\n", .{frame_with_error.error_code});
    Basics.debug.print("{}\n", .{frame_with_error.frame});
    @panic("Alignment check");
}

/// Machine Check handler
pub fn machineCheckHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: Machine Check at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
    @panic("Machine check");
}

/// SIMD Floating-Point Exception handler
pub fn simdFloatingPointHandler(frame: *InterruptFrame) callconv(.Interrupt) void {
    Basics.debug.print("EXCEPTION: SIMD Floating-Point Exception at 0x{x}\n", .{frame.instruction_pointer});
    Basics.debug.print("{}\n", .{frame});
    @panic("SIMD floating-point exception");
}

// ============================================================================
// Interrupt Safety Features
// ============================================================================

const atomic = Basics.atomic;

/// Per-CPU interrupt nesting counter (prevents recursive interrupt overflow)
threadlocal var interrupt_nesting_count: u32 = 0;

/// Maximum allowed interrupt nesting depth
const MAX_INTERRUPT_NESTING: u32 = 16;

/// Kernel stack red zone size for overflow detection (4KB)
const STACK_RED_ZONE_SIZE: usize = 4096;

/// Interrupt Nesting Guard
pub const InterruptNestingGuard = struct {
    entered: bool,

    /// Enter interrupt context with nesting check
    pub fn enter() !InterruptNestingGuard {
        interrupt_nesting_count += 1;

        if (interrupt_nesting_count > MAX_INTERRUPT_NESTING) {
            Basics.debug.print("FATAL: Interrupt nesting depth exceeded ({} > {})\n",
                .{interrupt_nesting_count, MAX_INTERRUPT_NESTING});
            @panic("Interrupt nesting overflow");
        }

        return .{ .entered = true };
    }

    /// Exit interrupt context
    pub fn exit(self: *InterruptNestingGuard) void {
        if (self.entered) {
            if (interrupt_nesting_count > 0) {
                interrupt_nesting_count -= 1;
            }
            self.entered = false;
        }
    }

    /// Get current nesting depth
    pub fn getNestingDepth() u32 {
        return interrupt_nesting_count;
    }
};

/// Stack Overflow Detector
pub const StackGuard = struct {
    /// Check if we're approaching stack overflow
    pub fn checkStack() bool {
        const rsp = asm.readRsp();

        // Get current thread/process kernel stack base
        // TODO: Get actual stack base from thread/process structure
        const stack_base = getKernelStackBase();

        // Check if we're in the red zone
        if (rsp < stack_base + STACK_RED_ZONE_SIZE) {
            Basics.debug.print("WARNING: Stack approaching overflow (RSP: 0x{x}, base: 0x{x})\n",
                .{rsp, stack_base});
            return false;
        }

        return true;
    }

    /// Panic if stack overflow detected
    pub fn checkStackOrPanic() void {
        if (!checkStack()) {
            @panic("Stack overflow detected");
        }
    }
};

/// Get kernel stack base for current thread
fn getKernelStackBase() usize {
    // TODO: Integrate with actual thread/process structure
    // For now, return a conservative estimate based on RSP
    const rsp = asm.readRsp();
    // Assume 16KB kernel stacks, aligned to 16KB
    const stack_size = 16 * 1024;
    return (rsp & ~(stack_size - 1));
}

// ============================================================================
// PIC (Programmable Interrupt Controller) Support
// ============================================================================

pub const PIC = struct {
    pub const PIC1_COMMAND: u16 = 0x20;
    pub const PIC1_DATA: u16 = 0x21;
    pub const PIC2_COMMAND: u16 = 0xA0;
    pub const PIC2_DATA: u16 = 0xA1;

    pub const ICW1_INIT: u8 = 0x10;
    pub const ICW1_ICW4: u8 = 0x01;
    pub const ICW4_8086: u8 = 0x01;

    pub const EOI: u8 = 0x20;

    /// Remap PIC to avoid conflicts with CPU exceptions
    pub fn remap(offset1: u8, offset2: u8) void {
        const mask1 = asm.inb(PIC1_DATA);
        const mask2 = asm.inb(PIC2_DATA);

        // Start initialization
        asm.outb(PIC1_COMMAND, ICW1_INIT | ICW1_ICW4);
        asm.ioWait();
        asm.outb(PIC2_COMMAND, ICW1_INIT | ICW1_ICW4);
        asm.ioWait();

        // Set vector offsets
        asm.outb(PIC1_DATA, offset1);
        asm.ioWait();
        asm.outb(PIC2_DATA, offset2);
        asm.ioWait();

        // Tell master PIC about slave
        asm.outb(PIC1_DATA, 4);
        asm.ioWait();
        asm.outb(PIC2_DATA, 2);
        asm.ioWait();

        // Set mode
        asm.outb(PIC1_DATA, ICW4_8086);
        asm.ioWait();
        asm.outb(PIC2_DATA, ICW4_8086);
        asm.ioWait();

        // Restore masks
        asm.outb(PIC1_DATA, mask1);
        asm.outb(PIC2_DATA, mask2);
    }

    /// Send End of Interrupt signal
    pub fn sendEoi(irq: u8) void {
        if (irq >= 8) {
            asm.outb(PIC2_COMMAND, EOI);
        }
        asm.outb(PIC1_COMMAND, EOI);
    }

    /// Disable PIC (for APIC usage)
    pub fn disable() void {
        asm.outb(PIC1_DATA, 0xFF);
        asm.outb(PIC2_DATA, 0xFF);
    }

    /// Set IRQ mask
    pub fn setMask(irq: u8) void {
        const port = if (irq < 8) PIC1_DATA else PIC2_DATA;
        const bit = irq % 8;
        const value = asm.inb(port) | (@as(u8, 1) << @intCast(bit));
        asm.outb(port, value);
    }

    /// Clear IRQ mask
    pub fn clearMask(irq: u8) void {
        const port = if (irq < 8) PIC1_DATA else PIC2_DATA;
        const bit = irq % 8;
        const value = asm.inb(port) & ~(@as(u8, 1) << @intCast(bit));
        asm.outb(port, value);
    }
};

// ============================================================================
// Interrupt Registration System
// ============================================================================

pub const InterruptManager = struct {
    idt: Idt,
    handlers: [256]?IrqHandler,

    pub fn init() InterruptManager {
        return .{
            .idt = Idt.init(),
            .handlers = [_]?IrqHandler{null} ** 256,
        };
    }

    /// Install default exception handlers
    pub fn installDefaultHandlers(self: *InterruptManager) void {
        // Exceptions without error codes
        self.idt.setException(.DivideByZero, divideByZeroHandler);
        self.idt.setException(.Debug, debugHandler);
        self.idt.setException(.Breakpoint, breakpointHandler);
        self.idt.setException(.Overflow, overflowHandler);
        self.idt.setException(.BoundRangeExceeded, boundRangeExceededHandler);
        self.idt.setException(.InvalidOpcode, invalidOpcodeHandler);
        self.idt.setException(.DeviceNotAvailable, deviceNotAvailableHandler);
        self.idt.setException(.x87FloatingPoint, x87FloatingPointHandler);
        self.idt.setException(.MachineCheck, machineCheckHandler);
        self.idt.setException(.SIMDFloatingPoint, simdFloatingPointHandler);

        // Exceptions with error codes
        self.idt.setExceptionWithError(.DoubleFault, doubleFaultHandler);
        self.idt.setExceptionWithError(.InvalidTSS, invalidTssHandler);
        self.idt.setExceptionWithError(.SegmentNotPresent, segmentNotPresentHandler);
        self.idt.setExceptionWithError(.StackSegmentFault, stackSegmentFaultHandler);
        self.idt.setExceptionWithError(.GeneralProtectionFault, generalProtectionFaultHandler);
        self.idt.setExceptionWithError(.PageFault, pageFaultHandler);
        self.idt.setExceptionWithError(.AlignmentCheck, alignmentCheckHandler);
    }

    /// Register IRQ handler
    pub fn registerIrq(self: *InterruptManager, irq: u8, handler: IrqHandler) void {
        self.idt.setIrq(irq, handler);
        self.handlers[32 + irq] = handler;
        PIC.clearMask(irq);
    }

    /// Unregister IRQ handler
    pub fn unregisterIrq(self: *InterruptManager, irq: u8) void {
        PIC.setMask(irq);
        self.handlers[32 + irq] = null;
    }

    /// Load and activate IDT
    pub fn activate(self: *InterruptManager) void {
        self.idt.load();
    }
};

// ============================================================================
// Interrupt Statistics
// ============================================================================

pub const InterruptStats = struct {
    counts: [256]u64,
    total: u64,

    pub fn init() InterruptStats {
        return .{
            .counts = [_]u64{0} ** 256,
            .total = 0,
        };
    }

    pub fn record(self: *InterruptStats, vector: u8) void {
        self.counts[vector] += 1;
        self.total += 1;
    }

    pub fn get(self: InterruptStats, vector: u8) u64 {
        return self.counts[vector];
    }

    pub fn reset(self: *InterruptStats) void {
        self.counts = [_]u64{0} ** 256;
        self.total = 0;
    }
};

// Tests
test "IDT entry size" {
    try Basics.testing.expectEqual(@as(usize, 16), @sizeOf(IdtEntry));
    try Basics.testing.expectEqual(@as(usize, 128), @bitSizeOf(IdtEntry));
}

test "IDT entry creation" {
    const entry = IdtEntry.interrupt(0x1000, 0x08, 0, 0);
    try Basics.testing.expectEqual(@as(usize, 0x1000), entry.getHandler());
    try Basics.testing.expectEqual(@as(u16, 0x08), entry.selector);
    try Basics.testing.expectEqual(@as(u1, 1), entry.present);
}

test "exception error codes" {
    try Basics.testing.expect(Exception.PageFault.hasErrorCode());
    try Basics.testing.expect(Exception.DoubleFault.hasErrorCode());
    try Basics.testing.expect(!Exception.DivideByZero.hasErrorCode());
    try Basics.testing.expect(!Exception.Breakpoint.hasErrorCode());
}

test "page fault error parsing" {
    const error_code: PageFaultError = @bitCast(@as(u64, 0b111));
    try Basics.testing.expect(error_code.present);
    try Basics.testing.expect(error_code.write);
    try Basics.testing.expect(error_code.user);
}

test "interrupt manager" {
    var manager = InterruptManager.init();
    manager.installDefaultHandlers();

    // Verify default handlers are installed
    const divide_entry = manager.idt.entries[@intFromEnum(Exception.DivideByZero)];
    try Basics.testing.expectEqual(@as(u1, 1), divide_entry.present);
}
