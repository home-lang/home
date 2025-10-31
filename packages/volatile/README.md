// Home Programming Language - Volatile Operations
# Volatile Operations Package

Comprehensive volatile memory access and Memory-Mapped I/O (MMIO) safety for hardware device drivers and kernel development.

## Features

### Volatile Pointer Wrapper
- Safe volatile memory access
- Read/write/modify operations
- Bit manipulation (set, clear, toggle, test)
- Busy-wait synchronization
- Address conversion

### MMIO Register Abstraction
- Named register access
- Read-only/write-only enforcement
- Bounds checking
- Bit-level operations
- Type safety

### MMIO Region Management
- Multi-register device regions
- Offset validation
- Named register lookup
- Address range checking

### Volatile Buffers
- DMA buffer access
- Slice operations
- Bounds checking
- Fill operations

### Memory Barriers
- Full barriers (read + write)
- Read barriers (acquire)
- Write barriers (release)

## Usage

### Basic Volatile Access

```zig
const volatile_pkg = @import("volatile");

// Wrap a volatile pointer
var hardware_reg: u32 = 0;
var vol_ptr: *volatile u32 = &hardware_reg;
const vol = volatile_pkg.Volatile(u32).init(vol_ptr);

// Read value
const value = vol.read();

// Write value
vol.write(0x12345678);

// Read-modify-write
vol.modify(struct {
    fn increment(v: u32) u32 {
        return v + 1;
    }
}.increment);
```

### Bit Operations

```zig
// Set specific bits
vol.setBits(0x0F); // Set lower nibble

// Clear specific bits
vol.clearBits(0xF0); // Clear upper nibble

// Toggle bits
vol.toggleBits(0xFF); // Flip all bits

// Test if bits are set
if (vol.testBits(0x01)) {
    // Bit 0 is set
}

// Wait for bits to be set
vol.waitBitsSet(0x80); // Busy wait for bit 7

// Wait for bits to clear
vol.waitBitsClear(0x80); // Busy wait for bit 7 to clear
```

### MMIO Register

```zig
// Define a memory-mapped register
const STATUS_REG = volatile_pkg.MmioRegister(u32).init(
    0x40000000,  // Hardware address
    "STATUS"     // Register name
);

// Read status
const status = STATUS_REG.read();

// Write control bits
STATUS_REG.write(0x0001); // Enable

// Set specific flags
STATUS_REG.setBits(0x0004); // Set bit 2

// Clear flags
STATUS_REG.clearBits(0x0008); // Clear bit 3

// Test flags
if (STATUS_REG.testBits(0x0100)) {
    // Ready bit is set
}
```

### Read-Only and Write-Only Registers

```zig
// Read-only register (data input)
const DATA_IN = volatile_pkg.MmioRegister(u32).initReadOnly(
    0x40000004,
    "DATA_IN"
);

const data = DATA_IN.read(); // OK
// DATA_IN.write(42); // Would panic!

// Write-only register (command output)
const CMD_OUT = volatile_pkg.MmioRegister(u32).initWriteOnly(
    0x40000008,
    "CMD_OUT"
);

CMD_OUT.write(0x01); // OK
// const val = CMD_OUT.read(); // Would panic!
```

### MMIO Region

```zig
// Define a device MMIO region
const UART_BASE = 0x10000000;
const UART_SIZE = 0x1000;

const uart_region = volatile_pkg.MmioRegion.init(
    UART_BASE,
    UART_SIZE,
    "UART0"
);

// Get registers within the region
const DATA_REG = uart_region.getRegister(u8, 0x00, "THR"); // Transmit
const STATUS_REG = uart_region.getRegisterReadOnly(u32, 0x14, "LSR"); // Status
const CTRL_REG = uart_region.getRegister(u32, 0x08, "LCR"); // Control

// Use registers
DATA_REG.write('H');
if (STATUS_REG.testBits(0x20)) { // TX empty
    DATA_REG.write('i');
}

// Check if address is in region
const in_range = uart_region.contains(0x10000100); // true
```

### Volatile Buffer (DMA)

