// PCI/PCIe Configuration Space Abstraction
// Enhanced configuration space access with type-safe register definitions

const std = @import("std");

/// PCI Configuration Space Registers (Type 0 Header)
pub const ConfigSpace = packed struct {
    // 0x00-0x0F: Device Identification
    vendor_id: u16,
    device_id: u16,
    command: CommandRegister,
    status: StatusRegister,
    revision_id: u8,
    prog_if: u8,
    subclass: u8,
    class_code: u8,

    // 0x08-0x0F: Class Code and Header
    cache_line_size: u8,
    latency_timer: u8,
    header_type: HeaderType,
    bist: u8,

    // 0x10-0x27: Base Address Registers
    bar0: u32,
    bar1: u32,
    bar2: u32,
    bar3: u32,
    bar4: u32,
    bar5: u32,

    // 0x28-0x2F: Expansion ROM and Capabilities
    cardbus_cis_pointer: u32,
    subsystem_vendor_id: u16,
    subsystem_id: u16,
    expansion_rom_base: u32,

    // 0x34-0x3F: Capabilities and Interrupts
    capabilities_pointer: u8,
    reserved: [7]u8,
    interrupt_line: u8,
    interrupt_pin: u8,
    min_grant: u8,
    max_latency: u8,

    /// Read configuration space from PCI device
    pub fn read(bus: u8, device: u5, function: u3) ConfigSpace {
        var config: ConfigSpace = undefined;
        const bytes = std.mem.asBytes(&config);

        var i: usize = 0;
        while (i < bytes.len) : (i += 4) {
            const dword = readConfigDword(bus, device, function, @intCast(i));
            @memcpy(bytes[i..][0..4], std.mem.asBytes(&dword));
        }

        return config;
    }

    /// Write configuration space to PCI device
    pub fn write(self: ConfigSpace, bus: u8, device: u5, function: u3) void {
        const bytes = std.mem.asBytes(&self);

        var i: usize = 0;
        while (i < bytes.len) : (i += 4) {
            var dword: u32 = undefined;
            @memcpy(std.mem.asBytes(&dword), bytes[i..][0..4]);
            writeConfigDword(bus, device, function, @intCast(i), dword);
        }
    }
};

/// PCI Command Register (0x04)
pub const CommandRegister = packed struct(u16) {
    io_space: bool, // Enable I/O space
    memory_space: bool, // Enable memory space
    bus_master: bool, // Enable bus mastering
    special_cycles: bool, // Monitor special cycles
    mem_write_invalidate: bool, // Enable memory write and invalidate
    vga_palette_snoop: bool, // VGA palette snoop
    parity_error_response: bool, // Parity error response
    reserved0: bool,
    serr_enable: bool, // Enable SERR# driver
    fast_back_to_back: bool, // Fast back-to-back enable
    interrupt_disable: bool, // Interrupt disable
    reserved1: u5,
};

/// PCI Status Register (0x06)
pub const StatusRegister = packed struct(u16) {
    reserved0: u3,
    interrupt_status: bool, // Interrupt status
    capabilities_list: bool, // Capabilities list present
    capable_66mhz: bool, // 66 MHz capable
    reserved1: bool,
    fast_back_to_back: bool, // Fast back-to-back capable
    master_data_parity_error: bool, // Master data parity error
    devsel_timing: u2, // DEVSEL timing
    signaled_target_abort: bool, // Signaled target abort
    received_target_abort: bool, // Received target abort
    received_master_abort: bool, // Received master abort
    signaled_system_error: bool, // Signaled system error
    detected_parity_error: bool, // Detected parity error
};

/// PCI Header Type (0x0E)
pub const HeaderType = packed struct(u8) {
    layout: u7, // 0 = normal, 1 = PCI-to-PCI bridge, 2 = CardBus bridge
    multi_function: bool, // Multi-function device
};

