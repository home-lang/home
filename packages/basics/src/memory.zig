const std = @import("std");
const builtin = @import("builtin");

/// Memory protection flags for mapped regions
pub const Protection = struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,

    pub fn toFlags(self: Protection) u32 {
        var flags: u32 = 0;
        if (self.read) flags |= std.posix.PROT.READ;
        if (self.write) flags |= std.posix.PROT.WRITE;
        if (self.execute) flags |= std.posix.PROT.EXEC;
        if (flags == 0) flags = std.posix.PROT.NONE;
        return flags;
    }
};

// Page alignment constant
const page_alignment = 4096; // Standard page size, actual runtime value from pageSize()

/// Memory mapped region
pub const MappedMemory = struct {
    ptr: [*]align(page_alignment) u8,
    len: usize,

    /// Create a new memory mapping
    pub fn create(length: usize, prot: Protection) !MappedMemory {
        const ptr = try std.posix.mmap(
            null,
            length,
            prot.toFlags(),
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );

        return .{
            .ptr = ptr.ptr,
            .len = ptr.len,
        };
    }

    /// Unmap the memory region
    pub fn unmap(self: MappedMemory) void {
        std.posix.munmap(@alignCast(self.ptr[0..self.len]));
    }

    /// Change protection flags on mapped memory
    pub fn protect(self: MappedMemory, prot: Protection) !void {
        try std.posix.mprotect(self.ptr[0..self.len], prot.toFlags());
    }

    /// Sync memory to disk (for file-backed mappings)
    pub fn sync(self: MappedMemory) !void {
        try std.posix.msync(self.ptr[0..self.len], std.posix.MSF.SYNC);
    }

    /// Get a slice view of the mapped memory
    pub fn asSlice(self: MappedMemory) []u8 {
        return self.ptr[0..self.len];
    }
};

/// Get the system page size
pub fn pageSize() usize {
    return std.heap.page_size_min;
}

/// Lock memory pages to prevent swapping (Unix-only)
/// Useful for security-sensitive data like encryption keys
pub fn lock(ptr: [*]u8, len: usize) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    try std.posix.mlock(ptr[0..len]);
}

/// Unlock previously locked memory pages
pub fn unlock(ptr: [*]u8, len: usize) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    try std.posix.munlock(ptr[0..len]);
}

/// Allocate memory with specific alignment
pub fn allocAligned(size: usize, alignment: usize) !*anyopaque {
    const c = struct {
        extern "c" fn posix_memalign(*?*anyopaque, usize, usize) c_int;
    };

    var ptr: ?*anyopaque = null;
    const result = c.posix_memalign(&ptr, alignment, size);
    if (result != 0) {
        return error.AlignedAllocFailed;
    }

    return ptr.?;
}

test "memory mapping" {
    const testing = std.testing;

    const prot = Protection{ .read = true, .write = true };
    const mapping = try MappedMemory.create(4096, prot);
    defer mapping.unmap();

    try testing.expectEqual(@as(usize, 4096), mapping.len);

    // Write to the mapped memory
    const slice = mapping.asSlice();
    slice[0] = 42;
    try testing.expectEqual(@as(u8, 42), slice[0]);
}

test "page size" {
    const testing = std.testing;

    const page_size = pageSize();
    try testing.expect(page_size > 0);
    try testing.expect(page_size % 4096 == 0); // Should be multiple of 4K
}