```zig
// DMA buffer for bulk transfers
var dma_buffer: [256]u8 align(4096) = undefined;
var volatile_dma: [*]volatile u8 = @ptrCast(&dma_buffer);

const vol_buf = volatile_pkg.VolatileBuffer(u8).init(volatile_dma, 256);

// Write individual bytes
vol_buf.write(0, 0xAA);
vol_buf.write(1, 0xBB);

// Read individual bytes
const byte0 = vol_buf.read(0);

// Write slice
const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
vol_buf.writeSlice(&data, 10); // Write at offset 10

// Read slice
var dest: [4]u8 = undefined;
vol_buf.readSlice(&dest, 10, 4); // Read 4 bytes from offset 10

// Fill entire buffer
vol_buf.fill(0x00);
```

### Memory Barriers

```zig
const Barrier = volatile_pkg.Barrier;

// Ensure all memory operations complete before proceeding
Barrier.full();

// Ensure all reads complete
Barrier.read();

// Ensure all writes complete
Barrier.write();

// Example: MMIO write sequence
STATUS_REG.write(0x01);  // Start operation
Barrier.write();          // Ensure write completes
while (!STATUS_REG.testBits(0x80)) {}  // Wait for completion
Barrier.read();           // Ensure read observes latest value
```

### Helper Functions

```zig
const VolatileOps = volatile_pkg.VolatileOps;

// Direct address operations
VolatileOps.write(u32, 0x40000000, 0x1234);
const val = VolatileOps.read(u32, 0x40000000);

// Bit operations on addresses
VolatileOps.setBits(u32, 0x40000000, 0x01);
VolatileOps.clearBits(u32, 0x40000000, 0x02);

// Read-modify-write
VolatileOps.modify(u32, 0x40000000, struct {
    fn transform(v: u32) u32 {
        return (v & 0xFFFF0000) | 0x5678;
    }
}.transform);
```

### Common MMIO Patterns

```zig
const Patterns = volatile_pkg.MmioPatterns;

var status_reg: u32 = 0;
var vol_status: *volatile u32 = &status_reg;

// Spin until value matches
Patterns.spinUntilEqual(u32, vol_status, 0x01);

// Spin until bits are set
Patterns.spinUntilBitsSet(u32, vol_status, 0x80);

// Spin until bits are clear
Patterns.spinUntilBitsClear(u32, vol_status, 0x40);

// Wait with timeout
const success = Patterns.waitWithTimeout(u32, vol_status, 0x01, 1000);
if (!success) {
    // Timeout occurred
    return error.DeviceTimeout;
}
```

## Real-World Examples

### Example 1: UART Driver

```zig
const uart_region = MmioRegion.init(0x10000000, 0x1000, "UART0");

const THR = uart_region.getRegisterWriteOnly(u8, 0x00, "THR"); // Transmit
const RBR = uart_region.getRegisterReadOnly(u8, 0x00, "RBR");  // Receive
const LSR = uart_region.getRegisterReadOnly(u8, 0x05, "LSR");  // Line Status

pub fn writeByte(byte: u8) void {
    // Wait for transmitter to be ready
    while (!LSR.testBits(0x20)) {} // THRE bit

    // Write byte
    THR.write(byte);
}

pub fn readByte() u8 {
    // Wait for data available
    while (!LSR.testBits(0x01)) {} // DR bit

    // Read byte
    return RBR.read();
}
```

### Example 2: GPIO Control

```zig
const gpio_region = MmioRegion.init(0x20200000, 0x100, "GPIO");

const GPSET = gpio_region.getRegisterWriteOnly(u32, 0x1C, "GPSET0");
const GPCLR = gpio_region.getRegisterWriteOnly(u32, 0x28, "GPCLR0");
const GPLEV = gpio_region.getRegisterReadOnly(u32, 0x34, "GPLEV0");

pub fn setPin(pin: u5) void {
    GPSET.write(@as(u32, 1) << pin);
}

pub fn clearPin(pin: u5) void {
    GPCLR.write(@as(u32, 1) << pin);
}

pub fn readPin(pin: u5) bool {
    return GPLEV.testBits(@as(u32, 1) << pin);
}
```

