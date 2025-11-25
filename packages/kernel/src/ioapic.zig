// Home Programming Language - I/O Advanced Programmable Interrupt Controller
// I/O APIC for interrupt routing in modern systems

const Basics = @import("basics");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// ============================================================================
// IOAPIC Register Offsets
// ============================================================================

const IOREGSEL: u32 = 0x00; // Register Select (index)
const IOWIN: u32 = 0x10; // Register Window (data)

// IOAPIC Registers (accessed via IOREGSEL/IOWIN)
pub const IoapicReg = struct {
    pub const ID: u8 = 0x00; // IOAPIC ID
    pub const VER: u8 = 0x01; // IOAPIC Version
    pub const ARB: u8 = 0x02; // IOAPIC Arbitration ID
    pub const REDTBL_BASE: u8 = 0x10; // Redirection Table Base (0x10-0x3F)
};

// ============================================================================
// Redirection Table Entry
// ============================================================================

pub const RedirectionEntry = packed struct(u64) {
    /// Interrupt vector (0-255)
    vector: u8,
    /// Delivery mode (000=Fixed, 001=Lowest Priority, etc.)
    delivery_mode: u3,
    /// Destination mode (0=Physical, 1=Logical)
    dest_mode: u1,
    /// Delivery status (0=Idle, 1=Send Pending) - Read Only
    delivery_status: u1,
    /// Pin polarity (0=Active High, 1=Active Low)
    polarity: u1,
    /// Remote IRR (Read Only)
    remote_irr: u1,
    /// Trigger mode (0=Edge, 1=Level)
    trigger_mode: u1,
    /// Interrupt mask (0=Enabled, 1=Masked)
    masked: u1,
    /// Reserved
    _reserved: u39,
    /// Destination (APIC ID)
    destination: u8,

    pub fn init(vector: u8, destination: u8) RedirectionEntry {
        return .{
            .vector = vector,
            .delivery_mode = 0, // Fixed
            .dest_mode = 0, // Physical
            .delivery_status = 0,
            .polarity = 0, // Active High
            .remote_irr = 0,
            .trigger_mode = 0, // Edge-triggered
            .masked = 1, // Start masked
            ._ reserved = 0,
            .destination = destination,
        };
    }

    pub fn toU64(self: RedirectionEntry) u64 {
        return @bitCast(self);
    }

    pub fn fromU64(value: u64) RedirectionEntry {
        return @bitCast(value);
    }
};

// ============================================================================
// Delivery Mode
// ============================================================================

pub const DeliveryMode = enum(u3) {
    Fixed = 0b000,
    LowestPriority = 0b001,
    SMI = 0b010,
    NMI = 0b100,
    INIT = 0b101,
    ExtINT = 0b111,
};

// ============================================================================
// IOAPIC Controller
// ============================================================================

