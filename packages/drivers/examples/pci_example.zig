// Example: PCI Device Enumeration

const std = @import("std");
const drivers = @import("drivers");

pub fn main() !void {
    std.debug.print("=== PCI Device Enumeration Example ===\n\n", .{});

    // Note: This example demonstrates the API
    // Actual hardware access would require kernel privileges

    std.debug.print("PCI Configuration Space:\n", .{});
    std.debug.print("  Address Port: 0x{X:0>4}\n", .{drivers.pci.PCI_CONFIG_ADDRESS});
    std.debug.print("  Data Port: 0x{X:0>4}\n\n", .{drivers.pci.PCI_CONFIG_DATA});

    // Demonstrate PCI address encoding
    std.debug.print("PCI Address Encoding:\n", .{});
    const addr1 = drivers.pci.PCIAddress.encode(0, 0, 0, 0);
    std.debug.print("  Bus 0, Device 0, Function 0, Reg 0: 0x{X:0>8}\n", .{addr1});

    const addr2 = drivers.pci.PCIAddress.encode(1, 15, 3, 0x10);
    std.debug.print("  Bus 1, Device 15, Function 3, Reg 0x10: 0x{X:0>8}\n\n", .{addr2});

    // Device class information
    std.debug.print("PCI Device Classes:\n", .{});
    const classes = [_]drivers.pci.PCIClass{
        .network,
        .display,
        .mass_storage,
        .bridge,
        .input,
    };

    for (classes) |class| {
        std.debug.print("  0x{X:0>2}: {s}\n", .{ @intFromEnum(class), class.toString() });
    }

    // Known vendors
    std.debug.print("\nKnown PCI Vendors:\n", .{});
    std.debug.print("  Intel: 0x{X:0>4}\n", .{drivers.pci.VendorID.INTEL});
    std.debug.print("  AMD: 0x{X:0>4}\n", .{drivers.pci.VendorID.AMD});
    std.debug.print("  NVIDIA: 0x{X:0>4}\n", .{drivers.pci.VendorID.NVIDIA});
    std.debug.print("  VMware: 0x{X:0>4}\n", .{drivers.pci.VendorID.VMWARE});
    std.debug.print("  QEMU: 0x{X:0>4}\n", .{drivers.pci.VendorID.QEMU});

    // Simulate device discovery
    std.debug.print("\nSimulated PCI Device:\n", .{});
    const sim_device = drivers.pci.PCIDevice{
        .bus = 0,
        .device = 2,
        .function = 0,
        .vendor_id = drivers.pci.VendorID.INTEL,
        .device_id = 0x1234,
        .class_code = .network,
        .subclass = 0x00,
        .prog_if = 0x00,
        .interrupt_line = 11,
        .interrupt_pin = 1,
        .bars = .{ 0xC0001000, 0, 0, 0, 0, 0 },
    };

    std.debug.print("  {}\n", .{sim_device});
    std.debug.print("  BAR0: 0x{X:0>8}\n", .{sim_device.bars[0]});
    if (sim_device.getBAR(0)) |bar_addr| {
        std.debug.print("  BAR0 Address: 0x{X}\n", .{bar_addr});
        std.debug.print("  Is I/O BAR: {}\n", .{sim_device.isIOBar(0)});
    }

    std.debug.print("\nNote: Actual PCI enumeration requires kernel mode access\n", .{});
}
