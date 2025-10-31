// Home OS - PCI/PCIe Driver Support
// PCI/PCIe device enumeration, configuration, and management

const std = @import("std");
const drivers = @import("drivers.zig");

// ============================================================================
// PCI Configuration Space Access
// ============================================================================

pub const PCI_CONFIG_ADDRESS = 0xCF8;
pub const PCI_CONFIG_DATA = 0xCFC;

pub const PCIAddress = packed struct {
    register: u8,
    function: u3,
    device: u5,
    bus: u8,
    reserved: u7,
    enable: u1,

    pub fn encode(bus: u8, device: u5, function: u3, register: u8) u32 {
        const addr = PCIAddress{
            .enable = 1,
            .reserved = 0,
            .bus = bus,
            .device = device,
            .function = function,
            .register = register & 0xFC, // Align to 4-byte boundary
        };
        return @bitCast(addr);
    }
};

// ============================================================================
// PCI Device Classes
// ============================================================================

pub const PCIClass = enum(u8) {
    unclassified = 0x00,
    mass_storage = 0x01,
    network = 0x02,
    display = 0x03,
    multimedia = 0x04,
    memory = 0x05,
    bridge = 0x06,
    simple_comm = 0x07,
    base_system = 0x08,
    input = 0x09,
    docking = 0x0A,
    processor = 0x0B,
    serial_bus = 0x0C,
    wireless = 0x0D,
    intelligent = 0x0E,
    satellite = 0x0F,
    encryption = 0x10,
    signal_processing = 0x11,
    processing_accelerator = 0x12,
    non_essential = 0x13,
    _,

    pub fn toString(self: PCIClass) []const u8 {
        return switch (self) {
            .unclassified => "Unclassified",
            .mass_storage => "Mass Storage Controller",
            .network => "Network Controller",
            .display => "Display Controller",
            .multimedia => "Multimedia Controller",
            .memory => "Memory Controller",
            .bridge => "Bridge Device",
            .simple_comm => "Simple Communication Controller",
            .base_system => "Base System Peripheral",
            .input => "Input Device",
            .docking => "Docking Station",
            .processor => "Processor",
            .serial_bus => "Serial Bus Controller",
            .wireless => "Wireless Controller",
            .intelligent => "Intelligent I/O Controller",
            .satellite => "Satellite Communication Controller",
            .encryption => "Encryption/Decryption Controller",
            .signal_processing => "Data Acquisition & Signal Processing",
            .processing_accelerator => "Processing Accelerator",
            .non_essential => "Non-Essential Instrumentation",
            else => "Unknown Device Class",
        };
    }
};

// ============================================================================
// PCI Device Configuration
// ============================================================================

pub const PCIConfig = packed struct {
    vendor_id: u16,
    device_id: u16,
    command: u16,
    status: u16,
    revision_id: u8,
    prog_if: u8,
    subclass: u8,
    class_code: u8,
    cache_line_size: u8,
    latency_timer: u8,
    header_type: u8,
    bist: u8,
    bar0: u32,
    bar1: u32,
    bar2: u32,
    bar3: u32,
    bar4: u32,
    bar5: u32,
    cardbus_cis_pointer: u32,
    subsystem_vendor_id: u16,
    subsystem_id: u16,
    expansion_rom_base: u32,
    capabilities_pointer: u8,
    reserved: [7]u8,
    interrupt_line: u8,
    interrupt_pin: u8,
    min_grant: u8,
    max_latency: u8,
};

// ============================================================================
// PCI Device Structure
// ============================================================================

pub const PCIDevice = struct {
    bus: u8,
    device: u5,
    function: u3,
    vendor_id: u16,
    device_id: u16,
    class_code: PCIClass,
    subclass: u8,
    prog_if: u8,
    interrupt_line: u8,
    interrupt_pin: u8,
    bars: [6]u32,

    pub fn format(
        self: *const PCIDevice,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("PCI {d:0>2}:{d:0>2}.{d} [{s}] {X:0>4}:{X:0>4}", .{
            self.bus,
            self.device,
            self.function,
            self.class_code.toString(),
            self.vendor_id,
            self.device_id,
        });
    }

    pub fn readConfig(self: PCIDevice, offset: u8) u32 {
        return readConfigDword(self.bus, self.device, self.function, offset);
    }

    pub fn writeConfig(self: PCIDevice, offset: u8, value: u32) void {
        writeConfigDword(self.bus, self.device, self.function, offset, value);
    }

    pub fn enableBusMastering(self: PCIDevice) void {
        const command = self.readConfig(0x04) & 0xFFFF;
        self.writeConfig(0x04, command | 0x04); // Set bus master bit
    }

    pub fn getBAR(self: PCIDevice, bar_index: u3) ?u64 {
        if (bar_index >= 6) return null;

        const bar = self.bars[bar_index];
        if (bar == 0) return null;

        // Check if this is a 64-bit BAR
        if ((bar & 0x06) == 0x04) {
            if (bar_index >= 5) return null; // Invalid 64-bit BAR at index 5

            const low = bar & 0xFFFFFFF0;
            const high = self.bars[bar_index + 1];
            return (@as(u64, high) << 32) | low;
        }

        // 32-bit BAR
        return bar & 0xFFFFFFF0;
    }

    pub fn isIOBar(self: PCIDevice, bar_index: u3) bool {
        if (bar_index >= 6) return false;
        return (self.bars[bar_index] & 0x01) == 1;
    }
};

// ============================================================================
// PCI Configuration Space I/O
// ============================================================================

