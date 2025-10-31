// Home Programming Language - Volatile Operations
// Memory-mapped I/O (MMIO) safety and volatile memory access

const std = @import("std");

// ============================================================================
// Volatile Pointer Wrapper
// ============================================================================

/// Safe wrapper for volatile memory access
pub fn Volatile(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: *volatile T,

        pub fn init(ptr: *volatile T) Self {
            return .{ .ptr = ptr };
        }

        pub fn initFromAddr(addr: usize) Self {
            return .{ .ptr = @ptrFromInt(addr) };
        }

        /// Read value with volatile semantics
        pub fn read(self: Self) T {
            return self.ptr.*;
        }

        /// Write value with volatile semantics
        pub fn write(self: Self, value: T) void {
            self.ptr.* = value;
        }

        /// Modify value with read-modify-write
        pub fn modify(self: Self, comptime func: fn (T) T) void {
            const old = self.read();
            const new = func(old);
            self.write(new);
        }

        /// Set specific bits (bitwise OR)
        pub fn setBits(self: Self, bits: T) void {
            if (@typeInfo(T) != .int) {
                @compileError("setBits requires integer type");
            }
            const old = self.read();
            self.write(old | bits);
        }

        /// Clear specific bits (bitwise AND NOT)
        pub fn clearBits(self: Self, bits: T) void {
            if (@typeInfo(T) != .int) {
                @compileError("clearBits requires integer type");
            }
            const old = self.read();
            self.write(old & ~bits);
        }

        /// Toggle specific bits (bitwise XOR)
        pub fn toggleBits(self: Self, bits: T) void {
            if (@typeInfo(T) != .int) {
                @compileError("toggleBits requires integer type");
            }
            const old = self.read();
            self.write(old ^ bits);
        }

        /// Test if specific bits are set
        pub fn testBits(self: Self, bits: T) bool {
            if (@typeInfo(T) != .int) {
                @compileError("testBits requires integer type");
            }
            return (self.read() & bits) == bits;
        }

        /// Wait until specific bits are set
        pub fn waitBitsSet(self: Self, bits: T) void {
            while (!self.testBits(bits)) {
                // Busy wait
            }
        }

        /// Wait until specific bits are clear
        pub fn waitBitsClear(self: Self, bits: T) void {
            while (self.testBits(bits)) {
                // Busy wait
            }
        }

        /// Get raw pointer
        pub fn getPtr(self: Self) *volatile T {
            return self.ptr;
        }

        /// Get address
        pub fn getAddr(self: Self) usize {
            return @intFromPtr(self.ptr);
        }
    };
}

// ============================================================================
// MMIO Register
// ============================================================================

/// Memory-mapped I/O register with safety features
pub fn MmioRegister(comptime T: type) type {
    return struct {
        const Self = @This();

        volatile_ptr: Volatile(T),
        name: []const u8,
        read_only: bool,
        write_only: bool,

        pub fn init(addr: usize, name: []const u8) Self {
            return .{
                .volatile_ptr = Volatile(T).initFromAddr(addr),
                .name = name,
                .read_only = false,
                .write_only = false,
            };
        }

        pub fn initReadOnly(addr: usize, name: []const u8) Self {
            return .{
                .volatile_ptr = Volatile(T).initFromAddr(addr),
                .name = name,
                .read_only = true,
                .write_only = false,
            };
        }

        pub fn initWriteOnly(addr: usize, name: []const u8) Self {
            return .{
                .volatile_ptr = Volatile(T).initFromAddr(addr),
                .name = name,
                .read_only = false,
                .write_only = true,
            };
        }

        pub fn read(self: Self) T {
            if (self.write_only) {
                @panic("Attempt to read write-only register");
            }
            return self.volatile_ptr.read();
        }

        pub fn write(self: Self, value: T) void {
            if (self.read_only) {
                @panic("Attempt to write read-only register");
            }
            self.volatile_ptr.write(value);
        }

        pub fn modify(self: Self, comptime func: fn (T) T) void {
            if (self.read_only) {
                @panic("Attempt to modify read-only register");
            }
            if (self.write_only) {
                @panic("Attempt to modify write-only register (need read-modify-write)");
            }
            self.volatile_ptr.modify(func);
        }

        pub fn setBits(self: Self, bits: T) void {
            const old = self.read();
            self.write(old | bits);
        }

        pub fn clearBits(self: Self, bits: T) void {
            const old = self.read();
            self.write(old & ~bits);
        }

        pub fn testBits(self: Self, bits: T) bool {
            return self.volatile_ptr.testBits(bits);
        }
    };
}