pub const IoApic = struct {
    /// Base address of IOAPIC MMIO region
    base_addr: u64,
    /// IOAPIC ID
    id: u8,
    /// Version
    version: u8,
    /// Maximum redirection entry (number of IRQs - 1)
    max_redirection_entry: u8,
    /// Global System Interrupt base
    gsi_base: u32,
    /// Lock for IOAPIC operations
    lock: sync.Spinlock,

    /// Create IOAPIC instance
    pub fn init(base_addr: u64, gsi_base: u32) !IoApic {
        var ioapic = IoApic{
            .base_addr = base_addr,
            .id = 0,
            .version = 0,
            .max_redirection_entry = 0,
            .gsi_base = gsi_base,
            .lock = sync.Spinlock.init(),
        };

        // Read ID and version
        ioapic.id = @truncate(ioapic.read(IoapicReg.ID) >> 24);
        const ver = ioapic.read(IoapicReg.VER);
        ioapic.version = @truncate(ver & 0xFF);
        ioapic.max_redirection_entry = @truncate((ver >> 16) & 0xFF);

        return ioapic;
    }

    /// Read from IOAPIC register
    fn read(self: *const IoApic, reg: u8) u32 {
        const sel_ptr: *volatile u32 = @ptrFromInt(self.base_addr + IOREGSEL);
        const win_ptr: *volatile u32 = @ptrFromInt(self.base_addr + IOWIN);

        sel_ptr.* = reg;
        return win_ptr.*;
    }

    /// Write to IOAPIC register
    fn write(self: *const IoApic, reg: u8, value: u32) void {
        const sel_ptr: *volatile u32 = @ptrFromInt(self.base_addr + IOREGSEL);
        const win_ptr: *volatile u32 = @ptrFromInt(self.base_addr + IOWIN);

        sel_ptr.* = reg;
        win_ptr.* = value;
    }

    /// Read redirection table entry
    pub fn readRedirectionEntry(self: *IoApic, irq: u8) !RedirectionEntry {
        if (irq > self.max_redirection_entry) {
            return error.InvalidIrq;
        }

        self.lock.acquire();
        defer self.lock.release();

        const reg = IoapicReg.REDTBL_BASE + (irq * 2);
        const low = self.read(reg);
        const high = self.read(reg + 1);

        const value = (@as(u64, high) << 32) | low;
        return RedirectionEntry.fromU64(value);
    }

    /// Write redirection table entry
    pub fn writeRedirectionEntry(self: *IoApic, irq: u8, entry: RedirectionEntry) !void {
        if (irq > self.max_redirection_entry) {
            return error.InvalidIrq;
        }

        self.lock.acquire();
        defer self.lock.release();

        const reg = IoapicReg.REDTBL_BASE + (irq * 2);
        const value = entry.toU64();

        self.write(reg, @truncate(value & 0xFFFFFFFF));
        self.write(reg + 1, @truncate(value >> 32));
    }

    /// Mask an IRQ
    pub fn maskIrq(self: *IoApic, irq: u8) !void {
        var entry = try self.readRedirectionEntry(irq);
        entry.masked = 1;
        try self.writeRedirectionEntry(irq, entry);
    }

    /// Unmask an IRQ
    pub fn unmaskIrq(self: *IoApic, irq: u8) !void {
        var entry = try self.readRedirectionEntry(irq);
        entry.masked = 0;
        try self.writeRedirectionEntry(irq, entry);
    }

    /// Setup IRQ routing
    pub fn routeIrq(
        self: *IoApic,
        irq: u8,
        vector: u8,
        destination: u8,
        trigger_level: bool,
        active_low: bool,
    ) !void {
        var entry = RedirectionEntry.init(vector, destination);
        entry.trigger_mode = if (trigger_level) 1 else 0;
        entry.polarity = if (active_low) 1 else 0;
        entry.masked = 0; // Unmask by default

        try self.writeRedirectionEntry(irq, entry);
    }

    /// Setup IRQ with specific delivery mode
    pub fn routeIrqWithMode(
        self: *IoApic,
        irq: u8,
        vector: u8,
        destination: u8,
        delivery_mode: DeliveryMode,
        trigger_level: bool,
        active_low: bool,
    ) !void {
        var entry = RedirectionEntry.init(vector, destination);
        entry.delivery_mode = @intFromEnum(delivery_mode);
        entry.trigger_mode = if (trigger_level) 1 else 0;
        entry.polarity = if (active_low) 1 else 0;
        entry.masked = 0;

        try self.writeRedirectionEntry(irq, entry);
    }

    /// Mask all IRQs
    pub fn maskAll(self: *IoApic) void {
        self.lock.acquire();
        defer self.lock.release();

        for (0..self.max_redirection_entry + 1) |i| {
            const irq: u8 = @intCast(i);
            self.maskIrq(irq) catch {};
        }
    }

    /// Get number of supported IRQs
    pub fn getIrqCount(self: *const IoApic) u8 {
        return self.max_redirection_entry + 1;
    }

    /// Get Global System Interrupt number for IRQ
    pub fn getGsi(self: *const IoApic, irq: u8) u32 {
        return self.gsi_base + irq;
    }

    /// Check if IRQ is valid for this IOAPIC
    pub fn ownsGsi(self: *const IoApic, gsi: u32) bool {
        return gsi >= self.gsi_base and
            gsi < self.gsi_base + (@as(u32, self.max_redirection_entry) + 1);
    }

    /// Print IOAPIC information
    pub fn format(
        self: IoApic,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "IOAPIC[{}] base=0x{X:0>16} ver={d} irqs={d} gsi_base={d}",
            .{
                self.id,
                self.base_addr,
                self.version,
                self.getIrqCount(),
                self.gsi_base,
            },
        );
    }
};

