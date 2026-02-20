// Home Programming Language - Advanced Programmable Interrupt Controller (APIC)
// Local APIC and x2APIC support for modern interrupt handling

const Basics = @import("basics");
const assembly = @import("asm.zig");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// ============================================================================
// APIC Register Offsets
// ============================================================================

pub const ApicReg = struct {
    pub const ID: u32 = 0x020; // Local APIC ID
    pub const VERSION: u32 = 0x030; // Local APIC Version
    pub const TPR: u32 = 0x080; // Task Priority Register
    pub const APR: u32 = 0x090; // Arbitration Priority Register
    pub const PPR: u32 = 0x0A0; // Processor Priority Register
    pub const EOI: u32 = 0x0B0; // End Of Interrupt
    pub const RRD: u32 = 0x0C0; // Remote Read Register
    pub const LDR: u32 = 0x0D0; // Logical Destination Register
    pub const DFR: u32 = 0x0E0; // Destination Format Register
    pub const SPURIOUS: u32 = 0x0F0; // Spurious Interrupt Vector Register
    pub const ISR: u32 = 0x100; // In-Service Register (0x100-0x170)
    pub const TMR: u32 = 0x180; // Trigger Mode Register (0x180-0x1F0)
    pub const IRR: u32 = 0x200; // Interrupt Request Register (0x200-0x270)
    pub const ERROR: u32 = 0x280; // Error Status Register
    pub const LVT_CMCI: u32 = 0x2F0; // LVT Corrected Machine Check Interrupt
    pub const ICR_LOW: u32 = 0x300; // Interrupt Command Register (bits 0-31)
    pub const ICR_HIGH: u32 = 0x310; // Interrupt Command Register (bits 32-63)
    pub const LVT_TIMER: u32 = 0x320; // LVT Timer Register
    pub const LVT_THERMAL: u32 = 0x330; // LVT Thermal Sensor Register
    pub const LVT_PERF: u32 = 0x340; // LVT Performance Counter Register
    pub const LVT_LINT0: u32 = 0x350; // LVT LINT0 Register
    pub const LVT_LINT1: u32 = 0x360; // LVT LINT1 Register
    pub const LVT_ERROR: u32 = 0x370; // LVT Error Register
    pub const TIMER_INITIAL: u32 = 0x380; // Initial Count Register (for Timer)
    pub const TIMER_CURRENT: u32 = 0x390; // Current Count Register (for Timer)
    pub const TIMER_DIVIDE: u32 = 0x3E0; // Divide Configuration Register (for Timer)
};

// ============================================================================
// APIC MSR Addresses (for x2APIC)
// ============================================================================

pub const ApicMsr = struct {
    pub const BASE: u32 = 0x1B; // APIC Base Address
    pub const X2APIC_ID: u32 = 0x802; // x2APIC ID
    pub const X2APIC_VERSION: u32 = 0x803; // x2APIC Version
    pub const X2APIC_TPR: u32 = 0x808; // Task Priority
    pub const X2APIC_PPR: u32 = 0x80A; // Processor Priority
    pub const X2APIC_EOI: u32 = 0x80B; // End of Interrupt
    pub const X2APIC_LDR: u32 = 0x80D; // Logical Destination
    pub const X2APIC_SPURIOUS: u32 = 0x80F; // Spurious Interrupt Vector
    pub const X2APIC_ISR0: u32 = 0x810; // In-Service (bits 0-31)
    pub const X2APIC_TMR0: u32 = 0x818; // Trigger Mode (bits 0-31)
    pub const X2APIC_IRR0: u32 = 0x820; // Interrupt Request (bits 0-31)
    pub const X2APIC_ERROR: u32 = 0x828; // Error Status
    pub const X2APIC_LVT_CMCI: u32 = 0x82F; // LVT CMCI
    pub const X2APIC_ICR: u32 = 0x830; // Interrupt Command (64-bit)
    pub const X2APIC_LVT_TIMER: u32 = 0x832; // LVT Timer
    pub const X2APIC_LVT_THERMAL: u32 = 0x833; // LVT Thermal
    pub const X2APIC_LVT_PERF: u32 = 0x834; // LVT Performance
    pub const X2APIC_LVT_LINT0: u32 = 0x835; // LVT LINT0
    pub const X2APIC_LVT_LINT1: u32 = 0x836; // LVT LINT1
    pub const X2APIC_LVT_ERROR: u32 = 0x837; // LVT Error
    pub const X2APIC_TIMER_INITIAL: u32 = 0x838; // Timer Initial Count
    pub const X2APIC_TIMER_CURRENT: u32 = 0x839; // Timer Current Count
    pub const X2APIC_TIMER_DIVIDE: u32 = 0x83E; // Timer Divide Configuration
    pub const X2APIC_SELF_IPI: u32 = 0x83F; // Self IPI
};

