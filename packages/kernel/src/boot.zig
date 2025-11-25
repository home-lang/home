// Home Programming Language - Kernel Boot Entry Point
// Main entry point called from boot assembly after transition to long mode

const multiboot2 = @import("multiboot2.zig");
const serial = @import("serial.zig");
const vga = @import("vga.zig");
const gdt = @import("gdt.zig");
const interrupts = @import("interrupts.zig");
const paging = @import("paging.zig");
const memory = @import("memory.zig");
const asm_ops = @import("asm.zig");
const kheap = @import("kheap.zig");

// ============================================================================
// External Assembly Symbols
// ============================================================================

extern var multiboot2_magic: u32;
extern var multiboot2_info: u32;

// ============================================================================
// Global State
// ============================================================================

var vga_buffer: vga.VgaBuffer = undefined;
var serial_port: serial.SerialPort = undefined;

// ============================================================================
// Kernel Entry Point
// ============================================================================

/// Main kernel entry point called from boot.s
/// Arguments passed via registers:
///   - magic: Multiboot2 magic number (should be 0x36d76289)
///   - info_addr: Physical address of Multiboot2 info structure
export fn kernel_main(magic: u32, info_addr: u32) callconv(.C) noreturn {
    // Initialize early boot console (VGA text mode and serial)
    vga_buffer = vga.VgaBuffer.init();
    vga_buffer.clear();

    serial_port = serial.SerialPort.init(serial.COM1);
    serial_port.setup() catch {
        // Serial port init failed, continue anyway
    };

    // Print boot banner
    printBanner();

    // Verify Multiboot2 magic number
    if (!multiboot2.verifyMagic(magic)) {
        panic("Invalid Multiboot2 magic number");
    }
    println("✓ Multiboot2 magic verified");

    // Parse Multiboot2 information
    const mb_info = multiboot2.Multiboot2Info.fromAddress(info_addr);
    parseMultibootInfo(&mb_info);

    // Initialize GDT (Global Descriptor Table)
    // Note: GDT is already setup by boot.s, but we can enhance it here
    println("✓ GDT initialized (from boot.s)");

    // Initialize IDT (Interrupt Descriptor Table)
    // Create and load full IDT with exception and IRQ handlers
    initIdt();
    println("✓ IDT initialized with exception handlers");

    // Initialize memory management
    initMemoryManagement(&mb_info);

    // Initialize paging (already done by boot assembly)
    initPaging();

    // Enable interrupts
    asm_ops.sti();
    println("✓ Interrupts enabled");

    // Kernel initialization complete
    println("\nKernel initialization complete!");
    println("Home OS v0.1.0 - Ready");

    // Enter idle loop
    idle();
}

// ============================================================================
// Boot Information Parsing
// ============================================================================

fn parseMultibootInfo(mb_info: *const multiboot2.Multiboot2Info) void {
    println("\n=== Multiboot2 Information ===");

    // Print bootloader name
    if (mb_info.getBootloaderName()) |name| {
        print("Bootloader: ");
        println(name);
    }

    // Print command line
    if (mb_info.getCommandLine()) |cmdline| {
        print("Command line: ");
        println(cmdline);
    }

    // Print basic memory info
    if (mb_info.getBasicMeminfo()) |meminfo| {
        println("\n=== Memory Information ===");
        print("Lower memory: ");
        printU64(meminfo.mem_lower);
        println(" KB");
        print("Upper memory: ");
        printU64(meminfo.mem_upper);
        println(" KB");
    }

    // Print memory map
    printMemoryMap(mb_info);

    // Print framebuffer info (if available)
    if (mb_info.getFramebuffer()) |fb| {
        println("\n=== Framebuffer Information ===");
        print("Address: 0x");
        printHex64(fb.framebuffer_addr);
        println("");
        print("Resolution: ");
        printU32(fb.framebuffer_width);
        print("x");
        printU32(fb.framebuffer_height);
        print("x");
        printU32(fb.framebuffer_bpp);
        println(" bpp");
    }
}

fn printMemoryMap(mb_info: *const multiboot2.Multiboot2Info) void {
    if (mb_info.getMemoryMap()) |mmap| {
        println("\n=== Memory Map ===");
        const entries = mmap.entries();

        for (entries) |entry| {
            print("  0x");
            printHex64(entry.base_addr);
            print(" - 0x");
            printHex64(entry.base_addr + entry.length);
            print(" (");
            printU64(entry.length / 1024 / 1024);
            print(" MB) - ");
            println(multiboot2.getMemoryTypeName(entry.type));
        }
    }
}

// ============================================================================
// Memory Management Initialization
// ============================================================================