// ============================================================================
// Global IOAPIC Management
// ============================================================================

const MAX_IOAPICS = 8;

var ioapics: [MAX_IOAPICS]?IoApic = [_]?IoApic{null} ** MAX_IOAPICS;
var ioapic_count: usize = 0;
var ioapic_lock = sync.Spinlock.init();

/// Register an IOAPIC
pub fn registerIoApic(base_addr: u64, gsi_base: u32) !void {
    ioapic_lock.acquire();
    defer ioapic_lock.release();

    if (ioapic_count >= MAX_IOAPICS) {
        return error.TooManyIoApics;
    }

    const ioapic = try IoApic.init(base_addr, gsi_base);
    ioapics[ioapic_count] = ioapic;
    ioapic_count += 1;
}

/// Find IOAPIC that owns a GSI
pub fn findIoApicForGsi(gsi: u32) ?*IoApic {
    ioapic_lock.acquire();
    defer ioapic_lock.release();

    for (0..ioapic_count) |i| {
        if (ioapics[i]) |*ioapic| {
            if (ioapic.ownsGsi(gsi)) {
                return ioapic;
            }
        }
    }
    return null;
}

/// Get IOAPIC by index
pub fn getIoApic(index: usize) ?*IoApic {
    if (index >= ioapic_count) return null;

    if (ioapics[index]) |*ioapic| {
        return ioapic;
    }
    return null;
}

/// Get number of IOAPICs
pub fn getIoApicCount() usize {
    return ioapic_count;
}

/// Route a Global System Interrupt to a vector
pub fn routeGsi(gsi: u32, vector: u8, destination: u8) !void {
    const ioapic = findIoApicForGsi(gsi) orelse return error.NoIoApicForGsi;

    const irq: u8 = @intCast(gsi - ioapic.gsi_base);
    try ioapic.routeIrq(irq, vector, destination, false, false);
}

/// Mask a Global System Interrupt
pub fn maskGsi(gsi: u32) !void {
    const ioapic = findIoApicForGsi(gsi) orelse return error.NoIoApicForGsi;

    const irq: u8 = @intCast(gsi - ioapic.gsi_base);
    try ioapic.maskIrq(irq);
}

/// Unmask a Global System Interrupt
pub fn unmaskGsi(gsi: u32) !void {
    const ioapic = findIoApicForGsi(gsi) orelse return error.NoIoApicForGsi;

    const irq: u8 = @intCast(gsi - ioapic.gsi_base);
    try ioapic.unmaskIrq(irq);
}

/// Setup standard PC IRQ mappings (IRQ 0-15 -> Vectors 32-47)
pub fn setupLegacyIrqs(base_vector: u8, destination: u8) !void {
    // Map legacy IRQs 0-15
    for (0..16) |i| {
        const gsi: u32 = @intCast(i);
        const vector = base_vector + @as(u8, @intCast(i));

        // IRQ 2 is usually cascade to second PIC, skip it
        if (i == 2) continue;

        routeGsi(gsi, vector, destination) catch |err| {
            // Ignore errors for IRQs not present
            if (err != error.NoIoApicForGsi) {
                return err;
            }
        };
    }
}

