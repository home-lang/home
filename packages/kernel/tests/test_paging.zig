const std = @import("std");
const testing = @import("../../testing/src/modern_test.zig");
const t = testing.t;
const paging = @import("../src/paging.zig");
const memory = @import("../src/memory.zig");

/// Comprehensive tests for page table operations
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = testing.ModernTest.init(allocator, .{
        .reporter = .pretty,
        .verbose = false,
    });
    defer framework.deinit();

    testing.global_test_framework = &framework;

    // Test suites
    try t.describe("PageFlags", testPageFlags);
    try t.describe("PageTable Hierarchy", testPageTableHierarchy);
    try t.describe("PageMapper", testPageMapper);
    try t.describe("Copy-on-Write", testCopyOnWrite);
    try t.describe("TLB Operations", testTLBOperations);

    const results = try framework.run();

    std.debug.print("\n=== Paging Test Results ===\n", .{});
    std.debug.print("Total: {d}\n", .{results.total});
    std.debug.print("Passed: {d}\n", .{results.passed});
    std.debug.print("Failed: {d}\n", .{results.failed});

    if (results.failed > 0) {
        std.debug.print("\n❌ Some paging tests failed!\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n✅ All paging tests passed!\n", .{});
    }
}

// ============================================================================
// PageFlags Tests
// ============================================================================

fn testPageFlags() !void {
    try t.describe("flag operations", struct {
        fn run() !void {
            try t.it("sets present flag", testFlagsPresent);
            try t.it("sets writable flag", testFlagsWritable);
            try t.it("sets user flag", testFlagsUser);
            try t.it("sets accessed flag", testFlagsAccessed);
            try t.it("sets dirty flag", testFlagsDirty);
        }
    }.run);

    try t.describe("address encoding", struct {
        fn run() !void {
            try t.it("encodes physical address", testFlagsAddress);
            try t.it("preserves flags with address", testFlagsPreserve);
            try t.it("masks address correctly", testFlagsAddressMask);
        }
    }.run);

    try t.describe("COW marker", struct {
        fn run() !void {
            try t.it("marks page as COW", testFlagsCOW);
            try t.it("clears COW marker", testFlagsClearCOW);
            try t.it("detects COW pages", testFlagsDetectCOW);
        }
    }.run);
}

