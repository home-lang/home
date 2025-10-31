// Home OS - ACPI Support
// Advanced Configuration and Power Interface parsing and management

const std = @import("std");
const drivers = @import("drivers.zig");

// ============================================================================
// ACPI Table Signatures
// ============================================================================

pub const Signature = enum(u32) {
    RSDP = 0x20445352, // "RSD PTR "
    RSDT = 0x54445352, // "RSDT"
    XSDT = 0x54445358, // "XSDT"
    FADT = 0x50434146, // "FACP"
    MADT = 0x43495041, // "APIC"
    HPET = 0x54455048, // "HPET"
    MCFG = 0x4746434D, // "MCFG"
    SSDT = 0x54445353, // "SSDT"
    DSDT = 0x54445344, // "DSDT"
    _,

    pub fn fromBytes(bytes: [4]u8) Signature {
        return @enumFromInt(std.mem.readInt(u32, &bytes, .little));
    }

    pub fn toString(self: Signature) []const u8 {
        return switch (self) {
            .RSDT => "RSDT - Root System Description Table",
            .XSDT => "XSDT - Extended System Description Table",
            .FADT => "FADT - Fixed ACPI Description Table",
            .MADT => "MADT - Multiple APIC Description Table",
            .HPET => "HPET - High Precision Event Timer",
            .MCFG => "MCFG - PCI Express Memory Mapped Configuration",
            .SSDT => "SSDT - Secondary System Description Table",
            .DSDT => "DSDT - Differentiated System Description Table",
            else => "Unknown ACPI Table",
        };
    }
};

// ============================================================================
// RSDP (Root System Description Pointer)
// ============================================================================

pub const RSDP = packed struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,

    // ACPI 2.0+ fields
    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,

    pub fn validate(self: *const RSDP) bool {
        // Validate signature
        if (!std.mem.eql(u8, &self.signature, "RSD PTR ")) {
            return false;
        }

        // Validate checksum (ACPI 1.0 portion)
        const bytes: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;
        for (0..20) |i| {
            sum +%= bytes[i];
        }

        if (sum != 0) return false;

        // If ACPI 2.0+, validate extended checksum
        if (self.revision >= 2) {
            sum = 0;
            for (0..self.length) |i| {
                sum +%= bytes[i];
            }
            return sum == 0;
        }

        return true;
    }
};

// ============================================================================
// SDT Header (System Description Table)
// ============================================================================

pub const SDTHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn validate(self: *const SDTHeader) bool {
        const bytes: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;
        for (0..self.length) |i| {
            sum +%= bytes[i];
        }
        return sum == 0;
    }

    pub fn getSignature(self: *const SDTHeader) Signature {
        return Signature.fromBytes(self.signature);
    }
};

// ============================================================================
// RSDT (Root System Description Table)
// ============================================================================

pub const RSDT = struct {
    header: *const SDTHeader,
    entries: []const u32,

    pub fn parse(header: *const SDTHeader) !RSDT {
        if (!header.validate()) {
            return drivers.DriverError.InvalidConfiguration;
        }

        const entry_count = (header.length - @sizeOf(SDTHeader)) / @sizeOf(u32);
        const entries_ptr: [*]const u32 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(header)) + @sizeOf(SDTHeader)));
        const entries = entries_ptr[0..entry_count];

        return .{
            .header = header,
            .entries = entries,
        };
    }

    pub fn findTable(self: RSDT, signature: Signature) ?*const SDTHeader {
        for (self.entries) |entry| {
            const table: *const SDTHeader = @ptrFromInt(entry);
            if (table.getSignature() == signature) {
                return table;
            }
        }
        return null;
    }
};

// ============================================================================
// XSDT (Extended System Description Table)
// ============================================================================