/// Base Address Register (BAR) decoder
pub const BAR = union(enum) {
    memory: MemoryBAR,
    io: IOBAR,
    invalid: void,

    pub const MemoryBAR = struct {
        address: u64,
        size: u64,
        prefetchable: bool,
        type_64bit: bool,
    };

    pub const IOBAR = struct {
        address: u32,
        size: u32,
    };

    /// Decode a BAR from raw value
    pub fn decode(bus: u8, device: u5, function: u3, bar_index: u3) BAR {
        const bar_offset: u8 = 0x10 + (@as(u8, bar_index) * 4);
        const bar_value = readConfigDword(bus, device, function, bar_offset);

        if (bar_value == 0 or bar_value == 0xFFFFFFFF) {
            return .invalid;
        }

        // Check if I/O or Memory BAR
        if ((bar_value & 0x1) == 1) {
            // I/O BAR
            const address = bar_value & 0xFFFFFFFC;

            // Get size by writing all 1s and reading back
            writeConfigDword(bus, device, function, bar_offset, 0xFFFFFFFF);
            const size_mask = readConfigDword(bus, device, function, bar_offset);
            writeConfigDword(bus, device, function, bar_offset, bar_value); // Restore

            const size = ~(size_mask & 0xFFFFFFFC) + 1;

            return .{ .io = .{
                .address = address,
                .size = size,
            } };
        } else {
            // Memory BAR
            const prefetchable = (bar_value & 0x8) != 0;
            const bar_type = (bar_value & 0x6) >> 1;
            const is_64bit = bar_type == 2;

            var address: u64 = bar_value & 0xFFFFFFF0;

            if (is_64bit and bar_index < 5) {
                const upper_bar = readConfigDword(bus, device, function, bar_offset + 4);
                address |= (@as(u64, upper_bar) << 32);
            }

            // Get size
            writeConfigDword(bus, device, function, bar_offset, 0xFFFFFFFF);
            var size_mask: u64 = readConfigDword(bus, device, function, bar_offset) & 0xFFFFFFF0;

            if (is_64bit and bar_index < 5) {
                writeConfigDword(bus, device, function, bar_offset + 4, 0xFFFFFFFF);
                const upper_mask = readConfigDword(bus, device, function, bar_offset + 4);
                size_mask |= (@as(u64, upper_mask) << 32);
            }

            writeConfigDword(bus, device, function, bar_offset, @truncate(bar_value));
            if (is_64bit) {
                writeConfigDword(bus, device, function, bar_offset + 4, @truncate(bar_value >> 32));
            }

            const size = ~size_mask + 1;

            return .{ .memory = .{
                .address = address,
                .size = size,
                .prefetchable = prefetchable,
                .type_64bit = is_64bit,
            } };
        }
    }
};

/// PCIe Extended Configuration Space (4KB per function)
pub const ExtendedConfigSpace = struct {
    base_config: ConfigSpace,
    // Extended space starts at 0x100

    /// PCIe Capability IDs
    pub const CapabilityID = enum(u16) {
        null = 0x0000,
        advanced_error_reporting = 0x0001,
        virtual_channel = 0x0002,
        device_serial_number = 0x0003,
        power_budgeting = 0x0004,
        root_complex_link_declaration = 0x0005,
        root_complex_internal_link = 0x0006,
        root_complex_event_collector = 0x0007,
        multi_function_virtual_channel = 0x0008,
        vendor_specific = 0x000B,
        access_control_services = 0x000D,
        alternative_routing_id = 0x000E,
        address_translation_services = 0x000F,
        sr_iov = 0x0010,
        multi_root_iov = 0x0011,
        _,
    };

    /// Find capability in extended config space
    pub fn findExtendedCapability(bus: u8, device: u5, function: u3, cap_id: CapabilityID) ?u16 {
        var offset: u16 = 0x100;

        while (offset < 0x1000) {
            const header = readExtendedConfigDword(bus, device, function, offset);

            if (header == 0 or header == 0xFFFFFFFF) {
                return null;
            }

            const id: u16 = @truncate(header & 0xFFFF);
            const next: u16 = @truncate((header >> 20) & 0xFFF);

            if (@as(u16, @intFromEnum(cap_id)) == id) {
                return offset;
            }

            if (next == 0) {
                return null;
            }

            offset = next;
        }

        return null;
    }

    /// Read MSI-X capability
    pub const MSIX = struct {
        table_size: u16,
        function_mask: bool,
        enable: bool,
        table_offset: u32,
        table_bar: u3,
        pba_offset: u32,
        pba_bar: u3,

        pub fn read(bus: u8, device: u5, function: u3, cap_offset: u8) ?MSIX {
            const msg_control = readConfigWord(bus, device, function, cap_offset + 2);
            const table_info = readConfigDword(bus, device, function, cap_offset + 4);
            const pba_info = readConfigDword(bus, device, function, cap_offset + 8);

            return MSIX{
                .table_size = (msg_control & 0x7FF) + 1,
                .function_mask = (msg_control & 0x4000) != 0,
                .enable = (msg_control & 0x8000) != 0,
                .table_bar = @truncate(table_info & 0x7),
                .table_offset = table_info & 0xFFFFFFF8,
                .pba_bar = @truncate(pba_info & 0x7),
                .pba_offset = pba_info & 0xFFFFFFF8,
            };
        }
    };

    /// Read MSI capability
    pub const MSI = struct {
        enable: bool,
        multi_message_capable: u3,
        multi_message_enable: u3,
        is_64bit: bool,
        per_vector_masking: bool,
        message_address: u64,
        message_data: u16,

        pub fn read(bus: u8, device: u5, function: u3, cap_offset: u8) MSI {
            const msg_control = readConfigWord(bus, device, function, cap_offset + 2);
            const is_64bit = (msg_control & 0x80) != 0;

            const addr_low = readConfigDword(bus, device, function, cap_offset + 4);
            var message_address: u64 = addr_low;

            const data_offset: u8 = if (is_64bit) 12 else 8;

            if (is_64bit) {
                const addr_high = readConfigDword(bus, device, function, cap_offset + 8);
                message_address |= (@as(u64, addr_high) << 32);
            }

            const message_data = readConfigWord(bus, device, function, cap_offset + data_offset);

            return MSI{
                .enable = (msg_control & 0x1) != 0,
                .multi_message_capable = @truncate((msg_control >> 1) & 0x7),
                .multi_message_enable = @truncate((msg_control >> 4) & 0x7),
                .is_64bit = is_64bit,
                .per_vector_masking = (msg_control & 0x100) != 0,
                .message_address = message_address,
                .message_data = message_data,
            };
        }
    };
};

