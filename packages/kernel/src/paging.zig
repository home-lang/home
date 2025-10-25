// Home Programming Language - Kernel Paging
// Type-safe page table management for virtual memory

const Basics = @import("basics");
const asm = @import("asm.zig");
const memory = @import("memory.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// Page Table Entry Flags
// ============================================================================

pub const PageFlags = packed struct(u64) {
    present: bool = false,           // Page is present in memory
    writable: bool = false,          // Page is writable
    user: bool = false,              // User mode accessible
    write_through: bool = false,     // Write-through caching
    cache_disable: bool = false,     // Cache disabled
    accessed: bool = false,          // Page has been accessed
    dirty: bool = false,             // Page has been written to
    huge: bool = false,              // Huge page (2MB/1GB)
    global: bool = false,            // Global page (not flushed on CR3 reload)
    available1: u3 = 0,              // Available for OS use
    address: u40 = 0,                // Physical address (bits 12-51)
    available2: u11 = 0,             // Available for OS use
    no_execute: bool = false,        // No execute

    /// Get physical address
    pub fn getAddress(self: PageFlags) u64 {
        return @as(u64, self.address) << 12;
    }

    /// Set physical address
    pub fn setAddress(self: *PageFlags, addr: u64) void {
        self.address = @truncate(addr >> 12);
    }

    /// Create a new page entry
    pub fn new(addr: u64, flags: struct {
        writable: bool = false,
        user: bool = false,
        write_through: bool = false,
        cache_disable: bool = false,
        huge: bool = false,
        global: bool = false,
        no_execute: bool = false,
    }) PageFlags {
        var entry = PageFlags{
            .present = true,
            .writable = flags.writable,
            .user = flags.user,
            .write_through = flags.write_through,
            .cache_disable = flags.cache_disable,
            .huge = flags.huge,
            .global = flags.global,
            .no_execute = flags.no_execute,
        };
        entry.setAddress(addr);
        return entry;
    }
};

comptime {
    if (@sizeOf(PageFlags) != 8) {
        @compileError("PageFlags must be 8 bytes");
    }
    if (@bitSizeOf(PageFlags) != 64) {
        @compileError("PageFlags must be 64 bits");
    }
}

// ============================================================================
// Page Table Structures
// ============================================================================

/// Page Table Entry (PTE) - 4KB pages
pub const PageTableEntry = PageFlags;

/// Page Directory Entry (PDE)
pub const PageDirectoryEntry = PageFlags;

/// Page Directory Pointer Table Entry (PDPTE)
pub const PageDirectoryPointerEntry = PageFlags;

/// Page Map Level 4 Entry (PML4E)
pub const PageMapLevel4Entry = PageFlags;

/// Generic page table with 512 entries
pub fn PageTable(comptime EntryType: type) type {
    return struct {
        const Self = @This();
        const NUM_ENTRIES = 512;

        entries: [NUM_ENTRIES]EntryType align(4096),

        pub fn init() Self {
            return .{
                .entries = [_]EntryType{Basics.mem.zeroes(EntryType)} ** NUM_ENTRIES,
            };
        }

        pub fn clear(self: *Self) void {
            self.entries = [_]EntryType{Basics.mem.zeroes(EntryType)} ** NUM_ENTRIES;
        }

        pub fn getEntry(self: *Self, index: usize) *EntryType {
            return &self.entries[index];
        }

        pub fn setEntry(self: *Self, index: usize, entry: EntryType) void {
            self.entries[index] = entry;
        }

        pub fn getPhysicalAddress(self: *const Self) u64 {
            return @intFromPtr(&self.entries);
        }
    };
}

// Concrete page table types
pub const PML4 = PageTable(PageMapLevel4Entry);
pub const PDPT = PageTable(PageDirectoryPointerEntry);
pub const PD = PageTable(PageDirectoryEntry);
pub const PT = PageTable(PageTableEntry);

comptime {
    if (@sizeOf(PML4) != 4096) {
        @compileError("PML4 must be 4096 bytes (one page)");
    }
    if (@sizeOf(PDPT) != 4096) {
        @compileError("PDPT must be 4096 bytes (one page)");
    }
    if (@sizeOf(PD) != 4096) {
        @compileError("PD must be 4096 bytes (one page)");
    }
    if (@sizeOf(PT) != 4096) {
        @compileError("PT must be 4096 bytes (one page)");
    }
}

// ============================================================================
// Virtual Address Decomposition
// ============================================================================

pub const VirtualAddress = packed struct(u64) {
    offset: u12,        // Page offset (bits 0-11)
    pt_index: u9,       // PT index (bits 12-20)
    pd_index: u9,       // PD index (bits 21-29)
    pdpt_index: u9,     // PDPT index (bits 30-38)
    pml4_index: u9,     // PML4 index (bits 39-47)
    sign_extend: u16,   // Sign extension (bits 48-63)

    pub fn fromU64(addr: u64) VirtualAddress {
        return @bitCast(addr);
    }

    pub fn toU64(self: VirtualAddress) u64 {
        return @bitCast(self);
    }

    pub fn new(pml4: u9, pdpt: u9, pd: u9, pt: u9, offset: u12) VirtualAddress {
        const sign_bit: u16 = if ((pml4 & 0x100) != 0) 0xFFFF else 0;
        return .{
            .offset = offset,
            .pt_index = pt,
            .pd_index = pd,
            .pdpt_index = pdpt,
            .pml4_index = pml4,
            .sign_extend = sign_bit,
        };
    }

    pub fn isCanonical(self: VirtualAddress) bool {
        const expected_sign: u16 = if ((self.pml4_index & 0x100) != 0) 0xFFFF else 0;
        return self.sign_extend == expected_sign;
    }

    pub fn alignDown(self: VirtualAddress) VirtualAddress {
        var aligned = self;
        aligned.offset = 0;
        return aligned;
    }

    pub fn alignUp(self: VirtualAddress) VirtualAddress {
        if (self.offset == 0) return self;
        var aligned = self;
        aligned.offset = 0;
        aligned.pt_index += 1;
        // Handle carry propagation
        if (aligned.pt_index == 0) {
            aligned.pd_index += 1;
            if (aligned.pd_index == 0) {
                aligned.pdpt_index += 1;
                if (aligned.pdpt_index == 0) {
                    aligned.pml4_index += 1;
                }
            }
        }
        return aligned;
    }
};

// ============================================================================
// Page Mapper
// ============================================================================

pub const PageMapper = struct {
    pml4: *PML4,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) !PageMapper {
        const pml4 = try allocator.create(PML4);
        pml4.* = PML4.init();
        return .{
            .pml4 = pml4,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PageMapper) void {
        // Clean up all page tables
        for (self.pml4.entries) |pml4e| {
            if (!pml4e.present) continue;

            const pdpt: *PDPT = @ptrFromInt(@as(usize, @intCast(pml4e.getAddress())));
            for (pdpt.entries) |pdpte| {
                if (!pdpte.present or pdpte.huge) continue;

                const pd: *PD = @ptrFromInt(@as(usize, @intCast(pdpte.getAddress())));
                for (pd.entries) |pde| {
                    if (!pde.present or pde.huge) continue;

                    const pt: *PT = @ptrFromInt(@as(usize, @intCast(pde.getAddress())));
                    self.allocator.destroy(pt);
                }
                self.allocator.destroy(pd);
            }
            self.allocator.destroy(pdpt);
        }
        self.allocator.destroy(self.pml4);
    }

    /// Map a virtual address to a physical address
    pub fn map(self: *PageMapper, virt: u64, phys: u64, flags: struct {
        writable: bool = false,
        user: bool = false,
        write_through: bool = false,
        cache_disable: bool = false,
        no_execute: bool = false,
    }) !void {
        const vaddr = VirtualAddress.fromU64(virt);

        if (!vaddr.isCanonical()) {
            return error.NonCanonicalAddress;
        }

        // Get or create PDPT
        const pdpt = try self.getOrCreateTable(
            PDPT,
            &self.pml4.entries[vaddr.pml4_index],
            flags.writable,
            flags.user,
        );

        // Get or create PD
        const pd = try self.getOrCreateTable(
            PD,
            &pdpt.entries[vaddr.pdpt_index],
            flags.writable,
            flags.user,
        );

        // Get or create PT
        const pt = try self.getOrCreateTable(
            PT,
            &pd.entries[vaddr.pd_index],
            flags.writable,
            flags.user,
        );

        // Set PT entry
        pt.entries[vaddr.pt_index] = PageFlags.new(phys, .{
            .writable = flags.writable,
            .user = flags.user,
            .write_through = flags.write_through,
            .cache_disable = flags.cache_disable,
            .no_execute = flags.no_execute,
        });

        // Invalidate TLB for this page
        asm.invlpg(virt);
    }

    /// Unmap a virtual address
    pub fn unmap(self: *PageMapper, virt: u64) !void {
        const vaddr = VirtualAddress.fromU64(virt);

        if (!vaddr.isCanonical()) {
            return error.NonCanonicalAddress;
        }

        const pml4e = self.pml4.entries[vaddr.pml4_index];
        if (!pml4e.present) return error.NotMapped;

        const pdpt: *PDPT = @ptrFromInt(@as(usize, @intCast(pml4e.getAddress())));
        const pdpte = pdpt.entries[vaddr.pdpt_index];
        if (!pdpte.present) return error.NotMapped;

        const pd: *PD = @ptrFromInt(@as(usize, @intCast(pdpte.getAddress())));
        const pde = pd.entries[vaddr.pd_index];
        if (!pde.present) return error.NotMapped;

        const pt: *PT = @ptrFromInt(@as(usize, @intCast(pde.getAddress())));
        pt.entries[vaddr.pt_index] = Basics.mem.zeroes(PageTableEntry);

        // Invalidate TLB entry
        asm.invlpg(virt);
    }

    /// Translate virtual address to physical address
    pub fn translate(self: *const PageMapper, virt: u64) !u64 {
        const vaddr = VirtualAddress.fromU64(virt);

        if (!vaddr.isCanonical()) {
            return error.NonCanonicalAddress;
        }

        const pml4e = self.pml4.entries[vaddr.pml4_index];
        if (!pml4e.present) return error.NotMapped;

        const pdpt: *PDPT = @ptrFromInt(@as(usize, @intCast(pml4e.getAddress())));
        const pdpte = pdpt.entries[vaddr.pdpt_index];
        if (!pdpte.present) return error.NotMapped;
        if (pdpte.huge) {
            // 1GB page
            return pdpte.getAddress() + (@as(u64, vaddr.pd_index) << 21) +
                   (@as(u64, vaddr.pt_index) << 12) + vaddr.offset;
        }

        const pd: *PD = @ptrFromInt(@as(usize, @intCast(pdpte.getAddress())));
        const pde = pd.entries[vaddr.pd_index];
        if (!pde.present) return error.NotMapped;
        if (pde.huge) {
            // 2MB page
            return pde.getAddress() + (@as(u64, vaddr.pt_index) << 12) + vaddr.offset;
        }

        const pt: *PT = @ptrFromInt(@as(usize, @intCast(pde.getAddress())));
        const pte = pt.entries[vaddr.pt_index];
        if (!pte.present) return error.NotMapped;

        // 4KB page
        return pte.getAddress() + vaddr.offset;
    }

    /// Get or create a page table
    fn getOrCreateTable(
        self: *PageMapper,
        comptime TableType: type,
        entry: *PageFlags,
        writable: bool,
        user: bool,
    ) !*TableType {
        if (entry.present) {
            return @ptrFromInt(@as(usize, @intCast(entry.getAddress())));
        }

        const table = try self.allocator.create(TableType);
        table.* = TableType.init();
        const table_phys = @intFromPtr(table);

        entry.* = PageFlags.new(table_phys, .{
            .writable = writable,
            .user = user,
        });

        return table;
    }

    /// Load this page table into CR3
    pub fn activate(self: *const PageMapper) void {
        const pml4_phys = self.pml4.getPhysicalAddress();
        asm.writeCr3(pml4_phys);
    }

    /// Map a range of pages
    pub fn mapRange(
        self: *PageMapper,
        virt_start: u64,
        phys_start: u64,
        size: u64,
        flags: struct {
            writable: bool = false,
            user: bool = false,
            write_through: bool = false,
            cache_disable: bool = false,
            no_execute: bool = false,
        },
    ) !void {
        const page_count = memory.pageCount(size);
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            const virt = virt_start + (i * memory.PAGE_SIZE);
            const phys = phys_start + (i * memory.PAGE_SIZE);
            try self.map(virt, phys, flags);
        }
    }

    /// Unmap a range of pages
    pub fn unmapRange(self: *PageMapper, virt_start: u64, size: u64) !void {
        const page_count = memory.pageCount(size);
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            const virt = virt_start + (i * memory.PAGE_SIZE);
            try self.unmap(virt);
        }
    }
};

