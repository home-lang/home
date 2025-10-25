// Home Programming Language - ARM Generic Interrupt Controller (GIC)
// GICv2 implementation for Raspberry Pi and other ARM64 systems

const Basics = @import("basics");

// ============================================================================
// GIC Distributor Registers (GICD)
// ============================================================================

pub const GicdRegs = extern struct {
    ctlr: volatile u32, // Distributor Control Register
    typer: volatile u32, // Interrupt Controller Type Register
    iidr: volatile u32, // Distributor Implementer Identification Register
    reserved1: [29]u32,
    igroupr: [32]volatile u32, // Interrupt Group Registers
    isenabler: [32]volatile u32, // Interrupt Set-Enable Registers
    icenabler: [32]volatile u32, // Interrupt Clear-Enable Registers
    ispendr: [32]volatile u32, // Interrupt Set-Pending Registers
    icpendr: [32]volatile u32, // Interrupt Clear-Pending Registers
    isactiver: [32]volatile u32, // Interrupt Set-Active Registers
    icactiver: [32]volatile u32, // Interrupt Clear-Active Registers
    ipriorityr: [255]volatile u32, // Interrupt Priority Registers
    reserved2: u32,
    itargetsr: [255]volatile u32, // Interrupt Processor Targets Registers
    reserved3: u32,
    icfgr: [64]volatile u32, // Interrupt Configuration Registers
};

// ============================================================================
// GIC CPU Interface Registers (GICC)
// ============================================================================

pub const GiccRegs = extern struct {
    ctlr: volatile u32, // CPU Interface Control Register
    pmr: volatile u32, // Interrupt Priority Mask Register
    bpr: volatile u32, // Binary Point Register
    iar: volatile u32, // Interrupt Acknowledge Register
    eoir: volatile u32, // End of Interrupt Register
    rpr: volatile u32, // Running Priority Register
    hppir: volatile u32, // Highest Priority Pending Interrupt Register
    abpr: volatile u32, // Aliased Binary Point Register
    aiar: volatile u32, // Aliased Interrupt Acknowledge Register
    aeoir: volatile u32, // Aliased End of Interrupt Register
    ahppir: volatile u32, // Aliased Highest Priority Pending Interrupt Register
    reserved1: [41]u32,
    apr: [4]volatile u32, // Active Priorities Registers
    nsapr: [4]volatile u32, // Non-secure Active Priorities Registers
    reserved2: [3]u32,
    iidr: volatile u32, // CPU Interface Identification Register
    reserved3: [960]u32,
    dir: volatile u32, // Deactivate Interrupt Register
};

// GIC base addresses for Raspberry Pi 3/4
pub const BCM2835_GIC_DIST_BASE = 0x3F00B000; // Raspberry Pi 3
pub const BCM2835_GIC_CPU_BASE = 0x3F00C000;

pub const BCM2711_GIC_DIST_BASE = 0xFF841000; // Raspberry Pi 4
pub const BCM2711_GIC_CPU_BASE = 0xFF842000;

// ============================================================================
// GIC Constants
// ============================================================================

pub const MAX_INTERRUPTS = 1024;
pub const SPI_OFFSET = 32; // Shared Peripheral Interrupts start at 32

// Distributor Control Register bits
pub const GICD_CTLR_ENABLE = 1 << 0;

// CPU Interface Control Register bits
pub const GICC_CTLR_ENABLE = 1 << 0;

// Priority values (lower = higher priority)
pub const PRIORITY_HIGHEST = 0x00;
pub const PRIORITY_HIGH = 0x40;
pub const PRIORITY_NORMAL = 0x80;
pub const PRIORITY_LOW = 0xC0;
pub const PRIORITY_LOWEST = 0xFF;

// ============================================================================
// GIC Driver
// ============================================================================

