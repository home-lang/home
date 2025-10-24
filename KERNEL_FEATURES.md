# Home Kernel Package - OS Development Features

> **Complete OS development primitives for the Home programming language**

---

## 🎯 Overview

The `kernel` package provides comprehensive, type-safe primitives for operating system development in Home. All features are zero-cost abstractions with compile-time safety guarantees.

### Package Contents

```zig
const Kernel = @import("kernel");

Kernel.asm           // Assembly operations and CPU control
Kernel.memory        // Memory management primitives
Kernel.interrupts    // Interrupt and exception handling
Kernel.paging        // Page tables and virtual memory
Kernel.atomic        // Atomic operations and lock-free structures
Kernel.sync          // Synchronization primitives
```

---

## 🔧 Core Features

### 1. Inline Assembly Support (`Kernel.asm`)

Complete x86_64 assembly operations with type safety:

#### I/O Port Operations
```zig
// Read/write bytes
const value = Kernel.asm.inb(0x60);  // Read from keyboard
Kernel.asm.outb(0x3F8, 'A');         // Write to serial port

// Read/write words (16-bit)
const data = Kernel.asm.inw(0x1F0);  // Read from disk
Kernel.asm.outw(0x1F0, 0x1234);

// Read/write dwords (32-bit)
const dword = Kernel.asm.inl(0xCF8);
Kernel.asm.outl(0xCF8, 0x80000000);
```

#### CPU Control
```zig
Kernel.asm.hlt();         // Halt CPU
Kernel.asm.pause();       // Pause (for spinloops)
Kernel.asm.cli();         // Disable interrupts
Kernel.asm.sti();         // Enable interrupts

// Memory barriers
Kernel.asm.mfence();      // Full barrier
Kernel.asm.lfence();      // Load barrier
Kernel.asm.sfence();      // Store barrier
```

#### CPU Feature Detection
```zig
const features = Kernel.asm.CpuFeatures.detect();

if (features.sse) {
    // Use SSE instructions
}
if (features.avx2) {
    // Use AVX2 instructions
}

// All features available:
features.fpu, features.tsc, features.msr, features.apic
features.sse, features.sse2, features.sse3, features.avx, features.avx2
features.syscall, features.nx
```

#### Control Registers
```zig
// CR0 - Control flags
const cr0 = Kernel.asm.readCr0();
Kernel.asm.writeCr0(cr0);

// CR2 - Page fault address
const fault_addr = Kernel.asm.readCr2();

// CR3 - Page table base
const pml4_addr = Kernel.asm.readCr3();
Kernel.asm.writeCr3(new_pml4);

// CR4 - Extended features
var cr4 = Kernel.asm.readCr4();
cr4 |= (1 << 5);  // Enable PAE
Kernel.asm.writeCr4(cr4);
```

#### MSR Operations
```zig
const IA32_EFER: u32 = 0xC0000080;

// Read MSR
const efer = Kernel.asm.rdmsr(IA32_EFER);

// Write MSR
Kernel.asm.wrmsr(IA32_EFER, efer | (1 << 11));  // Enable NX
```

---

### 2. Memory Management (`Kernel.memory`)

#### Memory-Mapped I/O (Type-Safe)
```zig
// Create MMIO register
const uart_data = Kernel.MMIO(u8){ .address = 0x3F8 };

// Read/write
const data = uart_data.read();
uart_data.write('H');

// Bit manipulation
uart_data.setBit(0);
uart_data.clearBit(7);

// Modify with function
uart_data.modify(struct {
    fn transform(val: u8) u8 {
        return val | 0x80;
    }
}.transform);
```

#### Hardware Register Abstraction
```zig
const UartData = Kernel.memory.Register.define(.{
    .Type = u8,
    .address = 0x3F8,
    .bits = 8,
    .read_only = false,
});

var uart = UartData.init(0x3F8);
uart.write('A');
const ch = uart.read();
```

#### Page Alignment Utilities
```zig
const addr: usize = 0x1234;

const aligned_down = Kernel.memory.alignDown(addr);  // 0x1000
const aligned_up = Kernel.memory.alignUp(addr);      // 0x2000
const is_aligned = Kernel.memory.isAligned(addr);    // false
const pages = Kernel.memory.pageCount(0x5000);       // 5 pages
```