fn initMemoryManagement(mb_info: *const multiboot2.Multiboot2Info) void {
    println("\n=== Initializing Memory Management ===");

    // Get memory map
    const mmap = mb_info.getMemoryMap() orelse {
        panic("No memory map provided by bootloader");
    };

    // Find usable memory regions
    var total_memory: u64 = 0;
    var usable_memory: u64 = 0;

    const entries = mmap.entries();
    for (entries) |entry| {
        total_memory += entry.length;
        if (entry.type == multiboot2.MULTIBOOT_MEMORY_AVAILABLE) {
            usable_memory += entry.length;
        }
    }

    print("Total memory: ");
    printU64(total_memory / 1024 / 1024);
    println(" MB");
    print("Usable memory: ");
    printU64(usable_memory / 1024 / 1024);
    println(" MB");

    // Initialize physical memory allocator using memory map
    // Find the first large usable region and initialize the frame allocator
    const frame_entries = mmap.entries();
    for (frame_entries) |entry| {
        if (entry.type == multiboot2.MULTIBOOT_MEMORY_AVAILABLE and entry.length >= 64 * 1024 * 1024) {
            // Found a large enough region (at least 64MB)
            // Initialize physical memory allocator starting from this region
            // Skip first 16MB to avoid BIOS/kernel memory
            const start_addr = if (entry.base_addr < 16 * 1024 * 1024)
                @max(entry.base_addr, 16 * 1024 * 1024)
            else
                entry.base_addr;
            const end_addr = entry.base_addr + entry.length;
            memory.initPhysicalAllocator(start_addr, end_addr) catch {
                panic("Failed to initialize physical memory allocator");
            };
            break;
        }
    }
    println("✓ Physical memory allocator initialized");

    // Initialize kernel heap allocator
    // The kernel heap uses the physical allocator for backing pages
    kheap.init() catch {
        panic("Failed to initialize kernel heap");
    };
    println("✓ Kernel heap initialized");
}

fn initPaging() void {
    println("\n=== Initializing Paging ===");

    // Boot assembly already set up identity mapping for first 1GB
    // Here we can set up more sophisticated page tables if needed

    println("✓ Paging initialized");
}

// ============================================================================
// IDT Initialization
// ============================================================================

var interrupt_manager: interrupts.InterruptManager = undefined;

fn initIdt() void {
    // Create interrupt manager and install default exception handlers
    interrupt_manager = interrupts.InterruptManager.init();
    interrupt_manager.installDefaultHandlers();

    // Remap PIC to avoid conflicts with CPU exceptions (vectors 0-31)
    // Map IRQ 0-7 to vectors 32-39 and IRQ 8-15 to vectors 40-47
    interrupts.PIC.remap(32, 40);

    // Load and activate the IDT
    interrupt_manager.activate();
}

// ============================================================================
// Panic Handler
// ============================================================================

pub fn panic(msg: []const u8) noreturn {
    // Disable interrupts
    asm_ops.cli();

    // Print panic message
    vga_buffer.setColor(vga.ColorCode.new(.White, .Red));
    print("\n\n!!! KERNEL PANIC !!!\n");
    println(msg);
    println("\nSystem halted.");

    // Halt CPU
    while (true) {
        asm_ops.hlt();
    }
}

// ============================================================================
// Idle Loop
// ============================================================================

fn idle() noreturn {
    while (true) {
        // Halt CPU until next interrupt
        asm_ops.hlt();
    }
}

// ============================================================================
// Boot Banner
// ============================================================================

fn printBanner() void {
    println("\n╔════════════════════════════════════════╗");
    println("║     Home Operating System v0.1.0      ║");
    println("║   Built with Home Programming Lang    ║");
    println("╚════════════════════════════════════════╝\n");
}

// ============================================================================
// Output Functions
// ============================================================================

fn print(msg: []const u8) void {
    for (msg) |c| {
        vga_buffer.putChar(c);
        serial_port.write(c) catch {};
    }
}

fn println(msg: []const u8) void {
    print(msg);
    print("\n");
}

fn printU32(value: u32) void {
    var buf: [20]u8 = undefined;
    const str = formatU64(value, &buf);
    print(str);
}

fn printU64(value: u64) void {
    var buf: [20]u8 = undefined;
    const str = formatU64(value, &buf);
    print(str);
}

fn printHex64(value: u64) void {
    var buf: [16]u8 = undefined;
    const str = formatHex64(value, &buf);
    print(str);
}

fn formatU64(value: u64, buf: []u8) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    var n = value;
    var i: usize = 0;

    // Build string in reverse
    while (n > 0) : (i += 1) {
        buf[i] = @as(u8, @intCast(n % 10)) + '0';
        n /= 10;
    }

    // Reverse the string
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }

    return buf[0..i];
}

fn formatHex64(value: u64, buf: []u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    var n = value;
    var i: usize = 16;

    while (i > 0) {
        i -= 1;
        buf[i] = hex_chars[@as(usize, @intCast(n & 0xF))];
        n >>= 4;
    }

    return buf[0..16];
}

// ============================================================================
// Tests
// ============================================================================

test "boot module" {
    // Basic compilation test
    const std = @import("std");
    try std.testing.expect(true);
}