/// PCI Express Capability Structure
pub const PCIeCapability = struct {
    capability_version: u4,
    device_type: DeviceType,
    slot_implemented: bool,
    interrupt_message_number: u5,

    pub const DeviceType = enum(u4) {
        pcie_endpoint = 0x0,
        legacy_pcie_endpoint = 0x1,
        root_port = 0x4,
        upstream_switch_port = 0x5,
        downstream_switch_port = 0x6,
        pcie_to_pci_bridge = 0x7,
        pci_to_pcie_bridge = 0x8,
        root_complex_integrated_endpoint = 0x9,
        root_complex_event_collector = 0xA,
        _,
    };

    /// Read PCIe capability from standard capability list
    pub fn read(bus: u8, device: u5, function: u3, cap_offset: u8) PCIeCapability {
        const caps_reg = readConfigWord(bus, device, function, cap_offset + 2);

        return .{
            .capability_version = @truncate(caps_reg & 0xF),
            .device_type = @enumFromInt(@as(u4, @truncate((caps_reg >> 4) & 0xF))),
            .slot_implemented = (caps_reg & 0x100) != 0,
            .interrupt_message_number = @truncate((caps_reg >> 9) & 0x1F),
        };
    }
};

/// PCI Capability List Walker
pub const CapabilityWalker = struct {
    pub const StandardCapID = enum(u8) {
        power_management = 0x01,
        agp = 0x02,
        vpd = 0x03,
        slot_identification = 0x04,
        msi = 0x05,
        compactpci_hot_swap = 0x06,
        pcix = 0x07,
        hypertransport = 0x08,
        vendor_specific = 0x09,
        debug_port = 0x0A,
        compactpci_crc = 0x0B,
        pci_hot_plug = 0x0C,
        bridge_subsystem_vendor_id = 0x0D,
        agp8x = 0x0E,
        secure_device = 0x0F,
        pci_express = 0x10,
        msix = 0x11,
        sata = 0x12,
        advanced_features = 0x13,
        _,
    };

    /// Find standard capability
    pub fn findCapability(bus: u8, device: u5, function: u3, cap_id: StandardCapID) ?u8 {
        // Check if capabilities list exists
        const status = readConfigWord(bus, device, function, 0x06);
        if ((status & 0x10) == 0) {
            return null;
        }

        var cap_ptr = readConfigByte(bus, device, function, 0x34);
        cap_ptr &= 0xFC; // Align to 4-byte boundary

        while (cap_ptr != 0 and cap_ptr != 0xFF) {
            const cap_header = readConfigWord(bus, device, function, cap_ptr);
            const id: u8 = @truncate(cap_header & 0xFF);
            const next: u8 = @truncate((cap_header >> 8) & 0xFF);

            if (@intFromEnum(cap_id) == id) {
                return cap_ptr;
            }

            cap_ptr = next & 0xFC;
        }

        return null;
    }
};

// Low-level access functions (to be provided by platform)
extern fn readConfigDword(bus: u8, device: u5, function: u3, offset: u8) u32;
extern fn writeConfigDword(bus: u8, device: u5, function: u3, offset: u8, value: u32) void;

fn readConfigWord(bus: u8, device: u5, function: u3, offset: u8) u16 {
    const dword = readConfigDword(bus, device, function, offset & 0xFC);
    const shift: u5 = @intCast((offset & 0x3) * 8);
    return @truncate(dword >> shift);
}

fn readConfigByte(bus: u8, device: u5, function: u3, offset: u8) u8 {
    const dword = readConfigDword(bus, device, function, offset & 0xFC);
    const shift: u5 = @intCast((offset & 0x3) * 8);
    return @truncate(dword >> shift);
}

fn readExtendedConfigDword(bus: u8, device: u5, function: u3, offset: u16) u32 {
    // For PCIe Enhanced Configuration Access Mechanism (ECAM)
    // This would use memory-mapped access instead of I/O ports
    // Placeholder - actual implementation depends on platform
    _ = bus;
    _ = device;
    _ = function;
    _ = offset;
    return 0;
}

// Tests
test "config space structures" {
    const testing = std.testing;

    // Test command register
    const cmd = CommandRegister{
        .io_space = true,
        .memory_space = true,
        .bus_master = true,
        .special_cycles = false,
        .mem_write_invalidate = false,
        .vga_palette_snoop = false,
        .parity_error_response = false,
        .reserved0 = false,
        .serr_enable = false,
        .fast_back_to_back = false,
        .interrupt_disable = false,
        .reserved1 = 0,
    };

    try testing.expect(cmd.io_space);
    try testing.expect(cmd.memory_space);
    try testing.expect(cmd.bus_master);

    // Test header type
    const header = HeaderType{
        .layout = 0,
        .multi_function = false,
    };

    try testing.expectEqual(@as(u7, 0), header.layout);
    try testing.expect(!header.multi_function);
}
