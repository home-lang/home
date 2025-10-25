// Home Programming Language - Kernel Memory Management
// Low-level memory primitives for OS development

const Basics = @import("basics");
const sync = @import("sync.zig");

/// Physical memory address
pub const PhysicalAddress = usize;

/// Virtual memory address
pub const VirtualAddress = usize;

/// Page size (4KB)
pub const PAGE_SIZE: usize = 4096;

/// Page alignment
pub const PAGE_ALIGN: usize = PAGE_SIZE;

// ============================================================================
// Memory-Mapped I/O (MMIO)
// ============================================================================

/// Type-safe memory-mapped I/O
pub fn MMIO(comptime T: type) type {
    return struct {
        const Self = @This();
        address: usize,

        /// Read from MMIO register
        pub fn read(self: Self) T {
            const ptr: *volatile T = @ptrFromInt(self.address);
            return ptr.*;
        }

        /// Write to MMIO register
        pub fn write(self: Self, value: T) void {
            const ptr: *volatile T = @ptrFromInt(self.address);
            ptr.* = value;
        }

        /// Modify MMIO register with function
        pub fn modify(self: Self, f: *const fn (T) T) void {
            self.write(f(self.read()));
        }

        /// Set specific bit
        pub fn setBit(self: Self, bit: comptime_int) void {
            comptime {
                if (bit >= @bitSizeOf(T)) {
                    @compileError("Bit index out of range");
                }
            }
            self.modify(struct {
                fn set(val: T) T {
                    return val | (@as(T, 1) << bit);
                }
            }.set);
        }

        /// Clear specific bit
        pub fn clearBit(self: Self, bit: comptime_int) void {
            comptime {
                if (bit >= @bitSizeOf(T)) {
                    @compileError("Bit index out of range");
                }
            }
            self.modify(struct {
                fn clear(val: T) T {
                    return val & ~(@as(T, 1) << bit);
                }
            }.clear);
        }
    };
}

// ============================================================================
// Hardware Register Abstraction
// ============================================================================

pub const RegisterSpec = struct {
    Type: type,
    address: usize,
    bits: comptime_int,
    read_only: bool = false,
    write_only: bool = false,
};

pub const Register = struct {
    pub fn define(comptime spec: RegisterSpec) type {
        return struct {
            const Self = @This();
            mmio: MMIO(spec.Type),

            pub fn init(address: usize) Self {
                return .{ .mmio = .{ .address = address } };
            }

            pub fn read(self: Self) spec.Type {
                comptime {
                    if (spec.write_only) {
                        @compileError("Cannot read from write-only register");
                    }
                }
                return self.mmio.read();
            }

            pub fn write(self: Self, value: spec.Type) void {
                comptime {
                    if (spec.read_only) {
                        @compileError("Cannot write to read-only register");
                    }
                }
                self.mmio.write(value);
            }

            pub fn setBit(self: Self, comptime bit: comptime_int) void {
                comptime {
                    if (spec.read_only) {
                        @compileError("Cannot write to read-only register");
                    }
                }
                self.mmio.setBit(bit);
            }

            pub fn clearBit(self: Self, comptime bit: comptime_int) void {
                comptime {
                    if (spec.read_only) {
                        @compileError("Cannot write to read-only register");
                    }
                }
                self.mmio.clearBit(bit);
            }
        };
    }
};

// ============================================================================
// Page Alignment Utilities
// ============================================================================

/// Align address down to page boundary
pub fn alignDown(addr: usize) usize {
    return addr & ~(PAGE_SIZE - 1);
}