// ============================================================================
// APIC Base MSR Bits
// ============================================================================

pub const APIC_BASE_BSP: u64 = 1 << 8; // Bootstrap Processor
pub const APIC_BASE_X2APIC_ENABLE: u64 = 1 << 10; // Enable x2APIC mode
pub const APIC_BASE_GLOBAL_ENABLE: u64 = 1 << 11; // Global APIC Enable

// ============================================================================
// Spurious Interrupt Vector Register Bits
// ============================================================================

pub const APIC_SPURIOUS_ENABLE: u32 = 1 << 8; // APIC Software Enable
pub const APIC_SPURIOUS_VECTOR: u32 = 0xFF; // Spurious Vector Mask

// ============================================================================
// Timer Divide Configuration Values
// ============================================================================

pub const TimerDivide = enum(u32) {
    Div2 = 0b0000,
    Div4 = 0b0001,
    Div8 = 0b0010,
    Div16 = 0b0011,
    Div32 = 0b1000,
    Div64 = 0b1001,
    Div128 = 0b1010,
    Div1 = 0b1011,
};

// ============================================================================
// Delivery Mode
// ============================================================================

pub const DeliveryMode = enum(u32) {
    Fixed = 0b000,
    LowestPriority = 0b001,
    SMI = 0b010,
    NMI = 0b100,
    INIT = 0b101,
    StartUp = 0b110,
    ExtINT = 0b111,
};

// ============================================================================
// Destination Mode
// ============================================================================

pub const DestinationMode = enum(u32) {
    Physical = 0,
    Logical = 1,
};

// ============================================================================
// IPI Destination Shorthand
// ============================================================================

pub const IpiDestination = enum(u32) {
    NoShorthand = 0b00,
    Self = 0b01,
    AllIncludingSelf = 0b10,
    AllExcludingSelf = 0b11,
};

// ============================================================================
// Local APIC
// ============================================================================

