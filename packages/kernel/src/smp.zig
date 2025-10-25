// Home Programming Language - SMP (Symmetric Multiprocessing) Support
// Application Processor startup and per-CPU data structures

const Basics = @import("basics");
const apic = @import("apic.zig");
const acpi = @import("acpi.zig");
const gdt = @import("gdt.zig");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");
const asm = @import("asm.zig");

// ============================================================================
// Per-CPU Data Structure
// ============================================================================

pub const PerCpuData = struct {
    /// CPU ID (from Local APIC)
    cpu_id: u32,
    /// Processor ID (ACPI)
    processor_id: u8,
    /// Is this CPU online?
    online: atomic.AtomicBool,
    /// Is this the BSP?
    is_bsp: bool,
    /// CPU-local GDT
    gdt_ptr: ?*gdt.GdtDescriptor,
    /// Kernel stack for this CPU
    kernel_stack: []u8,
    /// Current thread running on this CPU
    current_thread: ?*anyopaque,
    /// CPU-local allocator
    allocator: Basics.Allocator,

    pub fn init(cpu_id: u32, processor_id: u8, is_bsp: bool, allocator: Basics.Allocator) !PerCpuData {
        // Allocate kernel stack (16KB)
        const kernel_stack = try allocator.alloc(u8, 16384);
        errdefer allocator.free(kernel_stack);

        return PerCpuData{
            .cpu_id = cpu_id,
            .processor_id = processor_id,
            .online = atomic.AtomicBool.init(false),
            .is_bsp = is_bsp,
            .gdt_ptr = null,
            .kernel_stack = kernel_stack,
            .current_thread = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PerCpuData) void {
        self.allocator.free(self.kernel_stack);
    }

    pub fn markOnline(self: *PerCpuData) void {
        self.online.store(true, .Release);
    }

    pub fn markOffline(self: *PerCpuData) void {
        self.online.store(false, .Release);
    }

    pub fn isOnline(self: *const PerCpuData) bool {
        return self.online.load(.Acquire);
    }
};

// ============================================================================
// CPU Information
// ============================================================================

pub const CpuInfo = struct {
    cpu_id: u32,
    processor_id: u8,
    apic_id: u8,
    enabled: bool,
    is_bsp: bool,
};

// ============================================================================
// SMP Context
// ============================================================================

const MAX_CPUS = 256;

pub const SmpContext = struct {
    /// Array of per-CPU data
    per_cpu_data: [MAX_CPUS]?PerCpuData,
    /// Number of detected CPUs
    cpu_count: atomic.AtomicUsize,
    /// Number of online CPUs
    online_count: atomic.AtomicUsize,
    /// BSP (Bootstrap Processor) ID
    bsp_id: u32,
    /// Lock for SMP operations
    lock: sync.Spinlock,
    /// Allocator
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) SmpContext {
        return .{
            .per_cpu_data = [_]?PerCpuData{null} ** MAX_CPUS,
            .cpu_count = atomic.AtomicUsize.init(0),
            .online_count = atomic.AtomicUsize.init(0),
            .bsp_id = 0,
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };
    }

    /// Discover CPUs from ACPI MADT
    pub fn discoverCpus(self: *SmpContext) ![]CpuInfo {
        const madt = acpi.getMadt() orelse return error.NoMadt;

        var cpu_list = Basics.ArrayList(CpuInfo).init(self.allocator);
        errdefer cpu_list.deinit();

        // Get BSP APIC ID
        const local_apic = apic.getLocalApic() orelse return error.NoApic;
        const bsp_apic_id = local_apic.getCpuId();

        // Parse MADT entries
        var offset: u32 = 0;
        const entries = madt.getEntries();
        const total_size = madt.getEntriesSize();

        while (offset < total_size) {
            const header: *const acpi.MadtEntryHeader = @ptrCast(entries + offset);

            if (header.entry_type == @intFromEnum(acpi.MadtEntryType.LocalApic)) {
                const local_apic_entry: *const acpi.MadtLocalApic = @ptrCast(header);

                if (local_apic_entry.isEnabled()) {
                    try cpu_list.append(.{
                        .cpu_id = @intCast(cpu_list.items.len),
                        .processor_id = local_apic_entry.processor_id,
                        .apic_id = local_apic_entry.apic_id,
                        .enabled = true,
                        .is_bsp = local_apic_entry.apic_id == bsp_apic_id,
                    });
                }
            } else if (header.entry_type == @intFromEnum(acpi.MadtEntryType.ProcessorLocalX2Apic)) {
                // TODO: Handle x2APIC entries for > 255 CPUs
            }

            offset += header.length;
        }

        return cpu_list.toOwnedSlice();
    }

    /// Initialize per-CPU data structures
    pub fn initPerCpuData(self: *SmpContext, cpu_info: []const CpuInfo) !void {
        self.lock.acquire();
        defer self.lock.release();

        for (cpu_info) |info| {
            if (info.cpu_id >= MAX_CPUS) continue;

            var per_cpu = try PerCpuData.init(
                info.cpu_id,
                info.processor_id,
                info.is_bsp,
                self.allocator,
            );

            self.per_cpu_data[info.cpu_id] = per_cpu;

            if (info.is_bsp) {
                self.bsp_id = info.cpu_id;
                per_cpu.markOnline();
                _ = self.online_count.fetchAdd(1, .Release);
            }
        }

        self.cpu_count.store(cpu_info.len, .Release);
    }

    /// Get per-CPU data for specific CPU
    pub fn getPerCpuData(self: *SmpContext, cpu_id: u32) ?*PerCpuData {
        if (cpu_id >= MAX_CPUS) return null;
        if (self.per_cpu_data[cpu_id]) |*data| {
            return data;
        }
        return null;
    }

    /// Get current CPU's per-CPU data
    pub fn getCurrentCpuData(self: *SmpContext) ?*PerCpuData {
        const cpu_id = apic.getCpuId();
        return self.getPerCpuData(cpu_id);
    }

    /// Start Application Processor
    pub fn startAp(self: *SmpContext, cpu_id: u32) !void {
        const cpu_data = self.getPerCpuData(cpu_id) orelse return error.InvalidCpuId;
        if (cpu_data.is_bsp) return error.CannotStartBsp;

        const local_apic = apic.getLocalApic() orelse return error.NoApic;

        // Send INIT IPI
        local_apic.sendInitIpi(cpu_id);

        // Wait 10ms
        // TODO: Use proper timer delay
        for (0..10_000_000) |_| {
            asm.pause();
        }

        // Send Startup IPI with trampoline address (page 0)
        // The trampoline code should be at physical address 0x8000 (page 8)
        const startup_page: u8 = 0x08;
        local_apic.sendStartupIpi(cpu_id, startup_page);

        // Wait 200us
        for (0..200_000) |_| {
            asm.pause();
        }

        // Send second Startup IPI (as per Intel spec)
        local_apic.sendStartupIpi(cpu_id, startup_page);

        // Wait for AP to come online (with timeout)
        var timeout: u32 = 1000;
        while (timeout > 0) : (timeout -= 1) {
            if (cpu_data.isOnline()) {
                _ = self.online_count.fetchAdd(1, .Release);
                return;
            }

            // Wait 1ms
            for (0..1_000_000) |_| {
                asm.pause();
            }
        }

        return error.ApStartupTimeout;
    }

    /// Start all Application Processors
    pub fn startAllAps(self: *SmpContext) !void {
        const count = self.cpu_count.load(.Acquire);

        for (0..count) |i| {
            const cpu_id: u32 = @intCast(i);
            const cpu_data = self.getPerCpuData(cpu_id) orelse continue;

            if (cpu_data.is_bsp) continue;

            self.startAp(cpu_id) catch |err| {
                // Log error but continue with other CPUs
                _ = err;
                continue;
            };
        }
    }

    /// Get number of CPUs
    pub fn getCpuCount(self: *const SmpContext) usize {
        return self.cpu_count.load(.Acquire);
    }

    /// Get number of online CPUs
    pub fn getOnlineCpuCount(self: *const SmpContext) usize {
        return self.online_count.load(.Acquire);
    }

    /// Execute function on all CPUs
    pub fn executeOnAllCpus(self: *SmpContext, func: *const fn (cpu_id: u32) void) void {
        _ = self;
        _ = func;
        // TODO: Send IPI to all CPUs to execute function
    }

    /// Execute function on specific CPU
    pub fn executeOnCpu(self: *SmpContext, cpu_id: u32, func: *const fn (cpu_id: u32) void) !void {
        _ = self;
        _ = cpu_id;
        _ = func;
        // TODO: Send IPI to specific CPU to execute function
    }
};

