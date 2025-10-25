// Home Programming Language - OS-Specific Types
// Type-safe wrappers for OS development

const Basics = @import("basics");

// ============================================================================
// I/O Port Types
// ============================================================================

/// Compile-time I/O port with address
pub fn IoPort(comptime T: type, comptime address: u16) type {
    return struct {
        pub const Address = address;
        pub const DataType = T;

        /// Read from port
        pub inline fn read() T {
            return switch (T) {
                u8 => asm volatile ("inb %[port], %[result]"
                    : [result] "={al}" (-> u8),
                    : [port] "N{dx}" (address),
                ),
                u16 => asm volatile ("inw %[port], %[result]"
                    : [result] "={ax}" (-> u16),
                    : [port] "N{dx}" (address),
                ),
                u32 => asm volatile ("inl %[port], %[result]"
                    : [result] "={eax}" (-> u32),
                    : [port] "N{dx}" (address),
                ),
                else => @compileError("IoPort only supports u8, u16, u32"),
            };
        }

        /// Write to port
        pub inline fn write(value: T) void {
            switch (T) {
                u8 => asm volatile ("outb %[value], %[port]"
                    :
                    : [value] "{al}" (value),
                      [port] "N{dx}" (address),
                ),
                u16 => asm volatile ("outw %[value], %[port]"
                    :
                    : [value] "{ax}" (value),
                      [port] "N{dx}" (address),
                ),
                u32 => asm volatile ("outl %[value], %[port]"
                    :
                    : [value] "{eax}" (value),
                      [port] "N{dx}" (address),
                ),
                else => @compileError("IoPort only supports u8, u16, u32"),
            }
        }

        /// Wait (I/O delay)
        pub inline fn wait() void {
            // Port 0x80 is used for POST codes, reading it causes a delay
            asm volatile ("outb %%al, $0x80"
                :
                : [_] "{al}" (@as(u8, 0)),
            );
        }
    };
}

// ============================================================================
// Physical Address Types
// ============================================================================

/// Physical memory address (distinct from virtual)
pub const PhysicalAddress = packed struct {
    value: u64,

    pub fn init(addr: u64) PhysicalAddress {
        return .{ .value = addr };
    }

    pub fn toU64(self: PhysicalAddress) u64 {
        return self.value;
    }

    pub fn add(self: PhysicalAddress, offset: u64) PhysicalAddress {
        return .{ .value = self.value + offset };
    }

    pub fn alignDown(self: PhysicalAddress, alignment: u64) PhysicalAddress {
        return .{ .value = self.value & ~(alignment - 1) };
    }

    pub fn alignUp(self: PhysicalAddress, alignment: u64) PhysicalAddress {
        return .{ .value = (self.value + alignment - 1) & ~(alignment - 1) };
    }

    pub fn isAligned(self: PhysicalAddress, alignment: u64) bool {
        return (self.value & (alignment - 1)) == 0;
    }

    pub fn format(
        self: PhysicalAddress,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("PhysAddr(0x{x})", .{self.value});
    }
};

/// Virtual memory address
pub const VirtualAddress = packed struct {
    value: u64,

    pub fn init(addr: u64) VirtualAddress {
        return .{ .value = addr };
    }

    pub fn toU64(self: VirtualAddress) u64 {
        return self.value;
    }

    pub fn toPtr(self: VirtualAddress, comptime T: type) *T {
        return @ptrFromInt(self.value);
    }

    pub fn add(self: VirtualAddress, offset: u64) VirtualAddress {
        return .{ .value = self.value + offset };
    }

    pub fn alignDown(self: VirtualAddress, alignment: u64) VirtualAddress {
        return .{ .value = self.value & ~(alignment - 1) };
    }

    pub fn alignUp(self: VirtualAddress, alignment: u64) VirtualAddress {
        return .{ .value = (self.value + alignment - 1) & ~(alignment - 1) };
    }

    pub fn format(
        self: VirtualAddress,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("VirtAddr(0x{x})", .{self.value});
    }
};

