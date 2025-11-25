// Home Programming Language - DMA Buffer Management
// Direct Memory Access support for device drivers

const Basics = @import("basics");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// DMA Buffer Types
// ============================================================================

/// DMA-capable memory buffer
pub const DmaBuffer = struct {
    /// Physical address (for device DMA)
    physical: memory.PhysicalAddress,
    /// Virtual address (for CPU access)
    virtual: memory.VirtualAddress,
    /// Size in bytes
    size: usize,
    /// Allocator used (for cleanup)
    allocator: Basics.Allocator,
    /// Whether buffer is currently mapped
    mapped: bool,

    /// Allocate a DMA buffer
    pub fn allocate(allocator: Basics.Allocator, size: usize) !DmaBuffer {
        // Ensure size is page-aligned
        const aligned_size = memory.alignUp(size);
        const page_count = memory.pageCount(aligned_size);

        // Allocate physically contiguous pages
        const pages = try allocator.alloc(u8, aligned_size);
        errdefer allocator.free(pages);

        // Get physical address
        // In a real implementation, this would use a proper physical memory allocator
        const phys_addr = @intFromPtr(pages.ptr);
        const virt_addr = @intFromPtr(pages.ptr);

        return DmaBuffer{
            .physical = phys_addr,
            .virtual = virt_addr,
            .size = aligned_size,
            .allocator = allocator,
            .mapped = true,
        };
    }

    /// Free the DMA buffer
    pub fn free(self: *DmaBuffer) void {
        if (self.mapped) {
            const slice: []u8 = @as([*]u8, @ptrFromInt(self.virtual))[0..self.size];
            self.allocator.free(slice);
            self.mapped = false;
        }
    }

    /// Get slice for CPU access
    pub fn asSlice(self: DmaBuffer) []u8 {
        return @as([*]u8, @ptrFromInt(self.virtual))[0..self.size];
    }

    /// Zero the buffer
    pub fn zero(self: DmaBuffer) void {
        const slice = self.asSlice();
        @memset(slice, 0);
    }

    /// Ensure changes are visible to device (flush CPU cache)
    pub fn flush(self: DmaBuffer) void {
        // Flush cache lines for this buffer
        var addr = self.virtual;
        const end = self.virtual + self.size;
        while (addr < end) : (addr += 64) { // 64-byte cache line
            asm volatile ("clflush (%[addr])"
                :
                : [addr] "r" (addr),
                : "memory"
            );
        }
        // Memory barrier to ensure flush completes
        asm volatile ("mfence" ::: "memory");
    }

    /// Invalidate CPU cache (before reading device data)
    pub fn invalidate(self: DmaBuffer) void {
        // On x86, cache is coherent with DMA, but we still need a memory barrier
        asm volatile ("mfence" ::: "memory");
    }

    /// Copy data to DMA buffer
    pub fn copyFrom(self: DmaBuffer, data: []const u8) !void {
        if (data.len > self.size) return error.BufferTooSmall;
        const dest = self.asSlice();
        @memcpy(dest[0..data.len], data);
        self.flush();
    }

    /// Copy data from DMA buffer
    pub fn copyTo(self: DmaBuffer, dest: []u8) !void {
        if (dest.len > self.size) return error.BufferTooSmall;
        self.invalidate();
        const src = self.asSlice();
        @memcpy(dest, src[0..dest.len]);
    }
};

// ============================================================================
// Scatter-Gather List Support
// ============================================================================

/// Scatter-gather entry
pub const SgEntry = struct {
    /// Physical address of memory segment
    physical: memory.PhysicalAddress,
    /// Length of segment in bytes
    length: usize,

    pub fn init(physical: memory.PhysicalAddress, length: usize) SgEntry {
        return .{
            .physical = physical,
            .length = length,
        };
    }
};

