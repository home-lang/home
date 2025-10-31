// IOMMU Page Table Management
// Multi-level page tables for DMA address translation

const std = @import("std");

/// Page table level
pub const PageLevel = enum(u3) {
    level_1 = 1, // 4KB pages
    level_2 = 2, // 2MB pages
    level_3 = 3, // 1GB pages
    level_4 = 4, // 512GB (top level)
};

/// Page size for each level
pub fn pageSizeForLevel(level: PageLevel) usize {
    return switch (level) {
        .level_1 => 4 * 1024, // 4KB
        .level_2 => 2 * 1024 * 1024, // 2MB
        .level_3 => 1024 * 1024 * 1024, // 1GB
        .level_4 => 512 * 1024 * 1024 * 1024, // 512GB
    };
}

/// Page table entry flags
pub const PTEFlags = packed struct {
    present: bool, // Page is present
    read: bool, // Read permission
    write: bool, // Write permission
    execute: bool, // Execute permission (if supported)
    user: bool, // User mode access
    write_through: bool, // Write-through caching
    cache_disable: bool, // Disable caching
    accessed: bool, // Has been accessed
    dirty: bool, // Has been written to
    page_size: bool, // Large page (for non-leaf entries)
    global: bool, // Global page
    reserved: u5 = 0,

    pub fn readOnly() PTEFlags {
        return .{
            .present = true,
            .read = true,
            .write = false,
            .execute = false,
            .user = false,
            .write_through = false,
            .cache_disable = false,
            .accessed = false,
            .dirty = false,
            .page_size = false,
            .global = false,
        };
    }

    pub fn readWrite() PTEFlags {
        return .{
            .present = true,
            .read = true,
            .write = true,
            .execute = false,
            .user = false,
            .write_through = false,
            .cache_disable = false,
            .accessed = false,
            .dirty = false,
            .page_size = false,
            .global = false,
        };
    }
};

/// Page table entry
pub const PageTableEntry = struct {
    flags: PTEFlags,
    physical_addr: u64, // Physical address (page-aligned)

    pub fn init(paddr: u64, flags: PTEFlags) PageTableEntry {
        return .{
            .flags = flags,
            .physical_addr = paddr & 0xFFFFFFFF_FFFFF000, // Mask to page boundary
        };
    }

    pub fn isPresent(self: PageTableEntry) bool {
        return self.flags.present;
    }

    pub fn isWritable(self: PageTableEntry) bool {
        return self.flags.write;
    }

    pub fn getPhysicalAddr(self: PageTableEntry) u64 {
        return self.physical_addr;
    }
};

/// Page table (512 entries)
pub const PageTable = struct {
    entries: [512]PageTableEntry,
    level: PageLevel,

    pub fn init(level: PageLevel) PageTable {
        var table: PageTable = undefined;
        table.level = level;

        // Initialize all entries as not present
        for (&table.entries) |*entry| {
            entry.* = PageTableEntry{
                .flags = .{
                    .present = false,
                    .read = false,
                    .write = false,
                    .execute = false,
                    .user = false,
                    .write_through = false,
                    .cache_disable = false,
                    .accessed = false,
                    .dirty = false,
                    .page_size = false,
                    .global = false,
                },
                .physical_addr = 0,
            };
        }

        return table;
    }

    pub fn getEntry(self: *PageTable, index: u9) *PageTableEntry {
        return &self.entries[index];
    }

    pub fn setEntry(self: *PageTable, index: u9, entry: PageTableEntry) void {
        self.entries[index] = entry;
    }

    pub fn getPresentCount(self: *const PageTable) usize {
        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.isPresent()) count += 1;
        }
        return count;
    }
};

