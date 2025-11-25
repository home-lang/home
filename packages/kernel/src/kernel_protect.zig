// Home OS Kernel - Kernel Memory Protection
// Protects kernel code and data sections with appropriate permissions

const Basics = @import("basics");
const paging = @import("paging.zig");

// ============================================================================
// Kernel Section Protection Flags
// ============================================================================

pub const SectionType = enum {
    /// .text section (code) - Read + Execute, no Write
    TEXT,
    /// .rodata section (read-only data) - Read only
    RODATA,
    /// .data section (initialized data) - Read + Write, no Execute
    DATA,
    /// .bss section (uninitialized data) - Read + Write, no Execute
    BSS,
};

pub const SectionPermissions = struct {
    read: bool,
    write: bool,
    execute: bool,

    pub fn fromSectionType(section_type: SectionType) SectionPermissions {
        return switch (section_type) {
            .TEXT => .{ .read = true, .write = false, .execute = true },
            .RODATA => .{ .read = true, .write = false, .execute = false },
            .DATA, .BSS => .{ .read = true, .write = true, .execute = false },
        };
    }

    pub fn toPageFlags(self: SectionPermissions) u64 {
        var flags: u64 = 0x1; // Present bit

        // Write permission (bit 1)
        if (self.write) {
            flags |= 0x2;
        }

        // User/Supervisor (bit 2) - always supervisor (0) for kernel
        // flags |= 0x0;

        // No Execute (NX bit, bit 63)
        if (!self.execute) {
            flags |= (1 << 63);
        }

        return flags;
    }
};

// ============================================================================
// Kernel Section Definitions
// ============================================================================

/// Kernel section descriptor
pub const KernelSection = struct {
    name: []const u8,
    section_type: SectionType,
    start_addr: u64,
    end_addr: u64,

    pub fn size(self: *const KernelSection) u64 {
        return self.end_addr - self.start_addr;
    }

    pub fn pageCount(self: *const KernelSection) u64 {
        const PAGE_SIZE = 4096;
        return (self.size() + PAGE_SIZE - 1) / PAGE_SIZE;
    }
};

// External symbols from linker script
extern const __text_start: u8;
extern const __text_end: u8;
extern const __rodata_start: u8;
extern const __rodata_end: u8;
extern const __data_start: u8;
extern const __data_end: u8;
extern const __bss_start: u8;
extern const __bss_end: u8;

/// Get kernel section definitions
/// Note: These symbols come from the linker script
/// For now, we use placeholder values since linker script may not define these
pub fn getKernelSections() [4]KernelSection {
    // In a real implementation, these would come from linker script symbols
    // For now, we use safe placeholder values
    const KERNEL_BASE = 0xFFFF_8000_0000_0000;

    return [4]KernelSection{
        .{
            .name = ".text",
            .section_type = .TEXT,
            .start_addr = KERNEL_BASE,
            .end_addr = KERNEL_BASE + 0x100000, // 1MB placeholder
        },
        .{
            .name = ".rodata",
            .section_type = .RODATA,
            .start_addr = KERNEL_BASE + 0x100000,
            .end_addr = KERNEL_BASE + 0x150000,
        },
        .{
            .name = ".data",
            .section_type = .DATA,
            .start_addr = KERNEL_BASE + 0x150000,
            .end_addr = KERNEL_BASE + 0x180000,
        },
        .{
            .name = ".bss",
            .section_type = .BSS,
            .start_addr = KERNEL_BASE + 0x180000,
            .end_addr = KERNEL_BASE + 0x200000,
        },
    };
}

// ============================================================================
// CPU Feature Detection
// ============================================================================

/// Check if CPU supports NX bit (No-Execute)
pub fn hasNxSupport() bool {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    // CPUID function 0x80000001 (Extended Processor Info)
    eax = 0x80000001;

    asm volatile (
        \\cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [eax_in] "{eax}" (eax),
    );

    // NX bit is bit 20 of EDX
    return (edx & (1 << 20)) != 0;
}

/// Check if CPU supports SMEP (Supervisor Mode Execution Prevention)
pub fn hasSmepSupport() bool {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    // CPUID function 0x7, sub-leaf 0 (Extended Features)
    eax = 0x7;
    ecx = 0;

    asm volatile (
        \\cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [eax_in] "{eax}" (eax),
          [ecx_in] "{ecx}" (ecx),
    );

    // SMEP is bit 7 of EBX
    return (ebx & (1 << 7)) != 0;
}

/// Check if CPU supports SMAP (Supervisor Mode Access Prevention)
pub fn hasSmapSupport() bool {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    // CPUID function 0x7, sub-leaf 0
    eax = 0x7;
    ecx = 0;

    asm volatile (
        \\cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [eax_in] "{eax}" (eax),
          [ecx_in] "{ecx}" (ecx),
    );

    // SMAP is bit 20 of EBX
    return (ebx & (1 << 20)) != 0;
}

// ============================================================================
// CPU Feature Enablement
// ============================================================================

