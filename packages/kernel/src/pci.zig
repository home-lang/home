// Home Programming Language - PCI Bus Enumeration
// PCI (Peripheral Component Interconnect) device discovery and configuration

const Basics = @import("basics");
const asm = @import("asm.zig");
const memory = @import("memory.zig");

// ============================================================================
// PCI Configuration Space Access
// ============================================================================

/// PCI configuration address port (0xCF8)
const CONFIG_ADDRESS: u16 = 0xCF8;

/// PCI configuration data port (0xCFC)
const CONFIG_DATA: u16 = 0xCFC;

/// Enable bit for PCI configuration address
const CONFIG_ENABLE: u32 = 0x80000000;

/// PCI device location
pub const PciAddress = struct {
    bus: u8,
    device: u5,
    function: u3,

    /// Create PCI address from components
    pub fn init(bus: u8, device: u5, function: u3) PciAddress {
        return .{
            .bus = bus,
            .device = device,
            .function = function,
        };
    }

    /// Convert to configuration address format
    pub fn toConfigAddress(self: PciAddress, offset: u8) u32 {
        return CONFIG_ENABLE |
            (@as(u32, self.bus) << 16) |
            (@as(u32, self.device) << 11) |
            (@as(u32, self.function) << 8) |
            (@as(u32, offset) & 0xFC);
    }
};

/// Read 32-bit value from PCI configuration space
pub fn readConfig32(addr: PciAddress, offset: u8) u32 {
    const config_addr = addr.toConfigAddress(offset);
    asm.outl(CONFIG_ADDRESS, config_addr);
    return asm.inl(CONFIG_DATA);
}

/// Write 32-bit value to PCI configuration space
pub fn writeConfig32(addr: PciAddress, offset: u8, value: u32) void {
    const config_addr = addr.toConfigAddress(offset);
    asm.outl(CONFIG_ADDRESS, config_addr);
    asm.outl(CONFIG_DATA, value);
}

/// Read 16-bit value from PCI configuration space
pub fn readConfig16(addr: PciAddress, offset: u8) u16 {
    const config_addr = addr.toConfigAddress(offset);
    asm.outl(CONFIG_ADDRESS, config_addr);
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(asm.inl(CONFIG_DATA) >> shift);
}

/// Write 16-bit value to PCI configuration space
pub fn writeConfig16(addr: PciAddress, offset: u8, value: u16) void {
    const config_addr = addr.toConfigAddress(offset);
    asm.outl(CONFIG_ADDRESS, config_addr);

    const shift: u5 = @intCast((offset & 2) * 8);
    const old = asm.inl(CONFIG_DATA);
    const mask: u32 = 0xFFFF << shift;
    const new = (old & ~mask) | (@as(u32, value) << shift);

    asm.outl(CONFIG_ADDRESS, config_addr);
    asm.outl(CONFIG_DATA, new);
}

/// Read 8-bit value from PCI configuration space
pub fn readConfig8(addr: PciAddress, offset: u8) u8 {
    const config_addr = addr.toConfigAddress(offset);
    asm.outl(CONFIG_ADDRESS, config_addr);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(asm.inl(CONFIG_DATA) >> shift);
}

/// Write 8-bit value to PCI configuration space
pub fn writeConfig8(addr: PciAddress, offset: u8, value: u8) void {
    const config_addr = addr.toConfigAddress(offset);
    asm.outl(CONFIG_ADDRESS, config_addr);

    const shift: u5 = @intCast((offset & 3) * 8);
    const old = asm.inl(CONFIG_DATA);
    const mask: u32 = 0xFF << shift;
    const new = (old & ~mask) | (@as(u32, value) << shift);

    asm.outl(CONFIG_ADDRESS, config_addr);
    asm.outl(CONFIG_DATA, new);
}

// ============================================================================
// PCI Configuration Space Offsets
// ============================================================================