/// Multi-level page table walker
pub const PageTableWalker = struct {
    root_table: *PageTable,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !PageTableWalker {
        const root = try allocator.create(PageTable);
        root.* = PageTable.init(.level_4);

        return .{
            .root_table = root,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PageTableWalker) void {
        // In production, would recursively free all page tables
        self.allocator.destroy(self.root_table);
    }

    pub fn map(
        self: *PageTableWalker,
        virtual_addr: u64,
        physical_addr: u64,
        flags: PTEFlags,
    ) !void {
        _ = self;
        _ = virtual_addr;
        _ = physical_addr;
        _ = flags;

        // In production, would:
        // 1. Walk the page table hierarchy
        // 2. Allocate intermediate tables as needed
        // 3. Set the final PTE
        // 4. Flush TLBs
    }

    pub fn unmap(self: *PageTableWalker, virtual_addr: u64) !void {
        _ = self;
        _ = virtual_addr;

        // In production, would:
        // 1. Walk to the PTE
        // 2. Clear the present bit
        // 3. Free physical page if needed
        // 4. Flush TLBs
    }

    pub fn translate(self: *const PageTableWalker, virtual_addr: u64) ?u64 {
        _ = self;
        _ = virtual_addr;

        // In production, would walk page tables to translate address
        return null;
    }
};

/// TLB (Translation Lookaside Buffer) invalidation
pub const TLBInvalidation = struct {
    pub const InvalidationType = enum {
        global, // Invalidate all entries
        domain, // Invalidate all entries for a domain
        page, // Invalidate single page
        device, // Invalidate for specific device
    };

    pub fn invalidate(invalidation_type: InvalidationType, domain_id: ?u16, addr: ?u64) void {
        _ = invalidation_type;
        _ = domain_id;
        _ = addr;

        // In production, would write to IOMMU registers to flush TLB:
        // - Global: Flush entire IOTLB
        // - Domain: Flush IOTLB entries for domain
        // - Page: Flush specific IOVA
        // - Device: Flush device TLB (if supported)
    }
};

/// Address translation helper
pub const AddressTranslation = struct {
    pub fn extractPageOffset(addr: u64) u12 {
        return @truncate(addr & 0xFFF);
    }

    pub fn extractLevel1Index(addr: u64) u9 {
        return @truncate((addr >> 12) & 0x1FF);
    }

    pub fn extractLevel2Index(addr: u64) u9 {
        return @truncate((addr >> 21) & 0x1FF);
    }

    pub fn extractLevel3Index(addr: u64) u9 {
        return @truncate((addr >> 30) & 0x1FF);
    }

    pub fn extractLevel4Index(addr: u64) u9 {
        return @truncate((addr >> 39) & 0x1FF);
    }

    pub fn isPageAligned(addr: u64, level: PageLevel) bool {
        const page_size = pageSizeForLevel(level);
        return (addr & (page_size - 1)) == 0;
    }

    pub fn alignDown(addr: u64, level: PageLevel) u64 {
        const page_size = pageSizeForLevel(level);
        return addr & ~(page_size - 1);
    }

    pub fn alignUp(addr: u64, level: PageLevel) u64 {
        const page_size = pageSizeForLevel(level);
        return (addr + page_size - 1) & ~(page_size - 1);
    }
};

test "page size calculation" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 4096), pageSizeForLevel(.level_1));
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024), pageSizeForLevel(.level_2));
    try testing.expectEqual(@as(usize, 1024 * 1024 * 1024), pageSizeForLevel(.level_3));
}

test "page table entry" {
    const testing = std.testing;

    const flags = PTEFlags.readWrite();
    const entry = PageTableEntry.init(0x123000, flags);

    try testing.expect(entry.isPresent());
    try testing.expect(entry.isWritable());
    try testing.expectEqual(@as(u64, 0x123000), entry.getPhysicalAddr());
}

test "page table initialization" {
    const testing = std.testing;

    const table = PageTable.init(.level_1);

    try testing.expectEqual(@as(usize, 0), table.getPresentCount());
    try testing.expectEqual(PageLevel.level_1, table.level);
}

test "page table manipulation" {
    const testing = std.testing;

    var table = PageTable.init(.level_1);

    const flags = PTEFlags.readOnly();
    const entry = PageTableEntry.init(0x1000, flags);

    table.setEntry(0, entry);

    const retrieved = table.getEntry(0);
    try testing.expect(retrieved.isPresent());
    try testing.expect(!retrieved.isWritable());
    try testing.expectEqual(@as(u64, 0x1000), retrieved.getPhysicalAddr());
}

test "address extraction" {
    const testing = std.testing;

    const addr: u64 = 0x123456789ABC;

    const offset = AddressTranslation.extractPageOffset(addr);
    const l1_idx = AddressTranslation.extractLevel1Index(addr);
    const l2_idx = AddressTranslation.extractLevel2Index(addr);
    const l3_idx = AddressTranslation.extractLevel3Index(addr);
    const l4_idx = AddressTranslation.extractLevel4Index(addr);

    try testing.expectEqual(@as(u12, 0xABC), offset);
    try testing.expectEqual(@as(u9, 0x189), l1_idx);
    try testing.expectEqual(@as(u9, 0x02B), l2_idx);
    try testing.expectEqual(@as(u9, 0x068), l3_idx);
    try testing.expectEqual(@as(u9, 0x023), l4_idx);
}

test "page alignment" {
    const testing = std.testing;

    try testing.expect(AddressTranslation.isPageAligned(0x1000, .level_1));
    try testing.expect(!AddressTranslation.isPageAligned(0x1001, .level_1));

    try testing.expectEqual(@as(u64, 0x1000), AddressTranslation.alignDown(0x1234, .level_1));
    try testing.expectEqual(@as(u64, 0x2000), AddressTranslation.alignUp(0x1234, .level_1));
}

test "page table walker" {
    const testing = std.testing;

    var walker = try PageTableWalker.init(testing.allocator);
    defer walker.deinit();

    // Basic initialization test
    try testing.expectEqual(@as(usize, 0), walker.root_table.getPresentCount());
}
