// Home Programming Language - GDT Management
// Global Descriptor Table for x86_64 segmentation

const Basics = @import("basics");

// ============================================================================
// GDT Entry (Segment Descriptor)
// ============================================================================

pub const GdtEntry = packed struct(u64) {
    limit_low: u16,          // Limit bits 0-15
    base_low: u16,           // Base bits 0-15
    base_middle: u8,         // Base bits 16-23
    access: u8,              // Access byte
    limit_high_flags: u8,    // Limit bits 16-19 + flags
    base_high: u8,           // Base bits 24-31

    pub fn @"null"() GdtEntry {
        return @bitCast(@as(u64, 0));
    }

    pub fn code64(ring: u2) GdtEntry {
        return .{
            .limit_low = 0,
            .base_low = 0,
            .base_middle = 0,
            .access = 0x98 | (@as(u8, ring) << 5), // Present, Code, Executable, Readable
            .limit_high_flags = 0x20,              // 64-bit flag
            .base_high = 0,
        };
    }

    pub fn data64(ring: u2) GdtEntry {
        return .{
            .limit_low = 0,
            .base_low = 0,
            .base_middle = 0,
            .access = 0x92 | (@as(u8, ring) << 5), // Present, Data, Writable
            .limit_high_flags = 0x00,
            .base_high = 0,
        };
    }

    pub fn code32(base: u32, limit: u20, ring: u2) GdtEntry {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_middle = @truncate(base >> 16),
            .access = 0x9A | (@as(u8, ring) << 5),
            .limit_high_flags = 0xC0 | @as(u8, @truncate(limit >> 16)),
            .base_high = @truncate(base >> 24),
        };
    }

    pub fn data32(base: u32, limit: u20, ring: u2) GdtEntry {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_middle = @truncate(base >> 16),
            .access = 0x92 | (@as(u8, ring) << 5),
            .limit_high_flags = 0xC0 | @as(u8, @truncate(limit >> 16)),
            .base_high = @truncate(base >> 24),
        };
    }
};

comptime {
    if (@sizeOf(GdtEntry) != 8) {
        @compileError("GdtEntry must be 8 bytes");
    }
}

// ============================================================================
// TSS (Task State Segment) Descriptor
// ============================================================================

pub const TssDescriptor = packed struct(u128) {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: u8,
    limit_high_flags: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,

    pub fn init(tss: *const Tss) TssDescriptor {
        const base = @intFromPtr(tss);
        const limit = @sizeOf(Tss) - 1;

        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_middle = @truncate(base >> 16),
            .access = 0x89, // Present, Type=9 (Available 64-bit TSS)
            .limit_high_flags = @truncate(limit >> 16),
            .base_high = @truncate(base >> 24),
            .base_upper = @truncate(base >> 32),
            .reserved = 0,
        };
    }
};

comptime {
    if (@sizeOf(TssDescriptor) != 16) {
        @compileError("TssDescriptor must be 16 bytes");
    }
}

// ============================================================================
// TSS (Task State Segment)
// ============================================================================

pub const Tss = packed struct {
    reserved1: u32,
    rsp0: u64,               // Stack pointer for ring 0
    rsp1: u64,               // Stack pointer for ring 1
    rsp2: u64,               // Stack pointer for ring 2
    reserved2: u64,
    ist1: u64,               // Interrupt Stack Table 1
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    ist7: u64,
    reserved3: u64,
    reserved4: u16,
    iomap_base: u16,

    pub fn init() Tss {
        return Basics.mem.zeroes(Tss);
    }

    pub fn setKernelStack(self: *Tss, stack: u64) void {
        self.rsp0 = stack;
    }

    pub fn setInterruptStack(self: *Tss, index: u3, stack: u64) void {
        switch (index) {
            0 => self.ist1 = stack,
            1 => self.ist2 = stack,
            2 => self.ist3 = stack,
            3 => self.ist4 = stack,
            4 => self.ist5 = stack,
            5 => self.ist6 = stack,
            6 => self.ist7 = stack,
            else => {},
        }
    }
};

comptime {
    if (@sizeOf(Tss) != 104) {
        @compileError("TSS must be 104 bytes");
    }
}

// ============================================================================
// GDT Pointer
// ============================================================================

pub const GdtPointer = packed struct {
    limit: u16,
    base: u64,

    pub fn init(gdt: anytype) GdtPointer {
        const size = @sizeOf(@TypeOf(gdt.*));
        return .{
            .limit = @as(u16, @intCast(size - 1)),
            .base = @intFromPtr(gdt),
        };
    }
};

// ============================================================================
// Segment Selectors
// ============================================================================

pub const SegmentSelector = packed struct(u16) {
    rpl: u2,      // Requested Privilege Level
    ti: u1,       // Table Indicator (0=GDT, 1=LDT)
    index: u13,   // Index into descriptor table

    pub fn init(index: u13, ring: u2) SegmentSelector {
        return .{
            .rpl = ring,
            .ti = 0,
            .index = index,
        };
    }

    pub fn toU16(self: SegmentSelector) u16 {
        return @bitCast(self);
    }
};

// Common selectors
pub const KERNEL_CODE_SELECTOR = SegmentSelector.init(1, 0).toU16();
pub const KERNEL_DATA_SELECTOR = SegmentSelector.init(2, 0).toU16();
pub const USER_CODE_SELECTOR = SegmentSelector.init(3, 3).toU16();
pub const USER_DATA_SELECTOR = SegmentSelector.init(4, 3).toU16();
pub const TSS_SELECTOR = SegmentSelector.init(5, 0).toU16();