pub const XSDT = struct {
    header: *const SDTHeader,
    entries: []const u64,

    pub fn parse(header: *const SDTHeader) !XSDT {
        if (!header.validate()) {
            return drivers.DriverError.InvalidConfiguration;
        }

        const entry_count = (header.length - @sizeOf(SDTHeader)) / @sizeOf(u64);
        const entries_ptr: [*]const u64 = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(header)) + @sizeOf(SDTHeader)));
        const entries = entries_ptr[0..entry_count];

        return .{
            .header = header,
            .entries = entries,
        };
    }

    pub fn findTable(self: XSDT, signature: Signature) ?*const SDTHeader {
        for (self.entries) |entry| {
            const table: *const SDTHeader = @ptrFromInt(entry);
            if (table.getSignature() == signature) {
                return table;
            }
        }
        return null;
    }
};

// ============================================================================
// MADT (Multiple APIC Description Table)
// ============================================================================

pub const MADT = struct {
    header: *const SDTHeader,
    local_apic_address: u32,
    flags: u32,
    entries: []const u8,

    pub const EntryType = enum(u8) {
        processor_local_apic = 0,
        io_apic = 1,
        interrupt_source_override = 2,
        nmi_source = 3,
        local_apic_nmi = 4,
        local_apic_address_override = 5,
        io_sapic = 6,
        local_sapic = 7,
        platform_interrupt_sources = 8,
        processor_local_x2apic = 9,
        _,
    };

    pub const EntryHeader = packed struct {
        entry_type: EntryType,
        length: u8,
    };

    pub const LocalAPIC = packed struct {
        header: EntryHeader,
        acpi_processor_id: u8,
        apic_id: u8,
        flags: u32,
    };

    pub const IOAPIC = packed struct {
        header: EntryHeader,
        io_apic_id: u8,
        reserved: u8,
        io_apic_address: u32,
        global_system_interrupt_base: u32,
    };

    pub fn parse(header: *const SDTHeader) !MADT {
        if (!header.validate()) {
            return drivers.DriverError.InvalidConfiguration;
        }

        const data: [*]const u8 = @ptrCast(header);
        const local_apic_address = std.mem.readInt(u32, data[@sizeOf(SDTHeader)..][0..4], .little);
        const flags = std.mem.readInt(u32, data[@sizeOf(SDTHeader) + 4 ..][0..4], .little);

        const entries_start = @sizeOf(SDTHeader) + 8;
        const entries_len = header.length - entries_start;
        const entries = data[entries_start..][0..entries_len];

        return .{
            .header = header,
            .local_apic_address = local_apic_address,
            .flags = flags,
            .entries = entries,
        };
    }

    pub fn iterateEntries(self: MADT, callback: anytype) void {
        var offset: usize = 0;
        while (offset < self.entries.len) {
            const entry_header: *const EntryHeader = @ptrCast(@alignCast(&self.entries[offset]));
            callback(entry_header);
            offset += entry_header.length;
        }
    }
};

// ============================================================================
// MCFG (PCI Express Memory Mapped Configuration)
// ============================================================================

pub const MCFG = struct {
    header: *const SDTHeader,
    entries: []const Entry,

    pub const Entry = packed struct {
        base_address: u64,
        pci_segment_group: u16,
        start_bus: u8,
        end_bus: u8,
        reserved: u32,
    };

    pub fn parse(header: *const SDTHeader) !MCFG {
        if (!header.validate()) {
            return drivers.DriverError.InvalidConfiguration;
        }

        const entry_count = (header.length - @sizeOf(SDTHeader) - 8) / @sizeOf(Entry);
        const entries_ptr: [*]const Entry = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(header)) + @sizeOf(SDTHeader) + 8));
        const entries = entries_ptr[0..entry_count];

        return .{
            .header = header,
            .entries = entries,
        };
    }
};

// ============================================================================
// HPET (High Precision Event Timer)
// ============================================================================

