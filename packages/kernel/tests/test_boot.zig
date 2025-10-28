// Home Programming Language - Bootloader Tests
// Comprehensive tests for Multiboot2 and boot components

const std = @import("std");
const testing = std.testing;

// Test files need direct import access for Zig build system
const multiboot2_module = @import("multiboot2");

// Create a simple wrapper to expose the multiboot2 module
const multiboot2 = struct {
    pub usingnamespace multiboot2_module;
};

// ============================================================================
// Multiboot2 Header Tests
// ============================================================================

test "multiboot2: magic number is correct" {
    try testing.expectEqual(@as(u32, 0xe85250d6), multiboot2.MULTIBOOT2_HEADER_MAGIC);
}

test "multiboot2: bootloader magic is correct" {
    try testing.expectEqual(@as(u32, 0x36d76289), multiboot2.MULTIBOOT2_BOOTLOADER_MAGIC);
}

test "multiboot2: architecture constants" {
    try testing.expectEqual(@as(u32, 0), multiboot2.MULTIBOOT2_ARCHITECTURE_I386);
    try testing.expectEqual(@as(u32, 4), multiboot2.MULTIBOOT2_ARCHITECTURE_MIPS32);
}

test "multiboot2: header checksum calculation" {
    const arch = multiboot2.MULTIBOOT2_ARCHITECTURE_I386;
    const length: u32 = 24;
    const checksum = multiboot2.Multiboot2Header.calculateChecksum(arch, length);

    // Verify that magic + arch + length + checksum == 0
    const sum: i32 = @bitCast(multiboot2.MULTIBOOT2_HEADER_MAGIC + arch + length + checksum);
    try testing.expectEqual(@as(i32, 0), sum);
}

test "multiboot2: header size" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(multiboot2.Multiboot2Header));
}

test "multiboot2: header is correctly aligned" {
    try testing.expectEqual(@as(usize, 4), @alignOf(multiboot2.Multiboot2Header));
}

// ============================================================================
// Tag Structure Tests
// ============================================================================

test "multiboot2: tag types are unique" {
    const tag_types = [_]u16{
        multiboot2.MULTIBOOT_HEADER_TAG_END,
        multiboot2.MULTIBOOT_HEADER_TAG_INFORMATION_REQUEST,
        multiboot2.MULTIBOOT_HEADER_TAG_ADDRESS,
        multiboot2.MULTIBOOT_HEADER_TAG_ENTRY_ADDRESS,
        multiboot2.MULTIBOOT_HEADER_TAG_CONSOLE_FLAGS,
        multiboot2.MULTIBOOT_HEADER_TAG_FRAMEBUFFER,
        multiboot2.MULTIBOOT_HEADER_TAG_MODULE_ALIGN,
    };

    // Check that all tag types are unique
    for (tag_types, 0..) |tag1, i| {
        for (tag_types, 0..) |tag2, j| {
            if (i != j) {
                try testing.expect(tag1 != tag2);
            }
        }
    }
}

test "multiboot2: info tag types are unique" {
    const info_types = [_]u32{
        multiboot2.MULTIBOOT_TAG_TYPE_END,
        multiboot2.MULTIBOOT_TAG_TYPE_CMDLINE,
        multiboot2.MULTIBOOT_TAG_TYPE_BOOT_LOADER_NAME,
        multiboot2.MULTIBOOT_TAG_TYPE_MODULE,
        multiboot2.MULTIBOOT_TAG_TYPE_BASIC_MEMINFO,
        multiboot2.MULTIBOOT_TAG_TYPE_BOOTDEV,
        multiboot2.MULTIBOOT_TAG_TYPE_MMAP,
    };

    for (info_types, 0..) |type1, i| {
        for (info_types, 0..) |type2, j| {
            if (i != j) {
                try testing.expect(type1 != type2);
            }
        }
    }
}

test "multiboot2: tag structure sizes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(multiboot2.Multiboot2HeaderTag));
    try testing.expectEqual(@as(usize, 8), @sizeOf(multiboot2.Multiboot2HeaderTagEnd));
    try testing.expectEqual(@as(usize, 20), @sizeOf(multiboot2.Multiboot2HeaderTagFramebuffer));
}