/// Physical pointer (distinct from virtual pointer)
pub fn PhysicalPtr(comptime T: type) type {
    return struct {
        address: PhysicalAddress,

        pub fn init(addr: PhysicalAddress) @This() {
            return .{ .address = addr };
        }

        pub fn fromU64(addr: u64) @This() {
            return .{ .address = PhysicalAddress.init(addr) };
        }

        pub fn toPhysicalAddress(self: @This()) PhysicalAddress {
            return self.address;
        }

        pub fn offset(self: @This(), n: isize) @This() {
            const stride = @sizeOf(T);
            const byte_offset = @as(i64, n) * @as(i64, stride);
            return .{ .address = PhysicalAddress.init(@intCast(@as(i64, @intCast(self.address.value)) + byte_offset)) };
        }
    };
}

// ============================================================================
// Volatile Types (for MMIO)
// ============================================================================

/// Volatile wrapper for MMIO registers
pub fn Volatile(comptime T: type) type {
    return struct {
        value: *volatile T,

        pub fn init(addr: usize) @This() {
            return .{ .value = @ptrFromInt(addr) };
        }

        pub fn read(self: @This()) T {
            return self.value.*;
        }

        pub fn write(self: @This(), value: T) void {
            self.value.* = value;
        }

        pub fn modify(self: @This(), comptime func: fn (T) T) void {
            const current = self.read();
            const new_value = func(current);
            self.write(new_value);
        }

        pub fn setBits(self: @This(), mask: T) void {
            self.modify(struct {
                fn set(val: T) T {
                    return val | mask;
                }
            }.set);
        }

        pub fn clearBits(self: @This(), mask: T) void {
            self.modify(struct {
                fn clear(val: T) T {
                    return val & ~mask;
                }
            }.clear);
        }

        pub fn toggleBits(self: @This(), mask: T) void {
            self.modify(struct {
                fn toggle(val: T) T {
                    return val ^ mask;
                }
            }.toggle);
        }
    };
}

/// MMIO register with specific address
pub fn MmioRegister(comptime T: type, comptime address: u64) type {
    return struct {
        pub const Address = address;
        pub const DataType = T;

        const register = Volatile(T).init(address);

        pub inline fn read() T {
            return register.read();
        }

        pub inline fn write(value: T) void {
            register.write(value);
        }

        pub inline fn modify(comptime func: fn (T) T) void {
            register.modify(func);
        }

        pub inline fn setBits(mask: T) void {
            register.setBits(mask);
        }

        pub inline fn clearBits(mask: T) void {
            register.clearBits(mask);
        }
    };
}

// ============================================================================
// Aligned Types
// ============================================================================

/// Type with compile-time alignment guarantee
pub fn Aligned(comptime T: type, comptime alignment: usize) type {
    return struct {
        data: T align(alignment),

        pub fn init(value: T) @This() {
            return .{ .data = value };
        }

        pub fn get(self: *const @This()) T {
            return self.data;
        }

        pub fn set(self: *@This(), value: T) void {
            self.data = value;
        }

        pub fn getPtr(self: *@This()) *T {
            return &self.data;
        }

        pub fn getAlignment() usize {
            return alignment;
        }
    };
}

/// Page-aligned type (4KB alignment)
pub fn PageAligned(comptime T: type) type {
    return Aligned(T, 4096);
}

// ============================================================================
// DMA Buffer Types
// ============================================================================

/// DMA-safe buffer (physically contiguous, properly aligned)
pub fn DmaBuffer(comptime T: type) type {
    return struct {
        physical_address: PhysicalAddress,
        virtual_address: VirtualAddress,
        length: usize,

        pub fn init(phys: PhysicalAddress, virt: VirtualAddress, len: usize) @This() {
            return .{
                .physical_address = phys,
                .virtual_address = virt,
                .length = len,
            };
        }

        pub fn getPhysical(self: @This()) PhysicalAddress {
            return self.physical_address;
        }

        pub fn getVirtual(self: @This()) VirtualAddress {
            return self.virtual_address;
        }

        pub fn asSlice(self: @This()) []T {
            const ptr: [*]T = @ptrFromInt(self.virtual_address.value);
            return ptr[0..self.length];
        }

        pub fn asVolatileSlice(self: @This()) []volatile T {
            const ptr: [*]volatile T = @ptrFromInt(self.virtual_address.value);
            return ptr[0..self.length];
        }
    };
}