pub const LocalApic = struct {
    /// Base address of APIC MMIO region
    base_addr: u64,
    /// Is x2APIC mode enabled?
    x2apic_enabled: bool,
    /// APIC ID
    apic_id: u32,
    /// APIC version
    version: u32,
    /// Maximum LVT entries
    max_lvt: u8,
    /// Lock for APIC operations
    lock: sync.Spinlock,

    /// Initialize Local APIC
    pub fn init() !LocalApic {
        var apic = LocalApic{
            .base_addr = 0,
            .x2apic_enabled = false,
            .apic_id = 0,
            .version = 0,
            .max_lvt = 0,
            .lock = sync.Spinlock.init(),
        };

        // Read APIC base MSR
        const apic_base_msr = assembly.rdmsr(ApicMsr.BASE);
        apic.base_addr = apic_base_msr & 0xFFFF_F000;

        // Check if x2APIC is supported
        const cpuid_result = assembly.cpuid(1, 0);
        const x2apic_supported = (cpuid_result.ecx & (1 << 21)) != 0;

        if (x2apic_supported) {
            // Enable x2APIC mode
            try apic.enableX2Apic();
        } else {
            // Enable xAPIC mode
            try apic.enableXApic();
        }

        // Read APIC ID and version
        apic.apic_id = apic.readApicId();
        apic.version = apic.readReg(ApicReg.VERSION);
        apic.max_lvt = @truncate((apic.version >> 16) & 0xFF);

        return apic;
    }

    /// Enable x2APIC mode
    fn enableX2Apic(self: *LocalApic) !void {
        const apic_base = assembly.rdmsr(ApicMsr.BASE);
        const new_value = apic_base | APIC_BASE_X2APIC_ENABLE | APIC_BASE_GLOBAL_ENABLE;
        assembly.wrmsr(ApicMsr.BASE, new_value);
        self.x2apic_enabled = true;
    }

    /// Enable xAPIC mode
    fn enableXApic(self: *LocalApic) !void {
        const apic_base = assembly.rdmsr(ApicMsr.BASE);
        const new_value = (apic_base & ~APIC_BASE_X2APIC_ENABLE) | APIC_BASE_GLOBAL_ENABLE;
        assembly.wrmsr(ApicMsr.BASE, new_value);
        self.x2apic_enabled = false;
    }

    /// Read APIC register (handles both xAPIC and x2APIC)
    pub fn readReg(self: *const LocalApic, reg: u32) u32 {
        if (self.x2apic_enabled) {
            // x2APIC uses MSRs
            const msr = 0x800 + (reg >> 4);
            return @truncate(assembly.rdmsr(msr));
        } else {
            // xAPIC uses MMIO
            const ptr: *volatile u32 = @ptrFromInt(self.base_addr + reg);
            return ptr.*;
        }
    }

    /// Write APIC register (handles both xAPIC and x2APIC)
    pub fn writeReg(self: *const LocalApic, reg: u32, value: u32) void {
        if (self.x2apic_enabled) {
            // x2APIC uses MSRs
            const msr = 0x800 + (reg >> 4);
            assembly.wrmsr(msr, value);
        } else {
            // xAPIC uses MMIO
            const ptr: *volatile u32 = @ptrFromInt(self.base_addr + reg);
            ptr.* = value;
        }
    }

    /// Read APIC ID
    pub fn readApicId(self: *const LocalApic) u32 {
        if (self.x2apic_enabled) {
            return @truncate(assembly.rdmsr(ApicMsr.X2APIC_ID));
        } else {
            return self.readReg(ApicReg.ID) >> 24;
        }
    }

    /// Enable APIC
    pub fn enable(self: *LocalApic, spurious_vector: u8) void {
        self.lock.acquire();
        defer self.lock.release();

        // Set spurious interrupt vector and enable APIC
        const spurious = (@as(u32, spurious_vector) & 0xFF) | APIC_SPURIOUS_ENABLE;
        self.writeReg(ApicReg.SPURIOUS, spurious);

        // Clear error status
        self.writeReg(ApicReg.ERROR, 0);

        // Set task priority to accept all interrupts
        self.writeReg(ApicReg.TPR, 0);
    }

    /// Send End-Of-Interrupt
    pub fn eoi(self: *const LocalApic) void {
        self.writeReg(ApicReg.EOI, 0);
    }

    /// Setup Local APIC timer
    pub fn setupTimer(self: *LocalApic, vector: u8, divide: TimerDivide, initial_count: u32, periodic: bool) void {
        self.lock.acquire();
        defer self.lock.release();

        // Set divide configuration
        self.writeReg(ApicReg.TIMER_DIVIDE, @intFromEnum(divide));

        // Set LVT timer entry
        var lvt: u32 = vector;
        if (periodic) {
            lvt |= (1 << 17); // Set periodic mode
        }
        self.writeReg(ApicReg.LVT_TIMER, lvt);

        // Set initial count (starts timer)
        self.writeReg(ApicReg.TIMER_INITIAL, initial_count);
    }

    /// Stop APIC timer
    pub fn stopTimer(self: *LocalApic) void {
        self.lock.acquire();
        defer self.lock.release();

        self.writeReg(ApicReg.TIMER_INITIAL, 0);
    }

    /// Read current timer count
    pub fn readTimerCount(self: *const LocalApic) u32 {
        return self.readReg(ApicReg.TIMER_CURRENT);
    }

    /// Send Inter-Processor Interrupt (IPI)
    pub fn sendIpi(
        self: *LocalApic,
        destination: u32,
        vector: u8,
        delivery_mode: DeliveryMode,
        dest_mode: DestinationMode,
        level: bool,
        trigger: bool,
        dest_shorthand: IpiDestination,
    ) void {
        self.lock.acquire();
        defer self.lock.release();

        if (self.x2apic_enabled) {
            // x2APIC: 64-bit ICR in single MSR
            var icr: u64 = vector;
            icr |= @as(u64, @intFromEnum(delivery_mode)) << 8;
            icr |= @as(u64, @intFromEnum(dest_mode)) << 11;
            if (level) icr |= @as(u64, 1) << 14;
            if (trigger) icr |= @as(u64, 1) << 15;
            icr |= @as(u64, @intFromEnum(dest_shorthand)) << 18;
            icr |= @as(u64, destination) << 32;

            assembly.wrmsr(ApicMsr.X2APIC_ICR, icr);
        } else {
            // xAPIC: Two 32-bit registers
            const icr_high: u32 = destination << 24;
            var icr_low: u32 = vector;
            icr_low |= @as(u32, @intFromEnum(delivery_mode)) << 8;
            icr_low |= @as(u32, @intFromEnum(dest_mode)) << 11;
            if (level) icr_low |= 1 << 14;
            if (trigger) icr_low |= 1 << 15;
            icr_low |= @as(u32, @intFromEnum(dest_shorthand)) << 18;

            // Write high dword first
            self.writeReg(ApicReg.ICR_HIGH, icr_high);
            // Write low dword to trigger the IPI
            self.writeReg(ApicReg.ICR_LOW, icr_low);
        }

        // Wait for delivery
        self.waitForIpiDelivery();
    }

    /// Wait for IPI delivery to complete
    fn waitForIpiDelivery(self: *const LocalApic) void {
        if (!self.x2apic_enabled) {
            // In xAPIC, bit 12 of ICR_LOW indicates delivery pending
            while ((self.readReg(ApicReg.ICR_LOW) & (1 << 12)) != 0) {
                assembly.pause();
            }
        }
        // In x2APIC, IPIs are guaranteed to be delivered immediately
    }

    /// Send IPI to specific CPU
    pub fn sendIpiToCpu(self: *LocalApic, cpu_id: u32, vector: u8) void {
        self.sendIpi(
            cpu_id,
            vector,
            .Fixed,
            .Physical,
            false,
            false,
            .NoShorthand,
        );
    }

    /// Send IPI to all CPUs except self
    pub fn sendIpiBroadcast(self: *LocalApic, vector: u8) void {
        self.sendIpi(
            0,
            vector,
            .Fixed,
            .Physical,
            false,
            false,
            .AllExcludingSelf,
        );
    }

    /// Send INIT IPI to CPU (for SMP startup)
    pub fn sendInitIpi(self: *LocalApic, cpu_id: u32) void {
        self.sendIpi(
            cpu_id,
            0,
            .INIT,
            .Physical,
            true,
            true,
            .NoShorthand,
        );
    }

    /// Send SIPI (Startup IPI) to CPU
    pub fn sendStartupIpi(self: *LocalApic, cpu_id: u32, start_page: u8) void {
        self.sendIpi(
            cpu_id,
            start_page,
            .StartUp,
            .Physical,
            false,
            false,
            .NoShorthand,
        );
    }

    /// Setup LVT LINT0 (usually connected to INTR)
    pub fn setupLint0(self: *LocalApic, vector: u8, masked: bool) void {
        self.lock.acquire();
        defer self.lock.release();

        var lvt: u32 = vector;
        if (masked) lvt |= 1 << 16;
        self.writeReg(ApicReg.LVT_LINT0, lvt);
    }

    /// Setup LVT LINT1 (usually connected to NMI)
    pub fn setupLint1(self: *LocalApic, vector: u8, masked: bool) void {
        self.lock.acquire();
        defer self.lock.release();

        var lvt: u32 = vector;
        if (masked) lvt |= 1 << 16;
        self.writeReg(ApicReg.LVT_LINT1, lvt);
    }

    /// Setup LVT Error
    pub fn setupError(self: *LocalApic, vector: u8) void {
        self.lock.acquire();
        defer self.lock.release();

        self.writeReg(ApicReg.LVT_ERROR, vector);
    }

    /// Read error status register
    pub fn readError(self: *const LocalApic) u32 {
        // Reading ESR requires writing 0 first
        self.writeReg(ApicReg.ERROR, 0);
        return self.readReg(ApicReg.ERROR);
    }

    /// Get CPU ID from APIC ID
    pub fn getCpuId(self: *const LocalApic) u32 {
        return self.apic_id;
    }

    /// Check if this is the Bootstrap Processor
    pub fn isBsp(self: *const LocalApic) bool {
        _ = self;
        const apic_base = assembly.rdmsr(ApicMsr.BASE);
        return (apic_base & APIC_BASE_BSP) != 0;
    }
};