// ============================================================================
// Identity Mapping Helper
// ============================================================================

pub fn createIdentityMap(allocator: Basics.Allocator, size: u64) !PageMapper {
    var mapper = try PageMapper.init(allocator);
    errdefer mapper.deinit();

    try mapper.mapRange(0, 0, size, .{
        .writable = true,
        .user = false,
    });

    return mapper;
}

// ============================================================================
// Kernel Space Mapping
// ============================================================================

pub const KERNEL_BASE: u64 = 0xFFFF_8000_0000_0000;
pub const USER_END: u64 = 0x0000_7FFF_FFFF_FFFF;

// ============================================================================
// TLB Shootdown for Multi-Core
// ============================================================================

/// TLB shootdown request for IPI
pub const TlbShootdownRequest = struct {
    address: u64,
    is_range: bool,
    size: u64,
    acknowledged: atomic.AtomicUsize,
    target_cpus: u64, // Bitmask of CPUs to invalidate

    pub fn init(address: u64, is_range: bool, size: u64, target_cpus: u64) TlbShootdownRequest {
        return .{
            .address = address,
            .is_range = is_range,
            .size = size,
            .acknowledged = atomic.AtomicUsize.init(0),
            .target_cpus = target_cpus,
        };
    }

    pub fn acknowledge(self: *TlbShootdownRequest) void {
        _ = self.acknowledged.fetchAdd(1, .Release);
    }

    pub fn waitForAcknowledgments(self: *TlbShootdownRequest, expected: usize) void {
        while (self.acknowledged.load(.Acquire) < expected) {
            asm.pause();
        }
    }
};