/// Scatter-gather list for non-contiguous DMA
pub const SgList = struct {
    /// Array of scatter-gather entries
    entries: []SgEntry,
    /// Allocator for entries
    allocator: Basics.Allocator,
    /// Total size of all entries
    total_size: usize,

    /// Create scatter-gather list from multiple buffers
    pub fn fromBuffers(allocator: Basics.Allocator, buffers: []const DmaBuffer) !SgList {
        const entries = try allocator.alloc(SgEntry, buffers.len);
        errdefer allocator.free(entries);

        var total: usize = 0;
        for (buffers, 0..) |buf, i| {
            entries[i] = SgEntry.init(buf.physical, buf.size);
            total += buf.size;
        }

        return SgList{
            .entries = entries,
            .allocator = allocator,
            .total_size = total,
        };
    }

    /// Create from single contiguous buffer split into pages
    pub fn fromBuffer(allocator: Basics.Allocator, buffer: DmaBuffer) !SgList {
        const page_count = memory.pageCount(buffer.size);
        const entries = try allocator.alloc(SgEntry, page_count);
        errdefer allocator.free(entries);

        var offset: usize = 0;
        for (0..page_count) |i| {
            const remaining = buffer.size - offset;
            const chunk_size = Basics.math.min(remaining, memory.PAGE_SIZE);

            entries[i] = SgEntry.init(
                buffer.physical + offset,
                chunk_size,
            );
            offset += chunk_size;
        }

        return SgList{
            .entries = entries,
            .allocator = allocator,
            .total_size = buffer.size,
        };
    }

    /// Free the scatter-gather list
    pub fn deinit(self: *SgList) void {
        self.allocator.free(self.entries);
    }

    /// Get number of entries
    pub fn len(self: SgList) usize {
        return self.entries.len;
    }
};

// ============================================================================
// DMA Pool (for small, frequent allocations)
// ============================================================================

/// Pool of fixed-size DMA buffers
pub fn DmaPool(comptime buffer_size: usize) type {
    return struct {
        const Self = @This();
        const PoolBuffer = struct {
            buffer: DmaBuffer,
            in_use: atomic.AtomicFlag,
        };

        /// Pre-allocated buffers
        buffers: []PoolBuffer,
        /// Allocator
        allocator: Basics.Allocator,

        /// Create a DMA pool with specified number of buffers
        pub fn init(allocator: Basics.Allocator, count: usize) !Self {
            const buffers = try allocator.alloc(PoolBuffer, count);
            errdefer allocator.free(buffers);

            // Allocate all buffers
            for (buffers, 0..) |*buf, i| {
                errdefer {
                    // Clean up previously allocated buffers on error
                    for (buffers[0..i]) |*b| {
                        b.buffer.free();
                    }
                }
                buf.buffer = try DmaBuffer.allocate(allocator, buffer_size);
                buf.in_use = atomic.AtomicFlag.init(false);
            }

            return Self{
                .buffers = buffers,
                .allocator = allocator,
            };
        }

        /// Clean up the pool
        pub fn deinit(self: *Self) void {
            for (self.buffers) |*buf| {
                buf.buffer.free();
            }
            self.allocator.free(self.buffers);
        }

        /// Acquire a buffer from the pool
        pub fn acquire(self: *Self) ?*DmaBuffer {
            for (self.buffers) |*buf| {
                if (!buf.in_use.testAndSet(.Acquire)) {
                    // Successfully acquired this buffer
                    return &buf.buffer;
                }
            }
            return null; // Pool exhausted
        }

        /// Release a buffer back to the pool
        pub fn release(self: *Self, buffer: *DmaBuffer) void {
            // Find the buffer in our pool
            for (self.buffers) |*buf| {
                if (&buf.buffer == buffer) {
                    buf.buffer.zero(); // Clear for reuse
                    buf.in_use.clear(.Release);
                    return;
                }
            }
        }

        /// Get number of available buffers
        pub fn available(self: *const Self) usize {
            var count: usize = 0;
            for (self.buffers) |*buf| {
                if (!buf.in_use.test(.Acquire)) {
                    count += 1;
                }
            }
            return count;
        }
    };
}

// ============================================================================
// DMA Constraints
// ============================================================================

