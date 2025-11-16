# IOMMU (DMA Protection) Package

Hardware-assisted DMA protection using IOMMU/VT-d for device isolation and memory remapping in Home OS.

## Overview

The `iommu` package provides comprehensive DMA protection features:

- **DMA Remapping**: Translate device DMA addresses to protect memory
- **Device Isolation**: Separate address spaces per device/domain
- **Interrupt Remapping**: Prevent interrupt injection attacks
- **Page Tables**: Multi-level address translation
- **Fault Handling**: Detect and log DMA violations
- **Intel VT-d Support**: Industry-standard IOMMU implementation

## Why IOMMU?

Without an IOMMU, devices can access any physical memory via DMA (Direct Memory Access), enabling:

- **DMA Attacks**: Malicious devices reading/writing arbitrary memory
- **Data Exfiltration**: Devices stealing sensitive data
- **Privilege Escalation**: Devices modifying kernel memory
- **Thunderbolt/PCIe Attacks**: Hot-plug attacks via external ports

The IOMMU acts as a "MMU for devices", providing the same memory protection for DMA that the CPU MMU provides for software.

## Quick Start

### Basic IOMMU Initialization

```zig
const std = @import("std");
const iommu = @import("iommu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create IOMMU instance
    var io = iommu.IOMMU.init(allocator, .intel_vtd);

    // Enable DMA protection
    try io.enable();
    defer io.disable();

    std.debug.print("IOMMU enabled: {}\n", .{io.isEnabled()});
    std.debug.print("Protection level: {}\n", .{io.protection_level});
}
```

### Device Isolation with Domains

```zig
const std = @import("std");
const iommu = @import("iommu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create domain allocator
    var domain_alloc = iommu.iommu_domain.DomainAllocator.init(allocator);
    defer domain_alloc.deinit();

    // Create isolated domain for network card
    var net_domain = try domain_alloc.allocate(.dma);

    // Define devices (PCI Bus-Device-Function)
    const network_card = iommu.DeviceID.init(
        0,      // Segment
        0x02,   // Bus
        0x00,   // Device
        0x0,    // Function
    );

    // Attach device to domain
    try net_domain.attachDevice(network_card);

    // Map DMA buffer for device
    const dma_buffer_iova = 0x10000;  // Device-visible address
    const dma_buffer_phys = 0x50000;  // Actual physical address
    const buffer_size = 4096;

    const access = iommu.iommu_domain.AccessFlags{
        .read = true,
        .write = true,
        .execute = false,
    };

    try net_domain.map(dma_buffer_iova, dma_buffer_phys, buffer_size, access);

    std.debug.print("Network card isolated in domain {}\n", .{net_domain.id});
    std.debug.print("DMA buffer mapped: 0x{X}: 0x{X}\n", .{
        dma_buffer_iova,
        dma_buffer_phys,
    });
}
```

### Intel VT-d DMA Remapping

```zig
const std = @import("std");
const iommu = @import("iommu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure DMA Remapping Hardware Unit
    const drhd = iommu.dmar.DRHD{
        .base_addr = 0xFED90000,  // IOMMU MMIO base address
        .segment = 0,
        .flags = .{ .include_pci_all = true },
        .scope = &.{},
    };

    // Create DMAR engine
    var engine = iommu.dmar.DMAREngine.init(allocator, drhd);

    // Initialize root table
    var root_table = try iommu.dmar.RootTable.init(allocator);
    defer root_table.deinit();

    engine.setRootTable(root_table);

    // Enable DMA remapping
    try engine.enable();
    defer engine.disable();

    std.debug.print("VT-d DMA remapping enabled\n", .{});

    // Setup device context
    const device = iommu.DeviceID.init(0, 0x00, 0x1F, 0x0);
    const bus = device.bus;
    const devfn = (@as(u8, device.device) << 3) | @as(u8, device.function);

    // Get root entry for bus
    const root_entry = root_table.getEntry(bus);

    // Create context table
    var context_table = try iommu.dmar.ContextTable.init(allocator);
    defer context_table.deinit();

    root_entry.setContextTable(context_table);

    // Get context entry for device
    const context_entry = context_table.getEntry(devfn);

    // Configure for domain 1 with page table
    const page_table_addr: u64 = 0x100000;
    context_entry.setDomain(1, page_table_addr);

    std.debug.print("Device {} configured for DMA remapping\n", .{device});
}
```

### Interrupt Remapping

```zig
const std = @import("std");
const iommu = @import("iommu");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create interrupt remapping manager (256 IRTEs)
    var ir_manager = try iommu.interrupt.InterruptRemappingManager.init(allocator, 256);
    defer ir_manager.deinit();

    // Enable interrupt remapping
    ir_manager.enable();
    defer ir_manager.disable();

    const device = iommu.DeviceID.init(0, 0x02, 0x00, 0x0);

    // Map device interrupt to CPU 0, vector 0x42
    const irte_index = try ir_manager.mapDeviceInterrupt(
        device,
        0,      // Destination CPU
        0x42,   // Interrupt vector
    );

    std.debug.print("Device interrupt remapped to IRTE index {}\n", .{irte_index});
    std.debug.print("Interrupt remapping enabled: {}\n", .{ir_manager.isEnabled()});
}
```