/// Align address up to page boundary
pub fn alignUp(addr: usize) usize {
    return (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
}

/// Check if address is page-aligned
pub fn isAligned(addr: usize) bool {
    return (addr & (PAGE_SIZE - 1)) == 0;
}

/// Get number of pages needed for size
pub fn pageCou​nt(size: usize) usize {
    return (size + PAGE_SIZE - 1) / PAGE_SIZE;
}

// ============================================================================
// Bump Allocator (for early boot)
// ============================================================================

pub const BumpAllocator = struct {
    current: usize,
    limit: usize,
    lock: sync.Spinlock,

    pub fn init(start: usize, size: usize) @This() {
        return .{
            .current = start,
            .limit = start + size,
            .lock = sync.Spinlock.init(),
        };
    }

    pub fn alloc(self: *@This(), size: usize, alignment: usize) ![]u8 {
        self.lock.acquire();
        defer self.lock.release();

        // Align current pointer
        const aligned = Basics.mem.alignForward(usize, self.current, alignment);

        const new_current = aligned + size;
        if (new_current > self.limit) {
            return error.OutOfMemory;
        }

        self.current = new_current;
        const ptr: [*]u8 = @ptrFromInt(aligned);
        return ptr[0..size];
    }

    pub fn allocPage(self: *@This()) !PhysicalAddress {
        const mem = try self.alloc(PAGE_SIZE, PAGE_ALIGN);
        return @intFromPtr(mem.ptr);
    }

    pub fn allocPages(self: *@This(), count: usize) ![]PhysicalAddress {
        var pages: []PhysicalAddress = undefined;
        for (0..count) |i| {
            pages[i] = try self.allocPage();
        }
        return pages;
    }

    pub fn reset(self: *@This(), start: usize) void {
        self.current = start;
    }
};

// ============================================================================
// Slab Allocator (for fixed-size objects)
// ============================================================================

pub fn SlabAllocator(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slab = struct {
            next: ?*Slab,
        };

        free_list: ?*Slab,
        lock: sync.Spinlock,

        pub fn init() Self {
            return .{
                .free_list = null,
                .lock = sync.Spinlock.init(),
            };
        }

        pub fn alloc(self: *Self) !*T {
            self.lock.acquire();
            defer self.lock.release();

            if (self.free_list) |slab| {
                self.free_list = slab.next;
                const ptr: *T = @ptrCast(@alignCast(slab));
                return ptr;
            }

            return error.OutOfMemory;
        }

        pub fn free(self: *Self, ptr: *T) void {
            self.lock.acquire();
            defer self.lock.release();

            const slab: *Slab = @ptrCast(@alignCast(ptr));
            slab.next = self.free_list;
            self.free_list = slab;
        }

        pub fn addMemory(self: *Self, memory: []u8) void {
            comptime {
                if (@sizeOf(T) < @sizeOf(Slab)) {
                    @compileError("Type too small for slab allocator");
                }
            }

            self.lock.acquire();
            defer self.lock.release();

            const object_size = @sizeOf(T);
            const count = memory.len / object_size;

            for (0..count) |i| {
                const offset = i * object_size;
                const slab: *Slab = @ptrCast(@alignCast(memory[offset..].ptr));
                // Add to free list without locking (we already hold the lock)
                slab.next = self.free_list;
                self.free_list = slab;
            }
        }
    };
}

// ============================================================================
// Buddy Allocator (for variable-size allocations)
// ============================================================================

pub const BuddyAllocator = struct {
    const MAX_ORDER: usize = 11; // Up to 8MB blocks
    const Block = struct {
        next: ?*Block,
    };

    free_lists: [MAX_ORDER]?*Block,
    base_address: usize,
    total_size: usize,
    lock: sync.Spinlock,

    pub fn init(base: usize, size: usize) @This() {
        return .{
            .free_lists = [_]?*Block{null} ** MAX_ORDER,
            .base_address = base,
            .total_size = size,
            .lock = sync.Spinlock.init(),
        };
    }

    pub fn alloc(self: *@This(), size: usize) ![]u8 {
        self.lock.acquire();
        defer self.lock.release();

        const order = sizeToOrder(size);

        // Find smallest available block
        for (order..MAX_ORDER) |current_order| {
            if (self.free_lists[current_order]) |block| {
                self.free_lists[current_order] = block.next;

                // Split larger blocks
                var split_order = current_order;
                while (split_order > order) {
                    split_order -= 1;
                    const buddy_addr = @intFromPtr(block) + orderToSize(split_order);
                    const buddy: *Block = @ptrFromInt(buddy_addr);
                    buddy.next = self.free_lists[split_order];
                    self.free_lists[split_order] = buddy;
                }

                const ptr: [*]u8 = @ptrCast(block);
                return ptr[0..orderToSize(order)];
            }
        }

        return error.OutOfMemory;
    }

    pub fn free(self: *@This(), memory: []u8) void {
        self.lock.acquire();
        defer self.lock.release();

        var addr = @intFromPtr(memory.ptr);
        var order = sizeToOrder(memory.len);

        // Coalesce with buddy blocks
        while (order < MAX_ORDER - 1) {
            const buddy_addr = addr ^ orderToSize(order);
            if (!self.removeBuddy(buddy_addr, order)) {
                break;
            }

            // Merge with buddy
            addr = Basics.math.min(addr, buddy_addr);
            order += 1;
        }

        // Add to free list
        const block: *Block = @ptrFromInt(addr);
        block.next = self.free_lists[order];
        self.free_lists[order] = block;
    }

    fn removeBuddy(self: *@This(), addr: usize, order: usize) bool {
        var current = &self.free_lists[order];
        while (current.*) |block| {
            if (@intFromPtr(block) == addr) {
                current.* = block.next;
                return true;
            }
            current = &block.next;
        }
        return false;
    }

    fn orderToSize(order: usize) usize {
        return PAGE_SIZE << @intCast(order);
    }

    fn sizeToOrder(size: usize) usize {
        var order: usize = 0;
        var block_size = PAGE_SIZE;
        while (block_size < size and order < MAX_ORDER - 1) {
            block_size <<= 1;
            order += 1;
        }
        return order;
    }
};

