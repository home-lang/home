// Home Programming Language - Multiboot2 Specification
// Bootloader Interface for GRUB2 and other Multiboot2-compliant bootloaders
//
// Reference: https://www.gnu.org/software/grub/manual/multiboot2/multiboot.html

const std = @import("std");

// ============================================================================
// Multiboot2 Magic Numbers
// ============================================================================

/// Magic number for Multiboot2 header (must be in first 32KB of kernel)
pub const MULTIBOOT2_HEADER_MAGIC: u32 = 0xe85250d6;

/// Magic number passed by bootloader in EAX register
pub const MULTIBOOT2_BOOTLOADER_MAGIC: u32 = 0x36d76289;

/// Architecture: x86 (32-bit protected mode)
pub const MULTIBOOT2_ARCHITECTURE_I386: u32 = 0;

/// Architecture: MIPS
pub const MULTIBOOT2_ARCHITECTURE_MIPS32: u32 = 4;

// ============================================================================
// Multiboot2 Header Tag Types
// ============================================================================

pub const MULTIBOOT_HEADER_TAG_END: u16 = 0;
pub const MULTIBOOT_HEADER_TAG_INFORMATION_REQUEST: u16 = 1;
pub const MULTIBOOT_HEADER_TAG_ADDRESS: u16 = 2;
pub const MULTIBOOT_HEADER_TAG_ENTRY_ADDRESS: u16 = 3;
pub const MULTIBOOT_HEADER_TAG_CONSOLE_FLAGS: u16 = 4;
pub const MULTIBOOT_HEADER_TAG_FRAMEBUFFER: u16 = 5;
pub const MULTIBOOT_HEADER_TAG_MODULE_ALIGN: u16 = 6;
pub const MULTIBOOT_HEADER_TAG_EFI_BS: u16 = 7;
pub const MULTIBOOT_HEADER_TAG_ENTRY_ADDRESS_EFI32: u16 = 8;
pub const MULTIBOOT_HEADER_TAG_ENTRY_ADDRESS_EFI64: u16 = 9;
pub const MULTIBOOT_HEADER_TAG_RELOCATABLE: u16 = 10;

// ============================================================================
// Multiboot2 Information Tag Types
// ============================================================================

pub const MULTIBOOT_TAG_TYPE_END: u32 = 0;
pub const MULTIBOOT_TAG_TYPE_CMDLINE: u32 = 1;
pub const MULTIBOOT_TAG_TYPE_BOOT_LOADER_NAME: u32 = 2;
pub const MULTIBOOT_TAG_TYPE_MODULE: u32 = 3;
pub const MULTIBOOT_TAG_TYPE_BASIC_MEMINFO: u32 = 4;
pub const MULTIBOOT_TAG_TYPE_BOOTDEV: u32 = 5;
pub const MULTIBOOT_TAG_TYPE_MMAP: u32 = 6;
pub const MULTIBOOT_TAG_TYPE_VBE: u32 = 7;
pub const MULTIBOOT_TAG_TYPE_FRAMEBUFFER: u32 = 8;
pub const MULTIBOOT_TAG_TYPE_ELF_SECTIONS: u32 = 9;
pub const MULTIBOOT_TAG_TYPE_APM: u32 = 10;
pub const MULTIBOOT_TAG_TYPE_EFI32: u32 = 11;
pub const MULTIBOOT_TAG_TYPE_EFI64: u32 = 12;
pub const MULTIBOOT_TAG_TYPE_SMBIOS: u32 = 13;
pub const MULTIBOOT_TAG_TYPE_ACPI_OLD: u32 = 14;
pub const MULTIBOOT_TAG_TYPE_ACPI_NEW: u32 = 15;
pub const MULTIBOOT_TAG_TYPE_NETWORK: u32 = 16;
pub const MULTIBOOT_TAG_TYPE_EFI_MMAP: u32 = 17;
pub const MULTIBOOT_TAG_TYPE_EFI_BS: u32 = 18;
pub const MULTIBOOT_TAG_TYPE_EFI32_IH: u32 = 19;
pub const MULTIBOOT_TAG_TYPE_EFI64_IH: u32 = 20;
pub const MULTIBOOT_TAG_TYPE_LOAD_BASE_ADDR: u32 = 21;

