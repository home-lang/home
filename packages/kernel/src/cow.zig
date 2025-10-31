// Home Programming Language - Copy-on-Write (COW) Implementation
// Efficient memory sharing with copy-on-write for fork()

const Basics = @import("basics");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const process = @import("process.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// Physical Page Reference Counting
// ============================================================================

/// Maximum number of physical pages we track (16GB / 4KB)
const MAX_PHYSICAL_PAGES = (16 * 1024 * 1024 * 1024) / memory.PAGE_SIZE;

/// Reference count for each physical page
pub const PageRefCount = struct {
    /// Array of reference counts (one per physical page)
    refcounts: []atomic.AtomicU32,
    /// Lock for page frame allocation
    lock: @import("sync.zig").Spinlock,
    /// Base physical address
    base_addr: u64,
    /// Number of pages tracked
    num_pages: usize,

    /// Initialize page reference counting
    pub fn init(allocator: Basics.Allocator, base: u64, num_pages: usize) !*PageRefCount {
        const self = try allocator.create(PageRefCount);
        errdefer allocator.destroy(self);

        const refcounts = try allocator.alloc(atomic.AtomicU32, num_pages);
        errdefer allocator.free(refcounts);

        // Initialize all refcounts to 0
        for (refcounts) |*rc| {
            rc.* = atomic.AtomicU32.init(0);
        }

        self.* = .{
            .refcounts = refcounts,
            .lock = @import("sync.zig").Spinlock.init(),
            .base_addr = base,
            .num_pages = num_pages,
        };

        return self;
    }

    /// Deinitialize and free resources
    pub fn deinit(self: *PageRefCount, allocator: Basics.Allocator) void {
        allocator.free(self.refcounts);
        allocator.destroy(self);
    }

    /// Get page index from physical address
    fn getPageIndex(self: *PageRefCount, phys_addr: u64) !usize {
        if (phys_addr < self.base_addr) {
            return error.InvalidPhysicalAddress;
        }

        const offset = phys_addr - self.base_addr;
        const index = offset / memory.PAGE_SIZE;

        if (index >= self.num_pages) {
            return error.PhysicalAddressOutOfRange;
        }

        return index;
    }

    /// Increment reference count for a physical page
    pub fn acquire(self: *PageRefCount, phys_addr: u64) !u32 {
        const index = try self.getPageIndex(phys_addr);
        return self.refcounts[index].fetchAdd(1, .Monotonic);
    }

    /// Decrement reference count, returns true if page should be freed
    pub fn release(self: *PageRefCount, phys_addr: u64) !bool {
        const index = try self.getPageIndex(phys_addr);
        const old_count = self.refcounts[index].fetchSub(1, .Release);

        if (old_count == 0) {
            // Underflow - this is a bug!
            return error.RefCountUnderflow;
        }

        return old_count == 1; // Was 1, now 0 - page should be freed
    }

    /// Get current reference count
    pub fn getRefCount(self: *PageRefCount, phys_addr: u64) !u32 {
        const index = try self.getPageIndex(phys_addr);
        return self.refcounts[index].load(.Monotonic);
    }

    /// Set reference count (for initialization)
    pub fn setRefCount(self: *PageRefCount, phys_addr: u64, count: u32) !void {
        const index = try self.getPageIndex(phys_addr);
        self.refcounts[index].store(count, .Monotonic);
    }
};

/// Global page reference counter
var global_page_refcount: ?*PageRefCount = null;

pub fn initPageRefCount(refcount: *PageRefCount) void {
    global_page_refcount = refcount;
}

// ============================================================================
// COW Page Flags
// ============================================================================

/// COW bit position in page flags (using available bits)
pub const COW_BIT: u3 = 0; // First available bit

/// Check if page is marked as COW
pub fn isCowPage(flags: paging.PageFlags) bool {
    return (flags.available1 & (1 << COW_BIT)) != 0;
}

/// Mark page as COW
pub fn markCowPage(flags: *paging.PageFlags) void {
    flags.available1 |= (1 << COW_BIT);
    flags.writable = false; // COW pages must be read-only
}

/// Clear COW bit
pub fn clearCowPage(flags: *paging.PageFlags) void {
    flags.available1 &= ~(@as(u3, 1) << COW_BIT);
}

// ============================================================================
// COW Operations
// ============================================================================

/// Mark all writable pages in a page table as COW
pub fn markAddressSpaceCow(page_mapper: *paging.PageMapper, vma_list: ?*process.Vma) !void {
    var vma = vma_list;
    while (vma) |v| {
        // Only mark writable pages as COW
        if (v.flags.write) {
            try markVmaCow(page_mapper, v);
        }
        vma = v.next;
    }
}

/// Mark all pages in a VMA as COW
fn markVmaCow(page_mapper: *paging.PageMapper, vma: *process.Vma) !void {
    var addr = vma.start;
    while (addr < vma.end) : (addr += memory.PAGE_SIZE) {
        // Get current page flags
        const flags = page_mapper.getPageFlags(addr) catch {
            // Page not mapped yet, skip
            addr += memory.PAGE_SIZE;
            continue;
        };

        if (!flags.present) {
            continue;
        }

        // Increment reference count
        const phys_addr = flags.getAddress();
        if (global_page_refcount) |refcount| {
            _ = refcount.acquire(phys_addr) catch continue;
        }

        // Mark as COW and read-only
        var new_flags = flags;
        markCowPage(&new_flags);

        // Update page table entry
        try page_mapper.updatePageFlags(addr, new_flags);
    }
}

/// Copy page contents from source to destination
fn copyPageContents(src_phys: u64, dst_phys: u64) void {
    const src_ptr: [*]const u8 = @ptrFromInt(src_phys);
    const dst_ptr: [*]u8 = @ptrFromInt(dst_phys);

    @memcpy(dst_ptr[0..memory.PAGE_SIZE], src_ptr[0..memory.PAGE_SIZE]);
}

// ============================================================================
// COW Page Fault Handler
// ============================================================================

pub const CowFaultHandler = struct {
    /// Handle a COW page fault
    /// Returns true if fault was handled, false if it's a real protection violation
    pub fn handleFault(
        page_mapper: *paging.PageMapper,
        virt_addr: u64,
        is_write: bool,
    ) !bool {
        if (!is_write) {
            // Not a write fault, can't be COW
            return false;
        }

        // Get page flags
        const old_flags = try page_mapper.getPageFlags(virt_addr);

        if (!old_flags.present) {
            // Page not present - not a COW fault
            return false;
        }

        if (!isCowPage(old_flags)) {
            // Not marked as COW - real protection violation
            return false;
        }

        // This is a COW fault - handle it
        const old_phys = old_flags.getAddress();

        // Check reference count
        const refcount = global_page_refcount orelse return error.NoPageRefCount;
        const ref_count = try refcount.getRefCount(old_phys);

        if (ref_count == 1) {
            // We're the only user - just make it writable
            var new_flags = old_flags;
            new_flags.writable = true;
            clearCowPage(&new_flags);

            try page_mapper.updatePageFlags(virt_addr, new_flags);

            // Decrement refcount to 0
            _ = try refcount.release(old_phys);

            return true;
        }

        // Multiple users - need to copy the page
        const new_phys = try allocatePhysicalPage();
        errdefer freePhysicalPage(new_phys);

        // Copy page contents
        copyPageContents(old_phys, new_phys);

        // Create new page flags (writable, not COW)
        var new_flags = old_flags;
        new_flags.writable = true;
        clearCowPage(&new_flags);
        new_flags.setAddress(new_phys);

        // Update page table
        try page_mapper.updatePageFlags(virt_addr, new_flags);

        // Decrement refcount on old page
        const should_free = try refcount.release(old_phys);
        if (should_free) {
            freePhysicalPage(old_phys);
        }

        // Increment refcount on new page (to 1)
        try refcount.setRefCount(new_phys, 1);

        return true;
    }
};

// ============================================================================
// Helper Functions for Page Allocation
// ============================================================================

var global_page_allocator: ?*memory.PageAllocator = null;

pub fn initPageAllocator(allocator: *memory.PageAllocator) void {
    global_page_allocator = allocator;
}

fn allocatePhysicalPage() !u64 {
    if (global_page_allocator) |alloc| {
        return try alloc.allocPage();
    }
    return error.NoPageAllocator;
}

fn freePhysicalPage(addr: u64) void {
    if (global_page_allocator) |alloc| {
        alloc.freePage(addr);
    }
}

// ============================================================================
// COW Fork Implementation
// ============================================================================

pub const CowFork = struct {
    /// Prepare parent and child for COW sharing
    pub fn setupCowFork(
        parent: *process.Process,
        child: *process.Process,
    ) !void {
        // Mark all parent's writable pages as COW
        try markAddressSpaceCow(
            &parent.address_space.page_mapper,
            parent.address_space.vma_list,
        );

        // Child shares the same physical pages (COW)
        // The page tables are copied, but point to same physical pages
        // with increased reference counts

        // Copy page table structure (but share physical pages)
        try copyPageTablesWithCow(
            &parent.address_space.page_mapper,
            &child.address_space.page_mapper,
            parent.address_space.vma_list,
        );
    }

    /// Copy page tables while sharing physical pages
    fn copyPageTablesWithCow(
        src_mapper: *paging.PageMapper,
        dst_mapper: *paging.PageMapper,
        vma_list: ?*process.Vma,
    ) !void {
        var vma = vma_list;
        while (vma) |v| {
            var addr = v.start;
            while (addr < v.end) : (addr += memory.PAGE_SIZE) {
                const flags = src_mapper.getPageFlags(addr) catch continue;

                if (!flags.present) {
                    continue;
                }

                // Copy the page table entry to child
                try dst_mapper.updatePageFlags(addr, flags);

                // Reference count already incremented in markAddressSpaceCow
            }
            vma = v.next;
        }
    }
};

// ============================================================================
// COW Statistics
// ============================================================================

pub const CowStats = struct {
    /// Number of COW faults handled
    cow_faults: atomic.AtomicU64,
    /// Number of pages copied
    pages_copied: atomic.AtomicU64,
    /// Number of times we just made page writable (sole owner)
    pages_made_writable: atomic.AtomicU64,
    /// Number of COW pages currently active
    active_cow_pages: atomic.AtomicU64,

    pub fn init() CowStats {
        return .{
            .cow_faults = atomic.AtomicU64.init(0),
            .pages_copied = atomic.AtomicU64.init(0),
            .pages_made_writable = atomic.AtomicU64.init(0),
            .active_cow_pages = atomic.AtomicU64.init(0),
        };
    }

    pub fn recordCowFault(self: *CowStats) void {
        _ = self.cow_faults.fetchAdd(1, .Monotonic);
    }

    pub fn recordPageCopied(self: *CowStats) void {
        _ = self.pages_copied.fetchAdd(1, .Monotonic);
        _ = self.active_cow_pages.fetchSub(1, .Monotonic);
    }

    pub fn recordPageMadeWritable(self: *CowStats) void {
        _ = self.pages_made_writable.fetchAdd(1, .Monotonic);
        _ = self.active_cow_pages.fetchSub(1, .Monotonic);
    }

    pub fn recordCowPageCreated(self: *CowStats) void {
        _ = self.active_cow_pages.fetchAdd(1, .Monotonic);
    }
};

var global_cow_stats = CowStats.init();

pub fn getCowStats() CowStats {
    return CowStats{
        .cow_faults = atomic.AtomicU64.init(global_cow_stats.cow_faults.load(.Monotonic)),
        .pages_copied = atomic.AtomicU64.init(global_cow_stats.pages_copied.load(.Monotonic)),
        .pages_made_writable = atomic.AtomicU64.init(global_cow_stats.pages_made_writable.load(.Monotonic)),
        .active_cow_pages = atomic.AtomicU64.init(global_cow_stats.active_cow_pages.load(.Monotonic)),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "page reference counting" {
    const testing = Basics.testing;

    const base_addr: u64 = 0x100000;
    const num_pages: usize = 10;

    const refcount = try PageRefCount.init(testing.allocator, base_addr, num_pages);
    defer refcount.deinit(testing.allocator);

    const page_addr = base_addr + (2 * memory.PAGE_SIZE);

    // Initial refcount should be 0
    try testing.expectEqual(@as(u32, 0), try refcount.getRefCount(page_addr));

    // Acquire twice
    _ = try refcount.acquire(page_addr);
    _ = try refcount.acquire(page_addr);
    try testing.expectEqual(@as(u32, 2), try refcount.getRefCount(page_addr));

    // Release once - should not be freed
    const should_free1 = try refcount.release(page_addr);
    try testing.expect(!should_free1);
    try testing.expectEqual(@as(u32, 1), try refcount.getRefCount(page_addr));

    // Release again - should be freed
    const should_free2 = try refcount.release(page_addr);
    try testing.expect(should_free2);
    try testing.expectEqual(@as(u32, 0), try refcount.getRefCount(page_addr));
}

test "COW page flags" {
    const testing = Basics.testing;

    var flags = paging.PageFlags.new(0x100000, .{
        .writable = true,
        .user = true,
    });

    try testing.expect(!isCowPage(flags));
    try testing.expect(flags.writable);

    markCowPage(&flags);

    try testing.expect(isCowPage(flags));
    try testing.expect(!flags.writable); // Should be read-only now

    clearCowPage(&flags);

    try testing.expect(!isCowPage(flags));
}

test "COW statistics" {
    var stats = CowStats.init();

    stats.recordCowFault();
    stats.recordCowFault();
    stats.recordPageCopied();

    const cow_faults = stats.cow_faults.load(.Monotonic);
    const pages_copied = stats.pages_copied.load(.Monotonic);

    try Basics.testing.expectEqual(@as(u64, 2), cow_faults);
    try Basics.testing.expectEqual(@as(u64, 1), pages_copied);
}
