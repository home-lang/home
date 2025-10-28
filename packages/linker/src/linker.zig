// Home Programming Language - Linker Script Control System
// Comprehensive linker script generation and control for OS development
//
// Features:
// - Custom section placement
// - Symbol visibility control
// - Memory region definitions
// - Kernel/user space separation
// - Script generation
// - Validation and verification

const std = @import("std");

// ============================================================================
// Public API Exports
// ============================================================================

pub const LinkerScript = @import("script.zig").LinkerScript;
pub const MemoryRegion = @import("memory.zig").MemoryRegion;
pub const Section = @import("section.zig").Section;
pub const Symbol = @import("symbol.zig").Symbol;
pub const Validator = @import("validator.zig").Validator;
pub const Generator = @import("generator.zig").Generator;

// ============================================================================
// Memory Layout Types
// ============================================================================

pub const MemoryLayout = enum {
    Kernel,           // Kernel-only layout
    UserSpace,        // User-space only layout
    KernelUser,       // Kernel + user space
    Embedded,         // Embedded system layout
    HigherHalf,       // Higher-half kernel layout
    Custom,           // Fully custom layout
};

pub const AddressSpace = enum {
    Physical,         // Physical addresses
    Virtual,          // Virtual addresses
    HigherHalf,       // Higher-half kernel (0xffff800000000000+)
};

// ============================================================================
// Section Types
// ============================================================================

pub const SectionType = enum {
    Text,             // Executable code
    Rodata,           // Read-only data
    Data,             // Initialized data
    Bss,              // Uninitialized data
    TData,            // Thread-local initialized data
    Tbss,             // Thread-local uninitialized data
    Init,             // Initialization code
    Fini,             // Finalization code
    Debug,            // Debug information
    Custom,           // Custom section
};

pub const SectionFlags = packed struct {
    alloc: bool = false,        // Allocate space in memory
    load: bool = false,         // Load from file
    readonly: bool = false,     // Read-only
    code: bool = false,         // Contains code
    data: bool = false,         // Contains data
    executable: bool = false,   // Executable
    writable: bool = false,     // Writable
    tls: bool = false,          // Thread-local storage
};

// ============================================================================
// Symbol Types
// ============================================================================

pub const SymbolVisibility = enum {
    Local,            // File-local symbol
    Global,           // Globally visible
    Weak,             // Weak symbol (can be overridden)
    Hidden,           // Hidden (not exported)
    Protected,        // Protected (visible but not preemptible)
    Internal,         // Internal (not visible outside shared object)
};

pub const SymbolType = enum {
    NoType,           // Unspecified type
    Object,           // Data object
    Func,             // Function
    Section,          // Section symbol
    File,             // File name
    Common,           // Common data object
    Tls,              // Thread-local storage
};

// ============================================================================
// Memory Region Attributes
// ============================================================================

pub const MemoryAttributes = packed struct {
    readable: bool = true,
    writable: bool = false,
    executable: bool = false,
    cacheable: bool = true,
    device: bool = false,
    shared: bool = false,
};

// ============================================================================
// Alignment
// ============================================================================

pub const Alignment = enum(usize) {
    Byte = 1,
    Word = 2,
    DWord = 4,
    QWord = 8,
    Page = 4096,
    HugePage = 2 * 1024 * 1024,
    GigaPage = 1024 * 1024 * 1024,

    pub fn toBytes(self: Alignment) usize {
        return @intFromEnum(self);
    }

    pub fn fromBytes(bytes: usize) !Alignment {
        return switch (bytes) {
            1 => .Byte,
            2 => .Word,
            4 => .DWord,
            8 => .QWord,
            4096 => .Page,
            2 * 1024 * 1024 => .HugePage,
            1024 * 1024 * 1024 => .GigaPage,
            else => error.InvalidAlignment,
        };
    }

    pub fn alignAddress(self: Alignment, addr: u64) u64 {
        const align_bytes = self.toBytes();
        return (addr + align_bytes - 1) & ~(align_bytes - 1);
    }

    pub fn isAligned(self: Alignment, addr: u64) bool {
        return addr % self.toBytes() == 0;
    }
};

// ============================================================================
// Address Ranges
// ============================================================================

pub const AddressRange = struct {
    start: u64,
    end: u64,

    pub fn init(start: u64, end: u64) !AddressRange {
        if (start >= end) return error.InvalidRange;
        return .{ .start = start, .end = end };
    }

    pub fn size(self: AddressRange) u64 {
        return self.end - self.start;
    }

    pub fn contains(self: AddressRange, addr: u64) bool {
        return addr >= self.start and addr < self.end;
    }

    pub fn overlaps(self: AddressRange, other: AddressRange) bool {
        return self.start < other.end and other.start < self.end;
    }

    pub fn split(self: AddressRange, at: u64) ![2]AddressRange {
        if (!self.contains(at)) return error.SplitOutsideRange;
        return .{
            try AddressRange.init(self.start, at),
            try AddressRange.init(at, self.end),
        };
    }
};