// ============================================================================
// Bit Field Types
// ============================================================================

/// Bit field for register manipulation
pub fn BitField(comptime T: type, comptime shift: comptime_int, comptime width: comptime_int) type {
    const mask = (@as(T, 1) << width) - 1;

    return struct {
        pub fn get(value: T) T {
            return (value >> shift) & mask;
        }

        pub fn set(value: T, field_value: T) T {
            return (value & ~(mask << shift)) | ((field_value & mask) << shift);
        }

        pub fn mask() T {
            return mask << shift;
        }
    };
}

// ============================================================================
// Type-Safe Handles
// ============================================================================

/// Type-safe handle (prevents mixing different handle types)
pub fn Handle(comptime name: []const u8, comptime T: type) type {
    return struct {
        value: T,

        pub const Name = name;

        pub fn init(value: T) @This() {
            return .{ .value = value };
        }

        pub fn toRaw(self: @This()) T {
            return self.value;
        }

        pub fn isValid(self: @This()) bool {
            return self.value != 0;
        }

        pub fn invalid() @This() {
            return .{ .value = 0 };
        }
    };
}

// Common handle types
pub const ProcessHandle = Handle("Process", u32);
pub const ThreadHandle = Handle("Thread", u32);
pub const FileHandle = Handle("File", u32);

// ============================================================================
// Tests
// ============================================================================

test "I/O port type safety" {
    const SerialPort = IoPort(u8, 0x3F8);

    try Basics.testing.expectEqual(@as(u16, 0x3F8), SerialPort.Address);
    try Basics.testing.expectEqual(u8, SerialPort.DataType);
}

test "physical vs virtual addresses" {
    const phys = PhysicalAddress.init(0x1000);
    const virt = VirtualAddress.init(0xFFFF800000001000);

    try Basics.testing.expectEqual(@as(u64, 0x1000), phys.toU64());
    try Basics.testing.expectEqual(@as(u64, 0xFFFF800000001000), virt.toU64());

    // These are different types, cannot be mixed
    // const mixed = phys == virt; // Compile error!
}

test "aligned types" {
    const PageBuffer = PageAligned([4096]u8);
    var buffer = PageBuffer.init([_]u8{0} ** 4096);

    try Basics.testing.expectEqual(@as(usize, 4096), PageBuffer.getAlignment());
    try Basics.testing.expectEqual(@as(usize, 0), @intFromPtr(buffer.getPtr()) % 4096);
}

test "bit fields" {
    const StatusBit = BitField(u32, 0, 1);
    const CountField = BitField(u32, 8, 8);

    var value: u32 = 0;
    value = StatusBit.set(value, 1);
    value = CountField.set(value, 42);

    try Basics.testing.expectEqual(@as(u32, 1), StatusBit.get(value));
    try Basics.testing.expectEqual(@as(u32, 42), CountField.get(value));
}

test "type-safe handles" {
    const proc_handle = ProcessHandle.init(123);
    const thread_handle = ThreadHandle.init(456);

    try Basics.testing.expect(proc_handle.isValid());
    try Basics.testing.expectEqual(@as(u32, 123), proc_handle.toRaw());

    // These are different types, cannot be mixed
    // const mixed = proc_handle == thread_handle; // Compile error!
}

test "volatile register operations" {
    var dummy: u32 = 0;
    const reg = Volatile(u32).init(@intFromPtr(&dummy));

    reg.write(0x12345678);
    try Basics.testing.expectEqual(@as(u32, 0x12345678), reg.read());

    reg.setBits(0x0000000F);
    try Basics.testing.expectEqual(@as(u32, 0x1234567F), reg.read());

    reg.clearBits(0x000000F0);
    try Basics.testing.expectEqual(@as(u32, 0x1234560F), reg.read());
}
