// Home Programming Language - Kernel Module
// Operating System Development Primitives
//
// This module provides low-level OS development primitives including:
// - Inline assembly and CPU operations
// - Memory management (allocators, paging, MMIO)
// - Interrupt handling (IDT, exceptions, IRQs)
// - Atomic operations and memory ordering
// - Synchronization primitives (locks, mutexes, semaphores)

const Basics = @import("basics");

// ============================================================================
// Core Modules
// ============================================================================

/// Assembly operations and CPU control
pub const assembly = @import("asm.zig");

/// Memory management primitives
pub const memory = @import("memory.zig");

/// Interrupt and exception handling
pub const interrupts = @import("interrupts.zig");

/// Page table and virtual memory management
pub const paging = @import("paging.zig");

/// Atomic operations and lock-free data structures
pub const atomic = @import("atomic.zig");

/// Synchronization primitives (locks, mutexes, semaphores)
pub const sync = @import("sync.zig");

/// CPU context and register state management
pub const cpu_context = @import("cpu_context.zig");

/// GDT (Global Descriptor Table) management
pub const gdt = @import("gdt.zig");

/// System call interface (SYSCALL/SYSRET)
pub const syscall = @import("syscall.zig");

/// Serial port driver for debugging
pub const serial = @import("serial.zig");

/// VGA text mode driver
pub const vga = @import("vga.zig");

/// Multiboot2 bootloader interface
pub const multiboot2 = @import("multiboot2.zig");

/// Boot entry point and initialization
pub const boot = @import("boot.zig");

// ============================================================================
// Device Drivers and Hardware
// ============================================================================

/// PCI bus enumeration and device discovery
pub const pci = @import("pci.zig");

/// DMA buffer management
pub const dma = @import("dma.zig");

// ============================================================================
// Process and Thread Management
// ============================================================================

/// Process management
pub const process = @import("process.zig");

/// Process forking with copy-on-write
pub const fork = @import("fork.zig");

/// Process execution and program loading
pub const exec = @import("exec.zig");

/// Complete ELF loader with memory mapping
pub const elf_loader = @import("elf_loader.zig");

/// Copy-on-Write implementation
pub const cow = @import("cow.zig");

/// Thread management
pub const thread = @import("thread.zig");

/// Scheduler
pub const sched = @import("sched.zig");

// ============================================================================
// Re-exports for Convenience
// ============================================================================

// Memory types
pub const PhysicalAddress = memory.PhysicalAddress;
pub const VirtualAddress = memory.VirtualAddress;
pub const PAGE_SIZE = memory.PAGE_SIZE;
pub const MMIO = memory.MMIO;

// Page table types
pub const PageFlags = paging.PageFlags;
pub const PageMapper = paging.PageMapper;
pub const PML4 = paging.PML4;
pub const PDPT = paging.PDPT;
pub const PD = paging.PD;
pub const PT = paging.PT;

// Interrupt types
pub const InterruptFrame = interrupts.InterruptFrame;
pub const Exception = interrupts.Exception;
pub const Idt = interrupts.Idt;
pub const InterruptManager = interrupts.InterruptManager;

// Atomic types
pub const Atomic = atomic.Atomic;
pub const AtomicU32 = atomic.AtomicU32;
pub const AtomicU64 = atomic.AtomicU64;
pub const AtomicFlag = atomic.AtomicFlag;
pub const AtomicRefCount = atomic.AtomicRefCount;
pub const MemoryOrder = atomic.MemoryOrder;

// Lock types
pub const Spinlock = sync.Spinlock;
pub const IrqSpinlock = sync.IrqSpinlock;
pub const RwSpinlock = sync.RwSpinlock;
pub const Mutex = sync.Mutex;
pub const Semaphore = sync.Semaphore;
pub const Once = sync.Once;

// CPU context types
pub const CpuContext = cpu_context.CpuContext;
pub const RFlags = cpu_context.RFlags;
pub const StackFrame = cpu_context.StackFrame;
pub const FpuState = cpu_context.FpuState;
pub const TaskState = cpu_context.TaskState;

