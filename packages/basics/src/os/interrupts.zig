// Interrupt management for OS development
// Provides structures and functions for setting up the Interrupt Descriptor Table (IDT)

const cpu = @import("cpu.zig");
const serial = @import("serial.zig");

/// IDT Entry structure (16 bytes, 128 bits)
///
/// Represents a single entry in the Interrupt Descriptor Table.
/// Each entry describes how to handle a specific interrupt/exception.
pub const IdtEntry = packed struct(u128) {
    /// Bits 0-15: Lower 16 bits of handler address
    offset_low: u16,

    /// Bits 16-31: Code segment selector (must point to valid GDT entry)
    selector: u16,

    /// Bits 32-34: Interrupt Stack Table offset (0-7)
    ist: u3,

    /// Bits 35-39: Reserved (must be zero)
    reserved1: u5,

    /// Bits 40-43: Gate type (0xE = Interrupt Gate, 0xF = Trap Gate)
    gate_type: u4,

    /// Bit 44: Must be zero
    zero: u1,

    /// Bits 45-46: Descriptor Privilege Level (0 = kernel, 3 = user)
    dpl: u2,

    /// Bit 47: Present bit (1 = entry is valid)
    present: u1,

    /// Bits 48-63: Middle 16 bits of handler address
    offset_middle: u16,

    /// Bits 64-95: Upper 32 bits of handler address
    offset_high: u32,

    /// Bits 96-127: Reserved (must be zero)
    reserved2: u32,
};

/// IDTR structure (10 bytes)
///
/// Structure loaded into the IDTR register via LIDT instruction.
/// Contains the base address and limit of the IDT.
pub const Idtr = packed struct {
    /// Size of IDT in bytes minus 1 (for 256 entries: 256*16-1 = 4095)
    limit: u16,

    /// Base address of the IDT
    base: u64,
};

/// The Interrupt Descriptor Table (256 entries)
///
/// Stores handlers for all 256 possible x86-64 interrupts:
/// - 0-31: CPU exceptions (divide by zero, page fault, etc.)
/// - 32-47: Hardware interrupts (IRQs remapped from PIC)
/// - 48-255: Available for custom interrupts
var idt: [256]IdtEntry align(16) = undefined;

/// IDTR register value
var idtr: Idtr align(16) = undefined;

/// Create an IDT entry
///
/// Builds a properly formatted IDT entry for an interrupt handler.
///
/// Parameters:
///   - handler: Address of interrupt handler function
///   - selector: GDT code segment selector (usually 0x08)
///   - gate_type: Type of gate (0xE for interrupt, 0xF for trap)
///   - dpl: Privilege level (0-3)
///
/// Returns: Initialized IDT entry
pub fn create_entry(handler: u64, selector: u16, gate_type: u4, dpl: u2) IdtEntry {
    return IdtEntry{
        .offset_low = @truncate(handler & 0xFFFF),
        .selector = selector,
        .ist = 0,
        .reserved1 = 0,
        .gate_type = gate_type,
        .zero = 0,
        .dpl = dpl,
        .present = 1,
        .offset_middle = @truncate((handler >> 16) & 0xFFFF),
        .offset_high = @truncate((handler >> 32) & 0xFFFFFFFF),
        .reserved2 = 0,
    };
}

/// Dummy interrupt handler (does nothing)
///
/// Used for interrupts that don't have specific handlers yet.
export fn dummy_handler() callconv(.Naked) void {
    asm volatile (
        \\iretq
    );
}

/// Division by Zero Exception Handler (INT 0)
export fn division_error_handler() callconv(.Naked) void {
    asm volatile (
        \\pushq $0         // Error code (dummy)
        \\pushq $0         // Interrupt number
        \\jmp common_handler
    );
}

/// Page Fault Exception Handler (INT 14)
export fn page_fault_handler() callconv(.Naked) void {
    asm volatile (
        \\pushq $14        // Interrupt number
        \\jmp common_handler
    );
}

/// General Protection Fault Handler (INT 13)
export fn general_protection_fault_handler() callconv(.Naked) void {
    asm volatile (
        \\pushq $13        // Interrupt number
        \\jmp common_handler
    );
}

/// Common interrupt handler
///
/// Called by all interrupt stubs. Handles the interrupt and returns.
export fn common_handler() callconv(.Naked) void {
    asm volatile (
        // Save all registers
        \\pushq %%rax
        \\pushq %%rbx
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%rbp
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        // Handle interrupt (call Zig function)
        \\call handle_interrupt
        \\
        // Restore all registers
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rbp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\
        // Remove error code and interrupt number from stack
        \\addq $16, %%rsp
        \\
        // Return from interrupt
        \\iretq
    );
}

/// Handle interrupt in Zig code
///
/// Called from assembly interrupt handler. Logs interrupt info.
export fn handle_interrupt() void {
    serial.write("[INTERRUPT] Interrupt received\n");
}

/// Initialize the IDT
///
/// Sets up the Interrupt Descriptor Table with basic exception handlers.
/// Must be called before enabling interrupts.
pub fn init_idt() void {
    serial.write("Setting up IDT...\n");

    // Zero out the entire IDT
    @memset(@as([*]u8, @ptrCast(&idt))[0..(@sizeOf(@TypeOf(idt)))], 0);

    // Set up exception handlers (interrupts 0-31)
    const code_segment: u16 = 0x08; // GDT code segment selector

    // CPU Exception handlers
    idt[0] = create_entry(@intFromPtr(&division_error_handler), code_segment, 0xE, 0);
    idt[13] = create_entry(@intFromPtr(&general_protection_fault_handler), code_segment, 0xE, 0);
    idt[14] = create_entry(@intFromPtr(&page_fault_handler), code_segment, 0xE, 0);

    // Set all other entries to dummy handler
    var i: usize = 1;
    while (i < 256) : (i += 1) {
        if (i != 13 and i != 14) { // Skip ones we already set
            idt[i] = create_entry(@intFromPtr(&dummy_handler), code_segment, 0xE, 0);
        }
    }

    serial.write("IDT entries configured\n");

    // Set up IDTR
    idtr = Idtr{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    serial.write("Loading IDTR...\n");

    // Load IDT register
    cpu.lidt(&idtr);

    serial.write("IDT loaded successfully\n");
}

/// Test division by zero exception
///
/// Triggers INT 0 by dividing by zero. Used for testing IDT setup.
pub fn test_divide_by_zero() void {
    serial.write("Testing division by zero exception...\n");

    // This should trigger the division error handler
    const zero: u32 = 0;
    const result: u32 = 42 / zero;
    _ = result;
}