// ============================================================================
// Memory Map Entry Types
// ============================================================================

pub const MULTIBOOT_MEMORY_AVAILABLE: u32 = 1;
pub const MULTIBOOT_MEMORY_RESERVED: u32 = 2;
pub const MULTIBOOT_MEMORY_ACPI_RECLAIMABLE: u32 = 3;
pub const MULTIBOOT_MEMORY_NVS: u32 = 4;
pub const MULTIBOOT_MEMORY_BADRAM: u32 = 5;

// ============================================================================
// Framebuffer Types
// ============================================================================

pub const MULTIBOOT_FRAMEBUFFER_TYPE_INDEXED: u8 = 0;
pub const MULTIBOOT_FRAMEBUFFER_TYPE_RGB: u8 = 1;
pub const MULTIBOOT_FRAMEBUFFER_TYPE_EGA_TEXT: u8 = 2;

// ============================================================================
// Header Structures
// ============================================================================

/// Multiboot2 header - must be present in first 32KB of kernel image
pub const Multiboot2Header = extern struct {
    /// Magic number (MULTIBOOT2_HEADER_MAGIC)
    magic: u32,
    /// Architecture (0 = i386)
    architecture: u32,
    /// Header length (in bytes)
    header_length: u32,
    /// Checksum: -(magic + architecture + header_length)
    checksum: u32,

    /// Calculate checksum for header
    pub fn calculateChecksum(arch: u32, length: u32) u32 {
        return @as(u32, @bitCast(-%@as(i32, @bitCast(MULTIBOOT2_HEADER_MAGIC + arch + length))));
    }
};

/// Base structure for all header tags
pub const Multiboot2HeaderTag = extern struct {
    type: u16,
    flags: u16,
    size: u32,
};

/// End tag for header
pub const Multiboot2HeaderTagEnd = extern struct {
    type: u16 = MULTIBOOT_HEADER_TAG_END,
    flags: u16 = 0,
    size: u32 = 8,
};

/// Information request tag
pub const Multiboot2HeaderTagInformationRequest = extern struct {
    type: u16 = MULTIBOOT_HEADER_TAG_INFORMATION_REQUEST,
    flags: u16 = 0,
    size: u32,
    // Followed by array of u32 request types
};

/// Framebuffer tag
pub const Multiboot2HeaderTagFramebuffer = extern struct {
    type: u16 = MULTIBOOT_HEADER_TAG_FRAMEBUFFER,
    flags: u16 = 0,
    size: u32 = 20,
    width: u32,
    height: u32,
    depth: u32,
};

/// Module alignment tag
pub const Multiboot2HeaderTagModuleAlign = extern struct {
    type: u16 = MULTIBOOT_HEADER_TAG_MODULE_ALIGN,
    flags: u16 = 0,
    size: u32 = 8,
};

// ============================================================================
// Boot Information Structures
// ============================================================================

/// Base structure for all information tags
pub const Multiboot2Tag = extern struct {
    type: u32,
    size: u32,
};

/// Command line arguments
pub const Multiboot2TagString = extern struct {
    type: u32,
    size: u32,
    // Followed by null-terminated string

    pub fn getString(self: *const Multiboot2TagString) []const u8 {
        const ptr: [*]const u8 = @ptrCast(@as([*]const u8, @ptrCast(self)) + @sizeOf(Multiboot2TagString));
        const len = self.size - @sizeOf(Multiboot2TagString) - 1; // -1 for null terminator
        return ptr[0..len];
    }
};

/// Basic memory information
pub const Multiboot2TagBasicMeminfo = extern struct {
    type: u32,
    size: u32,
    mem_lower: u32, // KB of lower memory
    mem_upper: u32, // KB of upper memory
};

