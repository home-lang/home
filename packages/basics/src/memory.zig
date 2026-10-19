const std = @import("std");
const builtin = @import("builtin");

/// Memory protection flags for mapped regions
pub const Protection = struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,

    pub fn toFlags(self: Protection) std.posix.PROT {
        return .{ .READ = self.read, .WRITE = self.write, .EXEC = self.execute };
    }
};

/// Memory mapped region
pub const MappedMemory = struct {
    ptr: [*]align(std.heap.page_size_min) u8,
    len: usize,

    /// Create a new memory mapping
    pub fn create(length: usize, prot: Protection) !MappedMemory {
        if (length == 0) return error.InvalidLength;
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
        std.posix.munmap(self.ptr[0..self.len]);
    }

    /// Change protection flags on mapped memory
    pub fn protect(self: MappedMemory, prot: Protection) !void {
        const rc = std.posix.system.mprotect(@ptrCast(@alignCast(self.ptr)), self.len, prot.toFlags());
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .NOMEM => return error.UnmappedMemory,
            .INVAL => return error.InvalidArgument,
            else => |err| return std.posix.unexpectedErrno(err),
        }
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
    return std.heap.pageSize();
}

const libc_memory = struct {
    // POSIX accepts an address within a page; std.c's declarations require a
    // page-aligned pointer, which is too restrictive for this public API.
    extern "c" fn mlock([*]const u8, usize) c_int;
    extern "c" fn munlock([*]const u8, usize) c_int;
};

fn lockError(ptr: [*]u8, len: usize, comptime release: bool) std.posix.E {
    if (builtin.link_libc or builtin.os.tag != .linux) {
        const rc = if (release) libc_memory.munlock(ptr, len) else libc_memory.mlock(ptr, len);
        return std.c.errno(rc);
    }
    const rc = if (release) std.os.linux.munlock(ptr, len) else std.os.linux.mlock(ptr, len);
    return std.os.linux.errno(rc);
}

/// Lock memory pages to prevent swapping (Unix-only)
/// Useful for security-sensitive data like encryption keys
pub fn lock(ptr: [*]u8, len: usize) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }
    switch (lockError(ptr, len, false)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.LockedMemoryLimitExceeded,
        .PERM => return error.PermissionDenied,
        .INVAL => return error.InvalidArgument,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// Unlock previously locked memory pages
pub fn unlock(ptr: [*]u8, len: usize) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }
    switch (lockError(ptr, len, true)) {
        .SUCCESS => {},
        .NOMEM => return error.UnmappedMemory,
        .INVAL => return error.InvalidArgument,
        else => |err| return std.posix.unexpectedErrno(err),
    }
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
