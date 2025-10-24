# Home OS Development Roadmap

> **Transforming Home into the best systems programming language for OS development**

---

## 🎯 Vision

Build Home into a **systems programming language** that combines:
- ✅ **Zig's compile-time guarantees** - Safety without runtime cost
- ✅ **Rust's memory safety** - Fearless concurrency
- ✅ **C's simplicity** - Direct hardware access
- ✅ **TypeScript's DX** - Modern developer experience
- ✅ **Home's philosophy** - Making systems programming feel like home

**Goal:** Build a complete operating system in Home that rivals Linux, BSD, and Redox.

---

## 🔥 Critical OS Features Needed

### 1. Low-Level Memory Management ⚡

**Why:** OS kernels need direct memory control without allocators.

**What to implement:**
```zig
// Bare-metal memory management
pub const KernelAllocator = struct {
    // Bump allocator for early boot
    pub const Bump = struct {
        current: usize,
        limit: usize,

        pub fn alloc(self: *Bump, size: usize, alignment: usize) ![]u8 {
            // Compile-time aligned allocation
        }
    };

    // Slab allocator for fixed-size objects
    pub const Slab = struct {
        object_size: comptime_int,
        free_list: ?*anyopaque,

        pub fn alloc(self: *Slab) !*anyopaque {
            // O(1) allocation
        }
    };

    // Buddy allocator for variable-size allocations
    pub const Buddy = struct {
        free_lists: [MAX_ORDER]?*Block,

        pub fn alloc(self: *Buddy, size: usize) ![]u8 {
            // Efficient power-of-2 allocation
        }
    };
};

// Page allocator
pub const PageAllocator = struct {
    pub fn allocPage() !PhysicalAddress {
        // Allocate 4KB page
    }

    pub fn allocPages(count: usize) ![]PhysicalAddress {
        // Allocate contiguous pages
    }
};
```

### 2. Inline Assembly Support 🔧

**Why:** Direct CPU instruction access is essential for OS development.

**What to implement:**
```zig
// Intel syntax
pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [port] "N{dx}" (port),
          [value] "{al}" (value)
    );
}

// AT&T syntax
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8)
        : [port] "N{dx}" (port)
    );
}

// Multi-instruction blocks
pub fn hlt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

// CPUID
pub fn cpuid(leaf: u32) CpuIdResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (leaf)
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
```

### 3. Hardware Access & MMIO 🖥️

**Why:** OS needs to talk to hardware directly.

**What to implement:**
```zig
// Memory-mapped I/O with type safety
pub fn MMIO(comptime T: type) type {
    return struct {
        address: usize,

        pub fn read(self: @This()) T {
            const ptr: *volatile T = @ptrFromInt(self.address);
            return ptr.*;
        }

        pub fn write(self: @This(), value: T) void {
            const ptr: *volatile T = @ptrFromInt(self.address);
            ptr.* = value;
        }

        pub fn modify(self: @This(), comptime f: fn(T) T) void {
            self.write(f(self.read()));
        }
    };
}

// Hardware register abstraction
pub const Register = struct {
    pub fn define(comptime spec: RegisterSpec) type {
        return struct {
            mmio: MMIO(spec.Type),

            pub fn read(self: @This()) spec.Type {
                return self.mmio.read();
            }

            pub fn write(self: @This(), value: spec.Type) void {
                // Compile-time validation of reserved bits
                comptime {
                    if (spec.read_only) {
                        @compileError("Cannot write to read-only register");
                    }
                }
                self.mmio.write(value);
            }

            pub fn setBit(self: @This(), comptime bit: u32) void {
                comptime {
                    if (bit >= spec.bits) {
                        @compileError("Bit out of range");
                    }
                }
                self.modify(|val| val | (@as(spec.Type, 1) << bit));
            }
        };
    }
};

// Example: UART register
const UART_DATA = Register.define(.{
    .Type = u8,
    .address = 0x3F8,
    .bits = 8,
    .read_only = false,
});
```

### 4. Interrupt & Exception Handling ⚠️

**Why:** OS needs to handle CPU exceptions and interrupts.