test "multiboot2: info tag structure sizes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(multiboot2.Multiboot2Tag));
    try testing.expectEqual(@as(usize, 16), @sizeOf(multiboot2.Multiboot2TagBasicMeminfo));
    try testing.expectEqual(@as(usize, 20), @sizeOf(multiboot2.Multiboot2TagBootdev));
    try testing.expectEqual(@as(usize, 24), @sizeOf(multiboot2.Multiboot2MmapEntry));
}

// ============================================================================
// Memory Map Tests
// ============================================================================

test "multiboot2: memory type constants" {
    try testing.expectEqual(@as(u32, 1), multiboot2.MULTIBOOT_MEMORY_AVAILABLE);
    try testing.expectEqual(@as(u32, 2), multiboot2.MULTIBOOT_MEMORY_RESERVED);
    try testing.expectEqual(@as(u32, 3), multiboot2.MULTIBOOT_MEMORY_ACPI_RECLAIMABLE);
    try testing.expectEqual(@as(u32, 4), multiboot2.MULTIBOOT_MEMORY_NVS);
    try testing.expectEqual(@as(u32, 5), multiboot2.MULTIBOOT_MEMORY_BADRAM);
}

test "multiboot2: memory type names" {
    try testing.expectEqualStrings("Available", multiboot2.getMemoryTypeName(1));
    try testing.expectEqualStrings("Reserved", multiboot2.getMemoryTypeName(2));
    try testing.expectEqualStrings("ACPI Reclaimable", multiboot2.getMemoryTypeName(3));
    try testing.expectEqualStrings("ACPI NVS", multiboot2.getMemoryTypeName(4));
    try testing.expectEqualStrings("Bad RAM", multiboot2.getMemoryTypeName(5));
    try testing.expectEqualStrings("Unknown", multiboot2.getMemoryTypeName(99));
}

test "multiboot2: memory map entry alignment" {
    // Memory map entries must be properly aligned
    try testing.expectEqual(@as(usize, 8), @alignOf(multiboot2.Multiboot2MmapEntry));
}

// ============================================================================
// Magic Number Verification Tests
// ============================================================================

test "multiboot2: verify valid magic" {
    try testing.expect(multiboot2.verifyMagic(0x36d76289));
}

test "multiboot2: reject invalid magic" {
    try testing.expect(!multiboot2.verifyMagic(0x00000000));
    try testing.expect(!multiboot2.verifyMagic(0xFFFFFFFF));
    try testing.expect(!multiboot2.verifyMagic(0x12345678));
}

// ============================================================================
// Mock Multiboot2 Info Tests
// ============================================================================

test "multiboot2: parse mock info structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a mock Multiboot2 info structure in memory
    const mock_info = try createMockMultibootInfo(allocator);
    defer allocator.free(mock_info);

    const mb_info = multiboot2.Multiboot2Info.fromAddress(@intFromPtr(mock_info.ptr));

    // Verify total size
    try testing.expect(mb_info.total_size > 0);
}

test "multiboot2: find end tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mock_info = try createMockMultibootInfo(allocator);
    defer allocator.free(mock_info);

    const mb_info = multiboot2.Multiboot2Info.fromAddress(@intFromPtr(mock_info.ptr));

    // The last tag should be an end tag
    var found_end = false;
    var iter = mb_info.iterateTags();
    while (iter.next()) |tag| {
        if (tag.type == multiboot2.MULTIBOOT_TAG_TYPE_END) {
            found_end = true;
            break;
        }
    }
    try testing.expect(found_end);
}

test "multiboot2: tag iterator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mock_info = try createMockMultibootInfo(allocator);
    defer allocator.free(mock_info);

    const mb_info = multiboot2.Multiboot2Info.fromAddress(@intFromPtr(mock_info.ptr));

    // Count tags
    var count: usize = 0;
    var iter = mb_info.iterateTags();
    while (iter.next()) |_| {
        count += 1;
    }

    // Should have at least one tag (the end tag)
    try testing.expect(count > 0);
}

// ============================================================================
// Framebuffer Tests
// ============================================================================

