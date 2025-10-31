// Home Programming Language - Driver Memory Management
// Memory management utilities for device drivers

const std = @import("std");

/// Physical memory region
pub const PhysicalRegion = struct {
    base: u64,
    size: usize,
    flags: u32,

    pub fn init(base: u64, size: usize) PhysicalRegion {
        return .{
            .base = base,
            .size = size,
            .flags = 0,
        };
    }

    pub fn contains(self: PhysicalRegion, addr: u64) bool {
        return addr >= self.base and addr < self.base + self.size;
    }

    pub fn end(self: PhysicalRegion) u64 {
        return self.base + self.size;
    }
};

/// Memory mapping for device I/O
pub const MemoryMapping = struct {
    physical: u64,
    virtual: ?[*]volatile u8,
    size: usize,
    flags: u32,

    pub fn init(phys: u64, virt: ?[*]volatile u8, size: usize) MemoryMapping {
        return .{
            .physical = phys,
            .virtual = virt,
            .size = size,
            .flags = 0,
        };
    }

    pub fn readU8(self: MemoryMapping, offset: usize) u8 {
        if (self.virtual) |virt| {
            return virt[offset];
        }
        return 0;
    }

    pub fn writeU8(self: MemoryMapping, offset: usize, value: u8) void {
        if (self.virtual) |virt| {
            virt[offset] = value;
        }
    }

    pub fn readU32(self: MemoryMapping, offset: usize) u32 {
        if (self.virtual) |virt| {
            const ptr: *const volatile u32 = @ptrCast(@alignCast(&virt[offset]));
            return ptr.*;
        }
        return 0;
    }

    pub fn writeU32(self: MemoryMapping, offset: usize, value: u32) void {
        if (self.virtual) |virt| {
            const ptr: *volatile u32 = @ptrCast(@alignCast(&virt[offset]));
            ptr.* = value;
        }
    }

    pub fn readU64(self: MemoryMapping, offset: usize) u64 {
        if (self.virtual) |virt| {
            const ptr: *const volatile u64 = @ptrCast(@alignCast(&virt[offset]));
            return ptr.*;
        }
        return 0;
    }

    pub fn writeU64(self: MemoryMapping, offset: usize, value: u64) void {
        if (self.virtual) |virt| {
            const ptr: *volatile u64 = @ptrCast(@alignCast(&virt[offset]));
            ptr.* = value;
        }
    }
};

/// I/O port access (x86-specific)
pub const IoPort = struct {
    port: u16,

    pub fn init(port: u16) IoPort {
        return .{ .port = port };
    }

    pub fn outb(self: IoPort, value: u8) void {
        _ = self;
        _ = value;
        // Would use inline assembly on x86:
        // asm volatile ("outb %[value], %[port]"
        //     :
        //     : [value] "{al}" (value),
        //       [port] "N{dx}" (self.port)
        // );
    }

    pub fn inb(self: IoPort) u8 {
        _ = self;
        // Would use inline assembly on x86:
        // var value: u8 = undefined;
        // asm volatile ("inb %[port], %[value]"
        //     : [value] "={al}" (value)
        //     : [port] "N{dx}" (self.port)
        // );
        // return value;
        return 0;
    }
};

/// Memory barrier operations
pub fn memoryBarrier() void {
    std.atomic.compilerFence(.seq_cst);
}

pub fn readBarrier() void {
    std.atomic.compilerFence(.acquire);
}

pub fn writeBarrier() void {
    std.atomic.compilerFence(.release);
}

/// Allocate physically contiguous memory
pub fn allocatePhysical(allocator: std.mem.Allocator, size: usize, alignment: usize) !PhysicalRegion {
    _ = alignment;
    // In a real implementation, would allocate physically contiguous memory
    const memory = try allocator.alloc(u8, size);
    return PhysicalRegion.init(
        @intFromPtr(memory.ptr),
        size,
    );
}

/// Free physically contiguous memory
pub fn freePhysical(allocator: std.mem.Allocator, region: PhysicalRegion) void {
    // In a real implementation, would properly free physical memory
    const ptr: [*]u8 = @ptrFromInt(region.base);
    allocator.free(ptr[0..region.size]);
}

test "physical region operations" {
    const region = PhysicalRegion.init(0x1000, 4096);

    try std.testing.expect(region.contains(0x1000));
    try std.testing.expect(region.contains(0x1FFF));
    try std.testing.expect(!region.contains(0x2000));
    try std.testing.expectEqual(@as(u64, 0x2000), region.end());
}

test "memory mapping read/write" {
    const allocator = std.testing.allocator;
    const memory = try allocator.alloc(u8, 16);
    defer allocator.free(memory);

    const mapping = MemoryMapping.init(
        @intFromPtr(memory.ptr),
        @ptrCast(memory.ptr),
        memory.len,
    );

    mapping.writeU8(0, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), mapping.readU8(0));
}