#### Bump Allocator (Early Boot)
```zig
var bump = Kernel.memory.BumpAllocator.init(0x100000, 0x10000);

// Allocate memory
const mem = try bump.alloc(1024, 8);

// Allocate pages
const page = try bump.allocPage();
const pages = try bump.allocPages(10);

// Reset allocator
bump.reset(0x100000);
```

#### Slab Allocator (Fixed-Size Objects)
```zig
const Task = struct { id: u64, next: u64 };

var slab = Kernel.memory.SlabAllocator(Task).init();

// Add memory to slab
var memory: [4096]u8 align(@alignOf(Task)) = undefined;
slab.addMemory(&memory);

// Allocate objects
const task1 = try slab.alloc();
task1.id = 1;

const task2 = try slab.alloc();

// Free objects
slab.free(task1);
```

#### Buddy Allocator (Variable-Size)
```zig
var buddy = Kernel.memory.BuddyAllocator.init(0x200000, 0x100000);

// Allocate variable sizes
const small = try buddy.alloc(1024);
const large = try buddy.alloc(16384);

// Free memory
buddy.free(small);
buddy.free(large);
```

---

### 3. Interrupt Handling (`Kernel.interrupts`)

#### IDT Management
```zig
// Create and initialize IDT
var idt = Kernel.Idt.init();

// Set exception handlers
idt.setException(.DivideByZero, divideByZeroHandler);
idt.setException(.Breakpoint, breakpointHandler);
idt.setExceptionWithError(.PageFault, pageFaultHandler);

// Set IRQ handlers
idt.setIrq(1, keyboardHandler);  // Keyboard IRQ

// Load IDT
idt.load();
```

#### Exception Handlers
```zig
// Handler without error code
fn divideByZeroHandler(frame: *Kernel.InterruptFrame) callconv(.Interrupt) void {
    Kernel.panic("Divide by zero!");
}

// Handler with error code
fn pageFaultHandler(frame: *Kernel.interrupts.InterruptFrameWithError) callconv(.Interrupt) void {
    const error_code: Kernel.interrupts.PageFaultError = @bitCast(frame.error_code);
    const fault_addr = Kernel.asm.readCr2();

    if (error_code.write) {
        // Write violation
    }
    if (error_code.user) {
        // User mode fault
    }

    Kernel.panic("Page fault!");
}
```

#### PIC Management
```zig
// Remap PIC to avoid conflicts with CPU exceptions
Kernel.interrupts.PIC.remap(32, 40);

// Enable/disable IRQs
Kernel.interrupts.PIC.clearMask(1);  // Enable keyboard
Kernel.interrupts.PIC.setMask(1);    // Disable keyboard

// Send EOI (End of Interrupt)
Kernel.interrupts.PIC.sendEoi(1);

// Disable PIC (for APIC)
Kernel.interrupts.PIC.disable();
```

#### Interrupt Manager
```zig
var manager = Kernel.InterruptManager.init();

// Install default handlers
manager.installDefaultHandlers();

// Register IRQ handlers
manager.registerIrq(1, keyboardIrq);
manager.registerIrq(3, serialIrq);

// Activate IDT
manager.activate();

// Unregister handler
manager.unregisterIrq(1);
```

---

### 4. Page Tables and Virtual Memory (`Kernel.paging`)

#### Page Flags
```zig
var flags = Kernel.PageFlags.new(0x1000, .{
    .writable = true,
    .user = false,
    .no_execute = true,
});

const phys_addr = flags.getAddress();  // 0x1000
flags.setAddress(0x2000);
```

#### Page Mapper
```zig
var mapper = try Kernel.PageMapper.init(allocator);
defer mapper.deinit();

// Map single page
try mapper.map(
    0x400000,  // Virtual address
    0x200000,  // Physical address
    .{
        .writable = true,
        .user = true,
    },
);

// Map range of pages
try mapper.mapRange(
    0x0,       // Virtual start
    0x0,       // Physical start
    0x100000,  // Size
    .{ .writable = true },
);

// Translate virtual to physical
const phys = try mapper.translate(0x400123);

// Unmap pages
try mapper.unmap(0x400000);
try mapper.unmapRange(0x0, 0x100000);

// Activate page tables
mapper.activate();
```

