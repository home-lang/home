// Home Programming Language - ARM64/AArch64 Architecture Support
// For Raspberry Pi 3/4 and other ARM64 devices

const Basics = @import("basics");

// ============================================================================
// ARM64 System Registers
// ============================================================================

/// Current Exception Level
pub fn getCurrentEL() u8 {
    var el: u64 = undefined;
    asm volatile ("mrs %[el], CurrentEL"
        : [el] "=r" (el),
    );
    return @truncate((el >> 2) & 0x3);
}

/// Stack Pointer Selection
pub fn getSPSel() u64 {
    var sp_sel: u64 = undefined;
    asm volatile ("mrs %[sp], SPSel"
        : [sp] "=r" (sp_sel),
    );
    return sp_sel;
}

/// System Control Register (SCTLR_EL1)
pub const SCTLR_EL1 = struct {
    pub const M: u64 = 1 << 0; // MMU enable
    pub const A: u64 = 1 << 1; // Alignment check enable
    pub const C: u64 = 1 << 2; // Cache enable
    pub const SA: u64 = 1 << 3; // Stack alignment check
    pub const I: u64 = 1 << 12; // Instruction cache enable

    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], sctlr_el1"
            : [val] "=r" (value),
        );
        return value;
    }

    pub fn write(value: u64) void {
        asm volatile ("msr sctlr_el1, %[val]"
            :
            : [val] "r" (value),
        );
    }
};

/// Translation Control Register (TCR_EL1)
pub const TCR_EL1 = struct {
    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], tcr_el1"
            : [val] "=r" (value),
        );
        return value;
    }

    pub fn write(value: u64) void {
        asm volatile ("msr tcr_el1, %[val]"
            :
            : [val] "r" (value),
        );
    }
};

/// Memory Attribute Indirection Register (MAIR_EL1)
pub const MAIR_EL1 = struct {
    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], mair_el1"
            : [val] "=r" (value),
        );
        return value;
    }

    pub fn write(value: u64) void {
        asm volatile ("msr mair_el1, %[val]"
            :
            : [val] "r" (value),
        );
    }
};

/// Translation Table Base Register 0 (TTBR0_EL1)
pub const TTBR0_EL1 = struct {
    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], ttbr0_el1"
            : [val] "=r" (value),
        );
        return value;
    }

    pub fn write(value: u64) void {
        asm volatile ("msr ttbr0_el1, %[val]"
            :
            : [val] "r" (value),
        );
        asm volatile ("isb");
    }
};

/// Translation Table Base Register 1 (TTBR1_EL1)
pub const TTBR1_EL1 = struct {
    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], ttbr1_el1"
            : [val] "=r" (value),
        );
        return value;
    }

    pub fn write(value: u64) void {
        asm volatile ("msr ttbr1_el1, %[val]"
            :
            : [val] "r" (value),
        );
        asm volatile ("isb");
    }
};

// ============================================================================
// ARM64 Barriers
// ============================================================================

/// Data Memory Barrier
pub inline fn dmb() void {
    asm volatile ("dmb sy");
}

/// Data Synchronization Barrier
pub inline fn dsb() void {
    asm volatile ("dsb sy");
}

/// Instruction Synchronization Barrier
pub inline fn isb() void {
    asm volatile ("isb");
}

// ============================================================================
// ARM64 Cache Operations
// ============================================================================

pub const Cache = struct {
    /// Clean data cache by virtual address
    pub fn cleanDCacheVA(addr: u64) void {
        asm volatile ("dc cvac, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }

    /// Invalidate data cache by virtual address
    pub fn invalidateDCacheVA(addr: u64) void {
        asm volatile ("dc ivac, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }

    /// Clean and invalidate data cache by virtual address
    pub fn cleanInvalidateDCacheVA(addr: u64) void {
        asm volatile ("dc civac, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }

    /// Invalidate instruction cache
    pub fn invalidateICache() void {
        asm volatile ("ic iallu");
        isb();
    }

    /// Clean entire data cache
    pub fn cleanDCache() void {
        // Simplified - should iterate through cache levels
        asm volatile ("dc csw, xzr");
        dsb();
    }
};

// ============================================================================
// ARM64 Exception Handling
// ============================================================================

pub const ExceptionLevel = enum(u8) {
    EL0 = 0,
    EL1 = 1,
    EL2 = 2,
    EL3 = 3,
};

pub const ExceptionType = enum {
    Synchronous,
    IRQ,
    FIQ,
    SError,
};

/// Exception Syndrome Register (ESR_EL1)
pub const ESR_EL1 = struct {
    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], esr_el1"
            : [val] "=r" (value),
        );
        return value;
    }

    pub fn getEC(self: u64) u8 {
        return @truncate((self >> 26) & 0x3F);
    }

    pub fn getISS(self: u64) u32 {
        return @truncate(self & 0x1FFFFFF);
    }
};

/// Exception Link Register (ELR_EL1)
pub const ELR_EL1 = struct {
    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], elr_el1"
            : [val] "=r" (value),
        );
        return value;
    }

    pub fn write(value: u64) void {
        asm volatile ("msr elr_el1, %[val]"
            :
            : [val] "r" (value),
        );
    }
};