// ============================================================================
// Global SMP Context
// ============================================================================

var smp_context: ?SmpContext = null;
var smp_lock = sync.Spinlock.init();

/// Initialize SMP subsystem
pub fn init(allocator: Basics.Allocator) !void {
    smp_lock.acquire();
    defer smp_lock.release();

    var ctx = SmpContext.init(allocator);

    // Discover CPUs from ACPI
    const cpu_info = try ctx.discoverCpus();
    defer allocator.free(cpu_info);

    // Initialize per-CPU data
    try ctx.initPerCpuData(cpu_info);

    smp_context = ctx;
}

/// Get SMP context
pub fn getContext() ?*SmpContext {
    if (smp_context) |*ctx| {
        return ctx;
    }
    return null;
}

/// Start all Application Processors
pub fn startAllAps() !void {
    if (getContext()) |ctx| {
        try ctx.startAllAps();
    } else {
        return error.SmpNotInitialized;
    }
}

/// Get current CPU ID
pub fn getCurrentCpuId() u32 {
    return apic.getCpuId();
}

/// Get per-CPU data for current CPU
pub fn getCurrentCpuData() ?*PerCpuData {
    if (getContext()) |ctx| {
        return ctx.getCurrentCpuData();
    }
    return null;
}

/// Get number of CPUs
pub fn getCpuCount() usize {
    if (getContext()) |ctx| {
        return ctx.getCpuCount();
    }
    return 1;
}