pub const GicDriver = struct {
    dist: *volatile GicdRegs,
    cpu: *volatile GiccRegs,
    num_interrupts: u32,

    pub fn init(dist_base: u64, cpu_base: u64) !*GicDriver {
        const allocator = Basics.heap.page_allocator;
        const gic = try allocator.create(GicDriver);

        gic.dist = @ptrFromInt(dist_base);
        gic.cpu = @ptrFromInt(cpu_base);

        // Read number of supported interrupts
        const typer = gic.dist.typer;
        gic.num_interrupts = ((typer & 0x1F) + 1) * 32;

        return gic;
    }

    pub fn initDistributor(self: *GicDriver) void {
        // Disable distributor
        self.dist.ctlr = 0;

        // Disable all interrupts
        var i: u32 = 0;
        while (i < self.num_interrupts / 32) : (i += 1) {
            self.dist.icenabler[i] = 0xFFFFFFFF;
            self.dist.icpendr[i] = 0xFFFFFFFF;
            self.dist.icactiver[i] = 0xFFFFFFFF;
        }

        // Set all interrupts to lowest priority
        i = 0;
        while (i < self.num_interrupts / 4) : (i += 1) {
            self.dist.ipriorityr[i] = 0xA0A0A0A0;
        }

        // Set all SPIs to target CPU 0
        i = 8; // Start at SPI offset / 4
        while (i < self.num_interrupts / 4) : (i += 1) {
            self.dist.itargetsr[i] = 0x01010101;
        }

        // Configure all interrupts as level-sensitive
        i = 0;
        while (i < self.num_interrupts / 16) : (i += 1) {
            self.dist.icfgr[i] = 0;
        }

        // Enable distributor
        self.dist.ctlr = GICD_CTLR_ENABLE;
    }

    pub fn initCpuInterface(self: *GicDriver) void {
        // Set priority mask to allow all priorities
        self.cpu.pmr = 0xFF;

        // Set binary point to 0 (no grouping)
        self.cpu.bpr = 0;

        // Enable CPU interface
        self.cpu.ctlr = GICC_CTLR_ENABLE;
    }

    pub fn enableInterrupt(self: *GicDriver, irq: u32) void {
        if (irq >= self.num_interrupts) return;

        const reg_index = irq / 32;
        const bit_offset: u5 = @intCast(irq % 32);

        self.dist.isenabler[reg_index] = @as(u32, 1) << bit_offset;
    }

    pub fn disableInterrupt(self: *GicDriver, irq: u32) void {
        if (irq >= self.num_interrupts) return;

        const reg_index = irq / 32;
        const bit_offset: u5 = @intCast(irq % 32);

        self.dist.icenabler[reg_index] = @as(u32, 1) << bit_offset;
    }

    pub fn setPriority(self: *GicDriver, irq: u32, priority: u8) void {
        if (irq >= self.num_interrupts) return;

        const reg_index = irq / 4;
        const byte_offset: u5 = @intCast((irq % 4) * 8);

        var val = self.dist.ipriorityr[reg_index];
        val &= ~(@as(u32, 0xFF) << byte_offset);
        val |= @as(u32, priority) << byte_offset;
        self.dist.ipriorityr[reg_index] = val;
    }

    pub fn setTarget(self: *GicDriver, irq: u32, cpu_mask: u8) void {
        if (irq < SPI_OFFSET or irq >= self.num_interrupts) return;

        const reg_index = irq / 4;
        const byte_offset: u5 = @intCast((irq % 4) * 8);

        var val = self.dist.itargetsr[reg_index];
        val &= ~(@as(u32, 0xFF) << byte_offset);
        val |= @as(u32, cpu_mask) << byte_offset;
        self.dist.itargetsr[reg_index] = val;
    }

    pub fn acknowledgeInterrupt(self: *GicDriver) u32 {
        return self.cpu.iar;
    }

    pub fn endOfInterrupt(self: *GicDriver, irq: u32) void {
        self.cpu.eoir = irq;
    }

    pub fn isPending(self: *GicDriver, irq: u32) bool {
        if (irq >= self.num_interrupts) return false;

        const reg_index = irq / 32;
        const bit_offset: u5 = @intCast(irq % 32);

        return (self.dist.ispendr[reg_index] & (@as(u32, 1) << bit_offset)) != 0;
    }

    pub fn clearPending(self: *GicDriver, irq: u32) void {
        if (irq >= self.num_interrupts) return;

        const reg_index = irq / 32;
        const bit_offset: u5 = @intCast(irq % 32);

        self.dist.icpendr[reg_index] = @as(u32, 1) << bit_offset;
    }

    pub fn configureEdgeTriggered(self: *GicDriver, irq: u32) void {
        if (irq >= self.num_interrupts) return;

        const reg_index = irq / 16;
        const bit_offset: u5 = @intCast((irq % 16) * 2 + 1);

        self.dist.icfgr[reg_index] |= @as(u32, 1) << bit_offset;
    }

    pub fn configureLevelSensitive(self: *GicDriver, irq: u32) void {
        if (irq >= self.num_interrupts) return;

        const reg_index = irq / 16;
        const bit_offset: u5 = @intCast((irq % 16) * 2 + 1);

        self.dist.icfgr[reg_index] &= ~(@as(u32, 1) << bit_offset);
    }
};

// ============================================================================
// Common Raspberry Pi Interrupts
// ============================================================================

pub const RaspberryPiIRQ = struct {
    // Timer interrupts
    pub const TIMER0 = 96;
    pub const TIMER1 = 97;
    pub const TIMER2 = 98;
    pub const TIMER3 = 99;

    // UART interrupts
    pub const UART0 = 57;
    pub const UART1 = 29; // Mini UART

    // I2C interrupts
    pub const I2C0 = 69;
    pub const I2C1 = 70;
    pub const I2C2 = 71;

    // SPI interrupts
    pub const SPI0 = 54;
    pub const SPI1 = 55;
    pub const SPI2 = 56;

    // GPIO interrupts
    pub const GPIO0 = 49;
    pub const GPIO1 = 50;
    pub const GPIO2 = 51;
    pub const GPIO3 = 52;

    // USB interrupt
    pub const USB = 9;

    // DMA interrupts
    pub const DMA0 = 16;
    pub const DMA1 = 17;
    pub const DMA2 = 18;
    pub const DMA3 = 19;
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Initialize GIC for Raspberry Pi 3
pub fn initRaspberryPi3() !*GicDriver {
    const gic = try GicDriver.init(BCM2835_GIC_DIST_BASE, BCM2835_GIC_CPU_BASE);
    gic.initDistributor();
    gic.initCpuInterface();
    return gic;
}

/// Initialize GIC for Raspberry Pi 4
pub fn initRaspberryPi4() !*GicDriver {
    const gic = try GicDriver.init(BCM2711_GIC_DIST_BASE, BCM2711_GIC_CPU_BASE);
    gic.initDistributor();
    gic.initCpuInterface();
    return gic;
}

// ============================================================================
// Tests
// ============================================================================

test "GIC register offsets" {
    try Basics.testing.expectEqual(@as(usize, 0x000), @offsetOf(GicdRegs, "ctlr"));
    try Basics.testing.expectEqual(@as(usize, 0x100), @offsetOf(GicdRegs, "isenabler"));
    try Basics.testing.expectEqual(@as(usize, 0x400), @offsetOf(GicdRegs, "ipriorityr"));
}

test "GIC constants" {
    try Basics.testing.expectEqual(@as(u32, 32), SPI_OFFSET);
    try Basics.testing.expectEqual(@as(u8, 0x00), PRIORITY_HIGHEST);
}