#### Virtual Address Decomposition
```zig
const vaddr = Kernel.paging.VirtualAddress.fromU64(0x0000_1234_5678_9ABC);

// Extract indices
const pml4_idx = vaddr.pml4_index;   // 9 bits
const pdpt_idx = vaddr.pdpt_index;   // 9 bits
const pd_idx = vaddr.pd_index;       // 9 bits
const pt_idx = vaddr.pt_index;       // 9 bits
const offset = vaddr.offset;         // 12 bits

// Check canonical form
if (!vaddr.isCanonical()) {
    // Non-canonical address
}

// Alignment
const aligned_down = vaddr.alignDown();
const aligned_up = vaddr.alignUp();
```

#### Kernel/User Address Spaces
```zig
const KERNEL_BASE: u64 = 0xFFFF_8000_0000_0000;
const USER_END: u64 = 0x0000_7FFF_FFFF_FFFF;

if (Kernel.paging.isKernelAddress(addr)) {
    // Kernel space
}
if (Kernel.paging.isUserAddress(addr)) {
    // User space
}

// Map kernel space
try Kernel.paging.mapKernelSpace(&mapper, phys_start, size);

// Create identity map
var id_mapper = try Kernel.paging.createIdentityMap(allocator, 0x100000);
```

#### TLB Management
```zig
// Flush entire TLB
Kernel.paging.TLB.flushAll();

// Flush single entry
Kernel.paging.TLB.flush(0x400000);

// Flush range
Kernel.paging.TLB.flushRange(0x400000, 0x10000);
```

---

### 5. Atomic Operations (`Kernel.atomic`)

#### Atomic Types
```zig
var counter = Kernel.AtomicU64.init(0);

// Load/Store
const val = counter.load(.SeqCst);
counter.store(100, .Release);

// Swap
const old = counter.swap(200, .AcqRel);

// Compare and exchange
const result = counter.compareExchange(200, 300, .SeqCst, .SeqCst);
if (result == null) {
    // Success
} else {
    // Failed, result contains actual value
}

// Fetch and modify
_ = counter.fetchAdd(10, .AcqRel);
_ = counter.fetchSub(5, .Release);
_ = counter.fetchAnd(0xFF, .SeqCst);
_ = counter.fetchOr(0x100, .SeqCst);
_ = counter.fetchXor(0x55, .SeqCst);

// Increment/decrement
const old_val = counter.inc(.SeqCst);
const old_val2 = counter.dec(.SeqCst);
```

#### Memory Ordering
```zig
// Available orderings
.Relaxed   // No ordering constraints
.Acquire   // Load-acquire
.Release   // Store-release
.AcqRel    // Both acquire and release
.SeqCst    // Sequential consistency

// Memory barriers
Kernel.atomic.Barrier.full();      // mfence
Kernel.atomic.Barrier.load();      // lfence
Kernel.atomic.Barrier.store();     // sfence
Kernel.atomic.Barrier.compiler();  // Compiler barrier only
Kernel.atomic.Barrier.acquire();   // Load + compiler
Kernel.atomic.Barrier.release();   // Compiler + store
```

#### Atomic Pointer
```zig
var atomic_ptr = Kernel.atomic.AtomicPtr(Task).init(initial_ptr);

const ptr = atomic_ptr.load(.Acquire);
atomic_ptr.store(new_ptr, .Release);

const old_ptr = atomic_ptr.swap(another_ptr, .AcqRel);

if (atomic_ptr.compareExchange(expected, desired, .SeqCst, .SeqCst) == null) {
    // Success
}
```

#### Atomic Flag
```zig
var flag = Kernel.AtomicFlag.init(false);

// Test and set
const was_set = flag.testAndSet(.Acquire);

// Test without modifying
if (flag.test(.Relaxed)) {
    // Flag is set
}

// Clear
flag.clear(.Release);
```