pub const ConfigOffset = struct {
    pub const VENDOR_ID: u8 = 0x00;
    pub const DEVICE_ID: u8 = 0x02;
    pub const COMMAND: u8 = 0x04;
    pub const STATUS: u8 = 0x06;
    pub const REVISION_ID: u8 = 0x08;
    pub const PROG_IF: u8 = 0x09;
    pub const SUBCLASS: u8 = 0x0A;
    pub const CLASS_CODE: u8 = 0x0B;
    pub const CACHE_LINE_SIZE: u8 = 0x0C;
    pub const LATENCY_TIMER: u8 = 0x0D;
    pub const HEADER_TYPE: u8 = 0x0E;
    pub const BIST: u8 = 0x0F;
    pub const BAR0: u8 = 0x10;
    pub const BAR1: u8 = 0x14;
    pub const BAR2: u8 = 0x18;
    pub const BAR3: u8 = 0x1C;
    pub const BAR4: u8 = 0x20;
    pub const BAR5: u8 = 0x24;
    pub const CARDBUS_CIS: u8 = 0x28;
    pub const SUBSYSTEM_VENDOR_ID: u8 = 0x2C;
    pub const SUBSYSTEM_ID: u8 = 0x2E;
    pub const EXPANSION_ROM: u8 = 0x30;
    pub const CAPABILITIES: u8 = 0x34;
    pub const INTERRUPT_LINE: u8 = 0x3C;
    pub const INTERRUPT_PIN: u8 = 0x3D;
    pub const MIN_GRANT: u8 = 0x3E;
    pub const MAX_LATENCY: u8 = 0x3F;
};

// ============================================================================
// PCI Command Register Bits
// ============================================================================

pub const CommandBits = struct {
    pub const IO_SPACE: u16 = 1 << 0;
    pub const MEMORY_SPACE: u16 = 1 << 1;
    pub const BUS_MASTER: u16 = 1 << 2;
    pub const SPECIAL_CYCLES: u16 = 1 << 3;
    pub const MEMORY_WRITE_INVALIDATE: u16 = 1 << 4;
    pub const VGA_PALETTE_SNOOP: u16 = 1 << 5;
    pub const PARITY_ERROR_RESPONSE: u16 = 1 << 6;
    pub const SERR_ENABLE: u16 = 1 << 8;
    pub const FAST_BACK_TO_BACK: u16 = 1 << 9;
    pub const INTERRUPT_DISABLE: u16 = 1 << 10;
};

// ============================================================================
// PCI Header Types
// ============================================================================

pub const HeaderType = enum(u8) {
    General = 0x00,
    PciToPciBridge = 0x01,
    CardBusBridge = 0x02,
};

// ============================================================================
// BAR (Base Address Register) Types
// ============================================================================

pub const BarType = enum {
    Memory,
    Io,
    None,
};

pub const Bar = union(BarType) {
    Memory: struct {
        address: u64,
        size: u64,
        prefetchable: bool,
        type_64bit: bool,
    },
    Io: struct {
        address: u32,
        size: u32,
    },
    None: void,
};

// ============================================================================
// PCI Device Structure
// ============================================================================