/// Global TLB shootdown request (used by IPI handler)
pub var tlb_shootdown_request: ?*TlbShootdownRequest = null;

/// Perform TLB shootdown on all CPUs
pub fn tlbShootdownAll(address: u64) void {
    // Invalidate on local CPU
    asm.invlpg(address);

    // TODO: Send IPI to all other CPUs
    // This requires the APIC/SMP subsystem to be available
    // For now, we only invalidate locally
    // When SMP is active, this should:
    // 1. Create a TlbShootdownRequest
    // 2. Send IPI to all other CPUs
    // 3. Wait for acknowledgments
}

/// Perform TLB shootdown for a range on all CPUs
pub fn tlbShootdownRange(address: u64, size: u64) void {
    // Invalidate range on local CPU
    const page_count = memory.pageCount(size);
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const virt = address + (i * memory.PAGE_SIZE);
        asm.invlpg(virt);
    }

    // TODO: Send IPI to all other CPUs
}

/// TLB shootdown IPI handler (called by interrupt handler)
pub fn tlbShootdownIpiHandler() void {
    if (tlb_shootdown_request) |req| {
        if (req.is_range) {
            const page_count = memory.pageCount(req.size);
            var i: usize = 0;
            while (i < page_count) : (i += 1) {
                const virt = req.address + (i * memory.PAGE_SIZE);
                asm.invlpg(virt);
            }
        } else {
            asm.invlpg(req.address);
        }
        req.acknowledge();
    }
}