// ============================================================================
// Global APIC Instance
// ============================================================================

var local_apic: ?LocalApic = null;
var apic_lock = sync.Spinlock.init();

/// Initialize APIC subsystem
pub fn init() !void {
    apic_lock.acquire();
    defer apic_lock.release();

    local_apic = try LocalApic.init();

    if (local_apic) |*apic| {
        // Enable APIC with spurious vector 0xFF
        apic.enable(0xFF);
    }
}

/// Get local APIC instance
pub fn getLocalApic() ?*LocalApic {
    if (local_apic) |*apic| {
        return apic;
    }
    return null;
}

/// Send EOI (End of Interrupt)
pub fn sendEoi() void {
    if (getLocalApic()) |apic| {
        apic.eoi();
    }
}

/// Get current CPU ID
pub fn getCpuId() u32 {
    if (getLocalApic()) |apic| {
        return apic.getCpuId();
    }
    return 0;
}

// ============================================================================
// TLB Shootdown Support
// ============================================================================

/// TLB shootdown request
pub const TlbShootdownRequest = struct {
    /// Address to invalidate (0 for full flush)
    address: u64,
    /// Number of pages to invalidate (0 for single page, -1 for full flush)
    page_count: u64,
    /// CPUs that need to flush (bitset)
    cpu_mask: u64,
    /// Generation counter for batching
    generation: u64,
    /// Completion counter (atomic)
    completed: atomic.AtomicU32,
};

