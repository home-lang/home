// Home Programming Language - ACPI (Advanced Configuration and Power Interface) Parser
// Parsing ACPI tables for hardware discovery and configuration

const Basics = @import("basics");
const memory = @import("memory.zig");
const sync = @import("sync.zig");

// ============================================================================
// RSDP (Root System Description Pointer)
// ============================================================================

pub const Rsdp = extern struct {
    signature: [8]u8, // "RSD PTR "
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,

    // ACPI 2.0+ fields
    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,

    /// Validate RSDP checksum
    pub fn validateChecksum(self: *const Rsdp) bool {
        const bytes: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;

        // First 20 bytes for ACPI 1.0
        for (0..20) |i| {
            sum +%= bytes[i];
        }

        if (sum != 0) return false;

        // Extended checksum for ACPI 2.0+
        if (self.revision >= 2) {
            sum = 0;
            for (0..self.length) |i| {
                sum +%= bytes[i];
            }
            return sum == 0;
        }

        return true;
    }

    /// Check if this is a valid RSDP
    pub fn isValid(self: *const Rsdp) bool {
        const sig = "RSD PTR ";
        if (!Basics.mem.eql(u8, &self.signature, sig)) {
            return false;
        }
        return self.validateChecksum();
    }
};

// ============================================================================
// SDT Header (System Description Table Header)
// ============================================================================

pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    /// Validate table checksum
    pub fn validateChecksum(self: *const SdtHeader) bool {
        const bytes: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;

        for (0..self.length) |i| {
            sum +%= bytes[i];
        }

        return sum == 0;
    }

    /// Get signature as string
    pub fn getSignature(self: *const SdtHeader) []const u8 {
        return &self.signature;
    }

    /// Check if signature matches
    pub fn hasSignature(self: *const SdtHeader, sig: []const u8) bool {
        return Basics.mem.eql(u8, &self.signature, sig);
    }
};

// ============================================================================
// RSDT (Root System Description Table)
// ============================================================================

pub const Rsdt = extern struct {
    header: SdtHeader,
    // Followed by array of u32 pointers to other SDTs

    /// Get number of table pointers
    pub fn getTableCount(self: *const Rsdt) u32 {
        return (self.header.length - @sizeOf(SdtHeader)) / 4;
    }

    /// Get pointer to table at index
    pub fn getTablePointer(self: *const Rsdt, index: u32) ?u32 {
        if (index >= self.getTableCount()) return null;

        const ptr_array: [*]const u32 = @ptrCast(@as([*]const u8, @ptrCast(&self.header)) + @sizeOf(SdtHeader));
        return ptr_array[index];
    }
};

// ============================================================================
// XSDT (Extended System Description Table) - ACPI 2.0+
// ============================================================================

pub const Xsdt = extern struct {
    header: SdtHeader,
    // Followed by array of u64 pointers to other SDTs

    /// Get number of table pointers
    pub fn getTableCount(self: *const Xsdt) u32 {
        return (self.header.length - @sizeOf(SdtHeader)) / 8;
    }

    /// Get pointer to table at index
    pub fn getTablePointer(self: *const Xsdt, index: u32) ?u64 {
        if (index >= self.getTableCount()) return null;

        const ptr_array: [*]const u64 = @ptrCast(@as([*]const u8, @ptrCast(&self.header)) + @sizeOf(SdtHeader));
        return ptr_array[index];
    }
};

// ============================================================================
// MADT (Multiple APIC Description Table)
// ============================================================================

pub const Madt = extern struct {
    header: SdtHeader,
    local_apic_address: u32,
    flags: u32,
    // Followed by variable-length Interrupt Controller Structures

    /// Get pointer to interrupt controller structures
    pub fn getEntries(self: *const Madt) [*]const u8 {
        return @as([*]const u8, @ptrCast(&self.header)) + @sizeOf(Madt);
    }

    /// Get total size of interrupt controller structures
    pub fn getEntriesSize(self: *const Madt) u32 {
        return self.header.length - @sizeOf(Madt);
    }
};

/// MADT Entry Type
pub const MadtEntryType = enum(u8) {
    LocalApic = 0,
    IoApic = 1,
    InterruptSourceOverride = 2,
    NmiSource = 3,
    LocalApicNmi = 4,
    LocalApicAddressOverride = 5,
    IoSapic = 6,
    LocalSapic = 7,
    PlatformInterruptSources = 8,
    ProcessorLocalX2Apic = 9,
    LocalX2ApicNmi = 10,
    _,
};

/// MADT Entry Header
pub const MadtEntryHeader = extern struct {
    entry_type: u8,
    length: u8,
};

/// Local APIC Structure
pub const MadtLocalApic = extern struct {
    header: MadtEntryHeader,
    processor_id: u8,
    apic_id: u8,
    flags: u32, // Bit 0: Processor Enabled, Bit 1: Online Capable

    pub fn isEnabled(self: *const MadtLocalApic) bool {
        return (self.flags & 1) != 0;
    }
};