/// Mask all IRQs on all IOAPICs
pub fn maskAllIrqs() void {
    ioapic_lock.acquire();
    defer ioapic_lock.release();

    for (0..ioapic_count) |i| {
        if (ioapics[i]) |*ioapic| {
            ioapic.maskAll();
        }
    }
}

// ============================================================================
// ISA IRQ to GSI Mapping
// ============================================================================

// In standard PC, ISA IRQs map directly to GSIs 0-15, but this can be
// overridden by ACPI MADT Interrupt Source Override entries

var isa_irq_to_gsi: [16]u32 = undefined;
var isa_irq_overrides_set = false;

/// Initialize ISA IRQ to GSI mapping with defaults
pub fn initIsaIrqMapping() void {
    for (0..16) |i| {
        isa_irq_to_gsi[i] = @intCast(i);
    }
    isa_irq_overrides_set = true;
}

/// Set IRQ override (from ACPI MADT)
pub fn setIrqOverride(isa_irq: u8, gsi: u32, flags: u16) void {
    // Store flags for polarity/trigger mode configuration
    // Bits 0-1: Polarity (0=conform to bus, 1=active high, 2=reserved, 3=active low)
    // Bits 2-3: Trigger mode (0=conform to bus, 1=edge, 2=reserved, 3=level)
    const polarity = flags & 0x3;
    const trigger = (flags >> 2) & 0x3;

    if (isa_irq < 16) {
        isa_irq_to_gsi[isa_irq] = gsi;

        // Configure the redirection entry with polarity and trigger mode
        if (getIoApic()) |ioapic| {
            var entry = ioapic.readRedirection(gsi);

            // Set polarity (bit 13): 0=active high, 1=active low
            if (polarity == 3) { // Active low
                entry |= (1 << 13);
            } else { // Active high (default)
                entry &= ~@as(u64, 1 << 13);
            }

            // Set trigger mode (bit 15): 0=edge, 1=level
            if (trigger == 3) { // Level triggered
                entry |= (1 << 15);
            } else { // Edge triggered (default)
                entry &= ~@as(u64, 1 << 15);
            }

            ioapic.writeRedirection(gsi, entry);
        }
    }
}

/// Get GSI for ISA IRQ
pub fn getGsiForIsaIrq(isa_irq: u8) u32 {
    if (!isa_irq_overrides_set) {
        initIsaIrqMapping();
    }
    if (isa_irq < 16) {
        return isa_irq_to_gsi[isa_irq];
    }
    return isa_irq; // Fallback to identity mapping
}

/// Route ISA IRQ (with override handling)
pub fn routeIsaIrq(isa_irq: u8, vector: u8, destination: u8) !void {
    const gsi = getGsiForIsaIrq(isa_irq);
    try routeGsi(gsi, vector, destination);
}

// ============================================================================
// Tests
// ============================================================================

test "redirection entry" {
    const entry = RedirectionEntry.init(32, 0);

    try Basics.testing.expectEqual(@as(u8, 32), entry.vector);
    try Basics.testing.expectEqual(@as(u8, 0), entry.destination);
    try Basics.testing.expectEqual(@as(u3, 0), entry.delivery_mode);
    try Basics.testing.expectEqual(@as(u1, 1), entry.masked);

    // Test serialization
    const value = entry.toU64();
    const restored = RedirectionEntry.fromU64(value);
    try Basics.testing.expectEqual(entry.vector, restored.vector);
    try Basics.testing.expectEqual(entry.destination, restored.destination);
}

test "ISA IRQ mapping" {
    initIsaIrqMapping();

    // Default mapping
    try Basics.testing.expectEqual(@as(u32, 0), getGsiForIsaIrq(0));
    try Basics.testing.expectEqual(@as(u32, 1), getGsiForIsaIrq(1));

    // Override IRQ 9 -> GSI 20
    setIrqOverride(9, 20, 0);
    try Basics.testing.expectEqual(@as(u32, 20), getGsiForIsaIrq(9));
}