/// Flush entire TLB (reload CR3)
pub fn flushTlb() void {
    const cr3 = asm.readCr3();
    asm.writeCr3(cr3);
}

// ============================================================================
// Kernel Space Mapping
// ============================================================================

pub fn mapKernelSpace(
    mapper: *PageMapper,
    phys_start: u64,
    size: u64,
) !void {
    try mapper.mapRange(KERNEL_BASE, phys_start, size, .{
        .writable = true,
        .user = false,
        .no_execute = false,
    });
}

pub fn isKernelAddress(virt: u64) bool {
    return virt >= KERNEL_BASE;
}

pub fn isUserAddress(virt: u64) bool {
    return virt <= USER_END;
}

// ============================================================================
// TLB Management
// ============================================================================

pub const TLB = struct {
    /// Flush entire TLB by reloading CR3
    pub fn flushAll() void {
        const cr3 = asm.readCr3();
        asm.writeCr3(cr3);
    }

    /// Flush single TLB entry
    pub fn flush(virt: u64) void {
        asm.invlpg(virt);
    }

    /// Flush range of TLB entries
    pub fn flushRange(virt_start: u64, size: u64) void {
        const page_count = memory.pageCount(size);
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            const virt = virt_start + (i * memory.PAGE_SIZE);
            asm.invlpg(virt);
        }
    }
};

