# Device Tree Binary (DTB) Support

Comprehensive Device Tree Binary (DTB) parser for Home OS with full support for ARM64 boot, hardware discovery, and address translation.

## Features

- **Complete DTB Parser**: Parse Flattened Device Tree (FDT) binaries
- **Node Traversal**: Navigate device tree hierarchy
- **Property Access**: Type-safe property value extraction
- **Address Translation**: Translate addresses between bus hierarchies
- **Memory Discovery**: Parse memory nodes and reservations
- **Interrupt Mapping**: Parse interrupt specifications
- **Compatible Matching**: Device driver matching by compatible strings

## Architecture

### Modules

```
dtb/
├── dtb.zig       # Core DTB/FDT parser
├── address.zig   # Address translation and mapping
└── main.zig      # Public API
```

## Usage

### Parsing a Device Tree

```zig
const std = @import("std");
const dtb = @import("dtb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load DTB from file or memory
    const dtb_data = try std.fs.cwd().readFileAlloc(allocator, "device-tree.dtb", 1024 * 1024);
    defer allocator.free(dtb_data);

    // Parse device tree
    var device_tree = try dtb.DeviceTree.parse(allocator, dtb_data);
    defer device_tree.deinit();

    std.debug.print("Device Tree version: {d}\n", .{device_tree.header.version});
    std.debug.print("Total size: {d} bytes\n", .{device_tree.header.totalsize});
}
```

### Finding Nodes

```zig
// Find node by path
if (device_tree.findNode("/soc/uart@10000000")) |uart_node| {
    std.debug.print("Found UART node: {s}\n", .{uart_node.name});
}

// Find memory node
if (device_tree.findNode("/memory")) |memory_node| {
    const memory_ranges = try dtb.Memory.fromNode(memory_node, allocator);
    defer allocator.free(memory_ranges);

    for (memory_ranges) |mem| {
        std.debug.print("Memory: 0x{x} - 0x{x} ({d} MB)\n", .{
            mem.address,
            mem.address + mem.size,
            mem.size / (1024 * 1024),
        });
    }
}

// Iterate through children
const root = device_tree.root;
for (root.children.items) |child| {
    std.debug.print("Child node: {s}\n", .{child.name});
}
```

### Reading Properties

```zig
const node = device_tree.findNode("/soc/ethernet@20000000").?;

// String property
if (node.getProperty("status")) |prop| {
    const status = prop.asString().?;
    std.debug.print("Status: {s}\n", .{status});
}

// U32 property
if (node.getProperty("clock-frequency")) |prop| {
    const freq = prop.asU32().?;
    std.debug.print("Clock frequency: {d} Hz\n", .{freq});
}

// U64 property
if (node.getProperty("dma-mask")) |prop| {
    const mask = prop.asU64().?;
    std.debug.print("DMA mask: 0x{x}\n", .{mask});
}

// U32 array
if (node.getProperty("clocks")) |prop| {
    const clocks = try prop.asU32Array(allocator);
    defer allocator.free(clocks);

    for (clocks) |clock| {
        std.debug.print("Clock: 0x{x}\n", .{clock});
    }
}

// String list (compatible property)
if (node.getProperty("compatible")) |prop| {
    const compat_list = try prop.asStringList(allocator);
    defer allocator.free(compat_list);

    for (compat_list) |compat| {
        std.debug.print("Compatible: {s}\n", .{compat});
    }
}
```

### Device Matching

```zig
// Check if node is compatible with a specific driver
const node = device_tree.findNode("/soc/uart@10000000").?;

if (try node.isCompatible(allocator, "arm,pl011")) {
    std.debug.print("PL011 UART detected\n", .{});
}

// Get all compatible strings
const compat = try node.getCompatible(allocator) orelse return;
defer allocator.free(compat);

for (compat) |c| {
    std.debug.print("  - {s}\n", .{c});
}
```

### Address Translation

```zig
// Parse reg property
const node = device_tree.findNode("/soc/uart@10000000").?;
const reg_ranges = try dtb.parseReg(node, allocator);
defer allocator.free(reg_ranges);

for (reg_ranges, 0..) |range, i| {
    std.debug.print("Register {d}: addr=0x{x}, size=0x{x}\n", .{
        i,
        range.child_address,
        range.size,
    });
}

// Get physical address (translates through bus hierarchy)
const phys_addr = try dtb.getPhysicalAddress(node, allocator, 0);
std.debug.print("Physical address: 0x{x}\n", .{phys_addr});
```

### Memory Reservations

```zig
// Get memory reservations (regions reserved by firmware)
const reservations = try device_tree.getMemoryReservations(allocator);
defer allocator.free(reservations);

for (reservations) |reservation| {
    std.debug.print("Reserved: 0x{x} - 0x{x}\n", .{
        reservation.address,
        reservation.address + reservation.size,
    });
}
```

### Interrupt Handling