pub const PciDevice = struct {
    address: PciAddress,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    revision_id: u8,
    header_type: u8,
    interrupt_line: u8,
    interrupt_pin: u8,
    bars: [6]Bar,

    /// Check if device exists (vendor_id != 0xFFFF)
    pub fn exists(addr: PciAddress) bool {
        return readConfig16(addr, ConfigOffset.VENDOR_ID) != 0xFFFF;
    }

    /// Read device information from PCI configuration space
    pub fn read(addr: PciAddress) !PciDevice {
        const vendor_id = readConfig16(addr, ConfigOffset.VENDOR_ID);
        if (vendor_id == 0xFFFF) {
            return error.NoDevice;
        }

        var device = PciDevice{
            .address = addr,
            .vendor_id = vendor_id,
            .device_id = readConfig16(addr, ConfigOffset.DEVICE_ID),
            .class_code = readConfig8(addr, ConfigOffset.CLASS_CODE),
            .subclass = readConfig8(addr, ConfigOffset.SUBCLASS),
            .prog_if = readConfig8(addr, ConfigOffset.PROG_IF),
            .revision_id = readConfig8(addr, ConfigOffset.REVISION_ID),
            .header_type = readConfig8(addr, ConfigOffset.HEADER_TYPE) & 0x7F,
            .interrupt_line = readConfig8(addr, ConfigOffset.INTERRUPT_LINE),
            .interrupt_pin = readConfig8(addr, ConfigOffset.INTERRUPT_PIN),
            .bars = undefined,
        };

        // Read BARs
        for (0..6) |i| {
            device.bars[i] = device.readBar(@intCast(i));
        }

        return device;
    }

    /// Read a specific BAR
    fn readBar(self: PciDevice, bar_index: u8) Bar {
        if (bar_index >= 6) return .None;

        const bar_offset = ConfigOffset.BAR0 + (bar_index * 4);
        const bar_value = readConfig32(self.address, bar_offset);

        if (bar_value == 0) return .None;

        // Check if I/O or Memory
        if ((bar_value & 1) == 1) {
            // I/O BAR
            const base_address = bar_value & 0xFFFFFFFC;

            // Get size by writing all 1s and reading back
            writeConfig32(self.address, bar_offset, 0xFFFFFFFF);
            const size_mask = readConfig32(self.address, bar_offset) & 0xFFFFFFFC;
            writeConfig32(self.address, bar_offset, bar_value); // Restore

            const size = (~size_mask) + 1;

            return .{ .Io = .{
                .address = base_address,
                .size = size,
            } };
        } else {
            // Memory BAR
            const bar_type = (bar_value >> 1) & 0x3;
            const prefetchable = (bar_value & 0x8) != 0;

            if (bar_type == 0) {
                // 32-bit address
                const base_address = bar_value & 0xFFFFFFF0;

                // Get size
                writeConfig32(self.address, bar_offset, 0xFFFFFFFF);
                const size_mask = readConfig32(self.address, bar_offset) & 0xFFFFFFF0;
                writeConfig32(self.address, bar_offset, bar_value);

                const size = (~size_mask) + 1;

                return .{ .Memory = .{
                    .address = base_address,
                    .size = size,
                    .prefetchable = prefetchable,
                    .type_64bit = false,
                } };
            } else if (bar_type == 2) {
                // 64-bit address
                const low = bar_value & 0xFFFFFFF0;
                const high = readConfig32(self.address, bar_offset + 4);
                const base_address = (@as(u64, high) << 32) | low;

                // Get size (write to both low and high)
                writeConfig32(self.address, bar_offset, 0xFFFFFFFF);
                writeConfig32(self.address, bar_offset + 4, 0xFFFFFFFF);
                const size_low = readConfig32(self.address, bar_offset) & 0xFFFFFFF0;
                const size_high = readConfig32(self.address, bar_offset + 4);
                writeConfig32(self.address, bar_offset, bar_value);
                writeConfig32(self.address, bar_offset + 4, high);

                const size_mask = (@as(u64, size_high) << 32) | size_low;
                const size = (~size_mask) + 1;

                return .{ .Memory = .{
                    .address = base_address,
                    .size = size,
                    .prefetchable = prefetchable,
                    .type_64bit = true,
                } };
            }
        }

        return .None;
    }

    /// Get a specific BAR
    pub fn getBar(self: PciDevice, bar_index: u8) Bar {
        if (bar_index >= 6) return .None;
        return self.bars[bar_index];
    }

    /// Enable bus mastering (DMA)
    pub fn enableBusMastering(self: PciDevice) void {
        const command = readConfig16(self.address, ConfigOffset.COMMAND);
        writeConfig16(self.address, ConfigOffset.COMMAND, command | CommandBits.BUS_MASTER);
    }

    /// Disable bus mastering
    pub fn disableBusMastering(self: PciDevice) void {
        const command = readConfig16(self.address, ConfigOffset.COMMAND);
        writeConfig16(self.address, ConfigOffset.COMMAND, command & ~CommandBits.BUS_MASTER);
    }

    /// Enable memory space access
    pub fn enableMemorySpace(self: PciDevice) void {
        const command = readConfig16(self.address, ConfigOffset.COMMAND);
        writeConfig16(self.address, ConfigOffset.COMMAND, command | CommandBits.MEMORY_SPACE);
    }

    /// Enable I/O space access
    pub fn enableIoSpace(self: PciDevice) void {
        const command = readConfig16(self.address, ConfigOffset.COMMAND);
        writeConfig16(self.address, ConfigOffset.COMMAND, command | CommandBits.IO_SPACE);
    }

    /// Check if device is multi-function
    pub fn isMultiFunction(addr: PciAddress) bool {
        const header_type = readConfig8(addr, ConfigOffset.HEADER_TYPE);
        return (header_type & 0x80) != 0;
    }

    /// Get device name string
    pub fn getName(self: PciDevice) []const u8 {
        return getDeviceName(self.vendor_id, self.device_id);
    }

    /// Get class name
    pub fn getClassName(self: PciDevice) []const u8 {
        return getClassCodeName(self.class_code);
    }

    /// Format device for printing
    pub fn format(
        self: PciDevice,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "PCI {x:0>2}:{x:0>2}.{x} [{x:0>4}:{x:0>4}] {s}: {s}",
            .{
                self.address.bus,
                self.address.device,
                self.address.function,
                self.vendor_id,
                self.device_id,
                self.getClassName(),
                self.getName(),
            },
        );
    }
};