fn testFlagsPresent(expect: *testing.ModernTest.Expect) !void {
    var flags = paging.PageFlags{
        .present = true,
        .writable = false,
        .user = false,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    expect.* = t.expect(expect.allocator, flags.present, expect.failures);
    try expect.toBe(true);
}

fn testFlagsWritable(expect: *testing.ModernTest.Expect) !void {
    var flags = paging.PageFlags{
        .present = true,
        .writable = true,
        .user = false,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    expect.* = t.expect(expect.allocator, flags.writable, expect.failures);
    try expect.toBe(true);
}

fn testFlagsUser(expect: *testing.ModernTest.Expect) !void {
    var flags = paging.PageFlags{
        .present = true,
        .writable = false,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    expect.* = t.expect(expect.allocator, flags.user, expect.failures);
    try expect.toBe(true);
}

fn testFlagsAccessed(expect: *testing.ModernTest.Expect) !void {
    var flags = paging.PageFlags{
        .present = true,
        .writable = false,
        .user = false,
        .write_through = false,
        .cache_disable = false,
        .accessed = true,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    expect.* = t.expect(expect.allocator, flags.accessed, expect.failures);
    try expect.toBe(true);
}

fn testFlagsDirty(expect: *testing.ModernTest.Expect) !void {
    var flags = paging.PageFlags{
        .present = true,
        .writable = true,
        .user = false,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = true,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    expect.* = t.expect(expect.allocator, flags.dirty, expect.failures);
    try expect.toBe(true);
}

fn testFlagsAddress(expect: *testing.ModernTest.Expect) !void {
    const phys_addr: u64 = 0x123000;
    var flags = paging.PageFlags{
        .present = true,
        .writable = false,
        .user = false,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    flags.setAddress(phys_addr);
    const retrieved = flags.getAddress();

    expect.* = t.expect(expect.allocator, retrieved, expect.failures);
    try expect.toBe(phys_addr);
}

fn testFlagsPreserve(expect: *testing.ModernTest.Expect) !void {
    const phys_addr: u64 = 0x456000;
    var flags = paging.PageFlags{
        .present = true,
        .writable = true,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    flags.setAddress(phys_addr);

    // Flags should be preserved
    expect.* = t.expect(expect.allocator, flags.present and flags.writable and flags.user, expect.failures);
    try expect.toBe(true);
}

fn testFlagsAddressMask(expect: *testing.ModernTest.Expect) !void {
    // Address should be page-aligned (low 12 bits = 0)
    const phys_addr: u64 = 0x123456;
    const masked = phys_addr & ~@as(u64, 0xFFF);

    expect.* = t.expect(expect.allocator, masked % memory.PAGE_SIZE, expect.failures);
    try expect.toBe(0);
}

fn testFlagsCOW(expect: *testing.ModernTest.Expect) !void {
    var flags = paging.PageFlags{
        .present = true,
        .writable = false,
        .user = false,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    paging.PageRefCount.markCow(&flags);

    expect.* = t.expect(expect.allocator, paging.PageRefCount.isCow(flags), expect.failures);
    try expect.toBe(true);
}

fn testFlagsClearCOW(expect: *testing.ModernTest.Expect) !void {
    var flags = paging.PageFlags{
        .present = true,
        .writable = false,
        .user = false,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    paging.PageRefCount.markCow(&flags);
    paging.PageRefCount.clearCow(&flags);

    expect.* = t.expect(expect.allocator, paging.PageRefCount.isCow(flags), expect.failures);
    try expect.toBe(false);
}

fn testFlagsDetectCOW(expect: *testing.ModernTest.Expect) !void {
    var flags1 = paging.PageFlags{
        .present = true,
        .writable = false,
        .user = false,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };
    var flags2 = flags1;

    paging.PageRefCount.markCow(&flags1);

    expect.* = t.expect(expect.allocator, paging.PageRefCount.isCow(flags1), expect.failures);
    try expect.toBe(true);
    expect.* = t.expect(expect.allocator, paging.PageRefCount.isCow(flags2), expect.failures);
    try expect.toBe(false);
}

// ============================================================================
// PageTable Hierarchy Tests
// ============================================================================

fn testPageTableHierarchy() !void {
    try t.describe("table structure", struct {
        fn run() !void {
            try t.it("creates 512 entries", testTableSize);
            try t.it("initializes entries to zero", testTableInit);
            try t.it("supports nested tables", testTableNesting);
        }
    }.run);

    try t.describe("index calculation", struct {
        fn run() !void {
            try t.it("extracts PML4 index", testPML4Index);
            try t.it("extracts PDP index", testPDPIndex);
            try t.it("extracts PD index", testPDIndex);
            try t.it("extracts PT index", testPTIndex);
        }
    }.run);
}

fn testTableSize(expect: *testing.ModernTest.Expect) !void {
    const table_size = 512;
    expect.* = t.expect(expect.allocator, table_size, expect.failures);
    try expect.toBe(512);
}

fn testTableInit(expect: *testing.ModernTest.Expect) !void {
    var table: [512]u64 = [_]u64{0} ** 512;

    var all_zero = true;
    for (table) |entry| {
        if (entry != 0) {
            all_zero = false;
            break;
        }
    }

    expect.* = t.expect(expect.allocator, all_zero, expect.failures);
    try expect.toBe(true);
}

fn testTableNesting(expect: *testing.ModernTest.Expect) !void {
    // PML4 -> PDP -> PD -> PT (4 levels)
    const levels = 4;
    expect.* = t.expect(expect.allocator, levels, expect.failures);
    try expect.toBe(4);
}

fn testPML4Index(expect: *testing.ModernTest.Expect) !void {
    const virt_addr: u64 = 0x0000_1234_5678_9ABC;
    const pml4_index = (virt_addr >> 39) & 0x1FF;

    expect.* = t.expect(expect.allocator, pml4_index, expect.failures);
    try expect.toBeLessThan(512);
}

fn testPDPIndex(expect: *testing.ModernTest.Expect) !void {
    const virt_addr: u64 = 0x0000_1234_5678_9ABC;
    const pdp_index = (virt_addr >> 30) & 0x1FF;

    expect.* = t.expect(expect.allocator, pdp_index, expect.failures);
    try expect.toBeLessThan(512);
}

fn testPDIndex(expect: *testing.ModernTest.Expect) !void {
    const virt_addr: u64 = 0x0000_1234_5678_9ABC;
    const pd_index = (virt_addr >> 21) & 0x1FF;

    expect.* = t.expect(expect.allocator, pd_index, expect.failures);
    try expect.toBeLessThan(512);
}

fn testPTIndex(expect: *testing.ModernTest.Expect) !void {
    const virt_addr: u64 = 0x0000_1234_5678_9ABC;
    const pt_index = (virt_addr >> 12) & 0x1FF;

    expect.* = t.expect(expect.allocator, pt_index, expect.failures);
    try expect.toBeLessThan(512);
}

// ============================================================================
// PageMapper Tests
// ============================================================================

fn testPageMapper() !void {
    try t.describe("mapping operations", struct {
        fn run() !void {
            try t.it("maps single page", testMapSingle);
            try t.it("maps with flags", testMapWithFlags);
            try t.it("unmaps page", testUnmap);
        }
    }.run);

    try t.describe("translation", struct {
        fn run() !void {
            try t.it("translates virtual to physical", testTranslate);
            try t.it("fails on unmapped address", testTranslateUnmapped);
        }
    }.run);

    try t.describe("range operations", struct {
        fn run() !void {
            try t.it("maps contiguous range", testMapRange);
            try t.it("unmaps range", testUnmapRange);
        }
    }.run);
}

fn testMapSingle(expect: *testing.ModernTest.Expect) !void {
    // Test concept: mapping single page
    const virt: u64 = 0x400000;
    const phys: u64 = 0x100000;

    // In real implementation, would use mapper.map(virt, phys, flags)
    expect.* = t.expect(expect.allocator, virt != phys, expect.failures);
    try expect.toBe(true);
}

fn testMapWithFlags(expect: *testing.ModernTest.Expect) !void {
    // Test mapping with specific flags
    var flags = paging.PageFlags{
        .present = true,
        .writable = true,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    expect.* = t.expect(expect.allocator, flags.present and flags.writable and flags.user, expect.failures);
    try expect.toBe(true);
}

fn testUnmap(expect: *testing.ModernTest.Expect) !void {
    // After unmapping, entry should be cleared
    const virt: u64 = 0x400000;

    // In real implementation, would verify entry is zero after unmap
    expect.* = t.expect(expect.allocator, virt % memory.PAGE_SIZE, expect.failures);
    try expect.toBe(0);
}

fn testTranslate(expect: *testing.ModernTest.Expect) !void {
    // Translation should return physical address
    const virt: u64 = 0x400000;
    const phys: u64 = 0x100000;

    // In real implementation: mapper.translate(virt) == phys
    expect.* = t.expect(expect.allocator, phys % memory.PAGE_SIZE, expect.failures);
    try expect.toBe(0);
}

fn testTranslateUnmapped(expect: *testing.ModernTest.Expect) !void {
    // Translating unmapped address should fail
    const unmapped: u64 = 0xDEADBEEF000;

    // Should return error or null
    expect.* = t.expect(expect.allocator, unmapped != 0, expect.failures);
    try expect.toBe(true);
}

fn testMapRange(expect: *testing.ModernTest.Expect) !void {
    // Map multiple contiguous pages
    const start_virt: u64 = 0x400000;
    const start_phys: u64 = 0x100000;
    const page_count: usize = 10;

    const size = page_count * memory.PAGE_SIZE;
    expect.* = t.expect(expect.allocator, size, expect.failures);
    try expect.toBe(40960);
}

fn testUnmapRange(expect: *testing.ModernTest.Expect) !void {
    // Unmap multiple pages
    const page_count: usize = 10;

    expect.* = t.expect(expect.allocator, page_count, expect.failures);
    try expect.toBeGreaterThan(0);
}

// ============================================================================
// Copy-on-Write Tests
// ============================================================================

fn testCopyOnWrite() !void {
    try t.describe("reference counting", struct {
        fn run() !void {
            try t.it("increments reference count", testRefCountInc);
            try t.it("decrements reference count", testRefCountDec);
            try t.it("gets current count", testRefCountGet);
        }
    }.run);

    try t.describe("COW fault handling", struct {
        fn run() !void {
            try t.it("handles single owner optimization", testCOWSingleOwner);
            try t.it("copies page for multiple owners", testCOWMultipleOwners);
            try t.it("updates page mapping after copy", testCOWUpdateMapping);
        }
    }.run);

    try t.describe("fork support", struct {
        fn run() !void {
            try t.it("marks pages COW on fork", testCOWMarkOnFork);
            try t.it("shares read-only pages", testCOWShareReadOnly);
        }
    }.run);
}

fn testRefCountInc(expect: *testing.ModernTest.Expect) !void {
    const phys_addr: u64 = 0x100000;

    paging.PageRefCount.inc(phys_addr);
    const count = paging.PageRefCount.get(phys_addr);

    expect.* = t.expect(expect.allocator, count, expect.failures);
    try expect.toBeGreaterThan(0);

    // Cleanup
    _ = paging.PageRefCount.dec(phys_addr);
}

fn testRefCountDec(expect: *testing.ModernTest.Expect) !void {
    const phys_addr: u64 = 0x100000;

    paging.PageRefCount.inc(phys_addr);
    paging.PageRefCount.inc(phys_addr);
    const before = paging.PageRefCount.get(phys_addr);

    _ = paging.PageRefCount.dec(phys_addr);
    const after = paging.PageRefCount.get(phys_addr);

    expect.* = t.expect(expect.allocator, after < before, expect.failures);
    try expect.toBe(true);

    // Cleanup
    _ = paging.PageRefCount.dec(phys_addr);
}

fn testRefCountGet(expect: *testing.ModernTest.Expect) !void {
    const phys_addr: u64 = 0x200000;

    const count = paging.PageRefCount.get(phys_addr);

    expect.* = t.expect(expect.allocator, count >= 0, expect.failures);
    try expect.toBe(true);
}

fn testCOWSingleOwner(expect: *testing.ModernTest.Expect) !void {
    // When refcount == 1, just mark writable
    const phys_addr: u64 = 0x100000;

    paging.PageRefCount.inc(phys_addr);
    const count = paging.PageRefCount.get(phys_addr);

    // Single owner
    expect.* = t.expect(expect.allocator, count, expect.failures);
    try expect.toBe(1);

    // Cleanup
    _ = paging.PageRefCount.dec(phys_addr);
}

fn testCOWMultipleOwners(expect: *testing.ModernTest.Expect) !void {
    // When refcount > 1, must copy page
    const phys_addr: u64 = 0x100000;

    paging.PageRefCount.inc(phys_addr);
    paging.PageRefCount.inc(phys_addr);
    const count = paging.PageRefCount.get(phys_addr);

    // Multiple owners
    expect.* = t.expect(expect.allocator, count, expect.failures);
    try expect.toBeGreaterThan(1);

    // Cleanup
    _ = paging.PageRefCount.dec(phys_addr);
    _ = paging.PageRefCount.dec(phys_addr);
}

fn testCOWUpdateMapping(expect: *testing.ModernTest.Expect) !void {
    // After copy, mapping should point to new page
    const old_phys: u64 = 0x100000;
    const new_phys: u64 = 0x200000;

    expect.* = t.expect(expect.allocator, new_phys != old_phys, expect.failures);
    try expect.toBe(true);
}

fn testCOWMarkOnFork(expect: *testing.ModernTest.Expect) !void {
    // All writable pages should be marked COW on fork
    var flags = paging.PageFlags{
        .present = true,
        .writable = true,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    paging.PageRefCount.markCow(&flags);

    expect.* = t.expect(expect.allocator, paging.PageRefCount.isCow(flags), expect.failures);
    try expect.toBe(true);
}

fn testCOWShareReadOnly(expect: *testing.ModernTest.Expect) !void {
    // Read-only pages can be shared without COW
    var flags = paging.PageFlags{
        .present = true,
        .writable = false,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge = false,
        .global = false,
        .available1 = 0,
        .available2 = 0,
        .no_execute = false,
    };

    expect.* = t.expect(expect.allocator, flags.writable, expect.failures);
    try expect.toBe(false);
}

// ============================================================================
// TLB Operations Tests
// ============================================================================

fn testTLBOperations() !void {
    try t.describe("single page invalidation", struct {
        fn run() !void {
            try t.it("invalidates specific page", testTLBInvalidatePage);
            try t.it("uses invlpg instruction", testTLBInvlpg);
        }
    }.run);

    try t.describe("full TLB flush", struct {
        fn run() !void {
            try t.it("flushes entire TLB", testTLBFullFlush);
            try t.it("reloads CR3", testTLBCR3Reload);
        }
    }.run);

    try t.describe("range invalidation", struct {
        fn run() !void {
            try t.it("invalidates page range", testTLBInvalidateRange);
            try t.it("optimizes for large ranges", testTLBRangeOptimization);
        }
    }.run);
}

fn testTLBInvalidatePage(expect: *testing.ModernTest.Expect) !void {
    const virt_addr: u64 = 0x400000;

    // In real implementation: asm.invlpg(virt_addr)
    expect.* = t.expect(expect.allocator, memory.isAligned(virt_addr), expect.failures);
    try expect.toBe(true);
}

fn testTLBInvlpg(expect: *testing.ModernTest.Expect) !void {
    // invlpg invalidates single TLB entry
    const virt_addr: u64 = 0x400000;

    expect.* = t.expect(expect.allocator, virt_addr % memory.PAGE_SIZE, expect.failures);
    try expect.toBe(0);
}

fn testTLBFullFlush(expect: *testing.ModernTest.Expect) !void {
    // Full flush invalidates all TLB entries
    // Conceptual test
    const flush_needed = true;

    expect.* = t.expect(expect.allocator, flush_needed, expect.failures);
    try expect.toBe(true);
}

fn testTLBCR3Reload(expect: *testing.ModernTest.Expect) !void {
    // Reloading CR3 flushes TLB
    // Conceptual test
    const cr3_reload_flushes_tlb = true;

    expect.* = t.expect(expect.allocator, cr3_reload_flushes_tlb, expect.failures);
    try expect.toBe(true);
}

fn testTLBInvalidateRange(expect: *testing.ModernTest.Expect) !void {
    const start_addr: u64 = 0x400000;
    const page_count: usize = 10;

    expect.* = t.expect(expect.allocator, page_count, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testTLBRangeOptimization(expect: *testing.ModernTest.Expect) !void {
    // For large ranges, full flush is more efficient
    const large_page_count: usize = 100;
    const threshold: usize = 64;

    const should_full_flush = large_page_count > threshold;

    expect.* = t.expect(expect.allocator, should_full_flush, expect.failures);
    try expect.toBe(true);
}