## Features

### DMA Remapping

Translate device DMA addresses to physical addresses:

```zig
var domain = iommu.iommu_domain.Domain.init(allocator, 1, .dma);
defer domain.deinit();

// Map 2MB buffer
const iova = 0x100000;   // What device sees
const paddr = 0x500000;  // Actual memory
const size = 2 * 1024 * 1024;

const access = iommu.iommu_domain.AccessFlags{
    .read = true,
    .write = true,
    .execute = false,
};

try domain.map(iova, paddr, size, access);

// Device can only access mapped region
const translated = domain.translate(iova + 0x1000);
// Returns: 0x501000
```

**Benefits:**
- Devices can't access unmapped memory
- Multiple devices get isolated address spaces
- Kernel memory protected from malicious devices
- Fine-grained access control (RW permissions)

### Device Isolation

Separate address spaces per device or device group:

```zig
// Domain 1: Network card
var net_domain = try domain_alloc.allocate(.dma);
try net_domain.attachDevice(network_card);

// Domain 2: GPU
var gpu_domain = try domain_alloc.allocate(.dma);
try gpu_domain.attachDevice(graphics_card);

// Domains are completely isolated
// Network card cannot access GPU memory and vice versa
```

**Domain Types:**
- `dma`: Normal DMA domain with remapping
- `identity`: 1:1 mapping (passthrough mode)
- `unmanaged`: User-managed page tables

### Interrupt Remapping

Prevent interrupt injection attacks:

```zig
// Without interrupt remapping:
// - Malicious device can send any interrupt
// - Device can impersonate other devices
// - Can trigger kernel bugs via specific interrupts

// With interrupt remapping:
var irte = iommu.interrupt.IRTE.init();
irte.configure(
    0,              // CPU 0
    0x30,           // Vector
    .fixed,         // Delivery mode
);

// Now only this configured interrupt is allowed
// Device cannot send arbitrary interrupts
```

### Page Table Management

Multi-level page tables for address translation:

```zig
var walker = try iommu.page_table.PageTableWalker.init(allocator);
defer walker.deinit();

// Map page with permissions
const flags = iommu.page_table.PTEFlags.readWrite();
try walker.map(virtual_addr, physical_addr, flags);

// Translate address
const translated = walker.translate(virtual_addr);

// Unmap when done
try walker.unmap(virtual_addr);
```

**Page Levels:**
- Level 1: 4KB pages
- Level 2: 2MB pages (huge pages)
- Level 3: 1GB pages (giant pages)
- Level 4: 512GB (root level)

### Fault Handling

Detect and log DMA violations:

```zig
// DMA fault occurs when device violates policy
const fault = iommu.Fault.init(
    device_id,
    fault_addr,
    .invalid_address,
    "Device accessed unmapped memory",
);

// Record fault
io.status.recordFault();

// Check fault statistics
const fault_count = io.status.getFaultCount();
const translation_errors = io.status.getTranslationErrors();
```

**Fault Types:**
- `invalid_address`: Unmapped memory access
- `permission_denied`: Read-only write attempt
- `page_not_present`: Missing page table entry
- `context_entry_invalid`: Bad device configuration
- `interrupt_remap_fault`: Invalid interrupt

## Protection Levels

```zig
// Disabled: No protection (unsafe)
try io.setProtectionLevel(.disabled);

// Basic: DMA remapping only
try io.setProtectionLevel(.basic);

// Standard: DMA + interrupt remapping
try io.setProtectionLevel(.standard);

// Strict: Full isolation + paranoid checks
try io.setProtectionLevel(.strict);
```

## Complete Example

Secure system with full IOMMU protection:

```zig
const std = @import("std");
const iommu = @import("iommu");

pub const SecureIOMMU = struct {
    allocator: std.mem.Allocator,
    iommu: iommu.IOMMU,
    domain_alloc: iommu.iommu_domain.DomainAllocator,
    dmar_manager: iommu.dmar.DMARManager,
    ir_manager: iommu.interrupt.InterruptRemappingManager,

    pub fn init(allocator: std.mem.Allocator) !SecureIOMMU {
        var secure: SecureIOMMU = undefined;
        secure.allocator = allocator;
        secure.iommu = iommu.IOMMU.init(allocator, .intel_vtd);
        secure.domain_alloc = iommu.iommu_domain.DomainAllocator.init(allocator);
        secure.dmar_manager = iommu.dmar.DMARManager.init(allocator);
        secure.ir_manager = try iommu.interrupt.InterruptRemappingManager.init(allocator, 1024);

        // Enable protections
        try secure.iommu.enable();
        try secure.iommu.setProtectionLevel(.strict);
        secure.ir_manager.enable();

        return secure;
    }

    pub fn deinit(self: *SecureIOMMU) void {
        self.iommu.disable();
        self.ir_manager.disable();
        self.domain_alloc.deinit();
        self.dmar_manager.deinit();
        self.ir_manager.deinit();
    }

    pub fn isolateDevice(
        self: *SecureIOMMU,
        device_id: iommu.DeviceID,
    ) !*iommu.iommu_domain.Domain {
        // Create isolated domain
        var domain = try self.domain_alloc.allocate(.dma);
        try domain.attachDevice(device_id);

        // Register with DMAR
        try self.dmar_manager.attachDevice(device_id, domain.id);

        // Setup interrupt remapping
        _ = try self.ir_manager.mapDeviceInterrupt(device_id, 0, 0x40);

        self.iommu.recordDeviceRemapped();

        return domain;
    }

    pub fn mapDeviceBuffer(
        self: *SecureIOMMU,
        domain: *iommu.iommu_domain.Domain,
        iova: u64,
        paddr: u64,
        size: usize,
        writable: bool,
    ) !void {
        _ = self;

        const access = iommu.iommu_domain.AccessFlags{
            .read = true,
            .write = writable,
            .execute = false,
        };

        try domain.map(iova, paddr, size, access);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var secure_iommu = try SecureIOMMU.init(allocator);
    defer secure_iommu.deinit();

    // Isolate network card
    const net_card = iommu.DeviceID.init(0, 0x02, 0x00, 0x0);
    var net_domain = try secure_iommu.isolateDevice(net_card);

    // Map RX buffer
    try secure_iommu.mapDeviceBuffer(
        net_domain,
        0x10000,  // IOVA
        0x200000, // Physical
        64 * 1024, // 64KB
        true,     // Writable
    );

    // Map TX buffer (read-only from device perspective)
    try secure_iommu.mapDeviceBuffer(
        net_domain,
        0x20000,
        0x300000,
        64 * 1024,
        false, // Read-only
    );

    std.debug.print("Network card isolated with DMA protection\n", .{});
    std.debug.print("Remapped devices: {}\n", .{secure_iommu.iommu.getRemappedDeviceCount()});
}
```

## IOMMU Types

| Type | Description | Platforms |
|------|-------------|-----------|
| Intel VT-d | DMA Remapping | Intel CPUs with VT-d |
| AMD-Vi | AMD IOMMU | AMD CPUs |
| ARM SMMU | System MMU | ARM servers |

## Best Practices

### Security

1. **Always enable IOMMU**: Boot with `intel_iommu=on` or `amd_iommu=on`
2. **Use strict mode**: Maximum protection with paranoid checks
3. **Isolate untrusted devices**: External/hotplug devices get separate domains
4. **Enable interrupt remapping**: Prevent interrupt injection attacks
5. **Monitor faults**: Log and alert on DMA violations
6. **Least privilege**: Only map memory devices actually need
7. **Read-only when possible**: DMA buffers that devices only read

### Performance

1. **Use huge pages**: 2MB/1GB pages reduce TLB misses
2. **Batch mappings**: Group multiple map operations
3. **Pre-allocate domains**: Avoid allocation in fast path
4. **Passthrough for trusted**: Use identity domains for performance
5. **Device TLB**: Enable if hardware supports it

### Deployment

1. **Check BIOS settings**: IOMMU must be enabled in firmware
2. **Kernel parameters**: Set `iommu=pt` for passthrough default
3. **Test thoroughly**: Some devices have buggy DMA code
4. **Gradual rollout**: Start with non-critical devices
5. **Monitor performance**: Watch for TLB-related overhead
6. **Update firmware**: Newer IOMMU firmware may fix bugs

## Troubleshooting

### IOMMU Not Available

```zig
var io = iommu.IOMMU.init(allocator, .intel_vtd);
io.enable() catch |err| {
    if (err == error.NoIOMMU) {
        // IOMMU not present or disabled in BIOS
        std.debug.print("Enable VT-d in BIOS settings\n", .{});
    }
};
```

### DMA Faults

Common causes:
- Device driver bug (mapping wrong address)
- Buffer freed while device still using it
- Device firmware bug
- Insufficient aperture size

### Performance Issues

If IOMMU causes slowdown:
1. Check for excessive TLB misses
2. Use larger page sizes
3. Enable caching in IOMMU
4. Consider passthrough for trusted devices

## Hardware Requirements

- **Intel**: VT-d capable CPU (check with `cat /proc/cpuinfo | grep dmar`)
- **AMD**: AMD-Vi support (check `dmesg | grep AMD-Vi`)
- **BIOS**: IOMMU/VT-d enabled in firmware
- **Kernel**: IOMMU support compiled in

## License

Part of the Home programming language project.