/// TLB shootdown manager
pub const TlbShootdownManager = struct {
    /// Current generation counter
    generation: atomic.AtomicU64,
    /// Pending shootdown requests (per-CPU)
    pending_requests: [256]?*TlbShootdownRequest,
    /// Lock for request management
    lock: sync.Spinlock,

    /// Global shootdown manager
    var global: TlbShootdownManager = .{
        .generation = atomic.AtomicU64.init(0),
        .pending_requests = [_]?*TlbShootdownRequest{null} ** 256,
        .lock = sync.Spinlock.init(),
    };

    /// Shootdown IPI vector (must be configured in IDT)
    pub const TLB_SHOOTDOWN_VECTOR: u8 = 0xFD;

    /// Initialize TLB shootdown support
    pub fn init() void {
        // Just ensure static initialization is done
        _ = global.generation.load(.Monotonic);
    }

    /// Send TLB shootdown IPI to specific CPUs
    pub fn shootdown(address: u64, page_count: u64, cpu_mask: u64, allocator: Basics.Allocator) !void {
        // Don't send IPI to ourselves
        const current_cpu = getCpuId();
        const current_mask = @as(u64, 1) << @truncate(current_cpu);
        const target_mask = cpu_mask & ~current_mask;

        if (target_mask == 0) {
            // No other CPUs to notify, just flush locally
            flushLocal(address, page_count);
            return;
        }

        // Create shootdown request
        const request = try allocator.create(TlbShootdownRequest);
        errdefer allocator.destroy(request);

        const num_cpus = @popCount(target_mask);
        request.* = .{
            .address = address,
            .page_count = page_count,
            .cpu_mask = target_mask,
            .generation = global.generation.fetchAdd(1, .Monotonic),
            .completed = atomic.AtomicU32.init(0),
        };

        // Store request for each target CPU
        global.lock.acquire();
        var cpu: u6 = 0;
        while (cpu < 64) : (cpu += 1) {
            if ((target_mask & (@as(u64, 1) << cpu)) != 0) {
                global.pending_requests[cpu] = request;
            }
        }
        global.lock.release();

        // Send IPI to all target CPUs
        if (getLocalApic()) |apic| {
            // Send to each CPU individually
            cpu = 0;
            while (cpu < 64) : (cpu += 1) {
                if ((target_mask & (@as(u64, 1) << cpu)) != 0) {
                    apic.sendIpi(
                        cpu,
                        TLB_SHOOTDOWN_VECTOR,
                        .Fixed,
                        .Physical,
                        true, // assert
                        false, // edge triggered
                        .NoShorthand,
                    );
                }
            }
        }

        // Flush locally
        flushLocal(address, page_count);

        // Wait for all CPUs to complete
        const timeout_iterations: u64 = 1_000_000_000; // ~1 second
        var iterations: u64 = 0;

        while (iterations < timeout_iterations) : (iterations += 1) {
            if (request.completed.load(.Acquire) >= num_cpus) {
                break;
            }

            if (iterations % 1000 == 0) {
                assembly.pause();
            }
        }

        // Clean up request
        allocator.destroy(request);
    }

    /// Broadcast TLB shootdown to all other CPUs
    pub fn shootdownAll(address: u64, page_count: u64, allocator: Basics.Allocator) !void {
        // Send to all CPUs except self
        const cpu_mask = ~@as(u64, 0); // All CPUs
        try shootdown(address, page_count, cpu_mask, allocator);
    }

    /// Handle TLB shootdown IPI (called from interrupt handler)
    pub fn handleShootdownIpi() void {
        const current_cpu = getCpuId();

        global.lock.acquire();
        const request = global.pending_requests[current_cpu];
        global.pending_requests[current_cpu] = null;
        global.lock.release();

        if (request) |req| {
            // Perform TLB flush
            flushLocal(req.address, req.page_count);

            // Mark as completed
            _ = req.completed.fetchAdd(1, .Release);
        }

        // Send EOI
        sendEoi();
    }

    /// Flush TLB locally
    fn flushLocal(address: u64, page_count: u64) void {
        if (page_count == ~@as(u64, 0) or address == 0) {
            // Full TLB flush
            assembly.flushTlb();
        } else if (page_count == 0) {
            // Single page flush
            assembly.invlpg(address);
        } else {
            // Multiple pages
            var i: u64 = 0;
            while (i < page_count) : (i += 1) {
                assembly.invlpg(address + (i * memory.PAGE_SIZE));
            }
        }
    }

    /// Batch multiple TLB flushes
    pub fn batchFlush(addresses: []const u64, cpu_mask: u64, allocator: Basics.Allocator) !void {
        // For small batches, just send individual flushes
        if (addresses.len <= 8) {
            for (addresses) |addr| {
                try shootdown(addr, 0, cpu_mask, allocator);
            }
            return;
        }

        // For large batches, do a full flush instead
        try shootdown(0, ~@as(u64, 0), cpu_mask, allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "APIC constants" {
    try Basics.testing.expectEqual(@as(u32, 0x020), ApicReg.ID);
    try Basics.testing.expectEqual(@as(u32, 0x0B0), ApicReg.EOI);
    try Basics.testing.expectEqual(@as(u32, 0x300), ApicReg.ICR_LOW);
}

test "timer divide values" {
    try Basics.testing.expectEqual(@as(u32, 0b1011), @intFromEnum(TimerDivide.Div1));
    try Basics.testing.expectEqual(@as(u32, 0b0001), @intFromEnum(TimerDivide.Div4));
}