#### Reference Counting
```zig
var refcount = Kernel.AtomicRefCount.init(1);

// Increment
const new_count = refcount.inc();  // Returns new count

// Decrement (returns true if reached zero)
if (refcount.dec()) {
    // Last reference, can free
}

// Get current count
const count = refcount.get();
```

#### Lock-Free Stack
```zig
const Stack = Kernel.atomic.AtomicStack(u64);

var stack = Stack.init();

var node = Stack.Node{ .data = 42, .next = null };
stack.push(&node);

if (stack.pop()) |popped| {
    const value = popped.data;
}
```

#### Lock-Free Queue (MPSC)
```zig
const Queue = Kernel.atomic.AtomicQueue(u64);

var stub = Queue.Node{ .data = 0, .next = undefined };
var queue = Queue.init(&stub);

var node = Queue.Node{ .data = 42, .next = undefined };
queue.enqueue(&node);

if (queue.dequeue()) |dequeued| {
    const value = dequeued.data;
}
```

#### Atomic Bitset
```zig
var bitset = Kernel.atomic.AtomicBitset(256).init();

// Set/clear bits
bitset.set(5, .SeqCst);
bitset.clear(10, .Release);

// Test bits
if (bitset.test(5, .Acquire)) {
    // Bit 5 is set
}

// Test and set
const was_set = bitset.testAndSet(7, .AcqRel);
```

#### Sequence Lock
```zig
var seqlock = Kernel.atomic.SeqLock.init();

// Write side
const seq = seqlock.beginWrite();
// ... modify data ...
seqlock.endWrite();

// Read side
var data: MyStruct = undefined;
while (true) {
    const seq = seqlock.beginRead();
    // ... read data ...
    if (!seqlock.retryRead(seq)) {
        break;  // Consistent read
    }
}
```

---

### 6. Synchronization Primitives (`Kernel.sync`)

#### Spinlock
```zig
var lock = Kernel.Spinlock.init();

// Acquire/release
lock.acquire();
defer lock.release();

// Try acquire
if (lock.tryAcquire()) {
    defer lock.release();
    // Got lock
}

// With lock helper
lock.withLock(myFunction, .{ arg1, arg2 });
```

#### IRQ Spinlock (Disables Interrupts)
```zig
var lock = Kernel.IrqSpinlock.init();

// Automatically saves and restores interrupt state
lock.acquire();
defer lock.release();

if (lock.tryAcquire()) {
    defer lock.release();
    // Critical section with interrupts disabled
}
```

#### Reader-Writer Spinlock
```zig
var rwlock = Kernel.RwSpinlock.init();

// Multiple readers
rwlock.acquireRead();
defer rwlock.releaseRead();

// Single writer
rwlock.acquireWrite();
defer rwlock.releaseWrite();

// Try acquire
if (rwlock.tryAcquireRead()) {
    defer rwlock.releaseRead();
}

// With lock helpers
rwlock.withReadLock(readFunction, .{});
rwlock.withWriteLock(writeFunction, .{});
```

#### Mutex (Ticket-Based, Fair)
```zig
var mutex = Kernel.Mutex.init();

mutex.acquire();
defer mutex.release();

if (mutex.tryAcquire()) {
    defer mutex.release();
    // Critical section
}

mutex.withLock(criticalFunction, .{});
```

#### Semaphore
```zig
var sem = Kernel.Semaphore.init(5);  // Max 5 concurrent

// Wait (decrement)
sem.wait();

// Try wait without blocking
if (sem.tryWait()) {
    // Got semaphore
}

// Signal (increment)
sem.signal();

// Get count
const available = sem.getCount();
```

#### Barrier (Synchronization Point)
```zig
var barrier = Kernel.sync.SyncBarrier.init(4);  // 4 threads

// All threads wait here
barrier.wait();
// All threads proceed together
```

#### Once (Execute Exactly Once)
```zig
var once = Kernel.Once.init();

fn initialize() void {
    // Run expensive initialization
}

// Called multiple times, but runs once
once.call(initialize, .{});
once.call(initialize, .{});  // Blocks until first call completes

if (once.isCalled()) {
    // Already initialized
}
```