/// I/O APIC Structure
pub const MadtIoApic = extern struct {
    header: MadtEntryHeader,
    ioapic_id: u8,
    reserved: u8,
    ioapic_address: u32,
    global_system_interrupt_base: u32,
};

/// Interrupt Source Override
pub const MadtInterruptSourceOverride = extern struct {
    header: MadtEntryHeader,
    bus_source: u8, // Always 0 (ISA)
    irq_source: u8, // ISA IRQ
    global_system_interrupt: u32,
    flags: u16,

    pub fn isActiveLow(self: *const MadtInterruptSourceOverride) bool {
        return (self.flags & 0x3) == 0x3 or (self.flags & 0x3) == 0x1;
    }

    pub fn isLevelTriggered(self: *const MadtInterruptSourceOverride) bool {
        return ((self.flags >> 2) & 0x3) == 0x3 or ((self.flags >> 2) & 0x3) == 0x1;
    }
};

/// Local APIC NMI Structure
pub const MadtLocalApicNmi = extern struct {
    header: MadtEntryHeader,
    processor_id: u8,
    flags: u16,
    lint: u8, // Local APIC LINT# (0 or 1)
};

// ============================================================================
// FADT (Fixed ACPI Description Table)
// ============================================================================

pub const Fadt = extern struct {
    header: SdtHeader,
    firmware_ctrl: u32,
    dsdt: u32,
    reserved: u8,
    preferred_pm_profile: u8,
    sci_interrupt: u16,
    smi_command_port: u32,
    acpi_enable: u8,
    acpi_disable: u8,
    s4bios_req: u8,
    pstate_control: u8,
    pm1a_event_block: u32,
    pm1b_event_block: u32,
    pm1a_control_block: u32,
    pm1b_control_block: u32,
    pm2_control_block: u32,
    pm_timer_block: u32,
    gpe0_block: u32,
    gpe1_block: u32,
    pm1_event_length: u8,
    pm1_control_length: u8,
    pm2_control_length: u8,
    pm_timer_length: u8,
    gpe0_length: u8,
    gpe1_length: u8,
    gpe1_base: u8,
    cstate_control: u8,
    worst_c2_latency: u16,
    worst_c3_latency: u16,
    flush_size: u16,
    flush_stride: u16,
    duty_offset: u8,
    duty_width: u8,
    day_alarm: u8,
    month_alarm: u8,
    century: u8,
    boot_arch_flags: u16,
    reserved2: u8,
    flags: u32,
    // ... more fields for ACPI 2.0+
};

// ============================================================================
// HPET (High Precision Event Timer)
// ============================================================================

pub const Hpet = extern struct {
    header: SdtHeader,
    hardware_rev_id: u8,
    comparator_count: u8, // bits 0-4
    counter_size: u8, // bit 5
    reserved: u8,
    legacy_replacement: u8,
    pci_vendor_id: u16,
    address_space_id: u8,
    register_bit_width: u8,
    register_bit_offset: u8,
    reserved2: u8,
    address: u64,
    hpet_number: u8,
    minimum_tick: u16,
    page_protection: u8,

    pub fn getComparatorCount(self: *const Hpet) u8 {
        return (self.comparator_count & 0x1F) + 1;
    }

    pub fn is64Bit(self: *const Hpet) bool {
        return (self.counter_size & 0x20) != 0;
    }

    pub fn supportsLegacyReplacement(self: *const Hpet) bool {
        return self.legacy_replacement != 0;
    }
};

// ============================================================================
// ACPI Context
// ============================================================================