/// Fault Address Register (FAR_EL1)
pub const FAR_EL1 = struct {
    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], far_el1"
            : [val] "=r" (value),
        );
        return value;
    }
};

/// Saved Program Status Register (SPSR_EL1)
pub const SPSR_EL1 = struct {
    pub fn read() u64 {
        var value: u64 = undefined;
        asm volatile ("mrs %[val], spsr_el1"
            : [val] "=r" (value),
        );
        return value;
    }

    pub fn write(value: u64) void {
        asm volatile ("msr spsr_el1, %[val]"
            :
            : [val] "r" (value),
        );
    }
};

// ============================================================================
// ARM64 Interrupt Control
// ============================================================================

/// Disable interrupts (IRQ and FIQ)
pub inline fn disableInterrupts() void {
    asm volatile ("msr daifset, #0xF");
}

/// Enable interrupts (IRQ and FIQ)
pub inline fn enableInterrupts() void {
    asm volatile ("msr daifclr, #0xF");
}

/// Disable IRQ only
pub inline fn disableIRQ() void {
    asm volatile ("msr daifset, #0x2");
}

/// Enable IRQ only
pub inline fn enableIRQ() void {
    asm volatile ("msr daifclr, #0x2");
}

// ============================================================================
// ARM64 MMU Configuration
// ============================================================================

pub const PageTableEntry = packed struct(u64) {
    valid: bool,
    table_or_page: bool, // 1 = page, 0 = table (for L0-L2)
    attr_index: u3,
    ns: bool, // Non-secure
    ap: u2, // Access permissions
    sh: u2, // Shareability
    af: bool, // Access flag
    ng: bool, // Not global
    _reserved1: u4,
    _reserved2: u4,
    addr: u36, // Physical address [47:12]
    _reserved3: u4,
    _reserved4: u7,
    pxn: bool, // Privileged execute-never
    uxn: bool, // User execute-never
    _ignored: u4,

    pub fn init(phys_addr: u64, is_page: bool) PageTableEntry {
        return .{
            .valid = true,
            .table_or_page = is_page,
            .attr_index = 0,
            .ns = false,
            .ap = 0,
            .sh = 0,
            .af = true,
            .ng = false,
            ._reserved1 = 0,
            ._reserved2 = 0,
            .addr = @truncate((phys_addr >> 12) & 0xFFFFFFFFF),
            ._reserved3 = 0,
            ._reserved4 = 0,
            .pxn = false,
            .uxn = false,
            ._ignored = 0,
        };
    }
};

pub const MMU = struct {
    /// Enable MMU
    pub fn enable() void {
        var sctlr = SCTLR_EL1.read();
        sctlr |= SCTLR_EL1.M | SCTLR_EL1.C | SCTLR_EL1.I;
        SCTLR_EL1.write(sctlr);
        isb();
    }

    /// Disable MMU
    pub fn disable() void {
        var sctlr = SCTLR_EL1.read();
        sctlr &= ~(SCTLR_EL1.M | SCTLR_EL1.C);
        SCTLR_EL1.write(sctlr);
        isb();
    }

    /// Invalidate TLB
    pub fn invalidateTLB() void {
        asm volatile ("tlbi vmalle1");
        dsb();
        isb();
    }
};

// ============================================================================
// ARM64 Core Identification
// ============================================================================

/// Multiprocessor Affinity Register (MPIDR_EL1)
pub fn getCoreID() u64 {
    var mpidr: u64 = undefined;
    asm volatile ("mrs %[id], mpidr_el1"
        : [id] "=r" (mpidr),
    );
    return mpidr & 0xFF;
}

// ============================================================================
// ARM64 Performance Counters
// ============================================================================

pub const PMU = struct {
    /// Enable performance counters
    pub fn enable() void {
        // Enable user mode access
        asm volatile ("msr pmuserenr_el0, %[val]"
            :
            : [val] "r" (@as(u64, 1)),
        );
        // Enable all counters
        asm volatile ("msr pmcntenset_el0, %[val]"
            :
            : [val] "r" (@as(u64, 0x8000000F)),
        );
        // Enable cycle counter
        asm volatile ("msr pmcr_el0, %[val]"
            :
            : [val] "r" (@as(u64, 1)),
        );
    }

    /// Read cycle counter
    pub fn readCycleCount() u64 {
        var count: u64 = undefined;
        asm volatile ("mrs %[cnt], pmccntr_el0"
            : [cnt] "=r" (count),
        );
        return count;
    }
};

// ============================================================================
// ARM64 Wait For Event/Interrupt
// ============================================================================

pub inline fn wfe() void {
    asm volatile ("wfe");
}

pub inline fn wfi() void {
    asm volatile ("wfi");
}

pub inline fn sev() void {
    asm volatile ("sev");
}

// ============================================================================
// Tests
// ============================================================================

test "ARM64 exception level" {
    const el = getCurrentEL();
    try Basics.testing.expect(el <= 3);
}

test "ARM64 barriers compile" {
    dmb();
    dsb();
    isb();
}

test "ARM64 page table entry" {
    const entry = PageTableEntry.init(0x1000, true);
    try Basics.testing.expect(entry.valid);
    try Basics.testing.expect(entry.table_or_page);
    try Basics.testing.expectEqual(@as(u36, 1), entry.addr);
}