// ============================================================================
// PCI Bus Enumeration
// ============================================================================

/// Scan all PCI buses and return list of devices
pub fn enumerateDevices(allocator: Basics.Allocator) ![]PciDevice {
    var devices = Basics.ArrayList(PciDevice).init(allocator);
    errdefer devices.deinit();

    // Scan all buses (0-255)
    for (0..256) |bus| {
        try scanBus(&devices, @intCast(bus));
    }

    return devices.toOwnedSlice();
}

/// Scan a single PCI bus
fn scanBus(devices: *Basics.ArrayList(PciDevice), bus: u8) !void {
    // Scan all devices (0-31)
    for (0..32) |device| {
        try scanDevice(devices, bus, @intCast(device));
    }
}

/// Scan a single PCI device
fn scanDevice(devices: *Basics.ArrayList(PciDevice), bus: u8, device: u5) !void {
    const addr = PciAddress.init(bus, device, 0);

    if (!PciDevice.exists(addr)) return;

    // Function 0 always exists if device exists
    const dev0 = try PciDevice.read(addr);
    try devices.append(dev0);

    // Check if multi-function device
    if (PciDevice.isMultiFunction(addr)) {
        // Scan functions 1-7
        for (1..8) |func| {
            const func_addr = PciAddress.init(bus, device, @intCast(func));
            if (PciDevice.exists(func_addr)) {
                const dev = try PciDevice.read(func_addr);
                try devices.append(dev);
            }
        }
    }
}

/// Find devices by vendor and device ID
pub fn findDevice(devices: []const PciDevice, vendor_id: u16, device_id: u16) ?PciDevice {
    for (devices) |dev| {
        if (dev.vendor_id == vendor_id and dev.device_id == device_id) {
            return dev;
        }
    }
    return null;
}

/// Find devices by class code
pub fn findDevicesByClass(
    devices: []const PciDevice,
    class_code: u8,
    allocator: Basics.Allocator,
) ![]PciDevice {
    var result = Basics.ArrayList(PciDevice).init(allocator);
    errdefer result.deinit();

    for (devices) |dev| {
        if (dev.class_code == class_code) {
            try result.append(dev);
        }
    }

    return result.toOwnedSlice();
}

// ============================================================================
// Common PCI Class Codes
// ============================================================================

pub const ClassCode = struct {
    pub const UNCLASSIFIED: u8 = 0x00;
    pub const MASS_STORAGE: u8 = 0x01;
    pub const NETWORK: u8 = 0x02;
    pub const DISPLAY: u8 = 0x03;
    pub const MULTIMEDIA: u8 = 0x04;
    pub const MEMORY: u8 = 0x05;
    pub const BRIDGE: u8 = 0x06;
    pub const COMMUNICATION: u8 = 0x07;
    pub const SYSTEM: u8 = 0x08;
    pub const INPUT: u8 = 0x09;
    pub const DOCKING: u8 = 0x0A;
    pub const PROCESSOR: u8 = 0x0B;
    pub const SERIAL_BUS: u8 = 0x0C;
    pub const WIRELESS: u8 = 0x0D;
};