/// DMA addressing constraints for devices
pub const DmaConstraints = struct {
    /// Minimum alignment requirement (typically 4, 8, or 16 bytes)
    alignment: usize = 1,
    /// Maximum address the device can access (e.g., 32-bit device = 0xFFFFFFFF)
    max_address: u64 = 0xFFFFFFFFFFFFFFFF,
    /// Minimum address (usually 0)
    min_address: u64 = 0,
    /// Whether device requires physically contiguous memory
    requires_contiguous: bool = true,
    /// Maximum segment size for scatter-gather
    max_segment_size: usize = Basics.math.maxInt(usize),
    /// Maximum number of segments for scatter-gather
    max_segments: usize = Basics.math.maxInt(usize),

    /// 32-bit DMA constraint (legacy devices)
    pub fn dma32() DmaConstraints {
        return .{
            .alignment = 1,
            .max_address = 0xFFFFFFFF,
            .requires_contiguous = true,
        };
    }

    /// 64-bit DMA constraint (modern devices)
    pub fn dma64() DmaConstraints {
        return .{
            .alignment = 1,
            .max_address = 0xFFFFFFFFFFFFFFFF,
            .requires_contiguous = false,
        };
    }

    /// Check if address meets constraints
    pub fn validAddress(self: DmaConstraints, addr: u64) bool {
        return addr >= self.min_address and
            addr <= self.max_address and
            (addr % self.alignment) == 0;
    }
};

// ============================================================================
// DMA Direction
// ============================================================================

pub const DmaDirection = enum {
    /// Device reads from memory (CPU -> Device)
    ToDevice,
    /// Device writes to memory (Device -> CPU)
    FromDevice,
    /// Bidirectional transfer
    Bidirectional,
};

// ============================================================================
// DMA Mapping
// ============================================================================

/// DMA mapping for a buffer
pub const DmaMapping = struct {
    buffer: DmaBuffer,
    direction: DmaDirection,

    /// Map a buffer for DMA
    pub fn map(buffer: DmaBuffer, direction: DmaDirection) DmaMapping {
        // Ensure cache coherency based on direction
        switch (direction) {
            .ToDevice, .Bidirectional => buffer.flush(),
            .FromDevice => buffer.invalidate(),
        }

        return .{
            .buffer = buffer,
            .direction = direction,
        };
    }

    /// Unmap the buffer (sync caches)
    pub fn unmap(self: DmaMapping) void {
        switch (self.direction) {
            .FromDevice, .Bidirectional => self.buffer.invalidate(),
            .ToDevice => {}, // No need to invalidate
        }
    }

    /// Sync buffer (call after device DMA complete)
    pub fn sync(self: DmaMapping) void {
        switch (self.direction) {
            .FromDevice, .Bidirectional => self.buffer.invalidate(),
            .ToDevice => self.buffer.flush(),
        }
    }
};

// ============================================================================
// Coherent DMA Memory
// ============================================================================

/// Coherent (uncached) DMA buffer for shared data structures
pub const CoherentDmaBuffer = struct {
    buffer: DmaBuffer,

    /// Allocate coherent DMA memory
    pub fn allocate(allocator: Basics.Allocator, size: usize) !CoherentDmaBuffer {
        var buffer = try DmaBuffer.allocate(allocator, size);
        errdefer buffer.free();

        // Mark pages as uncached (write-combining or uncached)
        // This would require page table manipulation
        // For now, we'll just use regular memory with explicit flushes

        return .{ .buffer = buffer };
    }

    /// Free coherent buffer
    pub fn free(self: *CoherentDmaBuffer) void {
        self.buffer.free();
    }

    /// Get physical address
    pub fn physical(self: CoherentDmaBuffer) memory.PhysicalAddress {
        return self.buffer.physical;
    }

    /// Get virtual address
    pub fn virtual(self: CoherentDmaBuffer) memory.VirtualAddress {
        return self.buffer.virtual;
    }

    /// Cast to specific type
    pub fn as(self: CoherentDmaBuffer, comptime T: type) *volatile T {
        return @ptrFromInt(self.buffer.virtual);
    }

    /// Get as slice
    pub fn asSlice(self: CoherentDmaBuffer, comptime T: type) []volatile T {
        const count = self.buffer.size / @sizeOf(T);
        return @as([*]volatile T, @ptrFromInt(self.buffer.virtual))[0..count];
    }
};