**What to implement:**
```zig
// Interrupt descriptor
pub const InterruptDescriptor = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    attributes: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,

    pub fn init(handler: fn() callconv(.Interrupt) void) @This() {
        const addr = @intFromPtr(handler);
        return .{
            .offset_low = @truncate(addr),
            .selector = 0x08, // Kernel code segment
            .ist = 0,
            .attributes = 0x8E, // Present, DPL=0, Interrupt Gate
            .offset_mid = @truncate(addr >> 16),
            .offset_high = @truncate(addr >> 32),
            .reserved = 0,
        };
    }
};

// IDT (Interrupt Descriptor Table)
pub const IDT = struct {
    entries: [256]InterruptDescriptor,

    pub fn init() @This() {
        var idt: @This() = undefined;

        // Set up exception handlers
        idt.setHandler(0, divideByZeroHandler);
        idt.setHandler(14, pageFaultHandler);
        // ... more handlers

        return idt;
    }

    pub fn setHandler(self: *@This(), vector: u8, handler: fn() callconv(.Interrupt) void) void {
        self.entries[vector] = InterruptDescriptor.init(handler);
    }

    pub fn load(self: *const @This()) void {
        const idtr = packed struct {
            limit: u16,
            base: u64,
        }{
            .limit = @sizeOf(@This()) - 1,
            .base = @intFromPtr(&self.entries),
        };

        asm volatile ("lidt (%[idtr])"
            :
            : [idtr] "r" (&idtr)
        );
    }
};

// Exception handlers with calling convention
export fn divideByZeroHandler() callconv(.Interrupt) void {
    Basics.println("Division by zero!", .{});
    @panic("CPU exception");
}

export fn pageFaultHandler() callconv(.Interrupt) void {
    // Read CR2 for fault address
    const fault_addr = asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> usize)
    );

    Basics.println("Page fault at 0x{x}", .{fault_addr});
    @panic("Page fault");
}
```

### 5. Bootloader Integration 🚀

**Why:** OS needs to boot from bare metal.

**What to implement:**
```zig
// Multiboot2 header
const multiboot = @import("multiboot");

// Boot entry point
export fn _start() callconv(.Naked) noreturn {
    // Set up stack
    asm volatile (
        \\mov $stack_top, %%esp
        \\mov $stack_top, %%ebp
    );

    // Call kernel main
    kernelMain();
}

// Kernel main
pub fn kernelMain() noreturn {
    // Initialize GDT
    gdt.init();

    // Initialize IDT
    var idt = IDT.init();
    idt.load();

    // Initialize memory management
    mem.init();

    // Initialize drivers
    drivers.init();

    // Start scheduler
    scheduler.start();

    // Halt
    hlt();
}

// Linker script control
pub const linker = struct {
    pub const kernel_start: usize = 0xFFFFFFFF80000000;
    pub const kernel_size: usize = 16 * 1024 * 1024; // 16MB

    // Sections with compile-time alignment
    pub const text align(4096) = struct {
        pub const start: usize = kernel_start;
    };

    pub const rodata align(4096) = struct {
        pub const start: usize = text.start + text.size;
    };

    pub const data align(4096) = struct {
        pub const start: usize = rodata.start + rodata.size;
    };
};
```

### 6. Page Table Management 📄

**Why:** Virtual memory is fundamental to modern OS.