### Example 3: DMA Controller

```zig
const dma_region = MmioRegion.init(0x30000000, 0x1000, "DMA");

const CS = dma_region.getRegister(u32, 0x00, "CS");       // Control/Status
const CONBLK_AD = dma_region.getRegister(u32, 0x04, "CONBLK_AD"); // CB Address
const TI = dma_region.getRegister(u32, 0x08, "TI");       // Transfer Info

pub fn startTransfer(control_block_addr: u32) void {
    // Write control block address
    CONBLK_AD.write(control_block_addr);

    // Start DMA
    CS.setBits(0x01); // ACTIVE bit

    // Memory barrier to ensure writes complete
    Barrier.write();
}

pub fn waitForCompletion() !void {
    // Wait for END bit with timeout
    const success = MmioPatterns.waitWithTimeout(
        u32,
        CS.volatile_ptr.getPtr(),
        0x02,  // END bit
        100000
    );

    if (!success) {
        return error.DMATimeout;
    }
}
```

### Example 4: Interrupt Controller

```zig
const gic_dist = MmioRegion.init(0x08000000, 0x10000, "GIC_DIST");

const GICD_CTLR = gic_dist.getRegister(u32, 0x000, "CTLR");
const GICD_ISENABLER = gic_dist.getRegister(u32, 0x100, "ISENABLER");
const GICD_ICENABLER = gic_dist.getRegister(u32, 0x180, "ICENABLER");

pub fn enableInterrupt(irq: u8) void {
    const reg_offset = (irq / 32) * 4;
    const bit = @as(u32, 1) << @intCast(irq % 32);

    const enable_reg = gic_dist.getRegister(u32, 0x100 + reg_offset, "ISENABLE");
    enable_reg.write(bit);

    Barrier.write(); // Ensure enable completes
}

pub fn enableDistributor() void {
    GICD_CTLR.setBits(0x01); // Enable bit
    Barrier.write();
}
```

## MMIO Safety Features

### 1. Type Safety
- Compile-time type checking for all operations
- Cannot mix register types

### 2. Access Control
- Read-only registers prevent writes
- Write-only registers prevent reads
- Runtime panic on violations (debug builds)

### 3. Bounds Checking
- MMIO regions validate register offsets
- Volatile buffers check array indices
- Prevents out-of-bounds access

### 4. Memory Ordering
- Volatile semantics prevent compiler reordering
- Memory barriers for hardware ordering
- Acquire/release semantics

### 5. Named Registers
- Self-documenting code
- Easier debugging
- Clear hardware mapping

## Testing

Run the test suite:

```bash
cd packages/volatile
zig build test
```

All 11 tests validate:
- Basic volatile read/write
- Modify operations
- Bit operations (set, clear, toggle, test)
- MMIO register access
- MMIO region bounds checking
- Volatile buffer operations
- Helper function operations
- MMIO pattern timeouts
- Read-only register enforcement
- Volatile buffer slice operations

## Integration

This package integrates with:
- **Drivers**: Safe MMIO access for all device drivers
- **Kernel**: Hardware register manipulation
- **DMA**: Volatile buffer management
- **Interrupts**: Controller register access
- **Platform**: Architecture-specific memory barriers

## Best Practices

1. **Use wrappers**: Prefer `Volatile` and `MmioRegister` over raw volatile pointers
2. **Name registers**: Always provide descriptive names for debugging
3. **Enforce access patterns**: Use read-only/write-only when appropriate
4. **Add barriers**: Use memory barriers around critical MMIO sequences
5. **Check bounds**: Use `MmioRegion` to validate register offsets
6. **Handle timeouts**: Don't spin forever - use `waitWithTimeout`
7. **Document addresses**: Comment hardware register addresses and bit meanings

## Performance

- **Zero overhead**: Wrappers compile to direct volatile access
- **Inlined operations**: All functions inline to raw instructions
- **No allocations**: Stack-only structures
- **Compile-time checks**: Safety with no runtime cost