// ============================================================================
// MMIO Region
// ============================================================================

/// Memory-mapped I/O region with multiple registers
pub const MmioRegion = struct {
    base_addr: usize,
    size: usize,
    name: []const u8,

    pub fn init(base_addr: usize, size: usize, name: []const u8) MmioRegion {
        return .{
            .base_addr = base_addr,
            .size = size,
            .name = name,
        };
    }

    pub fn getRegister(self: MmioRegion, comptime T: type, offset: usize, name: []const u8) MmioRegister(T) {
        if (offset + @sizeOf(T) > self.size) {
            @panic("Register offset exceeds MMIO region size");
        }
        return MmioRegister(T).init(self.base_addr + offset, name);
    }

    pub fn getRegisterReadOnly(self: MmioRegion, comptime T: type, offset: usize, name: []const u8) MmioRegister(T) {
        if (offset + @sizeOf(T) > self.size) {
            @panic("Register offset exceeds MMIO region size");
        }
        return MmioRegister(T).initReadOnly(self.base_addr + offset, name);
    }

    pub fn getRegisterWriteOnly(self: MmioRegion, comptime T: type, offset: usize, name: []const u8) MmioRegister(T) {
        if (offset + @sizeOf(T) > self.size) {
            @panic("Register offset exceeds MMIO region size");
        }
        return MmioRegister(T).initWriteOnly(self.base_addr + offset, name);
    }

    pub fn contains(self: MmioRegion, addr: usize) bool {
        return addr >= self.base_addr and addr < self.base_addr + self.size;
    }
};

// ============================================================================
// Memory Barriers
// ============================================================================

pub const Barrier = struct {
    /// Full memory barrier (read and write)
    pub fn full() void {
        std.atomic.compilerFence(.seq_cst);
    }

    /// Read memory barrier
    pub fn read() void {
        std.atomic.compilerFence(.acquire);
    }

    /// Write memory barrier
    pub fn write() void {
        std.atomic.compilerFence(.release);
    }
};

// ============================================================================
// Volatile Buffer
// ============================================================================

/// Volatile buffer for DMA or MMIO arrays
pub fn VolatileBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: [*]volatile T,
        len: usize,

        pub fn init(ptr: [*]volatile T, len: usize) Self {
            return .{ .ptr = ptr, .len = len };
        }

        pub fn initFromAddr(addr: usize, len: usize) Self {
            return .{
                .ptr = @ptrFromInt(addr),
                .len = len,
            };
        }

        pub fn read(self: Self, index: usize) T {
            if (index >= self.len) {
                @panic("Buffer index out of bounds");
            }
            return self.ptr[index];
        }

        pub fn write(self: Self, index: usize, value: T) void {
            if (index >= self.len) {
                @panic("Buffer index out of bounds");
            }
            self.ptr[index] = value;
        }

        pub fn readSlice(self: Self, dest: []T, offset: usize, count: usize) void {
            if (offset + count > self.len or count > dest.len) {
                @panic("Buffer read out of bounds");
            }
            for (0..count) |i| {
                dest[i] = self.ptr[offset + i];
            }
        }

        pub fn writeSlice(self: Self, src: []const T, offset: usize) void {
            if (offset + src.len > self.len) {
                @panic("Buffer write out of bounds");
            }
            for (src, 0..) |value, i| {
                self.ptr[offset + i] = value;
            }
        }

        pub fn fill(self: Self, value: T) void {
            for (0..self.len) |i| {
                self.ptr[i] = value;
            }
        }

        pub fn getLength(self: Self) usize {
            return self.len;
        }
    };
}