pub const SubclassMassStorage = struct {
    pub const SCSI: u8 = 0x00;
    pub const IDE: u8 = 0x01;
    pub const FLOPPY: u8 = 0x02;
    pub const IPI: u8 = 0x03;
    pub const RAID: u8 = 0x04;
    pub const ATA: u8 = 0x05;
    pub const SATA: u8 = 0x06;
    pub const SAS: u8 = 0x07;
    pub const NVM: u8 = 0x08; // NVMe
};

pub const SubclassNetwork = struct {
    pub const ETHERNET: u8 = 0x00;
    pub const TOKEN_RING: u8 = 0x01;
    pub const FDDI: u8 = 0x02;
    pub const ATM: u8 = 0x03;
    pub const ISDN: u8 = 0x04;
    pub const WIFI: u8 = 0x80;
};

pub const SubclassSerialBus = struct {
    pub const FIREWIRE: u8 = 0x00;
    pub const ACCESS_BUS: u8 = 0x01;
    pub const SSA: u8 = 0x02;
    pub const USB: u8 = 0x03;
    pub const FIBRE_CHANNEL: u8 = 0x04;
    pub const SMBUS: u8 = 0x05;
};

// ============================================================================
// Device/Vendor Name Lookup (Partial Database)
// ============================================================================

fn getDeviceName(vendor_id: u16, device_id: u16) []const u8 {
    _ = device_id;
    return switch (vendor_id) {
        0x8086 => "Intel Device",
        0x1022 => "AMD Device",
        0x10EC => "Realtek Device",
        0x1234 => "QEMU Device",
        0x1AF4 => "VirtIO Device",
        0x15AD => "VMware Device",
        else => "Unknown Device",
    };
}

fn getClassCodeName(class_code: u8) []const u8 {
    return switch (class_code) {
        ClassCode.UNCLASSIFIED => "Unclassified",
        ClassCode.MASS_STORAGE => "Mass Storage Controller",
        ClassCode.NETWORK => "Network Controller",
        ClassCode.DISPLAY => "Display Controller",
        ClassCode.MULTIMEDIA => "Multimedia Controller",
        ClassCode.MEMORY => "Memory Controller",
        ClassCode.BRIDGE => "Bridge Device",
        ClassCode.COMMUNICATION => "Communication Controller",
        ClassCode.SYSTEM => "System Peripheral",
        ClassCode.INPUT => "Input Device",
        ClassCode.DOCKING => "Docking Station",
        ClassCode.PROCESSOR => "Processor",
        ClassCode.SERIAL_BUS => "Serial Bus Controller",
        ClassCode.WIRELESS => "Wireless Controller",
        else => "Unknown",
    };
}

// ============================================================================
// MSI/MSI-X Support
// ============================================================================

pub const MsiCapability = struct {
    address: u64,
    data: u32,
    vector: u8,
};

/// Find MSI capability in device
pub fn findMsiCapability(device: PciDevice) ?u8 {
    var cap_ptr = readConfig8(device.address, ConfigOffset.CAPABILITIES) & 0xFC;

    while (cap_ptr != 0) {
        const cap_id = readConfig8(device.address, cap_ptr);
        if (cap_id == 0x05) { // MSI capability
            return cap_ptr;
        }
        cap_ptr = readConfig8(device.address, cap_ptr + 1) & 0xFC;
    }

    return null;
}

/// Find MSI-X capability in device
pub fn findMsiXCapability(device: PciDevice) ?u8 {
    var cap_ptr = readConfig8(device.address, ConfigOffset.CAPABILITIES) & 0xFC;

    while (cap_ptr != 0) {
        const cap_id = readConfig8(device.address, cap_ptr);
        if (cap_id == 0x11) { // MSI-X capability
            return cap_ptr;
        }
        cap_ptr = readConfig8(device.address, cap_ptr + 1) & 0xFC;
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "PCI address conversion" {
    const addr = PciAddress.init(0, 0, 0);
    const config = addr.toConfigAddress(0);
    try Basics.testing.expect((config & CONFIG_ENABLE) != 0);
}

test "PCI device detection" {
    // Can't actually test without hardware, but verify API compiles
    _ = PciDevice.exists;
    _ = enumerateDevices;
}