```zig
// Parse interrupts property
const interrupts = try dtb.parseInterrupts(node, allocator);
defer {
    for (interrupts) |*int| {
        int.deinit(allocator);
    }
    allocator.free(interrupts);
}

for (interrupts, 0..) |interrupt, i| {
    std.debug.print("Interrupt {d}: ", .{i});
    for (interrupt.cells) |cell| {
        std.debug.print("0x{x} ", .{cell});
    }
    std.debug.print("\n", .{});
}
```

## Device Tree Structure

### Root Properties

```zig
const root = device_tree.root;

// Model name
if (root.getProperty("model")) |prop| {
    std.debug.print("Model: {s}\n", .{prop.asString().?});
}

// Compatible strings
const compat = try root.getCompatible(allocator) orelse return;
defer allocator.free(compat);

// Address and size cells (defaults for children)
const addr_cells = root.getAddressCells(); // Usually 2 for 64-bit
const size_cells = root.getSizeCells(); // Usually 1 or 2
```

### Common Node Types

#### CPU Nodes

```zig
const cpus = device_tree.findNode("/cpus").?;

for (cpus.children.items) |cpu| {
    if (std.mem.startsWith(u8, cpu.name, "cpu")) {
        // CPU properties
        if (cpu.getProperty("device_type")) |prop| {
            std.debug.print("Device type: {s}\n", .{prop.asString().?});
        }

        if (cpu.getProperty("reg")) |prop| {
            const cpu_id = prop.asU32().?;
            std.debug.print("CPU ID: {d}\n", .{cpu_id});
        }

        if (cpu.getProperty("clock-frequency")) |prop| {
            const freq = prop.asU32().?;
            std.debug.print("Frequency: {d} MHz\n", .{freq / 1_000_000});
        }
    }
}
```

#### Memory Nodes

```zig
if (device_tree.findNode("/memory")) |mem_node| {
    const memory = try dtb.Memory.fromNode(mem_node, allocator);
    defer allocator.free(memory);

    var total: u64 = 0;
    for (memory) |mem| {
        std.debug.print("RAM: 0x{x:0>16} size 0x{x:0>16}\n", .{
            mem.address,
            mem.size,
        });
        total += mem.size;
    }

    std.debug.print("Total RAM: {d} GB\n", .{total / (1024 * 1024 * 1024)});
}
```

#### Chosen Node (Boot Parameters)

```zig
if (device_tree.findNode("/chosen")) |chosen| {
    // Boot arguments
    if (chosen.getProperty("bootargs")) |prop| {
        std.debug.print("Boot args: {s}\n", .{prop.asString().?});
    }

    // stdout path
    if (chosen.getProperty("stdout-path")) |prop| {
        std.debug.print("Console: {s}\n", .{prop.asString().?});
    }

    // Initrd location
    if (chosen.getProperty("linux,initrd-start")) |prop| {
        const start = prop.asU64().?;
        std.debug.print("Initrd start: 0x{x}\n", .{start});
    }
}
```

#### SOC Bus

```zig
const soc = device_tree.findNode("/soc").?;

// Parse ranges for address translation
const ranges = try dtb.parseRanges(soc, allocator);
defer allocator.free(ranges);

for (ranges) |range| {
    std.debug.print("Bus mapping: child=0x{x} parent=0x{x} size=0x{x}\n", .{
        range.child_address,
        range.parent_address,
        range.size,
    });
}

// Enumerate devices
for (soc.children.items) |device| {
    const path = try device.getFullPath(allocator);
    defer allocator.free(path);

    std.debug.print("Device: {s}\n", .{path});
}
```

## Hardware Discovery

### Finding Devices by Type

```zig
pub fn findDevicesByCompatible(
    dt: *dtb.DeviceTree,
    allocator: std.mem.Allocator,
    compatible: []const u8,
) ![]* dtb.Node {
    var devices = std.ArrayList(*dtb.Node).init(allocator);

    try searchNodes(dt.root, &devices, allocator, compatible);

    return devices.toOwnedSlice();
}

fn searchNodes(
    node: *dtb.Node,
    devices: *std.ArrayList(*dtb.Node),
    allocator: std.mem.Allocator,
    compatible: []const u8,
) !void {
    if (try node.isCompatible(allocator, compatible)) {
        try devices.append(node);
    }

    for (node.children.items) |child| {
        try searchNodes(child, devices, allocator, compatible);
    }
}
```

### UART Discovery

```zig
// Find all UART devices
const uarts = try findDevicesByCompatible(device_tree, allocator, "ns16550a");
defer allocator.free(uarts);

for (uarts) |uart| {
    const addr = try dtb.getPhysicalAddress(uart, allocator, 0);
    std.debug.print("UART at 0x{x}\n", .{addr});

    if (uart.getProperty("clock-frequency")) |prop| {
        const freq = prop.asU32().?;
        std.debug.print("  Clock: {d} Hz\n", .{freq});
    }
}
```

### Ethernet Discovery