/// Boot device information
pub const Multiboot2TagBootdev = extern struct {
    type: u32,
    size: u32,
    biosdev: u32,
    partition: u32,
    sub_partition: u32,
};

/// Memory map entry
pub const Multiboot2MmapEntry = extern struct {
    base_addr: u64,
    length: u64,
    type: u32,
    reserved: u32 = 0,
};

/// Memory map tag
pub const Multiboot2TagMmap = extern struct {
    type: u32,
    size: u32,
    entry_size: u32,
    entry_version: u32,
    // Followed by array of Multiboot2MmapEntry

    pub fn entries(self: *const Multiboot2TagMmap) []const Multiboot2MmapEntry {
        const count = (self.size - @sizeOf(Multiboot2TagMmap)) / self.entry_size;
        const ptr: [*]const Multiboot2MmapEntry = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(self)) + @sizeOf(Multiboot2TagMmap)));
        return ptr[0..count];
    }
};

/// ELF sections tag
pub const Multiboot2TagElfSections = extern struct {
    type: u32,
    size: u32,
    num: u32,
    entsize: u32,
    shndx: u32,
    // Followed by section headers
};

/// Framebuffer common info
pub const Multiboot2TagFramebufferCommon = extern struct {
    type: u32,
    size: u32,
    framebuffer_addr: u64,
    framebuffer_pitch: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_bpp: u8,
    framebuffer_type: u8,
    reserved: u16,
};

/// EFI 32-bit system table pointer
pub const Multiboot2TagEfi32 = extern struct {
    type: u32,
    size: u32,
    pointer: u32,
};

/// EFI 64-bit system table pointer
pub const Multiboot2TagEfi64 = extern struct {
    type: u32,
    size: u32,
    pointer: u64,
};

/// ACPI RSDP (old)
pub const Multiboot2TagOldAcpi = extern struct {
    type: u32,
    size: u32,
    // Followed by ACPI RSDP v1
};

/// ACPI RSDP (new)
pub const Multiboot2TagNewAcpi = extern struct {
    type: u32,
    size: u32,
    // Followed by ACPI RSDP v2+
};

/// Load base physical address
pub const Multiboot2TagLoadBaseAddr = extern struct {
    type: u32,
    size: u32,
    load_base_addr: u32,
};

// ============================================================================
// Boot Information Parser
// ============================================================================