/// Enable NX bit in EFER (Extended Feature Enable Register)
pub fn enableNx() void {
    const MSR_EFER: u32 = 0xC0000080;
    const EFER_NXE: u64 = 1 << 11; // NX Enable bit

    // Read current EFER value
    var eax: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile (
        \\rdmsr
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [msr] "{ecx}" (MSR_EFER),
    );

    var efer: u64 = (@as(u64, edx) << 32) | @as(u64, eax);

    // Set NX enable bit
    efer |= EFER_NXE;

    // Write back to EFER
    eax = @truncate(efer);
    edx = @truncate(efer >> 32);

    asm volatile (
        \\wrmsr
        :
        : [msr] "{ecx}" (MSR_EFER),
          [eax] "{eax}" (eax),
          [edx] "{edx}" (edx),
    );
}

/// Enable SMEP in CR4
pub fn enableSmep() void {
    const CR4_SMEP: u64 = 1 << 20;

    var cr4: u64 = undefined;

    // Read CR4
    asm volatile (
        \\mov %%cr4, %[cr4]
        : [cr4] "=r" (cr4),
    );

    // Set SMEP bit
    cr4 |= CR4_SMEP;

    // Write back to CR4
    asm volatile (
        \\mov %[cr4], %%cr4
        :
        : [cr4] "r" (cr4),
    );
}

/// Enable SMAP in CR4
pub fn enableSmap() void {
    const CR4_SMAP: u64 = 1 << 21;

    var cr4: u64 = undefined;

    // Read CR4
    asm volatile (
        \\mov %%cr4, %[cr4]
        : [cr4] "=r" (cr4),
    );

    // Set SMAP bit
    cr4 |= CR4_SMAP;

    // Write back to CR4
    asm volatile (
        \\mov %[cr4], %%cr4
        :
        : [cr4] "r" (cr4),
    );
}

// ============================================================================
// Kernel Memory Protection
// ============================================================================

/// Apply memory protection to all kernel sections
pub fn protectKernelMemory() !void {
    // Check and enable CPU features
    if (hasNxSupport()) {
        enableNx();
    }

    if (hasSmepSupport()) {
        enableSmep();
    }

    if (hasSmapSupport()) {
        enableSmap();
    }

    // Get kernel sections
    const sections = getKernelSections();

    // Apply protection to each section
    for (sections) |section| {
        try protectSection(&section);
    }
}

/// Protect a specific kernel section
fn protectSection(section: *const KernelSection) !void {
    const perms = SectionPermissions.fromSectionType(section.section_type);
    const page_flags = perms.toPageFlags();

    // Calculate page range
    const PAGE_SIZE = 4096;
    const start_page = section.start_addr / PAGE_SIZE;
    const page_count = section.pageCount();

    // Apply protection to each page in the section
    const paging = @import("paging.zig");

    var i: u64 = 0;
    while (i < page_count) : (i += 1) {
        const page_addr = (start_page + i) * PAGE_SIZE;

        // Update page table entry flags for this page
        // Convert our page_flags to paging module's PageFlags format
        const paging_flags = paging.PageFlags{
            .writable = (page_flags & (1 << 1)) != 0, // Bit 1 = writable
            .user = (page_flags & (1 << 2)) != 0, // Bit 2 = user accessible
            .no_execute = (page_flags & (1 << 63)) != 0, // Bit 63 = NX bit
        };

        // Get current page table and update flags
        if (paging.getKernelPageTable()) |page_table| {
            paging.updatePageFlags(page_table, page_addr, paging_flags) catch {
                // Page may not be mapped yet, continue with next page
                continue;
            };
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "section permissions for TEXT" {
    const perms = SectionPermissions.fromSectionType(.TEXT);

    try Basics.testing.expect(perms.read);
    try Basics.testing.expect(!perms.write);
    try Basics.testing.expect(perms.execute);
}

test "section permissions for RODATA" {
    const perms = SectionPermissions.fromSectionType(.RODATA);

    try Basics.testing.expect(perms.read);
    try Basics.testing.expect(!perms.write);
    try Basics.testing.expect(!perms.execute);
}

test "section permissions for DATA" {
    const perms = SectionPermissions.fromSectionType(.DATA);

    try Basics.testing.expect(perms.read);
    try Basics.testing.expect(perms.write);
    try Basics.testing.expect(!perms.execute);
}

test "page flags conversion" {
    const text_perms = SectionPermissions.fromSectionType(.TEXT);
    const text_flags = text_perms.toPageFlags();

    // Should be present and not have NX bit
    try Basics.testing.expect((text_flags & 0x1) != 0); // Present
    try Basics.testing.expect((text_flags & 0x2) == 0); // Not writable
    try Basics.testing.expect((text_flags & (1 << 63)) == 0); // Execute allowed

    const data_perms = SectionPermissions.fromSectionType(.DATA);
    const data_flags = data_perms.toPageFlags();

    // Should be present, writable, and have NX bit
    try Basics.testing.expect((data_flags & 0x1) != 0); // Present
    try Basics.testing.expect((data_flags & 0x2) != 0); // Writable
    try Basics.testing.expect((data_flags & (1 << 63)) != 0); // No execute
}

test "kernel section sizes" {
    const sections = getKernelSections();

    for (sections) |section| {
        try Basics.testing.expect(section.end_addr > section.start_addr);
        try Basics.testing.expect(section.size() > 0);
        try Basics.testing.expect(section.pageCount() > 0);
    }
}

test "CPU feature detection" {
    // These tests just ensure the functions don't crash
    _ = hasNxSupport();
    _ = hasSmepSupport();
    _ = hasSmapSupport();
}