```zig
const ethernet_devices = try findDevicesByCompatible(
    device_tree,
    allocator,
    "ethernet",
);
defer allocator.free(ethernet_devices);

for (ethernet_devices) |eth| {
    // Get MAC address
    if (eth.getProperty("local-mac-address")) |prop| {
        const mac = prop.value;
        if (mac.len == 6) {
            std.debug.print("MAC: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
            });
        }
    }

    // Get PHY connection
    if (eth.getProperty("phy-mode")) |prop| {
        std.debug.print("PHY mode: {s}\n", .{prop.asString().?});
    }
}
```

### Timer Discovery

```zig
// ARM Generic Timer
if (device_tree.findNode("/timer")) |timer| {
    const interrupts = try dtb.parseInterrupts(timer, allocator);
    defer {
        for (interrupts) |*int| {
            int.deinit(allocator);
        }
        allocator.free(interrupts);
    }

    std.debug.print("Timer interrupts:\n", .{});
    const names = [_][]const u8{ "secure-phys", "phys", "virt", "hyp-phys", "hyp-virt" };
    for (interrupts, 0..) |int, i| {
        if (i < names.len) {
            std.debug.print("  {s}: ", .{names[i]});
            for (int.cells) |cell| {
                std.debug.print("0x{x} ", .{cell});
            }
            std.debug.print("\n", .{});
        }
    }
}
```

## ARM64-Specific Features

### PSCI (Power State Coordination Interface)

```zig
if (device_tree.findNode("/psci")) |psci| {
    const compat = try psci.getCompatible(allocator) orelse return;
    defer allocator.free(compat);

    std.debug.print("PSCI version: {s}\n", .{compat[0]});

    // PSCI methods
    if (psci.getProperty("method")) |prop| {
        std.debug.print("Method: {s}\n", .{prop.asString().?});
    }

    // CPU_ON function
    if (psci.getProperty("cpu_on")) |prop| {
        const func_id = prop.asU32().?;
        std.debug.print("CPU_ON: 0x{x}\n", .{func_id});
    }
}
```

### GIC (Generic Interrupt Controller)

```zig
// Find GIC
const gic = try findDevicesByCompatible(device_tree, allocator, "arm,gic-v3");
defer allocator.free(gic);

if (gic.len > 0) {
    const gic_node = gic[0];

    // Get distributor and redistributor addresses
    const reg = try dtb.parseReg(gic_node, allocator);
    defer allocator.free(reg);

    std.debug.print("GIC Distributor: 0x{x}\n", .{reg[0].child_address});
    std.debug.print("GIC Redistributor: 0x{x}\n", .{reg[1].child_address});
}
```

## DTB Format Details

### Header Structure

```
Offset  Size  Field
------  ----  -----
0x00    4     magic (0xd00dfeed)
0x04    4     totalsize
0x08    4     off_dt_struct
0x0C    4     off_dt_strings
0x10    4     off_mem_rsvmap
0x14    4     version
0x18    4     last_comp_version
0x1C    4     boot_cpuid_phys
0x20    4     size_dt_strings
0x24    4     size_dt_struct
```

### Structure Block Tokens

- `FDT_BEGIN_NODE` (0x00000001): Start of node
- `FDT_END_NODE` (0x00000002): End of node
- `FDT_PROP` (0x00000003): Property
- `FDT_NOP` (0x00000004): No operation
- `FDT_END` (0x00000009): End of structure block

### Property Format

```
[4 bytes] length (big-endian)
[4 bytes] name offset in strings block (big-endian)
[length bytes] value (padded to 4-byte alignment)
```

## Testing

Run all DTB tests:

```bash
# Test all modules
zig build test --match dtb

# Test specific modules
zig test packages/dtb/src/dtb.zig
zig test packages/dtb/src/address.zig
```

## Common Patterns

### Initialize from Boot

```zig
// ARM64 boot: DTB address passed in x0 register
extern fn getDeviceTreeAddress() usize;

pub fn initDeviceTree(allocator: std.mem.Allocator) !*dtb.DeviceTree {
    const dtb_phys_addr = getDeviceTreeAddress();

    // Map DTB into virtual memory
    const dtb_data = mapPhysicalMemory(dtb_phys_addr, 0x100000); // 1MB max

    return try dtb.DeviceTree.parse(allocator, dtb_data);
}
```

### Driver Initialization

```zig
pub fn initDrivers(dt: *dtb.DeviceTree, allocator: std.mem.Allocator) !void {
    // Initialize console first
    if (dt.findNode("/chosen")) |chosen| {
        if (chosen.getProperty("stdout-path")) |prop| {
            const console_path = prop.asString().?;
            if (dt.findNode(console_path)) |console| {
                try initConsoleDriver(console, allocator);
            }
        }
    }

    // Initialize other devices
    try initTimers(dt, allocator);
    try initInterruptControllers(dt, allocator);
    try initNetworkDevices(dt, allocator);
}
```

## References

- [Devicetree Specification](https://www.devicetree.org/specifications/)
- [Linux Device Tree Documentation](https://www.kernel.org/doc/Documentation/devicetree/)
- [ARM Device Tree Bindings](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/devicetree/bindings/arm)

## License

This Device Tree implementation is part of Home OS and follows the project's licensing terms.