**What to implement:**
```zig
// Page table entry
pub const PageTableEntry = packed struct(u64) {
    present: bool,
    writable: bool,
    user: bool,
    write_through: bool,
    cache_disable: bool,
    accessed: bool,
    dirty: bool,
    huge: bool,
    global: bool,
    available: u3,
    address: u40,
    reserved: u11,
    no_execute: bool,

    pub fn init(phys_addr: PhysicalAddress, flags: Flags) @This() {
        return .{
            .present = flags.present,
            .writable = flags.writable,
            .user = flags.user,
            .write_through = false,
            .cache_disable = false,
            .accessed = false,
            .dirty = false,
            .huge = flags.huge,
            .global = false,
            .available = 0,
            .address = @truncate(phys_addr >> 12),
            .reserved = 0,
            .no_execute = !flags.executable,
        };
    }

    pub fn getAddress(self: @This()) PhysicalAddress {
        return @as(u64, self.address) << 12;
    }
};

// Page table
pub const PageTable = struct {
    entries: [512]PageTableEntry align(4096),

    pub fn mapPage(
        self: *@This(),
        virt: VirtualAddress,
        phys: PhysicalAddress,
        flags: Flags,
    ) !void {
        const index = (virt >> 12) & 0x1FF;
        self.entries[index] = PageTableEntry.init(phys, flags);
    }

    pub fn unmapPage(self: *@This(), virt: VirtualAddress) void {
        const index = (virt >> 12) & 0x1FF;
        self.entries[index] = .{};
    }
};

// 4-level paging
pub const PageMap = struct {
    pml4: *PageTable,

    pub fn init(allocator: *PageAllocator) !@This() {
        const pml4_phys = try allocator.allocPage();
        const pml4: *PageTable = @ptrFromInt(pml4_phys);

        return .{ .pml4 = pml4 };
    }

    pub fn map(
        self: *@This(),
        virt: VirtualAddress,
        phys: PhysicalAddress,
        flags: Flags,
        allocator: *PageAllocator,
    ) !void {
        // Walk page tables and map
        const pml4_idx = (virt >> 39) & 0x1FF;
        const pdpt_idx = (virt >> 30) & 0x1FF;
        const pd_idx = (virt >> 21) & 0x1FF;
        const pt_idx = (virt >> 12) & 0x1FF;

        // Ensure tables exist at each level
        // ... implementation
    }
};
```

### 7. Atomic Operations & Lock-Free Structures 🔒

**Why:** Multi-core synchronization without locks.

**What to implement:**
```zig
// Atomic primitives
pub const Atomic = struct {
    pub fn compareAndSwap(
        comptime T: type,
        ptr: *T,
        expected: T,
        desired: T,
        comptime success_order: AtomicOrder,
        comptime failure_order: AtomicOrder,
    ) bool {
        return @cmpxchgStrong(T, ptr, expected, desired, success_order, failure_order) == null;
    }

    pub fn fetchAdd(comptime T: type, ptr: *T, value: T, comptime order: AtomicOrder) T {
        return @atomicRmw(T, ptr, .Add, value, order);
    }

    pub fn load(comptime T: type, ptr: *const T, comptime order: AtomicOrder) T {
        return @atomicLoad(T, ptr, order);
    }

    pub fn store(comptime T: type, ptr: *T, value: T, comptime order: AtomicOrder) void {
        @atomicStore(T, ptr, value, order);
    }
};

// Spinlock
pub const Spinlock = struct {
    locked: Atomic(bool) = false,

    pub fn lock(self: *@This()) void {
        while (true) {
            if (!Atomic.compareAndSwap(bool, &self.locked, false, true, .Acquire, .Monotonic)) {
                break;
            }
            // CPU pause instruction
            asm volatile ("pause");
        }
    }

    pub fn unlock(self: *@This()) void {
        Atomic.store(bool, &self.locked, false, .Release);
    }

    pub fn withLock(self: *@This(), comptime f: fn() void) void {
        self.lock();
        defer self.unlock();
        f();
    }
};

// Lock-free queue
pub fn LockFreeQueue(comptime T: type) type {
    return struct {
        const Node = struct {
            value: T,
            next: Atomic(?*Node),
        };

        head: Atomic(?*Node),
        tail: Atomic(?*Node),

        pub fn push(self: *@This(), value: T, allocator: Allocator) !void {
            const node = try allocator.create(Node);
            node.* = .{
                .value = value,
                .next = null,
            };

            while (true) {
                const tail = Atomic.load(?*Node, &self.tail, .Acquire);
                const next = Atomic.load(?*Node, &tail.?.next, .Acquire);

                if (next == null) {
                    if (Atomic.compareAndSwap(?*Node, &tail.?.next, null, node, .Release, .Acquire)) {
                        _ = Atomic.compareAndSwap(?*Node, &self.tail, tail, node, .Release, .Acquire);
                        return;
                    }
                } else {
                    _ = Atomic.compareAndSwap(?*Node, &self.tail, tail, next, .Release, .Acquire);
                }
            }
        }

        pub fn pop(self: *@This()) ?T {
            while (true) {
                const head = Atomic.load(?*Node, &self.head, .Acquire);
                const tail = Atomic.load(?*Node, &self.tail, .Acquire);
                const next = Atomic.load(?*Node, &head.?.next, .Acquire);

                if (head == tail) {
                    if (next == null) {
                        return null; // Queue is empty
                    }
                    _ = Atomic.compareAndSwap(?*Node, &self.tail, tail, next, .Release, .Acquire);
                } else {
                    const value = next.?.value;
                    if (Atomic.compareAndSwap(?*Node, &self.head, head, next, .Release, .Acquire)) {
                        return value;
                    }
                }
            }
        }
    };
}
```

