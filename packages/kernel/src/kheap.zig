// Home Programming Language - Kernel Heap
// General-purpose kernel memory allocator with slab integration

const Basics = @import("basics");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// ============================================================================
// Kernel Heap
// ============================================================================

pub const KernelHeap = struct {
    slab_allocator: ?*memory.SlabAllocator,
    buddy_allocator: ?*memory.BuddyAllocator,
    lock: sync.Spinlock,
    total_allocated: atomic.AtomicUsize,
    total_freed: atomic.AtomicUsize,

    pub fn init() KernelHeap {
        return .{
            .slab_allocator = null,
            .buddy_allocator = null,
            .lock = sync.Spinlock.init(),
            .total_allocated = atomic.AtomicUsize.init(0),
            .total_freed = atomic.AtomicUsize.init(0),
        };
    }

    pub fn alloc(self: *KernelHeap, size: usize, alignment: usize) ![]u8 {
        self.lock.acquire();
        defer self.lock.release();

        // Use slab for small allocations
        if (size <= 4096 and self.slab_allocator != null) {
            const ptr = try self.slab_allocator.?.allocate(size);
            _ = self.total_allocated.fetchAdd(size, .Monotonic);
            return ptr[0..size];
        }

        // Use buddy for larger allocations
        if (self.buddy_allocator) |buddy| {
            const ptr = try buddy.allocate(size, alignment);
            _ = self.total_allocated.fetchAdd(size, .Monotonic);
            return ptr[0..size];
        }

        return error.OutOfMemory;
    }

    pub fn free(self: *KernelHeap, ptr: []u8) void {
        self.lock.acquire();
        defer self.lock.release();

        _ = self.total_freed.fetchAdd(ptr.len, .Monotonic);

        // Determine which allocator owns this pointer based on address range
        // Slab allocator typically handles small allocations (<= 4KB)
        // Buddy allocator handles larger allocations
        const ptr_addr = @intFromPtr(ptr.ptr);

        if (self.slab_allocator) |slab| {
            // Check if pointer is within slab-managed memory
            // Slab uses small fixed-size blocks, typically for objects <= 4KB
            if (ptr.len <= 4096) {
                slab.free(ptr);
                return;
            }
        }

        if (self.buddy_allocator) |buddy| {
            // Larger allocations go to buddy allocator
            buddy.free(ptr_addr, ptr.len);
        }
    }

    pub fn getStats(self: *const KernelHeap) HeapStats {
        return .{
            .allocated = self.total_allocated.load(.Monotonic),
            .freed = self.total_freed.load(.Monotonic),
        };
    }
};

pub const HeapStats = struct {
    allocated: usize,
    freed: usize,

    pub fn inUse(self: HeapStats) usize {
        return self.allocated - self.freed;
    }
};

var kernel_heap: ?KernelHeap = null;

pub fn init() void {
    kernel_heap = KernelHeap.init();
}

pub fn alloc(size: usize) ![]u8 {
    if (kernel_heap) |*heap| {
        return heap.alloc(size, 8);
    }
    return error.HeapNotInitialized;
}

pub fn free(ptr: []u8) void {
    if (kernel_heap) |*heap| {
        heap.free(ptr);
    }
}