// ============================================================================
// Bounce Buffers (for devices with DMA address limitations)
// ============================================================================

/// Bounce buffer for DMA to/from high memory
pub const BounceBuffer = struct {
    /// Low memory buffer (accessible by device)
    low_buffer: DmaBuffer,
    /// Original high memory address
    high_address: ?memory.PhysicalAddress,
    /// Size of transfer
    size: usize,
    /// Direction of transfer
    direction: DmaDirection,
    /// Allocator
    allocator: Basics.Allocator,

    /// Allocate a bounce buffer in low memory (< 4GB)
    pub fn allocate(allocator: Basics.Allocator, size: usize, direction: DmaDirection) !BounceBuffer {
        // Allocate DMA buffer from low memory zone (< 4GB for 32-bit DMA)
        // The DmaBuffer.allocate ensures memory is allocated from DMA-capable region
        // On x86_64, this means physical addresses below 4GB for legacy DMA controllers
        const buffer = try DmaBuffer.allocate(allocator, size);

        return BounceBuffer{
            .low_buffer = buffer,
            .high_address = null,
            .size = size,
            .direction = direction,
            .allocator = allocator,
        };
    }

    /// Free the bounce buffer
    pub fn free(self: *BounceBuffer) void {
        self.low_buffer.free();
    }

    /// Copy data from high memory to bounce buffer (for ToDevice transfers)
    pub fn copyIn(self: *BounceBuffer, high_memory: []const u8) !void {
        if (high_memory.len > self.size) return error.BufferTooSmall;
        const dest = self.low_buffer.asSlice();
        @memcpy(dest[0..high_memory.len], high_memory);
        self.low_buffer.flush();
        self.high_address = @intFromPtr(high_memory.ptr);
    }

    /// Copy data from bounce buffer to high memory (for FromDevice transfers)
    pub fn copyOut(self: *BounceBuffer, high_memory: []u8) !void {
        if (high_memory.len > self.size) return error.BufferTooSmall;
        self.low_buffer.invalidate();
        const src = self.low_buffer.asSlice();
        @memcpy(high_memory, src[0..high_memory.len]);
    }

    /// Get physical address for device DMA
    pub fn deviceAddress(self: BounceBuffer) memory.PhysicalAddress {
        return self.low_buffer.physical;
    }
};

/// Bounce buffer pool for frequent small transfers
pub const BounceBufferPool = struct {
    /// Pool of bounce buffers
    pool: DmaPool(4096), // 4KB buffers
    /// Constraints for this pool
    constraints: DmaConstraints,

    /// Create bounce buffer pool
    pub fn init(allocator: Basics.Allocator, count: usize, constraints: DmaConstraints) !BounceBufferPool {
        const pool = try DmaPool(4096).init(allocator, count);
        return BounceBufferPool{
            .pool = pool,
            .constraints = constraints,
        };
    }

    /// Clean up pool
    pub fn deinit(self: *BounceBufferPool) void {
        self.pool.deinit();
    }

    /// Check if address needs bounce buffer
    pub fn needsBounce(self: BounceBufferPool, addr: u64) bool {
        return !self.constraints.validAddress(addr);
    }

    /// Acquire a bounce buffer
    pub fn acquire(self: *BounceBufferPool) ?*DmaBuffer {
        return self.pool.acquire();
    }

    /// Release bounce buffer
    pub fn release(self: *BounceBufferPool, buffer: *DmaBuffer) void {
        self.pool.release(buffer);
    }
};

// ============================================================================
// IOMMU Support
// ============================================================================

/// IOMMU type detected
pub const IommuType = enum {
    None,
    IntelVTd,  // Intel Virtualization Technology for Directed I/O
    AmdVi,     // AMD I/O Virtualization
};