---

## 🏗️ Implementation Phases

### Phase 1: Core Language Features (Weeks 1-4)
- [ ] Inline assembly support
- [ ] Volatile pointers and operations
- [ ] Packed structs with bitfield support
- [ ] Calling conventions (.Naked, .Interrupt, .C)
- [ ] @intFromPtr, @ptrFromInt type-safe conversions
- [ ] Compile-time size/alignment guarantees

### Phase 2: Memory Management (Weeks 5-8)
- [ ] Page allocator
- [ ] Bump allocator
- [ ] Slab allocator
- [ ] Buddy allocator
- [ ] Virtual memory management
- [ ] DMA support

### Phase 3: Hardware Access (Weeks 9-12)
- [ ] MMIO abstractions
- [ ] Port I/O (inb/outb)
- [ ] Interrupt handling
- [ ] Exception handling
- [ ] ACPI parsing
- [ ] PCI enumeration

### Phase 4: Concurrency Primitives (Weeks 13-16)
- [ ] Atomic operations
- [ ] Spinlocks
- [ ] RW locks
- [ ] Semaphores
- [ ] Lock-free data structures
- [ ] CPU feature detection

### Phase 5: System Components (Weeks 17-24)
- [ ] Scheduler
- [ ] System calls
- [ ] IPC mechanisms
- [ ] Device driver framework
- [ ] VFS abstraction
- [ ] Network stack basics

### Phase 6: Tooling & Documentation (Weeks 25-28)
- [ ] Cross-compilation
- [ ] Linker script generation
- [ ] Kernel debugger
- [ ] OS development guide
- [ ] Example kernel

---

## 🎯 Success Criteria

### 1. Can boot from bare metal
- ✅ Multiboot2 compliant
- ✅ Initializes GDT, IDT
- ✅ Sets up paging

### 2. Can manage memory
- ✅ Physical page allocation
- ✅ Virtual memory mapping
- ✅ Kernel heap allocation

### 3. Can handle interrupts
- ✅ Timer interrupts
- ✅ Keyboard interrupts
- ✅ Exception handling

### 4. Can run tasks
- ✅ Basic scheduler
- ✅ Task switching
- ✅ User/kernel separation

### 5. Can communicate
- ✅ System calls
- ✅ IPC mechanisms
- ✅ Network stack basics

---

## 📚 Inspiration & References

### Languages to Study
- **Zig** - Compile-time execution, simple memory model
- **Rust** - Memory safety, zero-cost abstractions
- **C** - Direct hardware access, simplicity
- **Ada/SPARK** - Formal verification

### OS Projects to Study
- **SerenityOS** - Modern C++ OS
- **Redox** - Rust OS
- **Haiku** - BeOS successor
- **Linux** - The standard
- **Zircon** - Fuchsia microkernel

### Key Principles
1. **Zero-cost abstractions** - No runtime overhead
2. **Compile-time safety** - Catch errors early
3. **Explicit control** - No hidden magic
4. **Type safety** - Prevent undefined behavior
5. **Great DX** - Make systems programming accessible

---

*Home Programming Language - OS Development Roadmap*
*Building the best systems programming language*
*Version 1.0.0*