/// Get number of online CPUs
pub fn getOnlineCpuCount() usize {
    if (getContext()) |ctx| {
        return ctx.getOnlineCpuCount();
    }
    return 1;
}

// ============================================================================
// AP Entry Point
// ============================================================================

/// Called by AP after startup
pub export fn apEntry() callconv(.C) void {
    // Get current CPU ID from APIC
    const cpu_id = apic.getCpuId();

    if (getContext()) |ctx| {
        if (ctx.getPerCpuData(cpu_id)) |cpu_data| {
            // Mark CPU as online
            cpu_data.markOnline();

            // Initialize Local APIC for this CPU
            if (apic.getLocalApic()) |local_apic| {
                local_apic.enable(0xFF);
            }

            // TODO: Initialize scheduler for this CPU
            // TODO: Load per-CPU GDT
            // TODO: Setup per-CPU IDT

            // Enter idle loop
            while (true) {
                asm.hlt();
            }
        }
    }
}

// ============================================================================
// CPU Hotplug
// ============================================================================

/// Bring CPU online
pub fn bringCpuOnline(cpu_id: u32) !void {
    if (getContext()) |ctx| {
        try ctx.startAp(cpu_id);
    } else {
        return error.SmpNotInitialized;
    }
}

/// Take CPU offline
pub fn takeCpuOffline(cpu_id: u32) !void {
    if (getContext()) |ctx| {
        if (ctx.getPerCpuData(cpu_id)) |cpu_data| {
            if (cpu_data.is_bsp) {
                return error.CannotOfflineBsp;
            }

            // TODO: Migrate threads away from this CPU
            // TODO: Send IPI to stop CPU

            cpu_data.markOffline();
            _ = ctx.online_count.fetchSub(1, .Release);
        } else {
            return error.InvalidCpuId;
        }
    } else {
        return error.SmpNotInitialized;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "per-CPU data" {
    const allocator = Basics.testing.allocator;

    var cpu_data = try PerCpuData.init(0, 0, true, allocator);
    defer cpu_data.deinit();

    try Basics.testing.expect(!cpu_data.isOnline());
    cpu_data.markOnline();
    try Basics.testing.expect(cpu_data.isOnline());
}

test "SMP context" {
    const allocator = Basics.testing.allocator;

    var ctx = SmpContext.init(allocator);

    try Basics.testing.expectEqual(@as(usize, 0), ctx.getCpuCount());
    try Basics.testing.expectEqual(@as(usize, 0), ctx.getOnlineCpuCount());
}