#### Lazy Initialization
```zig
var lazy_config = Kernel.sync.Lazy(Config).init();

fn createConfig() Config {
    return Config{ /* ... */ };
}

// Gets or initializes on first call
const config = lazy_config.get(createConfig);
```

#### Wait Queue
```zig
var wq = Kernel.sync.WaitQueue.init();

// Wait for state change
wq.wait(expected_state);

// Wake all waiters
wq.wake();

// Set specific state
wq.setState(new_state);

const current = wq.getState();
```

---

## 🏗️ Complete Kernel Initialization Example

```zig
const Basics = @import("basics");
const Kernel = @import("kernel");

pub fn kmain() !void {
    // 1. Initialize allocator
    var gpa = Basics.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 2. Initialize kernel
    var kernel = try Kernel.Kernel.init(.{
        .phys_mem_start = 0x100000,
        .phys_mem_size = 0x1000000,  // 16MB
        .serial_console = true,
        .enable_interrupts = true,
        .remap_pic = true,
    }, allocator);
    defer kernel.deinit();

    // 3. Activate paging
    kernel.activatePaging();

    // 4. Enable interrupts
    kernel.enableInterrupts();

    // 5. OS is running!
    Kernel.println("Kernel initialized!", .{});

    // Halt
    Kernel.halt();
}
```

---

## 📊 Feature Matrix

| Feature | Status | Notes |
|---------|--------|-------|
| Inline Assembly | ✅ Complete | AT&T syntax, all x86_64 ops |
| I/O Ports | ✅ Complete | inb/outb/inw/outw/inl/outl |
| CPUID | ✅ Complete | Full feature detection |
| Control Registers | ✅ Complete | CR0-CR4 access |
| MSR Operations | ✅ Complete | rdmsr/wrmsr |
| MMIO | ✅ Complete | Type-safe, compile-time checked |
| Page Tables | ✅ Complete | 4-level paging, canonical addresses |
| Virtual Memory | ✅ Complete | Mapper, TLB, kernel/user spaces |
| Allocators | ✅ Complete | Bump, Slab, Buddy |
| Interrupts | ✅ Complete | IDT, exceptions, IRQs, PIC |
| Atomic Operations | ✅ Complete | All orderings, CAS, fetch-ops |
| Lock-Free Structures | ✅ Complete | Stack, queue, bitset, refcount |
| Spinlocks | ✅ Complete | Basic, IRQ-safe, RW |
| Mutexes | ✅ Complete | Ticket-based fairness |
| Semaphores | ✅ Complete | Counting semaphore |
| Barriers | ✅ Complete | Thread synchronization |
| Memory Barriers | ✅ Complete | mfence, lfence, sfence |

---

## 🎯 Zero-Cost Guarantees

All kernel primitives are **zero-cost abstractions**:

- **No runtime overhead**: All type safety is compile-time
- **Inline assembly**: Direct CPU instructions, no wrappers
- **Compile-time validation**: Invalid operations caught at compile time
- **No allocations**: Stack-only or caller-provided memory
- **Lock-free where possible**: CAS loops instead of locks

---

## 🧪 Testing

All modules include comprehensive tests:

```bash
zig test packages/kernel/src/asm.zig
zig test packages/kernel/src/memory.zig
zig test packages/kernel/src/interrupts.zig
zig test packages/kernel/src/paging.zig
zig test packages/kernel/src/atomic.zig
zig test packages/kernel/src/sync.zig
```

---

## 📚 Examples

See `/examples/kernel_example.zig` for a complete demonstration of all features.

---

## 🏠 Home Philosophy

The kernel package embodies Home's core principles:

- **Type Safety**: Compile-time validation prevents runtime errors
- **Zero Cost**: No runtime overhead for abstractions
- **Friendly API**: Clear, readable code even at the lowest level
- **Compile-Time Power**: Use `comptime` for maximum performance

**Making OS development feel like home!** 🏠

---

*Home Programming Language - Kernel Package v0.1.0*
*Date: 2025-10-24*
