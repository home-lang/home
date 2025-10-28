// CPU operations for OS development
// Provides low-level CPU instructions via inline assembly

/// Output a byte to an I/O port
///
/// Writes a single byte to the specified port using the x86 OUT instruction.
///
/// Parameters:
///   - port: I/O port address (0-65535)
///   - value: Byte value to write
pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [port] "N{dx}" (port),
          [value] "{al}" (value),
    );
}

/// Input a byte from an I/O port
///
/// Reads a single byte from the specified port using the x86 IN instruction.
///
/// Parameters:
///   - port: I/O port address (0-65535)
///
/// Returns: Byte value read from port
pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// Output a word (16-bit) to an I/O port
///
/// Writes a 16-bit value to the specified port using the x86 OUT instruction.
///
/// Parameters:
///   - port: I/O port address (0-65535)
///   - value: 16-bit value to write
pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [port] "N{dx}" (port),
          [value] "{ax}" (value),
    );
}

/// Input a word (16-bit) from an I/O port
///
/// Reads a 16-bit value from the specified port using the x86 IN instruction.
///
/// Parameters:
///   - port: I/O port address (0-65535)
///
/// Returns: 16-bit value read from port
pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

/// Output a double word (32-bit) to an I/O port
///
/// Writes a 32-bit value to the specified port using the x86 OUT instruction.
///
/// Parameters:
///   - port: I/O port address (0-65535)
///   - value: 32-bit value to write
pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [port] "N{dx}" (port),
          [value] "{eax}" (value),
    );
}

/// Input a double word (32-bit) from an I/O port
///
/// Reads a 32-bit value from the specified port using the x86 IN instruction.
///
/// Parameters:
///   - port: I/O port address (0-65535)
///
/// Returns: 32-bit value read from port
pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

/// Halt the CPU until the next interrupt
///
/// Puts the CPU into a low-power state until an interrupt occurs.
/// This is commonly used in idle loops to save power.
pub inline fn hlt() void {
    asm volatile ("hlt");
}

/// Disable interrupts (Clear Interrupt Flag)
///
/// Prevents the CPU from responding to maskable interrupts.
/// Use with caution - disabling interrupts for too long can cause system issues.
pub inline fn cli() void {
    asm volatile ("cli");
}

/// Enable interrupts (Set Interrupt Flag)
///
/// Allows the CPU to respond to maskable interrupts again.
pub inline fn sti() void {
    asm volatile ("sti");
}

/// Read the CPU timestamp counter
///
/// Returns the number of CPU cycles since reset using the RDTSC instruction.
///
/// Returns: 64-bit timestamp counter value
pub inline fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );

    return (@as(u64, high) << 32) | @as(u64, low);
}

/// Load the Interrupt Descriptor Table Register
///
/// Sets the IDTR to point to the IDT.
///
/// Parameters:
///   - idtr_ptr: Pointer to IDTR structure (6 bytes: 2-byte limit + 4/8-byte base)
pub inline fn lidt(idtr_ptr: *const anyopaque) void {
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (idtr_ptr),
    );
}

/// Load the Global Descriptor Table Register
///
/// Sets the GDTR to point to the GDT.
///
/// Parameters:
///   - gdtr_ptr: Pointer to GDTR structure (6 bytes: 2-byte limit + 4/8-byte base)
pub inline fn lgdt(gdtr_ptr: *const anyopaque) void {
    asm volatile ("lgdt (%[gdtr])"
        :
        : [gdtr] "r" (gdtr_ptr),
    );
}

/// Invalidate TLB entry for a specific page
///
/// Flushes the Translation Lookaside Buffer entry for the given virtual address.
///
/// Parameters:
///   - addr: Virtual address to invalidate
pub inline fn invlpg(addr: usize) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

/// Write to Control Register 3 (Page Directory Base)
///
/// Sets the CR3 register which controls page table addressing.
///
/// Parameters:
///   - value: Physical address of page directory
pub inline fn write_cr3(value: usize) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (value),
        : "memory"
    );
}

/// Read from Control Register 3 (Page Directory Base)
///
/// Gets the current CR3 register value.
///
/// Returns: Physical address of current page directory
pub inline fn read_cr3() usize {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> usize),
    );
}

/// Read from Control Register 2 (Page Fault Linear Address)
///
/// Gets the CR2 register which contains the address that caused a page fault.
///
/// Returns: Virtual address that caused the last page fault
pub inline fn read_cr2() usize {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> usize),
    );
}

/// No operation instruction
///
/// Does nothing, but prevents optimization from removing the instruction.
pub inline fn nop() void {
    asm volatile ("nop");
}

/// Pause instruction for spin-wait loops
///
/// Provides a hint to the CPU that we're in a spin-wait loop.
/// Improves performance and reduces power consumption.
pub inline fn pause() void {
    asm volatile ("pause");
}
