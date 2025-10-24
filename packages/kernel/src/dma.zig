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
