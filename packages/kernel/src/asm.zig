// Home Programming Language - Inline Assembly Support
// Low-level CPU operations for OS development

const Basics = @import("basics");

// ============================================================================
// CPU I/O Port Operations
// ============================================================================

/// Output byte to port
pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [port] "N{dx}" (port),
          [value] "{al}" (value),
    );
}

/// Input byte from port
pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// Output word to port
pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [port] "N{dx}" (port),
          [value] "{ax}" (value),
    );
}

/// Input word from port
pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

/// Output dword to port
pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [port] "N{dx}" (port),
          [value] "{eax}" (value),
    );
}

/// Input dword from port
pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

/// I/O wait (small delay)
pub inline fn ioWait() void {
    outb(0x80, 0);
}

// ============================================================================
// CPU Control Instructions
// ============================================================================

/// Halt CPU until next interrupt
pub inline fn hlt() void {
    asm volatile ("hlt");
}

/// Halt CPU forever
pub fn hltForever() noreturn {
    while (true) {
        hlt();
    }
}

/// Pause instruction (for spin loops)
pub inline fn pause() void {
    asm volatile ("pause");
}

/// No operation
pub inline fn nop() void {
    asm volatile ("nop");
}

/// Memory fence
pub inline fn mfence() void {
    asm volatile ("mfence" ::: "memory");
}

/// Load fence
pub inline fn lfence() void {
    asm volatile ("lfence" ::: "memory");
}

/// Store fence
pub inline fn sfence() void {
    asm volatile ("sfence" ::: "memory");
}

// ============================================================================
// CPU Feature Detection (CPUID)
// ============================================================================

pub const CpuIdResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Execute CPUID instruction
pub fn cpuid(leaf: u32, subleaf: u32) CpuIdResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

/// Get CPU vendor string
pub fn getCpuVendor() [12]u8 {
    const result = cpuid(0, 0);
    var vendor: [12]u8 = undefined;

    Basics.mem.copy(u8, vendor[0..4], Basics.mem.asBytes(&result.ebx));
    Basics.mem.copy(u8, vendor[4..8], Basics.mem.asBytes(&result.edx));
    Basics.mem.copy(u8, vendor[8..12], Basics.mem.asBytes(&result.ecx));

    return vendor;
}

/// CPU features from CPUID
pub const CpuFeatures = struct {
    fpu: bool,          // x87 FPU
    tsc: bool,          // Time Stamp Counter
    msr: bool,          // Model Specific Registers
    apic: bool,         // APIC
    sse: bool,          // SSE
    sse2: bool,         // SSE2
    sse3: bool,         // SSE3
    ssse3: bool,        // SSSE3
    sse4_1: bool,       // SSE4.1
    sse4_2: bool,       // SSE4.2
    avx: bool,          // AVX
    avx2: bool,         // AVX2
    x2apic: bool,       // x2APIC
    pae: bool,          // Physical Address Extension
    pge: bool,          // Page Global Enable
    pat: bool,          // Page Attribute Table
    pse: bool,          // Page Size Extension
    syscall: bool,      // SYSCALL/SYSRET
    nx: bool,           // No-Execute bit

    pub fn detect() CpuFeatures {
        const leaf1 = cpuid(1, 0);
        const leaf7 = cpuid(7, 0);
        const extended = cpuid(0x80000001, 0);

        return .{
            .fpu = (leaf1.edx & (1 << 0)) != 0,
            .tsc = (leaf1.edx & (1 << 4)) != 0,
            .msr = (leaf1.edx & (1 << 5)) != 0,
            .apic = (leaf1.edx & (1 << 9)) != 0,
            .sse = (leaf1.edx & (1 << 25)) != 0,
            .sse2 = (leaf1.edx & (1 << 26)) != 0,
            .sse3 = (leaf1.ecx & (1 << 0)) != 0,
            .ssse3 = (leaf1.ecx & (1 << 9)) != 0,
            .sse4_1 = (leaf1.ecx & (1 << 19)) != 0,
            .sse4_2 = (leaf1.ecx & (1 << 20)) != 0,
            .avx = (leaf1.ecx & (1 << 28)) != 0,
            .avx2 = (leaf7.ebx & (1 << 5)) != 0,
            .x2apic = (leaf1.ecx & (1 << 21)) != 0,
            .pae = (leaf1.edx & (1 << 6)) != 0,
            .pge = (leaf1.edx & (1 << 13)) != 0,
            .pat = (leaf1.edx & (1 << 16)) != 0,
            .pse = (leaf1.edx & (1 << 3)) != 0,
            .syscall = (extended.edx & (1 << 11)) != 0,
            .nx = (extended.edx & (1 << 20)) != 0,
        };
    }
};