// ============================================================================
// Standard Memory Layouts
// ============================================================================

pub const StandardLayouts = struct {
    /// x86-64 higher-half kernel layout
    pub fn x86_64_higher_half() MemoryLayout {
        // Kernel at -2GB (0xffff_ffff_8000_0000)
        return .HigherHalf;
    }

    /// x86-64 lower-half kernel layout
    pub fn x86_64_lower_half() MemoryLayout {
        // Kernel at 1MB (0x0010_0000)
        return .Kernel;
    }

    /// ARM64 kernel layout
    pub fn arm64_kernel() MemoryLayout {
        return .Kernel;
    }

    /// RISC-V kernel layout
    pub fn riscv_kernel() MemoryLayout {
        return .Kernel;
    }
};

// ============================================================================
// Common Address Constants
// ============================================================================

pub const CommonAddresses = struct {
    // x86-64 addresses
    pub const X86_64_KERNEL_BASE: u64 = 0x0010_0000; // 1MB
    pub const X86_64_HIGHER_HALF: u64 = 0xffff_8000_0000_0000; // -2GB
    pub const X86_64_USER_END: u64 = 0x0000_7fff_ffff_f000;

    // ARM64 addresses
    pub const ARM64_KERNEL_BASE: u64 = 0x0000_0000_0010_0000;
    pub const ARM64_USER_END: u64 = 0x0000_ffff_ffff_f000;

    // Page sizes
    pub const PAGE_4K: u64 = 4096;
    pub const PAGE_2M: u64 = 2 * 1024 * 1024;
    pub const PAGE_1G: u64 = 1024 * 1024 * 1024;
};

// ============================================================================
// Utility Functions
// ============================================================================

pub fn alignUp(addr: u64, alignment: Alignment) u64 {
    return alignment.alignAddress(addr);
}

pub fn alignDown(addr: u64, alignment: Alignment) u64 {
    const align_bytes = alignment.toBytes();
    return addr & ~(align_bytes - 1);
}

pub fn isAligned(addr: u64, alignment: Alignment) bool {
    return alignment.isAligned(addr);
}

// ============================================================================
// Tests
// ============================================================================

test "linker module imports" {
    // Verify all modules load
    _ = LinkerScript;
    _ = MemoryRegion;
    _ = Section;
    _ = Symbol;
}

test "alignment operations" {
    const testing = std.testing;

    // Align up
    try testing.expectEqual(@as(u64, 4096), alignUp(100, .Page));
    try testing.expectEqual(@as(u64, 4096), alignUp(4096, .Page));
    try testing.expectEqual(@as(u64, 8192), alignUp(4097, .Page));

    // Align down
    try testing.expectEqual(@as(u64, 0), alignDown(100, .Page));
    try testing.expectEqual(@as(u64, 4096), alignDown(4096, .Page));
    try testing.expectEqual(@as(u64, 4096), alignDown(4097, .Page));

    // Is aligned
    try testing.expect(!isAligned(100, .Page));
    try testing.expect(isAligned(4096, .Page));
    try testing.expect(!isAligned(4097, .Page));
}

test "address range operations" {
    const testing = std.testing;

    const range = try AddressRange.init(0x1000, 0x2000);

    try testing.expectEqual(@as(u64, 0x1000), range.size());
    try testing.expect(range.contains(0x1500));
    try testing.expect(!range.contains(0x2000));
    try testing.expect(!range.contains(0x500));

    const range2 = try AddressRange.init(0x1800, 0x2800);
    try testing.expect(range.overlaps(range2));

    const range3 = try AddressRange.init(0x3000, 0x4000);
    try testing.expect(!range.overlaps(range3));
}

test "address range split" {
    const testing = std.testing;

    const range = try AddressRange.init(0x1000, 0x3000);
    const split = try range.split(0x2000);

    try testing.expectEqual(@as(u64, 0x1000), split[0].start);
    try testing.expectEqual(@as(u64, 0x2000), split[0].end);
    try testing.expectEqual(@as(u64, 0x2000), split[1].start);
    try testing.expectEqual(@as(u64, 0x3000), split[1].end);
}

test "alignment enum conversion" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 1), Alignment.Byte.toBytes());
    try testing.expectEqual(@as(usize, 4096), Alignment.Page.toBytes());

    try testing.expectEqual(Alignment.Page, try Alignment.fromBytes(4096));
    try testing.expectError(error.InvalidAlignment, Alignment.fromBytes(3));
}

test "section flags" {
    const testing = std.testing;

    const flags = SectionFlags{
        .alloc = true,
        .load = true,
        .readonly = true,
        .code = true,
        .executable = true,
    };

    try testing.expect(flags.alloc);
    try testing.expect(flags.code);
    try testing.expect(!flags.writable);
}

test "memory attributes" {
    const testing = std.testing;

    const attrs = MemoryAttributes{
        .readable = true,
        .writable = true,
        .executable = false,
        .cacheable = true,
    };

    try testing.expect(attrs.readable);
    try testing.expect(attrs.writable);
    try testing.expect(!attrs.executable);
}