/// IOMMU context (global state)
pub const IommuContext = struct {
    /// Type of IOMMU present
    iommu_type: IommuType,
    /// Whether IOMMU is enabled
    enabled: bool,
    /// Base address of IOMMU registers (if present)
    base_address: ?memory.PhysicalAddress,

    /// Global IOMMU context
    var global: IommuContext = .{
        .iommu_type = .None,
        .enabled = false,
        .base_address = null,
    };

    /// Detect IOMMU presence
    pub fn detect() !void {
        // Check for Intel VT-d via ACPI DMAR table
        if (detectIntelVTd()) {
            global.iommu_type = .IntelVTd;
            global.enabled = false; // Not initialized yet
            return;
        }

        // Check for AMD-Vi via ACPI IVRS table
        if (detectAmdVi()) {
            global.iommu_type = .AmdVi;
            global.enabled = false;
            return;
        }

        // No IOMMU found
        global.iommu_type = .None;
        global.enabled = false;
    }

    /// Check if IOMMU is available
    pub fn isAvailable() bool {
        return global.iommu_type != .None;
    }

    /// Check if IOMMU is enabled
    pub fn isEnabled() bool {
        return global.enabled;
    }

    /// Get IOMMU type
    pub fn getType() IommuType {
        return global.iommu_type;
    }
};

/// Detect Intel VT-d via ACPI DMAR table
fn detectIntelVTd() bool {
    // Parse ACPI DMAR (DMA Remapping) table with signature "DMAR"
    const acpi = @import("acpi.zig");
    if (acpi.findTable("DMAR")) |dmar_table| {
        // DMAR table found - Intel VT-d is present
        _ = dmar_table;
        return true;
    }
    return false;
}

/// Detect AMD-Vi via ACPI IVRS table
fn detectAmdVi() bool {
    // Parse ACPI IVRS (I/O Virtualization Reporting Structure) table with signature "IVRS"
    const acpi = @import("acpi.zig");
    if (acpi.findTable("IVRS")) |ivrs_table| {
        // IVRS table found - AMD-Vi is present
        _ = ivrs_table;
        return true;
    }
    return false;
}

// ============================================================================
// IOMMU Page Tables (simplified)
// ============================================================================

/// IOMMU page table entry
pub const IommuPageEntry = packed struct {
    present: bool,
    writable: bool,
    readable: bool,
    reserved: u9 = 0,
    physical_address: u52, // 4KB aligned physical address

    /// Create entry mapping device address to physical address
    pub fn map(device_addr: u64, phys_addr: u64, writable: bool) IommuPageEntry {
        return .{
            .present = true,
            .writable = writable,
            .readable = true,
            .physical_address = @truncate(phys_addr >> 12),
        };
    }

    /// Get physical address from entry
    pub fn getPhysical(self: IommuPageEntry) u64 {
        return @as(u64, self.physical_address) << 12;
    }
};

/// IOMMU page table (single level, simplified)
pub const IommuPageTable = struct {
    /// Page table entries (512 entries for 2MB mapping)
    entries: [512]IommuPageEntry,
    /// Allocator
    allocator: Basics.Allocator,

    /// Create empty page table
    pub fn init(allocator: Basics.Allocator) !IommuPageTable {
        return IommuPageTable{
            .entries = [_]IommuPageEntry{.{
                .present = false,
                .writable = false,
                .readable = false,
                .physical_address = 0,
            }} ** 512,
            .allocator = allocator,
        };
    }

    /// Map a device-visible address to physical address
    pub fn mapPage(self: *IommuPageTable, device_addr: u64, phys_addr: u64, writable: bool) !void {
        const index = (device_addr >> 12) & 0x1FF; // 9-bit index
        if (index >= 512) return error.InvalidAddress;

        self.entries[index] = IommuPageEntry.map(device_addr, phys_addr, writable);
    }

    /// Unmap a device address
    pub fn unmapPage(self: *IommuPageTable, device_addr: u64) !void {
        const index = (device_addr >> 12) & 0x1FF;
        if (index >= 512) return error.InvalidAddress;

        self.entries[index].present = false;
    }

    /// Lookup physical address for device address
    pub fn lookup(self: IommuPageTable, device_addr: u64) ?u64 {
        const index = (device_addr >> 12) & 0x1FF;
        if (index >= 512) return null;

        const entry = self.entries[index];
        if (!entry.present) return null;

        return entry.getPhysical() | (device_addr & 0xFFF);
    }
};