// ============================================================================
// Page Allocator Interface
// ============================================================================

pub const PageAllocator = struct {
    allocator_type: enum { Bump, Buddy },
    bump: ?BumpAllocator,
    buddy: ?BuddyAllocator,

    pub fn initBump(start: usize, size: usize) @This() {
        return .{
            .allocator_type = .Bump,
            .bump = BumpAllocator.init(start, size),
            .buddy = null,
        };
    }

    pub fn initBuddy(base: usize, size: usize) @This() {
        return .{
            .allocator_type = .Buddy,
            .bump = null,
            .buddy = BuddyAllocator.init(base, size),
        };
    }

    pub fn allocPage(self: *@This()) !PhysicalAddress {
        return switch (self.allocator_type) {
            .Bump => self.bump.?.allocPage(),
            .Buddy => {
                const mem = try self.buddy.?.alloc(PAGE_SIZE);
                return @intFromPtr(mem.ptr);
            },
        };
    }

    pub fn allocPages(self: *@This(), count: usize) ![]PhysicalAddress {
        return switch (self.allocator_type) {
            .Bump => self.bump.?.allocPages(count),
            .Buddy => {
                const mem = try self.buddy.?.alloc(count * PAGE_SIZE);
                var pages: []PhysicalAddress = undefined;
                for (0..count) |i| {
                    pages[i] = @intFromPtr(mem.ptr) + (i * PAGE_SIZE);
                }
                return pages;
            },
        };
    }

    pub fn freePage(self: *@This(), addr: PhysicalAddress) void {
        if (self.allocator_type == .Buddy) {
            const ptr: [*]u8 = @ptrFromInt(addr);
            self.buddy.?.free(ptr[0..PAGE_SIZE]);
        }
        // Bump allocator doesn't support freeing
    }
};

// Tests
test "MMIO operations" {
    var value: u32 = 0x12345678;
    const mmio = MMIO(u32){ .address = @intFromPtr(&value) };

    try Basics.testing.expectEqual(@as(u32, 0x12345678), mmio.read());

    mmio.write(0xABCDEF00);
    try Basics.testing.expectEqual(@as(u32, 0xABCDEF00), value);

    mmio.setBit(0);
    try Basics.testing.expectEqual(@as(u32, 0xABCDEF01), value);
}

test "page alignment" {
    try Basics.testing.expectEqual(@as(usize, 0x1000), alignDown(0x1234));
    try Basics.testing.expectEqual(@as(usize, 0x2000), alignUp(0x1234));
    try Basics.testing.expect(isAligned(0x1000));
    try Basics.testing.expect(!isAligned(0x1234));
    try Basics.testing.expectEqual(@as(usize, 2), pageCount(0x1234));
}

test "bump allocator" {
    var bump = BumpAllocator.init(0x100000, 0x10000);

    const mem1 = try bump.alloc(1024, 8);
    try Basics.testing.expectEqual(@as(usize, 1024), mem1.len);

    const page = try bump.allocPage();
    try Basics.testing.expect(isAligned(page));
}

test "slab allocator" {
    const TestStruct = struct {
        value: u64,
        next: u64,
    };

    var slab = SlabAllocator(TestStruct).init();

    // Add some memory
    var memory: [1024]u8 align(@alignOf(TestStruct)) = undefined;
    slab.addMemory(&memory);

    // Allocate objects
    const obj1 = try slab.alloc();
    obj1.value = 42;

    const obj2 = try slab.alloc();
    obj2.value = 123;

    // Free and reuse
    slab.free(obj1);
    const obj3 = try slab.alloc();
    try Basics.testing.expectEqual(@intFromPtr(obj1), @intFromPtr(obj3));
}