pub const AcpiContext = struct {
    rsdp: ?*const Rsdp,
    rsdt: ?*const Rsdt,
    xsdt: ?*const Xsdt,
    madt: ?*const Madt,
    fadt: ?*const Fadt,
    hpet: ?*const Hpet,
    lock: sync.Spinlock,

    pub fn init() AcpiContext {
        return .{
            .rsdp = null,
            .rsdt = null,
            .xsdt = null,
            .madt = null,
            .fadt = null,
            .hpet = null,
            .lock = sync.Spinlock.init(),
        };
    }

    /// Find RSDP in BIOS memory
    pub fn findRsdp(self: *AcpiContext) !void {
        self.lock.acquire();
        defer self.lock.release();

        // Search EBDA (Extended BIOS Data Area)
        const ebda_base: u32 = @as(*const u16, @ptrFromInt(0x40E)).* << 4;
        if (ebda_base != 0) {
            if (self.searchRsdpInRange(ebda_base, ebda_base + 1024)) |rsdp| {
                self.rsdp = rsdp;
                return;
            }
        }

        // Search main BIOS area (0xE0000 - 0xFFFFF)
        if (self.searchRsdpInRange(0xE0000, 0x100000)) |rsdp| {
            self.rsdp = rsdp;
            return;
        }

        return error.RsdpNotFound;
    }

    /// Search for RSDP in memory range
    fn searchRsdpInRange(self: *AcpiContext, start: u32, end: u32) ?*const Rsdp {
        _ = self;
        var addr = start;
        while (addr < end) : (addr += 16) {
            const rsdp: *const Rsdp = @ptrFromInt(addr);
            if (rsdp.isValid()) {
                return rsdp;
            }
        }
        return null;
    }

    /// Parse RSDT/XSDT and find tables
    pub fn parseTables(self: *AcpiContext) !void {
        self.lock.acquire();
        defer self.lock.release();

        const rsdp = self.rsdp orelse return error.NoRsdp;

        // Prefer XSDT for ACPI 2.0+
        if (rsdp.revision >= 2 and rsdp.xsdt_address != 0) {
            self.xsdt = @ptrFromInt(rsdp.xsdt_address);
            try self.parseXsdt();
        } else {
            self.rsdt = @ptrFromInt(rsdp.rsdt_address);
            try self.parseRsdt();
        }
    }

    /// Parse RSDT
    fn parseRsdt(self: *AcpiContext) !void {
        const rsdt = self.rsdt orelse return error.NoRsdt;

        if (!rsdt.header.validateChecksum()) {
            return error.InvalidChecksum;
        }

        const count = rsdt.getTableCount();
        for (0..count) |i| {
            if (rsdt.getTablePointer(@intCast(i))) |ptr| {
                const header: *const SdtHeader = @ptrFromInt(ptr);
                try self.processTable(header);
            }
        }
    }

    /// Parse XSDT
    fn parseXsdt(self: *AcpiContext) !void {
        const xsdt = self.xsdt orelse return error.NoXsdt;

        if (!xsdt.header.validateChecksum()) {
            return error.InvalidChecksum;
        }

        const count = xsdt.getTableCount();
        for (0..count) |i| {
            if (xsdt.getTablePointer(@intCast(i))) |ptr| {
                const header: *const SdtHeader = @ptrFromInt(ptr);
                try self.processTable(header);
            }
        }
    }

    /// Process individual ACPI table
    fn processTable(self: *AcpiContext, header: *const SdtHeader) !void {
        if (!header.validateChecksum()) {
            return error.InvalidChecksum;
        }

        if (header.hasSignature("APIC")) {
            self.madt = @ptrCast(header);
        } else if (header.hasSignature("FACP")) {
            self.fadt = @ptrCast(header);
        } else if (header.hasSignature("HPET")) {
            self.hpet = @ptrCast(header);
        }
    }

    /// Enumerate MADT entries
    pub fn enumerateMadt(self: *AcpiContext, callback: *const fn (*const MadtEntryHeader) void) void {
        const madt = self.madt orelse return;

        var offset: u32 = 0;
        const entries = madt.getEntries();
        const total_size = madt.getEntriesSize();

        while (offset < total_size) {
            const entry: *const MadtEntryHeader = @ptrCast(entries + offset);
            callback(entry);
            offset += entry.length;
        }
    }
};

// ============================================================================
// Global ACPI Context
// ============================================================================

var acpi_context: ?AcpiContext = null;
var acpi_lock = sync.Spinlock.init();

/// Initialize ACPI
pub fn init() !void {
    acpi_lock.acquire();
    defer acpi_lock.release();

    var ctx = AcpiContext.init();

    // Find and parse RSDP
    try ctx.findRsdp();

    // Parse all tables
    try ctx.parseTables();

    acpi_context = ctx;
}

/// Get ACPI context
pub fn getContext() ?*AcpiContext {
    if (acpi_context) |*ctx| {
        return ctx;
    }
    return null;
}

/// Get MADT table
pub fn getMadt() ?*const Madt {
    if (getContext()) |ctx| {
        return ctx.madt;
    }
    return null;
}

/// Get FADT table
pub fn getFadt() ?*const Fadt {
    if (getContext()) |ctx| {
        return ctx.fadt;
    }
    return null;
}

/// Get HPET table
pub fn getHpet() ?*const Hpet {
    if (getContext()) |ctx| {
        return ctx.hpet;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "SDT header size" {
    try Basics.testing.expectEqual(@as(usize, 36), @sizeOf(SdtHeader));
}

test "RSDP size" {
    try Basics.testing.expectEqual(@as(usize, 36), @sizeOf(Rsdp));
}

test "MADT entry types" {
    try Basics.testing.expectEqual(@as(u8, 0), @intFromEnum(MadtEntryType.LocalApic));
    try Basics.testing.expectEqual(@as(u8, 1), @intFromEnum(MadtEntryType.IoApic));
    try Basics.testing.expectEqual(@as(u8, 2), @intFromEnum(MadtEntryType.InterruptSourceOverride));
}