// ============================================================================
// Copy-on-Write (COW) Support
// ============================================================================

/// Page reference counter for COW
pub const PageRefCount = struct {
    /// Reference count map (physical page -> refcount)
    /// Using available1 bits in PageFlags for COW marker
    const COW_BIT: u3 = 0x1; // Bit 0 of available1 marks COW pages

    /// Global reference count table
    /// In production, this should be a proper hash map
    /// For now, we use a simplified array-based approach
    var ref_counts: [4096]atomic.AtomicU32 = [_]atomic.AtomicU32{atomic.AtomicU32.init(0)} ** 4096;
    var ref_counts_initialized: bool = false;

    pub fn init() void {
        if (!ref_counts_initialized) {
            for (&ref_counts) |*count| {
                count.* = atomic.AtomicU32.init(0);
            }
            ref_counts_initialized = true;
        }
    }

    /// Get index for physical address
    fn getIndex(phys_addr: u64) usize {
        // Simple hash: use page number modulo array size
        const page_num = phys_addr >> 12;
        return @intCast(page_num % ref_counts.len);
    }

    /// Increment reference count
    pub fn inc(phys_addr: u64) void {
        const index = getIndex(phys_addr);
        _ = ref_counts[index].fetchAdd(1, .Monotonic);
    }

    /// Decrement reference count, return new count
    pub fn dec(phys_addr: u64) u32 {
        const index = getIndex(phys_addr);
        return ref_counts[index].fetchSub(1, .Monotonic) - 1;
    }

    /// Get reference count
    pub fn get(phys_addr: u64) u32 {
        const index = getIndex(phys_addr);
        return ref_counts[index].load(.Monotonic);
    }

    /// Mark page entry as COW
    pub fn markCow(entry: *PageFlags) void {
        entry.available1 |= COW_BIT;
    }

    /// Check if page entry is COW
    pub fn isCow(entry: PageFlags) bool {
        return (entry.available1 & COW_BIT) != 0;
    }

    /// Clear COW marker
    pub fn clearCow(entry: *PageFlags) void {
        entry.available1 &= ~COW_BIT;
    }
};