pub fn readConfigDword(bus: u8, device: u5, function: u3, offset: u8) u32 {
    const address = PCIAddress.encode(bus, device, function, offset);
    outl(PCI_CONFIG_ADDRESS, address);
    return inl(PCI_CONFIG_DATA);
}

pub fn writeConfigDword(bus: u8, device: u5, function: u3, offset: u8, value: u32) void {
    const address = PCIAddress.encode(bus, device, function, offset);
    outl(PCI_CONFIG_ADDRESS, address);
    outl(PCI_CONFIG_DATA, value);
}

pub fn readConfigWord(bus: u8, device: u5, function: u3, offset: u8) u16 {
    const dword = readConfigDword(bus, device, function, offset);
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(dword >> shift);
}

pub fn readConfigByte(bus: u8, device: u5, function: u3, offset: u8) u8 {
    const dword = readConfigDword(bus, device, function, offset);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(dword >> shift);
}

// ============================================================================
// Port I/O Functions (x86/x86_64)
// ============================================================================

inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}

inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

// ============================================================================
// PCI Bus Enumeration
// ============================================================================

pub const PCIEnumerator = struct {
    devices: std.ArrayList(PCIDevice),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PCIEnumerator {
        return .{
            .devices = std.ArrayList(PCIDevice).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PCIEnumerator) void {
        self.devices.deinit();
    }

    pub fn scan(self: *PCIEnumerator) !void {
        // Scan all buses (0-255)
        for (0..256) |bus_num| {
            const bus: u8 = @intCast(bus_num);
            try self.scanBus(bus);
        }
    }

    fn scanBus(self: *PCIEnumerator, bus: u8) !void {
        // Scan all devices (0-31)
        for (0..32) |device_num| {
            const device: u5 = @intCast(device_num);
            try self.scanDevice(bus, device);
        }
    }

    fn scanDevice(self: *PCIEnumerator, bus: u8, device: u5) !void {
        const vendor_id = readConfigWord(bus, device, 0, 0x00);

        // 0xFFFF means no device
        if (vendor_id == 0xFFFF) return;

        // Check function 0
        try self.scanFunction(bus, device, 0);

        // Check if multi-function device
        const header_type = readConfigByte(bus, device, 0, 0x0E);
        if ((header_type & 0x80) != 0) {
            // Multi-function device, scan functions 1-7
            for (1..8) |func_num| {
                const function: u3 = @intCast(func_num);
                const func_vendor = readConfigWord(bus, device, function, 0x00);
                if (func_vendor != 0xFFFF) {
                    try self.scanFunction(bus, device, function);
                }
            }
        }
    }

    fn scanFunction(self: *PCIEnumerator, bus: u8, device: u5, function: u3) !void {
        const vendor_id = readConfigWord(bus, device, function, 0x00);
        if (vendor_id == 0xFFFF) return;

        const device_id = readConfigWord(bus, device, function, 0x02);
        const class_code: PCIClass = @enumFromInt(readConfigByte(bus, device, function, 0x0B));
        const subclass = readConfigByte(bus, device, function, 0x0A);
        const prog_if = readConfigByte(bus, device, function, 0x09);
        const interrupt_line = readConfigByte(bus, device, function, 0x3C);
        const interrupt_pin = readConfigByte(bus, device, function, 0x3D);

        // Read BARs
        var bars: [6]u32 = undefined;
        for (0..6) |i| {
            const offset: u8 = @intCast(0x10 + (i * 4));
            bars[i] = readConfigDword(bus, device, function, offset);
        }

        const pci_device = PCIDevice{
            .bus = bus,
            .device = device,
            .function = function,
            .vendor_id = vendor_id,
            .device_id = device_id,
            .class_code = class_code,
            .subclass = subclass,
            .prog_if = prog_if,
            .interrupt_line = interrupt_line,
            .interrupt_pin = interrupt_pin,
            .bars = bars,
        };

        try self.devices.append(pci_device);
    }

    pub fn findDevice(self: *PCIEnumerator, vendor_id: u16, device_id: u16) ?PCIDevice {
        for (self.devices.items) |device| {
            if (device.vendor_id == vendor_id and device.device_id == device_id) {
                return device;
            }
        }
        return null;
    }

    pub fn findByClass(self: *PCIEnumerator, class_code: PCIClass) []const PCIDevice {
        var result = std.ArrayList(PCIDevice).init(self.allocator);
        for (self.devices.items) |device| {
            if (device.class_code == class_code) {
                result.append(device) catch break;
            }
        }
        return result.toOwnedSlice() catch &[_]PCIDevice{};
    }
};

// ============================================================================
// Known Vendor IDs
// ============================================================================

pub const VendorID = struct {
    pub const INTEL = 0x8086;
    pub const AMD = 0x1022;
    pub const NVIDIA = 0x10DE;
    pub const VMWARE = 0x15AD;
    pub const QEMU = 0x1234;
    pub const VIRTIO = 0x1AF4;
    pub const REALTEK = 0x10EC;
    pub const BROADCOM = 0x14E4;
};

// ============================================================================
// Tests
// ============================================================================

test "PCI address encoding" {
    const testing = std.testing;

    const addr = PCIAddress.encode(0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 0x80000000), addr);

    const addr2 = PCIAddress.encode(1, 2, 3, 0x10);
    const expected: u32 = 0x80010B10;
    try testing.expectEqual(expected, addr2);
}

test "PCI class toString" {
    const testing = std.testing;

    try testing.expect(std.mem.eql(u8, "Network Controller", PCIClass.network.toString()));
    try testing.expect(std.mem.eql(u8, "Display Controller", PCIClass.display.toString()));
}