// ============================================================================
// Volatile Operations Helper
// ============================================================================

pub const VolatileOps = struct {
    /// Read from volatile address
    pub fn read(comptime T: type, addr: usize) T {
        const ptr: *volatile T = @ptrFromInt(addr);
        return ptr.*;
    }

    /// Write to volatile address
    pub fn write(comptime T: type, addr: usize, value: T) void {
        const ptr: *volatile T = @ptrFromInt(addr);
        ptr.* = value;
    }

    /// Read-modify-write at volatile address
    pub fn modify(comptime T: type, addr: usize, comptime func: fn (T) T) void {
        const ptr: *volatile T = @ptrFromInt(addr);
        const old = ptr.*;
        const new = func(old);
        ptr.* = new;
    }

    /// Set bits at address
    pub fn setBits(comptime T: type, addr: usize, bits: T) void {
        if (@typeInfo(T) != .int) {
            @compileError("setBits requires integer type");
        }
        const old = read(T, addr);
        write(T, addr, old | bits);
    }

    /// Clear bits at address
    pub fn clearBits(comptime T: type, addr: usize, bits: T) void {
        if (@typeInfo(T) != .int) {
            @compileError("clearBits requires integer type");
        }
        const old = read(T, addr);
        write(T, addr, old & ~bits);
    }
};

// ============================================================================
// Common MMIO Patterns
// ============================================================================

pub const MmioPatterns = struct {
    /// Spin until register matches expected value
    pub fn spinUntilEqual(comptime T: type, reg: *volatile T, expected: T) void {
        while (reg.* != expected) {
            // Busy wait
        }
    }

    /// Spin until register bits are set
    pub fn spinUntilBitsSet(comptime T: type, reg: *volatile T, bits: T) void {
        while ((reg.* & bits) != bits) {
            // Busy wait
        }
    }

    /// Spin until register bits are clear
    pub fn spinUntilBitsClear(comptime T: type, reg: *volatile T, bits: T) void {
        while ((reg.* & bits) != 0) {
            // Busy wait
        }
    }

    /// Wait with timeout
    pub fn waitWithTimeout(comptime T: type, reg: *volatile T, expected: T, max_iterations: usize) bool {
        var iterations: usize = 0;
        while (reg.* != expected) : (iterations += 1) {
            if (iterations >= max_iterations) {
                return false; // Timeout
            }
        }
        return true; // Success
    }
};

// ============================================================================
// Tests
// ============================================================================

test "volatile wrapper basic operations" {
    const testing = std.testing;

    var value: u32 = 42;
    const volatile_val: *volatile u32 = &value;
    const vol = Volatile(u32).init(volatile_val);

    try testing.expectEqual(@as(u32, 42), vol.read());

    vol.write(100);
    try testing.expectEqual(@as(u32, 100), vol.read());
}

test "volatile modify" {
    const testing = std.testing;

    var value: u32 = 10;
    const volatile_val: *volatile u32 = &value;
    const vol = Volatile(u32).init(volatile_val);

    vol.modify(struct {
        fn double(v: u32) u32 {
            return v * 2;
        }
    }.double);

    try testing.expectEqual(@as(u32, 20), vol.read());
}

test "volatile bit operations" {
    const testing = std.testing;

    var value: u32 = 0;
    const volatile_val: *volatile u32 = &value;
    const vol = Volatile(u32).init(volatile_val);

    vol.setBits(0x0F);
    try testing.expectEqual(@as(u32, 0x0F), vol.read());
    try testing.expect(vol.testBits(0x0F));

    vol.clearBits(0x03);
    try testing.expectEqual(@as(u32, 0x0C), vol.read());
    try testing.expect(!vol.testBits(0x03));

    vol.toggleBits(0xFF);
    try testing.expectEqual(@as(u32, 0xF3), vol.read());
}