// ============================================================================
// Control Registers
// ============================================================================

/// Read CR0
pub inline fn readCr0() u64 {
    return asm volatile ("mov %%cr0, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Write CR0
pub inline fn writeCr0(value: u64) void {
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (value),
    );
}

/// Read CR2 (page fault address)
pub inline fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Read CR3 (page table base)
pub inline fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Write CR3 (page table base)
pub inline fn writeCr3(value: u64) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (value),
        : "memory"
    );
}

/// Read CR4
pub inline fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Write CR4
pub inline fn writeCr4(value: u64) void {
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "r" (value),
    );
}

// ============================================================================
// Segment Registers
// ============================================================================

/// Read CS
pub inline fn readCs() u16 {
    return asm volatile ("mov %%cs, %[result]"
        : [result] "=r" (-> u16),
    );
}

/// Read DS
pub inline fn readDs() u16 {
    return asm volatile ("mov %%ds, %[result]"
        : [result] "=r" (-> u16),
    );
}

/// Write DS
pub inline fn writeDs(value: u16) void {
    asm volatile ("mov %[value], %%ds"
        :
        : [value] "r" (value),
    );
}

/// Read ES
pub inline fn readEs() u16 {
    return asm volatile ("mov %%es, %[result]"
        : [result] "=r" (-> u16),
    );
}

/// Write ES
pub inline fn writeEs(value: u16) void {
    asm volatile ("mov %[value], %%es"
        :
        : [value] "r" (value),
    );
}

/// Read SS
pub inline fn readSs() u16 {
    return asm volatile ("mov %%ss, %[result]"
        : [result] "=r" (-> u16),
    );
}

/// Write SS
pub inline fn writeSs(value: u16) void {
    asm volatile ("mov %[value], %%ss"
        :
        : [value] "r" (value),
    );
}

// ============================================================================
// Model Specific Registers (MSR)
// ============================================================================

/// Read MSR
pub fn rdmsr(msr: u32) u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("rdmsr"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [msr] "{ecx}" (msr),
    );

    return (@as(u64, edx) << 32) | eax;
}

/// Write MSR
pub fn wrmsr(msr: u32, value: u64) void {
    const eax: u32 = @truncate(value);
    const edx: u32 = @truncate(value >> 32);

    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [eax] "{eax}" (eax),
          [edx] "{edx}" (edx),
    );
}

// Common MSRs
pub const MSR = struct {
    pub const IA32_APIC_BASE: u32 = 0x1B;
    pub const IA32_EFER: u32 = 0xC0000080;
    pub const IA32_STAR: u32 = 0xC0000081;
    pub const IA32_LSTAR: u32 = 0xC0000082;
    pub const IA32_CSTAR: u32 = 0xC0000083;
    pub const IA32_FMASK: u32 = 0xC0000084;
    pub const IA32_FS_BASE: u32 = 0xC0000100;
    pub const IA32_GS_BASE: u32 = 0xC0000101;
    pub const IA32_KERNEL_GS_BASE: u32 = 0xC0000102;
};

// ============================================================================
// Interrupt Control
// ============================================================================

/// Enable interrupts
pub inline fn sti() void {
    asm volatile ("sti");
}

/// Disable interrupts
pub inline fn cli() void {
    asm volatile ("cli");
}