// ============================================================================
// GDT Management
// ============================================================================

pub const Gdt = struct {
    entries: []align(16) u64,
    tss: *Tss,
    pointer: GdtPointer,

    pub fn init(allocator: Basics.Allocator) !Gdt {
        // Allocate GDT entries (8 entries for basic setup)
        // 0: Null
        // 1: Kernel Code
        // 2: Kernel Data
        // 3: User Code
        // 4: User Data
        // 5-6: TSS (2 entries, 16 bytes)
        // 7: Reserved

        const entries = try allocator.alignedAlloc(u64, 16, 8);
        errdefer allocator.free(entries);

        const tss = try allocator.create(Tss);
        errdefer allocator.destroy(tss);

        tss.* = Tss.init();

        var gdt = Gdt{
            .entries = entries,
            .tss = tss,
            .pointer = undefined,
        };

        // Setup entries
        const gdt_entries: [*]GdtEntry = @ptrCast(entries.ptr);
        gdt_entries[0] = GdtEntry.@"null"();
        gdt_entries[1] = GdtEntry.code64(0); // Kernel code
        gdt_entries[2] = GdtEntry.data64(0); // Kernel data
        gdt_entries[3] = GdtEntry.code64(3); // User code
        gdt_entries[4] = GdtEntry.data64(3); // User data

        // Setup TSS descriptor (takes 2 entries)
        const tss_desc = TssDescriptor.init(tss);
        const tss_ptr: *TssDescriptor = @ptrCast(&entries[5]);
        tss_ptr.* = tss_desc;

        gdt.pointer = GdtPointer.init(&gdt.entries);

        return gdt;
    }

    pub fn deinit(self: *Gdt, allocator: Basics.Allocator) void {
        allocator.destroy(self.tss);
        allocator.free(self.entries);
    }

    /// Load GDT and reload segment registers
    pub fn load(self: *Gdt) void {
        // Load GDT
        asm volatile ("lgdt (%[ptr])"
            :
            : [ptr] "r" (&self.pointer),
            : .{ .memory = true }
        );

        // Reload CS (code segment)
        asm volatile (
            \\pushq %[sel]
            \\leaq 1f(%%rip), %%rax
            \\pushq %%rax
            \\lretq
            \\1:
            :
            : [sel] "i" (KERNEL_CODE_SELECTOR),
            : .{ .rax = true, .memory = true }
        );

        // Reload data segments
        asm volatile (
            \\mov %[sel], %%ax
            \\mov %%ax, %%ds
            \\mov %%ax, %%es
            \\mov %%ax, %%ss
            :
            : [sel] "i" (KERNEL_DATA_SELECTOR),
            : .{ .rax = true }
        );

        // Clear FS and GS (for per-CPU data)
        asm volatile (
            \\xor %%ax, %%ax
            \\mov %%ax, %%fs
            \\mov %%ax, %%gs
            :
            :
            : .{ .rax = true }
        );
    }

    /// Load TSS
    pub fn loadTss(self: *Gdt) void {
        _ = self;
        asm volatile ("ltr %[sel]"
            :
            : [sel] "r" (@as(u16, TSS_SELECTOR)),
        );
    }

    /// Set kernel stack for privilege transitions
    pub fn setKernelStack(self: *Gdt, stack: u64) void {
        self.tss.setKernelStack(stack);
    }

    /// Set interrupt stack
    pub fn setInterruptStack(self: *Gdt, index: u3, stack: u64) void {
        self.tss.setInterruptStack(index, stack);
    }
};

// ============================================================================
// Privilege Level Checking
// ============================================================================

pub fn getCurrentPrivilegeLevel() u2 {
    const cs = asm volatile ("mov %%cs, %[result]"
        : [result] "=r" (-> u16),
    );
    return @truncate(cs & 0x3);
}

pub fn isKernelMode() bool {
    return getCurrentPrivilegeLevel() == 0;
}

pub fn isUserMode() bool {
    return getCurrentPrivilegeLevel() == 3;
}

// Tests
test "gdt entry size" {
    try Basics.testing.expectEqual(@as(usize, 8), @sizeOf(GdtEntry));
}

test "tss descriptor size" {
    try Basics.testing.expectEqual(@as(usize, 16), @sizeOf(TssDescriptor));
}

test "tss size" {
    try Basics.testing.expectEqual(@as(usize, 104), @sizeOf(Tss));
}

test "segment selector" {
    const sel = SegmentSelector.init(1, 0);
    try Basics.testing.expectEqual(@as(u2, 0), sel.rpl);
    try Basics.testing.expectEqual(@as(u1, 0), sel.ti);
    try Basics.testing.expectEqual(@as(u13, 1), sel.index);
}

test "null descriptor" {
    const null_desc = GdtEntry.@"null"();
    const value: u64 = @bitCast(null_desc);
    try Basics.testing.expectEqual(@as(u64, 0), value);
}

test "code64 descriptor" {
    const code = GdtEntry.code64(0);
    try Basics.testing.expectEqual(@as(u8, 0x98), code.access);
    try Basics.testing.expectEqual(@as(u8, 0x20), code.limit_high_flags);
}