test "MMIO register" {
    const testing = std.testing;

    var backing: u32 = 0;
    const volatile_backing: *volatile u32 = &backing;
    const addr = @intFromPtr(volatile_backing);

    const reg = MmioRegister(u32).init(addr, "TEST_REG");
    reg.write(0x12345678);
    try testing.expectEqual(@as(u32, 0x12345678), reg.read());

    reg.setBits(0x0000000F);
    try testing.expectEqual(@as(u32, 0x1234567F), reg.read());
}

test "MMIO region" {
    const testing = std.testing;

    const region = MmioRegion.init(0x1000, 0x100, "TEST_REGION");

    try testing.expect(region.contains(0x1000));
    try testing.expect(region.contains(0x10FF));
    try testing.expect(!region.contains(0x0FFF));
    try testing.expect(!region.contains(0x1100));
}

test "volatile buffer" {
    const testing = std.testing;

    var backing = [_]u8{ 0, 0, 0, 0 };
    const volatile_backing: [*]volatile u8 = @ptrCast(&backing);
    const buf = VolatileBuffer(u8).init(volatile_backing, 4);

    buf.write(0, 0xAA);
    buf.write(1, 0xBB);
    try testing.expectEqual(@as(u8, 0xAA), buf.read(0));
    try testing.expectEqual(@as(u8, 0xBB), buf.read(1));

    buf.fill(0xFF);
    for (0..4) |i| {
        try testing.expectEqual(@as(u8, 0xFF), buf.read(i));
    }
}

test "volatile ops helpers" {
    const testing = std.testing;

    var value: u32 = 0;
    const volatile_val: *volatile u32 = &value;
    const addr = @intFromPtr(volatile_val);

    VolatileOps.write(u32, addr, 0x12345678);
    try testing.expectEqual(@as(u32, 0x12345678), VolatileOps.read(u32, addr));

    VolatileOps.setBits(u32, addr, 0x0F);
    try testing.expectEqual(@as(u32, 0x1234567F), VolatileOps.read(u32, addr));

    VolatileOps.clearBits(u32, addr, 0xFF);
    try testing.expectEqual(@as(u32, 0x12345600), VolatileOps.read(u32, addr));
}

test "MMIO patterns timeout" {
    const testing = std.testing;

    var value: u32 = 0;
    const volatile_val: *volatile u32 = &value;

    // Should timeout
    const success = MmioPatterns.waitWithTimeout(u32, volatile_val, 42, 10);
    try testing.expect(!success);

    // Should succeed
    value = 42;
    const success2 = MmioPatterns.waitWithTimeout(u32, volatile_val, 42, 10);
    try testing.expect(success2);
}

test "read-only register enforcement" {
    // Note: This test would panic in debug builds
    // Commenting out the actual panic-inducing code
    const testing = std.testing;

    var backing: u32 = 0;
    const volatile_backing: *volatile u32 = &backing;
    const addr = @intFromPtr(volatile_backing);

    const reg = MmioRegister(u32).initReadOnly(addr, "RO_REG");
    _ = reg.read(); // OK

    // reg.write(42); // Would panic
    try testing.expect(reg.read_only);
}

test "volatile buffer slice operations" {
    const testing = std.testing;

    var backing = [_]u8{ 0, 0, 0, 0 };
    const volatile_backing: [*]volatile u8 = @ptrCast(&backing);
    const buf = VolatileBuffer(u8).init(volatile_backing, 4);

    const src = [_]u8{ 0xAA, 0xBB };
    buf.writeSlice(&src, 1);

    try testing.expectEqual(@as(u8, 0x00), buf.read(0));
    try testing.expectEqual(@as(u8, 0xAA), buf.read(1));
    try testing.expectEqual(@as(u8, 0xBB), buf.read(2));

    var dest: [2]u8 = undefined;
    buf.readSlice(&dest, 1, 2);
    try testing.expectEqual(@as(u8, 0xAA), dest[0]);
    try testing.expectEqual(@as(u8, 0xBB), dest[1]);
}
