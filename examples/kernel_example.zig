// Home Programming Language - Kernel Example
// Demonstrates OS development primitives

const Basics = @import("basics");
const Kernel = @import("kernel");

pub fn main() !void {
    Basics.println("=== Home Kernel Example ===", .{});
    Basics.println("", .{});

    // ========================================================================
    // 1. CPU Feature Detection
    // ========================================================================
    Basics.println("1. CPU Features:", .{});
    const features = Kernel.asm.CpuFeatures.detect();
    Basics.println("  - FPU: {}", .{features.fpu});
    Basics.println("  - SSE: {}", .{features.sse});
    Basics.println("  - SSE2: {}", .{features.sse2});
    Basics.println("  - AVX: {}", .{features.avx});
    Basics.println("  - AVX2: {}", .{features.avx2});
    Basics.println("", .{});

    // ========================================================================
    // 2. Memory Management
    // ========================================================================
    Basics.println("2. Memory Management:", .{});

    // Bump allocator for early boot
    var bump = Kernel.memory.BumpAllocator.init(0x100000, 0x10000);
    const page1 = try bump.allocPage();
    Basics.println("  - Allocated page at: 0x{x}", .{page1});
    Basics.println("  - Page aligned: {}", .{Kernel.memory.isAligned(page1)});

    // Page alignment utilities
    const unaligned: usize = 0x1234;
    Basics.println("  - Align down 0x{x} -> 0x{x}", .{ unaligned, Kernel.memory.alignDown(unaligned) });
    Basics.println("  - Align up 0x{x} -> 0x{x}", .{ unaligned, Kernel.memory.alignUp(unaligned) });
    Basics.println("", .{});

    // ========================================================================
    // 3. Atomic Operations
    // ========================================================================
    Basics.println("3. Atomic Operations:", .{});

    var counter = Kernel.AtomicU64.init(0);
    _ = counter.inc(.SeqCst);
    _ = counter.inc(.SeqCst);
    Basics.println("  - Counter value: {}", .{counter.load(.SeqCst)});

    const old = counter.swap(100, .SeqCst);
    Basics.println("  - Swapped {} -> {}", .{ old, counter.load(.SeqCst) });

    // Compare and exchange
    const result = counter.compareExchange(100, 200, .SeqCst, .SeqCst);
    if (result == null) {
        Basics.println("  - CAS succeeded: {}", .{counter.load(.SeqCst)});
    }
    Basics.println("", .{});

    // ========================================================================
    // 4. Synchronization Primitives
    // ========================================================================
    Basics.println("4. Synchronization:", .{});

    // Spinlock
    var spinlock = Kernel.Spinlock.init();
    spinlock.acquire();
    Basics.println("  - Spinlock acquired", .{});
    spinlock.release();
    Basics.println("  - Spinlock released", .{});

    // Mutex (ticket-based)
    var mutex = Kernel.Mutex.init();
    mutex.acquire();
    Basics.println("  - Mutex acquired", .{});
    mutex.release();
    Basics.println("  - Mutex released", .{});

    // Semaphore
    var sem = Kernel.Semaphore.init(3);
    Basics.println("  - Semaphore initial count: {}", .{sem.getCount()});
    sem.wait();
    Basics.println("  - After wait: {}", .{sem.getCount()});
    sem.signal();
    Basics.println("  - After signal: {}", .{sem.getCount()});

    // Once (execute code exactly once)
    var once = Kernel.Once.init();
    var call_count: u32 = 0;

    const increment = struct {
        fn func(c: *u32) void {
            c.* += 1;
        }
    }.func;

    once.call(increment, .{&call_count});
    once.call(increment, .{&call_count});
    once.call(increment, .{&call_count});
    Basics.println("  - Once called {} times (expected 1)", .{call_count});
    Basics.println("", .{});

    // ========================================================================
    // 5. Page Tables and Virtual Memory
    // ========================================================================
    Basics.println("5. Virtual Memory:", .{});

    // Virtual address decomposition
    const vaddr = Kernel.paging.VirtualAddress.fromU64(0x0000_1234_5678_9ABC);
    Basics.println("  - Virtual address: 0x{x}", .{vaddr.toU64()});
    Basics.println("    PML4 index: {}", .{vaddr.pml4_index});
    Basics.println("    PDPT index: {}", .{vaddr.pdpt_index});
    Basics.println("    PD index: {}", .{vaddr.pd_index});
    Basics.println("    PT index: {}", .{vaddr.pt_index});
    Basics.println("    Offset: 0x{x}", .{vaddr.offset});
    Basics.println("    Canonical: {}", .{vaddr.isCanonical()});

    // Kernel/user address space
    const kernel_addr: u64 = 0xFFFF_8000_0000_0000;
    const user_addr: u64 = 0x0000_7FFF_FFFF_FFFF;
    Basics.println("  - 0x{x} is kernel: {}", .{ kernel_addr, Kernel.paging.isKernelAddress(kernel_addr) });
    Basics.println("  - 0x{x} is user: {}", .{ user_addr, Kernel.paging.isUserAddress(user_addr) });
    Basics.println("", .{});

    // ========================================================================
    // 6. Memory-Mapped I/O
    // ========================================================================
    Basics.println("6. Memory-Mapped I/O:", .{});

    var mmio_value: u32 = 0x12345678;
    const mmio = Kernel.MMIO(u32){ .address = @intFromPtr(&mmio_value) };

    Basics.println("  - MMIO read: 0x{x}", .{mmio.read()});
    mmio.write(0xABCDEF00);
    Basics.println("  - MMIO write: 0x{x}", .{mmio_value});
    mmio.setBit(0);
    Basics.println("  - MMIO set bit 0: 0x{x}", .{mmio_value});
    Basics.println("", .{});

    // ========================================================================
    // 7. Lock-Free Data Structures
    // ========================================================================
    Basics.println("7. Lock-Free Data Structures:", .{});

    // Atomic flag
    var flag = Kernel.AtomicFlag.init(false);
    const was_set = flag.testAndSet(.SeqCst);
    Basics.println("  - Flag was set: {}", .{was_set});
    Basics.println("  - Flag is now: {}", .{flag.test(.SeqCst)});
    flag.clear(.SeqCst);
    Basics.println("  - Flag after clear: {}", .{flag.test(.SeqCst)});

    // Reference counting
    var refcount = Kernel.AtomicRefCount.init(1);
    Basics.println("  - Initial refcount: {}", .{refcount.get()});
    _ = refcount.inc();
    Basics.println("  - After inc: {}", .{refcount.get()});
    const is_zero = refcount.dec();
    Basics.println("  - After dec (is zero: {}): {}", .{ is_zero, refcount.get() });
    Basics.println("", .{});

    // ========================================================================
    // 8. Reader-Writer Lock
    // ========================================================================
    Basics.println("8. Reader-Writer Lock:", .{});

    var rwlock = Kernel.RwSpinlock.init();

    // Multiple readers can acquire
    rwlock.acquireRead();
    Basics.println("  - Reader 1 acquired", .{});
    const reader2_ok = rwlock.tryAcquireRead();
    Basics.println("  - Reader 2 try acquire: {}", .{reader2_ok});
    if (reader2_ok) rwlock.releaseRead();
    rwlock.releaseRead();

    // Writer has exclusive access
    rwlock.acquireWrite();
    Basics.println("  - Writer acquired", .{});
    const reader3_ok = rwlock.tryAcquireRead();
    Basics.println("  - Reader 3 try acquire (should fail): {}", .{reader3_ok});
    rwlock.releaseWrite();
    Basics.println("", .{});

    // ========================================================================
    // 9. Memory Barriers
    // ========================================================================
    Basics.println("9. Memory Ordering:", .{});
    Basics.println("  - Full barrier (mfence)", .{});
    Kernel.atomic.Barrier.full();
    Basics.println("  - Load barrier (lfence)", .{});
    Kernel.atomic.Barrier.load();
    Basics.println("  - Store barrier (sfence)", .{});
    Kernel.atomic.Barrier.store();
    Basics.println("", .{});

    // ========================================================================
    // Summary
    // ========================================================================
    Basics.println("=== Kernel Features Demonstrated ===", .{});
    Basics.println("✓ CPU feature detection (CPUID)", .{});
    Basics.println("✓ Memory management (allocators, paging)", .{});
    Basics.println("✓ Atomic operations (CAS, fetch-add, etc.)", .{});
    Basics.println("✓ Synchronization (spinlock, mutex, semaphore)", .{});
    Basics.println("✓ Virtual memory (page tables, address spaces)", .{});
    Basics.println("✓ Memory-mapped I/O", .{});
    Basics.println("✓ Lock-free data structures", .{});
    Basics.println("✓ Memory ordering and barriers", .{});
    Basics.println("", .{});
    Basics.println("Home is ready for OS development!", .{});
}