test "multiboot2: framebuffer type constants" {
    try testing.expectEqual(@as(u8, 0), multiboot2.MULTIBOOT_FRAMEBUFFER_TYPE_INDEXED);
    try testing.expectEqual(@as(u8, 1), multiboot2.MULTIBOOT_FRAMEBUFFER_TYPE_RGB);
    try testing.expectEqual(@as(u8, 2), multiboot2.MULTIBOOT_FRAMEBUFFER_TYPE_EGA_TEXT);
}

test "multiboot2: framebuffer structure size" {
    const size = @sizeOf(multiboot2.Multiboot2TagFramebufferCommon);
    // Should be at least the base size plus framebuffer info
    try testing.expect(size >= 24);
}

// ============================================================================
// EFI Tests
// ============================================================================

test "multiboot2: efi structure sizes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(multiboot2.Multiboot2TagEfi32));
    try testing.expectEqual(@as(usize, 24), @sizeOf(multiboot2.Multiboot2TagEfi64));
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a mock Multiboot2 info structure for testing
fn createMockMultibootInfo(allocator: std.mem.Allocator) ![]align(8) u8 {
    // Calculate total size: header + cmdline tag + end tag
    const header_size = 8; // total_size (4) + reserved (4)
    const cmdline_tag_size = 32; // type (4) + size (4) + string (24)
    const end_tag_size = 8; // type (4) + size (4)
    const total_size = header_size + cmdline_tag_size + end_tag_size;

    // Allocate aligned memory
    var buffer = try allocator.alignedAlloc(u8, 8, total_size);
    @memset(buffer, 0);

    var offset: usize = 0;

    // Write header
    std.mem.writeInt(u32, buffer[offset..][0..4], @as(u32, @intCast(total_size)), .little);
    offset += 4;
    std.mem.writeInt(u32, buffer[offset..][0..4], 0, .little); // reserved
    offset += 4;

    // Write command line tag
    std.mem.writeInt(u32, buffer[offset..][0..4], multiboot2.MULTIBOOT_TAG_TYPE_CMDLINE, .little);
    offset += 4;
    std.mem.writeInt(u32, buffer[offset..][0..4], cmdline_tag_size, .little);
    offset += 4;
    const cmdline = "test command line";
    @memcpy(buffer[offset..][0..cmdline.len], cmdline);
    offset += 24; // Align to 8-byte boundary

    // Write end tag
    std.mem.writeInt(u32, buffer[offset..][0..4], multiboot2.MULTIBOOT_TAG_TYPE_END, .little);
    offset += 4;
    std.mem.writeInt(u32, buffer[offset..][0..4], end_tag_size, .little);

    return buffer;
}

// ============================================================================
// Integration Tests
// ============================================================================

test "multiboot2: full boot info parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mock_info = try createMockMultibootInfo(allocator);
    defer allocator.free(mock_info);

    const mb_info = multiboot2.Multiboot2Info.fromAddress(@intFromPtr(mock_info.ptr));

    // Should be able to get command line
    if (mb_info.getCommandLine()) |cmdline| {
        try testing.expect(cmdline.len > 0);
    }

    // Iterator should work
    var iter = mb_info.iterateTags();
    var found_cmdline = false;
    var found_end = false;

    while (iter.next()) |tag| {
        switch (tag.type) {
            multiboot2.MULTIBOOT_TAG_TYPE_CMDLINE => found_cmdline = true,
            multiboot2.MULTIBOOT_TAG_TYPE_END => found_end = true,
            else => {},
        }
    }

    try testing.expect(found_cmdline);
    try testing.expect(found_end);
}

test "multiboot2: alignment requirements" {
    // All structures should be properly aligned
    try testing.expect(@alignOf(multiboot2.Multiboot2Header) >= 4);
    try testing.expect(@alignOf(multiboot2.Multiboot2Tag) >= 4);
    try testing.expect(@alignOf(multiboot2.Multiboot2MmapEntry) >= 8);
}

test "multiboot2: size limits" {
    // Ensure structures don't exceed expected sizes
    try testing.expect(@sizeOf(multiboot2.Multiboot2Header) <= 32);
    try testing.expect(@sizeOf(multiboot2.Multiboot2Tag) <= 16);
    try testing.expect(@sizeOf(multiboot2.Multiboot2MmapEntry) <= 32);
}