// GDT types
pub const Gdt = gdt.Gdt;
pub const GdtEntry = gdt.GdtEntry;
pub const Tss = gdt.Tss;
pub const SegmentSelector = gdt.SegmentSelector;

// System call types
pub const SyscallNumber = syscall.SyscallNumber;
pub const SyscallTable = syscall.SyscallTable;

// Serial and VGA
pub const SerialPort = serial.SerialPort;
pub const VgaBuffer = vga.VgaBuffer;
pub const Color = vga.Color;
pub const ColorCode = vga.ColorCode;

// PCI types
pub const PciDevice = pci.PciDevice;
pub const PciAddress = pci.PciAddress;

// DMA types
pub const DmaBuffer = dma.DmaBuffer;
pub const DmaPool = dma.DmaPool;
pub const SgList = dma.SgList;

// Process/Thread types
pub const Process = process.Process;
pub const ProcessState = process.ProcessState;
pub const Thread = thread.Thread;
pub const ThreadState = thread.ThreadState;
pub const Scheduler = sched.CpuScheduler;

// ============================================================================
// Kernel Initialization
// ============================================================================

pub const KernelConfig = struct {
    /// Physical memory start
    phys_mem_start: u64,
    /// Physical memory size
    phys_mem_size: u64,
    /// Enable serial console output
    serial_console: bool = true,
    /// Enable interrupt handlers
    enable_interrupts: bool = true,
    /// Remap PIC IRQs
    remap_pic: bool = true,
};

pub const Kernel = struct {
    config: KernelConfig,
    page_mapper: ?PageMapper = null,
    interrupt_manager: ?InterruptManager = null,

    pub fn init(config: KernelConfig, allocator: Basics.Allocator) !Kernel {
        var kernel = Kernel{
            .config = config,
        };

        // Initialize page mapper
        kernel.page_mapper = try PageMapper.init(allocator);
        errdefer if (kernel.page_mapper) |*pm| pm.deinit();

        // Map kernel space
        try paging.mapKernelSpace(
            &kernel.page_mapper.?,
            config.phys_mem_start,
            config.phys_mem_size,
        );

        // Initialize interrupt manager
        if (config.enable_interrupts) {
            kernel.interrupt_manager = InterruptManager.init();
            kernel.interrupt_manager.?.installDefaultHandlers();

            if (config.remap_pic) {
                // Remap PIC to avoid conflicts with CPU exceptions
                interrupts.PIC.remap(32, 40);
            }

            kernel.interrupt_manager.?.activate();
        }

        return kernel;
    }

    pub fn deinit(self: *Kernel) void {
        if (self.page_mapper) |*pm| {
            pm.deinit();
        }
    }

    pub fn activatePaging(self: *Kernel) void {
        if (self.page_mapper) |*pm| {
            pm.activate();
        }
    }

    pub fn enableInterrupts(self: *Kernel) void {
        _ = self;
        asm.sti();
    }

    pub fn disableInterrupts(self: *Kernel) void {
        _ = self;
        asm.cli();
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Halt the CPU
pub fn halt() noreturn {
    while (true) {
        asm.hlt();
    }
}

/// Panic handler for kernel
pub fn panic(msg: []const u8) noreturn {
    asm.cli(); // Disable interrupts
    Basics.debug.print("KERNEL PANIC: {s}\n", .{msg});
    halt();
}

/// Print to kernel console
pub fn print(comptime fmt: []const u8, args: anytype) void {
    Basics.debug.print(fmt, args);
}

/// Print with newline
pub fn println(comptime fmt: []const u8, args: anytype) void {
    Basics.debug.print(fmt ++ "\n", args);
}

// ============================================================================
// Tests
// ============================================================================

test "kernel module imports" {
    // Verify all modules are accessible
    _ = asm;
    _ = memory;
    _ = interrupts;
    _ = paging;
    _ = atomic;
    _ = sync;
}

test "kernel types" {
    // Verify type re-exports
    const addr: PhysicalAddress = 0x1000;
    try Basics.testing.expectEqual(@as(u64, 0x1000), addr);

    try Basics.testing.expectEqual(@as(usize, 4096), PAGE_SIZE);
}
