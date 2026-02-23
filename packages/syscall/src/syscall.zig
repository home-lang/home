// Home Programming Language - System Calls Wrapper Library
// Low-level system call abstractions
//
// NOTE: For most use cases, prefer the `basics` package which provides
// higher-level, user-friendly APIs. This package is for when you need
// direct system call access.

const std = @import("std");
const builtin = @import("builtin");

// Low-level I/O operations (read, write, dup, ioctl, fcntl)
pub const io = @import("io.zig");

// Low-level file system operations (stat, chmod, chown, symlink)
pub const fs = @import("fs.zig");

pub const Error = error{
    PermissionDenied,
    FileNotFound,
    DirectoryNotFound,
    PathTooLong,
    NotADirectory,
    IsADirectory,
    InvalidArgument,
    TooManyOpenFiles,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    Busy,
    OperationNotSupported,
    Interrupted,
    WouldBlock,
    TimedOut,
    BrokenPipe,
    ConnectionRefused,
    ConnectionReset,
    AddressInUse,
    AddressNotAvailable,
    NetworkUnreachable,
    HostUnreachable,
} || std.mem.Allocator.Error;

// Platform detection helper
pub fn isUnix() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd => true,
        else => false,
    };
}

pub fn isWindows() bool {
    return builtin.os.tag == .windows;
}

// File descriptor wrapper
pub const FileDescriptor = struct {
    fd: i32,

    pub fn close(self: FileDescriptor) void {
        if (comptime isUnix()) {
            std.posix.close(@as(std.posix.fd_t, self.fd));
        }
    }

    pub fn read(self: FileDescriptor, buffer: []u8) !usize {
        if (comptime isUnix()) {
            return std.posix.read(@as(std.posix.fd_t, self.fd), buffer);
        }
        return error.OperationNotSupported;
    }

    pub fn write(self: FileDescriptor, data: []const u8) !usize {
        if (comptime isUnix()) {
            return std.posix.write(@as(std.posix.fd_t, self.fd), data);
        }
        return error.OperationNotSupported;
    }

    pub fn isValid(self: FileDescriptor) bool {
        return self.fd >= 0;
    }
};

// Standard file descriptors
pub const stdin = FileDescriptor{ .fd = 0 };
pub const stdout = FileDescriptor{ .fd = 1 };
pub const stderr = FileDescriptor{ .fd = 2 };

// User and group IDs (Unix-specific)
pub const Credentials = struct {
    uid: u32,
    gid: u32,
    euid: u32,
    egid: u32,

    pub fn current() !Credentials {
        if (comptime !isUnix()) {
            return error.OperationNotSupported;
        }

        return .{
            .uid = std.posix.getuid(),
            .gid = std.posix.getgid(),
            .euid = std.posix.geteuid(),
            .egid = std.posix.getegid(),
        };
    }

    pub fn isRoot(self: Credentials) bool {
        return self.euid == 0;
    }
};

// Resource limits (Unix-specific)
pub const ResourceLimit = enum {
    cpu_time,
    file_size,
    data_segment,
    stack_size,
    core_file,
    open_files,
    virtual_memory,
    process_count,
};

pub fn getResourceLimit(resource: ResourceLimit) !struct { soft: u64, hard: u64 } {
    if (comptime !isUnix()) {
        return error.OperationNotSupported;
    }

    const rlimit_resource = switch (resource) {
        .cpu_time => std.posix.rlimit_resource.CPU,
        .file_size => std.posix.rlimit_resource.FSIZE,
        .data_segment => std.posix.rlimit_resource.DATA,
        .stack_size => std.posix.rlimit_resource.STACK,
        .core_file => std.posix.rlimit_resource.CORE,
        .open_files => std.posix.rlimit_resource.NOFILE,
        .virtual_memory => std.posix.rlimit_resource.AS,
        .process_count => std.posix.rlimit_resource.NPROC,
    };

    const rlim = try std.posix.getrlimit(rlimit_resource);
    return .{ .soft = rlim.cur, .hard = rlim.max };
}

pub fn setResourceLimit(resource: ResourceLimit, soft: u64, hard: u64) !void {
    if (comptime !isUnix()) {
        return error.OperationNotSupported;
    }

    const rlimit_resource = switch (resource) {
        .cpu_time => std.posix.rlimit_resource.CPU,
        .file_size => std.posix.rlimit_resource.FSIZE,
        .data_segment => std.posix.rlimit_resource.DATA,
        .stack_size => std.posix.rlimit_resource.STACK,
        .core_file => std.posix.rlimit_resource.CORE,
        .open_files => std.posix.rlimit_resource.NOFILE,
        .virtual_memory => std.posix.rlimit_resource.AS,
        .process_count => std.posix.rlimit_resource.NPROC,
    };

    const rlim = std.posix.rlimit{
        .cur = soft,
        .max = hard,
    };

    try std.posix.setrlimit(rlimit_resource, rlim);
}

// Utility functions
pub fn getPageSize() usize {
    return std.mem.page_size;
}

pub fn getCpuCount() !usize {
    return try std.Thread.getCpuCount();
}

test "platform detection" {
    const testing = std.testing;

    // At least one should be true
    const is_unix = isUnix();
    const is_win = isWindows();
    try testing.expect(is_unix or is_win);
}

test "standard file descriptors" {
    const testing = std.testing;

    try testing.expect(stdin.isValid());
    try testing.expect(stdout.isValid());
    try testing.expect(stderr.isValid());
}

test "resource limits" {
    const testing = std.testing;

    if (isUnix()) {
        const limit = try getResourceLimit(.open_files);
        try testing.expect(limit.soft > 0);
        try testing.expect(limit.hard > 0);
    }
}