/// Read interrupt flag
pub inline fn readFlags() u64 {
    return asm volatile ("pushfq; popq %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Read stack pointer (RSP)
pub inline fn readRsp() u64 {
    return asm volatile ("movq %%rsp, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Write flags
pub inline fn writeFlags(flags: u64) void {
    asm volatile ("pushq %[flags]; popfq"
        :
        : [flags] "r" (flags),
        : "cc"
    );
}

/// Check if interrupts are enabled
pub fn interruptsEnabled() bool {
    return (readFlags() & (1 << 9)) != 0;
}

/// Execute with interrupts disabled
pub fn withoutInterrupts(comptime f: fn () void) void {
    const enabled = interruptsEnabled();
    cli();
    defer if (enabled) sti();
    f();
}

// ============================================================================
// Time Stamp Counter
// ============================================================================

/// Read TSC
pub inline fn rdtsc() u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("rdtsc"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
    );

    return (@as(u64, edx) << 32) | eax;
}

/// Read TSC with processor ID
pub fn rdtscp() struct { tsc: u64, processor_id: u32 } {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    var ecx: u32 = undefined;

    asm volatile ("rdtscp"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
          [ecx] "={ecx}" (ecx),
    );

    return .{
        .tsc = (@as(u64, edx) << 32) | eax,
        .processor_id = ecx,
    };
}

// ============================================================================
// Cache Control
// ============================================================================

/// Invalidate TLB entry
pub inline fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

/// Write back and invalidate cache
pub inline fn wbinvd() void {
    asm volatile ("wbinvd" ::: "memory");
}

/// Invalidate cache
pub inline fn invd() void {
    asm volatile ("invd" ::: "memory");
}

/// Flush cache line
pub inline fn clflush(addr: u64) void {
    asm volatile ("clflush (%[addr])"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

// ============================================================================
// Descriptor Tables
// ============================================================================

pub const DescriptorTablePointer = packed struct {
    limit: u16,
    base: u64,
};

/// Load GDT
pub inline fn lgdt(gdtr: *const DescriptorTablePointer) void {
    asm volatile ("lgdt (%[gdtr])"
        :
        : [gdtr] "r" (gdtr),
    );
}

/// Store GDT
pub fn sgdt() DescriptorTablePointer {
    var gdtr: DescriptorTablePointer = undefined;
    asm volatile ("sgdt %[gdtr]"
        : [gdtr] "=m" (gdtr),
    );
    return gdtr;
}

/// Load IDT
pub inline fn lidt(idtr: *const DescriptorTablePointer) void {
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (idtr),
    );
}

/// Store IDT
pub fn sidt() DescriptorTablePointer {
    var idtr: DescriptorTablePointer = undefined;
    asm volatile ("sidt %[idtr]"
        : [idtr] "=m" (idtr),
    );
    return idtr;
}

/// Load Task Register
pub inline fn ltr(selector: u16) void {
    asm volatile ("ltr %[selector]"
        :
        : [selector] "r" (selector),
    );
}

// ============================================================================
// Atomic Operations
// ============================================================================

/// Atomic compare and exchange
pub fn cmpxchg(comptime T: type, ptr: *volatile T, expected: T, desired: T) T {
    return asm volatile ("lock cmpxchg %[desired], %[ptr]"
        : [result] "={eax}" (-> T),
          [ptr] "+m" (ptr.*),
        : [desired] "r" (desired),
          [expected] "{eax}" (expected),
        : "cc", "memory"
    );
}

/// Atomic exchange
pub fn xchg(comptime T: type, ptr: *volatile T, value: T) T {
    return asm volatile ("xchg %[value], %[ptr]"
        : [result] "=r" (-> T),
          [ptr] "+m" (ptr.*),
        : [value] "0" (value),
        : "memory"
    );
}

/// Atomic add and fetch
pub fn xadd(comptime T: type, ptr: *volatile T, value: T) T {
    return asm volatile ("lock xadd %[value], %[ptr]"
        : [result] "=r" (-> T),
          [ptr] "+m" (ptr.*),
        : [value] "0" (value),
        : "cc", "memory"
    );
}

// Tests
test "I/O port operations" {
    // Can't actually test port I/O in userspace
    // But we can verify the functions compile
    _ = outb;
    _ = inb;
    _ = outw;
    _ = inw;
    _ = outl;
    _ = inl;
}

test "CPU feature detection" {
    const features = CpuFeatures.detect();

    // Most modern CPUs have these
    try Basics.testing.expect(features.fpu);
    try Basics.testing.expect(features.tsc);
}

test "control register operations" {
    _ = readCr0;
    _ = readCr3;
    _ = readCr4;
}