/// Copy-on-Write page fault handler
pub const CowHandler = struct {
    allocator: Basics.Allocator,
    mapper: *PageMapper,

    pub fn init(allocator: Basics.Allocator, mapper: *PageMapper) CowHandler {
        PageRefCount.init();
        return .{
            .allocator = allocator,
            .mapper = mapper,
        };
    }

    /// Handle COW page fault
    /// Returns true if fault was handled, false if it's a real fault
    pub fn handleFault(self: *CowHandler, faulting_addr: u64, was_write: bool) !bool {
        if (!was_write) {
            return false; // Not a write fault, not COW
        }

        // Look up the page table entry
        const entry = try self.mapper.getEntry(faulting_addr);

        // Check if this is a COW page
        if (!PageRefCount.isCow(entry.*)) {
            return false; // Not a COW page, real fault
        }

        const phys_addr = entry.getAddress();
        const ref_count = PageRefCount.get(phys_addr);

        if (ref_count <= 1) {
            // We're the only owner, just mark writable
            entry.writable = true;
            PageRefCount.clearCow(entry);

            // Flush TLB for this page
            asm.invlpg(faulting_addr);

            return true; // Fault handled
        }

        // Multiple references, need to copy
        // Allocate new physical page
        const new_page = try self.allocator.alloc(u8, memory.PAGE_SIZE);
        const new_phys = @intFromPtr(new_page.ptr);

        // Copy old page content
        const old_virt: [*]const u8 = @ptrFromInt(@as(usize, @intCast(faulting_addr & ~@as(u64, 0xFFF))));
        @memcpy(new_page, old_virt[0..memory.PAGE_SIZE]);

        // Decrement old page refcount
        _ = PageRefCount.dec(phys_addr);

        // Update page table entry
        entry.setAddress(new_phys);
        entry.writable = true;
        PageRefCount.clearCow(entry);

        // Increment refcount for new page
        PageRefCount.inc(new_phys);

        // Flush TLB
        asm.invlpg(faulting_addr);

        return true; // Fault handled
    }
};

/// Mark all pages in address space as COW for fork
pub fn markCowForFork(parent_mapper: *PageMapper, child_mapper: *PageMapper) !void {
    // Walk parent's page tables and mark pages as COW
    for (parent_mapper.pml4.entries, 0..) |pml4e, pml4_idx| {
        if (!pml4e.present) continue;

        const pdpt: *PDPT = @ptrFromInt(@as(usize, @intCast(pml4e.getAddress())));
        for (pdpt.entries, 0..) |pdpte, pdpt_idx| {
            if (!pdpte.present or pdpte.huge) continue;

            const pd: *PD = @ptrFromInt(@as(usize, @intCast(pdpte.getAddress())));
            for (pd.entries, 0..) |pde, pd_idx| {
                if (!pde.present or pde.huge) continue;

                const pt: *PT = @ptrFromInt(@as(usize, @intCast(pde.getAddress())));
                for (pt.entries, 0..) |*pte, pt_idx| {
                    if (!pte.present) continue;

                    // Mark as COW if writable
                    if (pte.writable) {
                        // Mark parent page as read-only COW
                        pte.writable = false;
                        PageRefCount.markCow(pte);

                        // Increment reference count
                        PageRefCount.inc(pte.getAddress());

                        // Copy same entry to child (read-only, COW)
                        const child_entry = try child_mapper.getEntryMut(
                            VirtualAddress.new(
                                @truncate(pml4_idx),
                                @truncate(pdpt_idx),
                                @truncate(pd_idx),
                                @truncate(pt_idx),
                                0,
                            ).toU64(),
                        );
                        child_entry.* = pte.*;

                        // Flush TLB for parent (child has new CR3 so no flush needed)
                        const vaddr = VirtualAddress.new(
                            @truncate(pml4_idx),
                            @truncate(pdpt_idx),
                            @truncate(pd_idx),
                            @truncate(pt_idx),
                            0,
                        );
                        asm.invlpg(vaddr.toU64());
                    }
                }
            }
        }
    }
}

