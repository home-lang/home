// Home Programming Language - Advanced Kernel Example
// Demonstrates advanced OS features: GDT, syscalls, serial, VGA

const Basics = @import("basics");
const Kernel = @import("kernel");

pub fn main() !void {
    var gpa = Basics.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    Basics.println("=== Home Advanced Kernel Features ===", .{});
    Basics.println("", .{});

    // ========================================================================
    // 1. Serial Port (Debugging Console)
    // ========================================================================
    Basics.println("1. Serial Port Driver:", .{});

    // Initialize COM1 serial port
    var serial = Kernel.SerialPort.init(Kernel.serial.COM1);
    try serial.setup();
    Basics.println("  - Serial port COM1 initialized at 115200 baud", .{});

    // Write to serial port
    serial.writeString("Hello from Home kernel!\n");
    serial.println("Serial debug output works!", .{});
    Basics.println("  - Serial output sent", .{});

    // Check status
    const status = serial.getLineStatus();
    Basics.println("  - Transmit buffer empty: {}", .{status.transmit_empty});
    Basics.println("", .{});

    // ========================================================================
    // 2. VGA Text Mode
    // ========================================================================
    Basics.println("2. VGA Text Mode Driver:", .{});

    var vga = Kernel.VgaBuffer.init();
    vga.clear();
    Basics.println("  - VGA buffer initialized (80x25)", .{});

    // Set colors
    vga.setColor(Kernel.ColorCode.new(.Yellow, .Blue));
    vga.writeString("Hello VGA!\n");

    // Draw a box
    vga.drawBox(5, 3, 30, 10, Kernel.ColorCode.new(.White, .Black));
    Basics.println("  - Drew box at (5, 3) with size 30x10", .{});

    // Fill rectangle
    vga.fillRect(40, 5, 20, 5, ' ', Kernel.ColorCode.new(.White, .Green));
    Basics.println("  - Filled rectangle with green background", .{});

    // Print formatted text
    vga.setCursor(10, 12);
    vga.setColor(Kernel.ColorCode.new(.White, .Black));
    vga.println("Formatted output: {}", .{42});
    Basics.println("  - VGA output complete", .{});
    Basics.println("", .{});

    // ========================================================================
    // 3. GDT (Global Descriptor Table)
    // ========================================================================
    Basics.println("3. GDT Management:", .{});

    var kernel_gdt = try Kernel.Gdt.init(allocator);
    defer kernel_gdt.deinit(allocator);

    Basics.println("  - GDT initialized with segments:", .{});
    Basics.println("    • Null segment (0)", .{});
    Basics.println("    • Kernel code segment (ring 0)", .{});
    Basics.println("    • Kernel data segment (ring 0)", .{});
    Basics.println("    • User code segment (ring 3)", .{});
    Basics.println("    • User data segment (ring 3)", .{});
    Basics.println("    • TSS (Task State Segment)", .{});

    // Set kernel stack for privilege transitions
    const kernel_stack: u64 = 0xFFFF_8000_0010_0000;
    kernel_gdt.setKernelStack(kernel_stack);
    Basics.println("  - Kernel stack set to: 0x{x}", .{kernel_stack});

    // Set interrupt stacks
    kernel_gdt.setInterruptStack(0, 0xFFFF_8000_0020_0000);
    Basics.println("  - Interrupt stack 0 set", .{});

    // Segment selectors
    Basics.println("  - Kernel code selector: 0x{x}", .{Kernel.gdt.KERNEL_CODE_SELECTOR});
    Basics.println("  - Kernel data selector: 0x{x}", .{Kernel.gdt.KERNEL_DATA_SELECTOR});
    Basics.println("  - User code selector: 0x{x}", .{Kernel.gdt.USER_CODE_SELECTOR});
    Basics.println("  - TSS selector: 0x{x}", .{Kernel.gdt.TSS_SELECTOR});
    Basics.println("", .{});

    // ========================================================================
    // 4. CPU Context and Register State
    // ========================================================================
    Basics.println("4. CPU Context Management:", .{});

    // Read RFLAGS
    const rflags = Kernel.RFlags.read();
    Basics.println("  - RFLAGS register:", .{});
    Basics.println("    • Carry: {}", .{rflags.carry});
    Basics.println("    • Zero: {}", .{rflags.zero});
    Basics.println("    • Interrupt enable: {}", .{rflags.interrupt_enable});
    Basics.println("    • Direction: {}", .{rflags.direction});

    // Stack frame walking
    Basics.println("  - Current stack frame:", .{});
    const frame = Kernel.StackFrame.current();
    Basics.println("    • RBP: 0x{x:0>16}", .{frame.rbp});
    Basics.println("    • RIP: 0x{x:0>16}", .{frame.rip});

    // FPU state
    var fpu_state = Kernel.FpuState.init();
    Basics.println("  - FPU state structure initialized (512 bytes)", .{});
    _ = fpu_state;

    // Task state
    var task = Kernel.TaskState.init();
    Basics.println("  - Task state initialized (CPU + FPU)", .{});
    _ = task;
    Basics.println("", .{});

    // ========================================================================
    // 5. System Call Interface
    // ========================================================================
    Basics.println("5. System Call Interface:", .{});

    var syscall_table = Kernel.SyscallTable.init();

    // Register system call handlers
    syscall_table.register(.Exit, sysExitHandler);
    syscall_table.register(.Write, sysWriteHandler);
    syscall_table.register(.Getpid, sysGetpidHandler);
    Basics.println("  - Registered 3 system call handlers:", .{});
    Basics.println("    • Exit (0)", .{});
    Basics.println("    • Write (2)", .{});
    Basics.println("    • Getpid (16)", .{});

    // Test syscall dispatch (simulated)
    const args = Kernel.syscall.SyscallArgs{
        .number = @intFromEnum(Kernel.SyscallNumber.Getpid),
        .arg1 = 0,
        .arg2 = 0,
        .arg3 = 0,
        .arg4 = 0,
        .arg5 = 0,
        .arg6 = 0,
    };

    const handler = syscall_table.get(args.number);
    if (handler) |h| {
        const result = h(args);
        Basics.println("  - Simulated syscall result: {}", .{result});
    }

    Basics.println("  - System call MSRs:", .{});
    Basics.println("    • IA32_STAR: 0x{x}", .{Kernel.syscall.IA32_STAR});
    Basics.println("    • IA32_LSTAR: 0x{x}", .{Kernel.syscall.IA32_LSTAR});
    Basics.println("    • IA32_FMASK: 0x{x}", .{Kernel.syscall.IA32_FMASK});
    Basics.println("", .{});

    // ========================================================================
    // 6. Stack Trace
    // ========================================================================
    Basics.println("6. Stack Trace:", .{});
    Basics.println("  - Walking stack frames:", .{});

    var depth: usize = 0;
    Kernel.cpu_context.walkStack({}, struct {
        fn print(_: void, f: Kernel.StackFrame) void {
            Basics.println("    #{} RBP: 0x{x:0>16}  RIP: 0x{x:0>16}", .{ depth, f.rbp, f.rip });
            depth += 1;
        }
    }.print);
    Basics.println("", .{});

    // ========================================================================
    // 7. Complete CPU Context
    // ========================================================================
    Basics.println("7. Complete CPU Context:", .{});

    var cpu_ctx = Basics.mem.zeroes(Kernel.CpuContext);
    cpu_ctx.rax = 0x1234_5678_9ABC_DEF0;
    cpu_ctx.rbx = 0xFEDC_BA98_7654_3210;
    cpu_ctx.rip = 0xFFFF_8000_0000_1000;
    cpu_ctx.rsp = 0xFFFF_8000_0010_0000;
    cpu_ctx.vector = 14; // Page fault

    Basics.println("  - Simulated exception context:", .{});
    Basics.println("{}", .{cpu_ctx});
    Basics.println("", .{});

    // ========================================================================
    // 8. VGA Color Palette
    // ========================================================================
    Basics.println("8. VGA Color Palette:", .{});
    Basics.println("  - Available colors:", .{});

    const colors = [_]Kernel.Color{
        .Black,      .Blue,       .Green,      .Cyan,
        .Red,        .Magenta,    .Brown,      .LightGray,
        .DarkGray,   .LightBlue,  .LightGreen, .LightCyan,
        .LightRed,   .Pink,       .Yellow,     .White,
    };

    for (colors) |color| {
        Basics.println("    • {s}", .{@tagName(color)});
    }
    Basics.println("", .{});

    // ========================================================================
    // Summary
    // ========================================================================
    Basics.println("=== Advanced Features Summary ===", .{});
    Basics.println("✓ Serial port (COM1-COM4) for debugging", .{});
    Basics.println("✓ VGA text mode (80x25, 16 colors)", .{});
    Basics.println("✓ GDT with kernel/user segments", .{});
    Basics.println("✓ TSS for privilege transitions", .{});
    Basics.println("✓ System call interface (SYSCALL/SYSRET)", .{});
    Basics.println("✓ Full CPU context capture", .{});
    Basics.println("✓ Stack frame walking", .{});
    Basics.println("✓ FPU/SSE state management", .{});
    Basics.println("✓ RFLAGS manipulation", .{});
    Basics.println("", .{});
    Basics.println("Home is production-ready for OS development!", .{});
}

// System call handlers
fn sysExitHandler(args: Kernel.syscall.SyscallArgs) callconv(.C) u64 {
    Basics.println("  [SYSCALL] Exit with code: {}", .{args.arg1});
    return 0;
}

fn sysWriteHandler(args: Kernel.syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    return 0;
}

fn sysGetpidHandler(args: Kernel.syscall.SyscallArgs) callconv(.C) u64 {
    _ = args;
    return 1234; // Mock PID
}