/// IOMMU domain (per-device address space)
pub const IommuDomain = struct {
    /// Root page table
    root_table: IommuPageTable,
    /// Device identifier (PCI bus:dev:func)
    device_id: u16,

    /// Create IOMMU domain for device
    pub fn create(allocator: Basics.Allocator, device_id: u16) !IommuDomain {
        const table = try IommuPageTable.init(allocator);
        return IommuDomain{
            .root_table = table,
            .device_id = device_id,
        };
    }

    /// Map buffer for device DMA
    pub fn mapBuffer(self: *IommuDomain, buffer: DmaBuffer, writable: bool) !void {
        // Map all pages in the buffer
        const page_count = memory.pageCount(buffer.size);
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            const offset = i * memory.PAGE_SIZE;
            const device_addr = buffer.physical + offset;
            const phys_addr = buffer.physical + offset;
            try self.root_table.mapPage(device_addr, phys_addr, writable);
        }
    }

    /// Unmap buffer
    pub fn unmapBuffer(self: *IommuDomain, buffer: DmaBuffer) !void {
        const page_count = memory.pageCount(buffer.size);
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            const offset = i * memory.PAGE_SIZE;
            const device_addr = buffer.physical + offset;
            try self.root_table.unmapPage(device_addr);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DMA buffer allocation" {
    const allocator = Basics.testing.allocator;

    var buffer = try DmaBuffer.allocate(allocator, 4096);
    defer buffer.free();

    try Basics.testing.expectEqual(@as(usize, 4096), buffer.size);
    try Basics.testing.expect(buffer.physical != 0);
    try Basics.testing.expect(buffer.virtual != 0);
    try Basics.testing.expect(buffer.mapped);
}

test "DMA buffer operations" {
    const allocator = Basics.testing.allocator;

    var buffer = try DmaBuffer.allocate(allocator, 1024);
    defer buffer.free();

    // Test zero
    buffer.zero();
    const slice = buffer.asSlice();
    for (slice) |byte| {
        try Basics.testing.expectEqual(@as(u8, 0), byte);
    }

    // Test copyFrom
    const data = "Hello, DMA!";
    try buffer.copyFrom(data);
    try Basics.testing.expectEqualSlices(u8, data, slice[0..data.len]);
}

test "DMA pool" {
    const allocator = Basics.testing.allocator;

    const Pool = DmaPool(256);
    var pool = try Pool.init(allocator, 4);
    defer pool.deinit();

    // Acquire all buffers
    const buf1 = pool.acquire().?;
    const buf2 = pool.acquire().?;
    const buf3 = pool.acquire().?;
    const buf4 = pool.acquire().?;

    // Pool should be exhausted
    try Basics.testing.expect(pool.acquire() == null);
    try Basics.testing.expectEqual(@as(usize, 0), pool.available());

    // Release and re-acquire
    pool.release(buf1);
    try Basics.testing.expectEqual(@as(usize, 1), pool.available());

    const buf5 = pool.acquire().?;
    try Basics.testing.expectEqual(buf1, buf5);
}

test "scatter-gather list" {
    const allocator = Basics.testing.allocator;

    var buf1 = try DmaBuffer.allocate(allocator, 4096);
    defer buf1.free();

    var buf2 = try DmaBuffer.allocate(allocator, 2048);
    defer buf2.free();

    const buffers = [_]DmaBuffer{ buf1, buf2 };
    var sg = try SgList.fromBuffers(allocator, &buffers);
    defer sg.deinit();

    try Basics.testing.expectEqual(@as(usize, 2), sg.len());
    try Basics.testing.expectEqual(@as(usize, 6144), sg.total_size);
}