/// Get mutable entry (for COW handler)
fn getEntryMut(self: *PageMapper, virt: u64) !*PageFlags {
    const vaddr = VirtualAddress.fromU64(virt);

    // Get or create PML4 entry
    var pml4e = self.pml4.getEntry(vaddr.pml4_index);
    if (!pml4e.present) {
        return error.PageNotMapped;
    }

    // Get PDPT
    const pdpt: *PDPT = @ptrFromInt(@as(usize, @intCast(pml4e.getAddress())));
    var pdpte = pdpt.getEntry(vaddr.pdpt_index);
    if (!pdpte.present) {
        return error.PageNotMapped;
    }

    // Get PD
    const pd: *PD = @ptrFromInt(@as(usize, @intCast(pdpte.getAddress())));
    var pde = pd.getEntry(vaddr.pd_index);
    if (!pde.present) {
        return error.PageNotMapped;
    }

    // Get PT
    const pt: *PT = @ptrFromInt(@as(usize, @intCast(pde.getAddress())));
    return pt.getEntry(vaddr.pt_index);
}

/// Get read-only entry for lookup
fn getEntry(self: *PageMapper, virt: u64) !*const PageFlags {
    return try self.getEntryMut(virt);
}

// ============================================================================
// Tests
// ============================================================================

test "page flags size" {
    try Basics.testing.expectEqual(@as(usize, 8), @sizeOf(PageFlags));
    try Basics.testing.expectEqual(@as(usize, 64), @bitSizeOf(PageFlags));
}

test "page flags address" {
    var flags = PageFlags.new(0x1000, .{});
    try Basics.testing.expectEqual(@as(u64, 0x1000), flags.getAddress());

    flags.setAddress(0x2000);
    try Basics.testing.expectEqual(@as(u64, 0x2000), flags.getAddress());
}

test "page table size" {
    try Basics.testing.expectEqual(@as(usize, 4096), @sizeOf(PML4));
    try Basics.testing.expectEqual(@as(usize, 4096), @sizeOf(PDPT));
    try Basics.testing.expectEqual(@as(usize, 4096), @sizeOf(PD));
    try Basics.testing.expectEqual(@as(usize, 4096), @sizeOf(PT));
}

test "virtual address decomposition" {
    const vaddr = VirtualAddress.new(0, 1, 2, 3, 0x456);
    try Basics.testing.expectEqual(@as(u9, 0), vaddr.pml4_index);
    try Basics.testing.expectEqual(@as(u9, 1), vaddr.pdpt_index);
    try Basics.testing.expectEqual(@as(u9, 2), vaddr.pd_index);
    try Basics.testing.expectEqual(@as(u9, 3), vaddr.pt_index);
    try Basics.testing.expectEqual(@as(u12, 0x456), vaddr.offset);
}

test "virtual address canonical" {
    const vaddr1 = VirtualAddress.fromU64(0x0000_7FFF_FFFF_FFFF);
    try Basics.testing.expect(vaddr1.isCanonical());

    const vaddr2 = VirtualAddress.fromU64(0xFFFF_8000_0000_0000);
    try Basics.testing.expect(vaddr2.isCanonical());

    const vaddr3 = VirtualAddress.fromU64(0x0000_8000_0000_0000);
    try Basics.testing.expect(!vaddr3.isCanonical());
}

test "kernel/user address spaces" {
    try Basics.testing.expect(isKernelAddress(0xFFFF_8000_0000_0000));
    try Basics.testing.expect(!isKernelAddress(0x0000_7FFF_FFFF_FFFF));
    try Basics.testing.expect(isUserAddress(0x0000_7FFF_FFFF_FFFF));
    try Basics.testing.expect(!isUserAddress(0xFFFF_8000_0000_0000));
}