pub const Multiboot2Info = struct {
    total_size: u32,
    reserved: u32 = 0,
    first_tag: *const Multiboot2Tag,

    pub fn fromAddress(addr: usize) Multiboot2Info {
        const ptr: *const u32 = @ptrFromInt(addr);
        const total_size = ptr[0];
        const tag_ptr: *const Multiboot2Tag = @ptrFromInt(addr + 8);

        return Multiboot2Info{
            .total_size = total_size,
            .first_tag = tag_ptr,
        };
    }

    /// Find a specific tag by type
    pub fn findTag(self: *const Multiboot2Info, tag_type: u32) ?*const Multiboot2Tag {
        var tag = self.first_tag;
        const end_addr = @intFromPtr(self.first_tag) + self.total_size - 8;

        while (@intFromPtr(tag) < end_addr) {
            if (tag.type == MULTIBOOT_TAG_TYPE_END) {
                return null;
            }
            if (tag.type == tag_type) {
                return tag;
            }

            // Move to next tag (8-byte aligned)
            const next_addr = @intFromPtr(tag) + ((tag.size + 7) & ~@as(usize, 7));
            tag = @ptrFromInt(next_addr);
        }

        return null;
    }

    /// Get command line string
    pub fn getCommandLine(self: *const Multiboot2Info) ?[]const u8 {
        if (self.findTag(MULTIBOOT_TAG_TYPE_CMDLINE)) |tag| {
            const cmdline: *const Multiboot2TagString = @ptrCast(tag);
            return cmdline.getString();
        }
        return null;
    }

    /// Get bootloader name
    pub fn getBootloaderName(self: *const Multiboot2Info) ?[]const u8 {
        if (self.findTag(MULTIBOOT_TAG_TYPE_BOOT_LOADER_NAME)) |tag| {
            const bootloader: *const Multiboot2TagString = @ptrCast(tag);
            return bootloader.getString();
        }
        return null;
    }

    /// Get memory map
    pub fn getMemoryMap(self: *const Multiboot2Info) ?*const Multiboot2TagMmap {
        if (self.findTag(MULTIBOOT_TAG_TYPE_MMAP)) |tag| {
            return @ptrCast(@alignCast(tag));
        }
        return null;
    }

    /// Get basic memory info
    pub fn getBasicMeminfo(self: *const Multiboot2Info) ?*const Multiboot2TagBasicMeminfo {
        if (self.findTag(MULTIBOOT_TAG_TYPE_BASIC_MEMINFO)) |tag| {
            return @ptrCast(@alignCast(tag));
        }
        return null;
    }

    /// Get framebuffer info
    pub fn getFramebuffer(self: *const Multiboot2Info) ?*const Multiboot2TagFramebufferCommon {
        if (self.findTag(MULTIBOOT_TAG_TYPE_FRAMEBUFFER)) |tag| {
            return @ptrCast(@alignCast(tag));
        }
        return null;
    }

    /// Iterate through all tags
    pub fn iterateTags(self: *const Multiboot2Info) TagIterator {
        return TagIterator{
            .current = self.first_tag,
            .end_addr = @intFromPtr(self.first_tag) + self.total_size - 8,
        };
    }
};

pub const TagIterator = struct {
    current: *const Multiboot2Tag,
    end_addr: usize,

    pub fn next(self: *TagIterator) ?*const Multiboot2Tag {
        if (@intFromPtr(self.current) >= self.end_addr) {
            return null;
        }

        if (self.current.type == MULTIBOOT_TAG_TYPE_END) {
            return null;
        }

        const tag = self.current;

        // Move to next tag (8-byte aligned)
        const next_addr = @intFromPtr(self.current) + ((self.current.size + 7) & ~@as(usize, 7));
        self.current = @ptrFromInt(next_addr);

        return tag;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Verify Multiboot2 magic number
pub fn verifyMagic(magic: u32) bool {
    return magic == MULTIBOOT2_BOOTLOADER_MAGIC;
}

/// Get human-readable memory type name
pub fn getMemoryTypeName(mem_type: u32) []const u8 {
    return switch (mem_type) {
        MULTIBOOT_MEMORY_AVAILABLE => "Available",
        MULTIBOOT_MEMORY_RESERVED => "Reserved",
        MULTIBOOT_MEMORY_ACPI_RECLAIMABLE => "ACPI Reclaimable",
        MULTIBOOT_MEMORY_NVS => "ACPI NVS",
        MULTIBOOT_MEMORY_BADRAM => "Bad RAM",
        else => "Unknown",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "multiboot2 magic numbers" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0xe85250d6), MULTIBOOT2_HEADER_MAGIC);
    try testing.expectEqual(@as(u32, 0x36d76289), MULTIBOOT2_BOOTLOADER_MAGIC);
}

test "multiboot2 header checksum" {
    const testing = std.testing;
    const arch = MULTIBOOT2_ARCHITECTURE_I386;
    const length: u32 = 24;
    const checksum = Multiboot2Header.calculateChecksum(arch, length);

    // Verify that magic + arch + length + checksum == 0 (wrapping arithmetic)
    const sum = MULTIBOOT2_HEADER_MAGIC +% arch +% length +% checksum;
    try testing.expectEqual(@as(u32, 0), sum);
}

test "multiboot2 struct sizes" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 16), @sizeOf(Multiboot2Header));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Multiboot2HeaderTag));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Multiboot2Tag));
    try testing.expectEqual(@as(usize, 24), @sizeOf(Multiboot2MmapEntry));
}