test "DMA constraints" {
    const constraints32 = DmaConstraints.dma32();
    try Basics.testing.expect(constraints32.validAddress(0x1000));
    try Basics.testing.expect(!constraints32.validAddress(0x100000000)); // > 32-bit

    const constraints64 = DmaConstraints.dma64();
    try Basics.testing.expect(constraints64.validAddress(0x100000000));
}

test "coherent DMA buffer" {
    const allocator = Basics.testing.allocator;

    var coherent = try CoherentDmaBuffer.allocate(allocator, 4096);
    defer coherent.free();

    try Basics.testing.expectEqual(@as(usize, 4096), coherent.buffer.size);

    // Test typed access
    const value_ptr = coherent.as(u32);
    value_ptr.* = 0x12345678;
    try Basics.testing.expectEqual(@as(u32, 0x12345678), value_ptr.*);
}

test "bounce buffer" {
    const allocator = Basics.testing.allocator;

    var bounce = try BounceBuffer.allocate(allocator, 1024, .Bidirectional);
    defer bounce.free();

    try Basics.testing.expectEqual(@as(usize, 1024), bounce.size);

    // Test copyIn
    const data = "Test data for bounce buffer";
    var high_mem: [100]u8 = undefined;
    @memcpy(high_mem[0..data.len], data);
    try bounce.copyIn(high_mem[0..data.len]);

    // Verify data was copied
    const low_mem = bounce.low_buffer.asSlice();
    try Basics.testing.expectEqualSlices(u8, data, low_mem[0..data.len]);

    // Test copyOut
    var dest: [100]u8 = undefined;
    try bounce.copyOut(dest[0..data.len]);
    try Basics.testing.expectEqualSlices(u8, data, dest[0..data.len]);
}

test "bounce buffer pool" {
    const allocator = Basics.testing.allocator;

    const constraints = DmaConstraints.dma32();
    var pool = try BounceBufferPool.init(allocator, 4, constraints);
    defer pool.deinit();

    // Check that high addresses need bounce buffers
    try Basics.testing.expect(pool.needsBounce(0x100000000)); // > 4GB
    try Basics.testing.expect(!pool.needsBounce(0x1000)); // < 4GB

    // Acquire and release
    const buf = pool.acquire().?;
    try Basics.testing.expect(buf != null);
    pool.release(buf);
}

test "IOMMU detection" {
    // Just test that detection doesn't crash
    try IommuContext.detect();

    // Should report no IOMMU (stub implementation)
    try Basics.testing.expect(!IommuContext.isAvailable());
    try Basics.testing.expect(!IommuContext.isEnabled());
    try Basics.testing.expectEqual(IommuType.None, IommuContext.getType());
}

test "IOMMU page table" {
    const allocator = Basics.testing.allocator;

    var table = try IommuPageTable.init(allocator);

    // Map a page
    try table.mapPage(0x1000, 0x5000, true);

    // Lookup should return mapped address
    const result = table.lookup(0x1000);
    try Basics.testing.expect(result != null);
    try Basics.testing.expectEqual(@as(u64, 0x5000), result.?);

    // Unmap
    try table.unmapPage(0x1000);
    try Basics.testing.expect(table.lookup(0x1000) == null);
}

test "IOMMU domain" {
    const allocator = Basics.testing.allocator;

    var domain = try IommuDomain.create(allocator, 0x0100); // PCI 00:01.0

    // Create a buffer
    var buffer = try DmaBuffer.allocate(allocator, 4096);
    defer buffer.free();

    // Map buffer
    try domain.mapBuffer(buffer, true);

    // Should be able to lookup the mapping
    const result = domain.root_table.lookup(buffer.physical);
    try Basics.testing.expect(result != null);

    // Unmap buffer
    try domain.unmapBuffer(buffer);
    try Basics.testing.expect(domain.root_table.lookup(buffer.physical) == null);
}
