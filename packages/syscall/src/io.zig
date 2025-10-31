// Home Programming Language - I/O Operations
// Low-level I/O system calls

const std = @import("std");

// Read from file descriptor
pub fn read(fd: std.posix.fd_t, buffer: []u8) !usize {
    return try std.posix.read(fd, buffer);
}

// Write to file descriptor
pub fn write(fd: std.posix.fd_t, data: []const u8) !usize {
    return try std.posix.write(fd, data);
}

// Positioned read
pub fn pread(fd: std.posix.fd_t, buffer: []u8, offset: u64) !usize {
    return try std.posix.pread(fd, buffer, offset);
}

// Positioned write
pub fn pwrite(fd: std.posix.fd_t, data: []const u8, offset: u64) !usize {
    return try std.posix.pwrite(fd, data, offset);
}

// Seek file descriptor
pub const SeekFrom = enum {
    start,
    current,
    end,
};

pub fn lseek(fd: std.posix.fd_t, offset: i64, whence: SeekFrom) !u64 {
    _ = whence;
    return try std.posix.lseek_SET(fd, @intCast(offset));
}

// Duplicate file descriptor
pub fn dup(fd: std.posix.fd_t) !std.posix.fd_t {
    return try std.posix.dup(fd);
}

pub fn dup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !std.posix.fd_t {
    return try std.posix.dup2(old_fd, new_fd);
}

// I/O control
pub fn ioctl(fd: std.posix.fd_t, request: u32, arg: usize) !void {
    const result = std.posix.system.ioctl(fd, request, arg);
    if (result < 0) {
        return error.IoctlFailed;
    }
}

// File control operations
pub const FcntlCmd = enum {
    get_flags,
    set_flags,
    get_fd_flags,
    set_fd_flags,
};

pub fn fcntl(fd: std.posix.fd_t, cmd: FcntlCmd, arg: u32) !u32 {
    const c_cmd: u32 = switch (cmd) {
        .get_flags => std.posix.F.GETFL,
        .set_flags => std.posix.F.SETFL,
        .get_fd_flags => std.posix.F.GETFD,
        .set_fd_flags => std.posix.F.SETFD,
    };

    const result = std.posix.system.fcntl(fd, c_cmd, arg);
    if (result < 0) {
        return error.FcntlFailed;
    }

    return @intCast(result);
}

test "io operations" {
    const testing = std.testing;

    // Test dup
    const stdout_fd = std.posix.STDOUT_FILENO;
    const dup_fd = try dup(stdout_fd);
    defer std.posix.close(dup_fd);

    try testing.expect(dup_fd != stdout_fd);
}