pub const HPET = struct {
    header: *const SDTHeader,
    hardware_rev_id: u8,
    comparator_count: u5,
    counter_size: u1,
    reserved1: u1,
    legacy_replacement: u1,
    pci_vendor_id: u16,
    address_space_id: u8,
    register_bit_width: u8,
    register_bit_offset: u8,
    reserved2: u8,
    address: u64,
    hpet_number: u8,
    minimum_tick: u16,
    page_protection: u8,

    pub fn parse(header: *const SDTHeader) !HPET {
        if (!header.validate()) {
            return drivers.DriverError.InvalidConfiguration;
        }

        const data: [*]const u8 = @ptrCast(header);
        const offset = @sizeOf(SDTHeader);

        return .{
            .header = header,
            .hardware_rev_id = data[offset],
            .comparator_count = @truncate(data[offset + 1] & 0x1F),
            .counter_size = @truncate((data[offset + 1] >> 5) & 1),
            .reserved1 = @truncate((data[offset + 1] >> 6) & 1),
            .legacy_replacement = @truncate((data[offset + 1] >> 7) & 1),
            .pci_vendor_id = std.mem.readInt(u16, data[offset + 2 ..][0..2], .little),
            .address_space_id = data[offset + 4],
            .register_bit_width = data[offset + 5],
            .register_bit_offset = data[offset + 6],
            .reserved2 = data[offset + 7],
            .address = std.mem.readInt(u64, data[offset + 8 ..][0..8], .little),
            .hpet_number = data[offset + 16],
            .minimum_tick = std.mem.readInt(u16, data[offset + 17 ..][0..2], .little),
            .page_protection = data[offset + 19],
        };
    }
};

// ============================================================================
// ACPI Manager
// ============================================================================

pub const ACPIManager = struct {
    rsdp: ?*const RSDP,
    rsdt: ?RSDT,
    xsdt: ?XSDT,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ACPIManager {
        return .{
            .rsdp = null,
            .rsdt = null,
            .xsdt = null,
            .allocator = allocator,
        };
    }

    pub fn findRSDP(self: *ACPIManager) !void {
        // Search EBDA (Extended BIOS Data Area)
        const ebda_address: usize = @as(usize, std.mem.readInt(u16, @as(*const [2]u8, @ptrFromInt(0x40E)), .little)) << 4;
        if (try self.searchRSDP(ebda_address, 1024)) {
            return;
        }

        // Search main BIOS area (0xE0000 - 0xFFFFF)
        if (try self.searchRSDP(0xE0000, 0x20000)) {
            return;
        }

        return drivers.DriverError.NotFound;
    }

    fn searchRSDP(self: *ACPIManager, start: usize, length: usize) !bool {
        const search_area: [*]const u8 = @ptrFromInt(start);
        var offset: usize = 0;

        while (offset < length) : (offset += 16) {
            const potential_rsdp: *const RSDP = @ptrCast(@alignCast(&search_area[offset]));

            if (potential_rsdp.validate()) {
                self.rsdp = potential_rsdp;
                return true;
            }
        }

        return false;
    }

    pub fn parseRSDT(self: *ACPIManager) !void {
        if (self.rsdp == null) return drivers.DriverError.NotFound;

        const rsdt_header: *const SDTHeader = @ptrFromInt(self.rsdp.?.rsdt_address);
        self.rsdt = try RSDT.parse(rsdt_header);
    }

    pub fn parseXSDT(self: *ACPIManager) !void {
        if (self.rsdp == null) return drivers.DriverError.NotFound;
        if (self.rsdp.?.revision < 2) return drivers.DriverError.NotSupported;

        const xsdt_header: *const SDTHeader = @ptrFromInt(self.rsdp.?.xsdt_address);
        self.xsdt = try XSDT.parse(xsdt_header);
    }

    pub fn findTable(self: *ACPIManager, signature: Signature) ?*const SDTHeader {
        if (self.xsdt) |xsdt| {
            return xsdt.findTable(signature);
        }

        if (self.rsdt) |rsdt| {
            return rsdt.findTable(signature);
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ACPI signature conversion" {
    const testing = std.testing;

    const rsdt_sig = Signature.fromBytes(.{ 'R', 'S', 'D', 'T' });
    try testing.expectEqual(Signature.RSDT, rsdt_sig);
}

test "SDT header size" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 36), @sizeOf(SDTHeader));
}
