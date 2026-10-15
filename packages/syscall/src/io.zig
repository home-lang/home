// Home Programming Language - I/O Operations
// Low-level I/O system calls

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const Io = std.Io;
const File = Io.File;

const has_posix_descriptor_controls = switch (builtin.os.tag) {
    .driverkit,
    .dragonfly,
    .freebsd,
    .haiku,
    .illumos,
    .ios,
    .linux,
    .maccatalyst,
    .macos,
    .netbsd,
    .openbsd,
    .serenity,
    .tvos,
    .visionos,
    .watchos,
    => true,
    else => false,
};

fn fileFromDescriptor(fd: std.posix.fd_t) File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

// Read from file descriptor
pub fn read(fd: std.posix.fd_t, buffer: []u8) !usize {
    return readWithIo(compat.io(), fd, buffer);
}

pub fn readWithIo(io: Io, fd: std.posix.fd_t, buffer: []u8) !usize {
    return fileFromDescriptor(fd).readStreaming(io, &.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
}

// Write to file descriptor
pub fn write(fd: std.posix.fd_t, data: []const u8) !usize {
    return writeWithIo(compat.io(), fd, data);
}

pub fn writeWithIo(io: Io, fd: std.posix.fd_t, data: []const u8) !usize {
    return fileFromDescriptor(fd).writeStreaming(io, &.{}, &.{data}, 1);
}

// Positioned read
pub fn pread(fd: std.posix.fd_t, buffer: []u8, offset: u64) !usize {
    return preadWithIo(compat.io(), fd, buffer, offset);
}

pub fn preadWithIo(io: Io, fd: std.posix.fd_t, buffer: []u8, offset: u64) !usize {
    return fileFromDescriptor(fd).readPositional(io, &.{buffer}, offset);
}

// Positioned write
pub fn pwrite(fd: std.posix.fd_t, data: []const u8, offset: u64) !usize {
    return pwriteWithIo(compat.io(), fd, data, offset);
}

pub fn pwriteWithIo(io: Io, fd: std.posix.fd_t, data: []const u8, offset: u64) !usize {
    return fileFromDescriptor(fd).writePositional(io, &.{data}, offset);
}

// Seek file descriptor
pub const SeekFrom = enum {
    start,
    current,
    end,
};

pub fn lseek(fd: std.posix.fd_t, offset: i64, whence: SeekFrom) !u64 {
    if (comptime !has_posix_descriptor_controls) return error.OperationNotSupported;

    const raw_whence: u32 = switch (whence) {
        .start => std.posix.SEEK.SET,
        .current => std.posix.SEEK.CUR,
        .end => std.posix.SEEK.END,
    };

    if (comptime builtin.os.tag == .linux and !builtin.link_libc and @sizeOf(std.posix.system.syscall_arg_t) == 4) {
        while (true) {
            var result: i64 = undefined;
            switch (std.posix.errno(std.posix.system.llseek(fd, offset, &result, raw_whence))) {
                .SUCCESS => return @intCast(result),
                .INTR => continue,
                .BADF => return error.InvalidFileDescriptor,
                .INVAL => return error.InvalidArgument,
                .OVERFLOW => return error.Overflow,
                .SPIPE => return error.Unseekable,
                .NXIO => return error.NoDevice,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    const lseek_sym = if (std.posix.lfs64_abi) std.posix.system.lseek64 else std.posix.system.lseek;
    while (true) {
        const result = if (comptime builtin.os.tag == .linux and !builtin.link_libc)
            lseek_sym(fd, offset, raw_whence)
        else
            lseek_sym(fd, offset, @intCast(raw_whence));
        switch (std.posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .BADF => return error.InvalidFileDescriptor,
            .INVAL => return error.InvalidArgument,
            .OVERFLOW => return error.Overflow,
            .SPIPE => return error.Unseekable,
            .NXIO => return error.NoDevice,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

// Duplicate file descriptor
pub fn dup(fd: std.posix.fd_t) !std.posix.fd_t {
    if (comptime !has_posix_descriptor_controls) return error.OperationNotSupported;

    while (true) {
        const result = std.posix.system.dup(fd);
        switch (std.posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .BADF => return error.InvalidFileDescriptor,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub fn dup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !std.posix.fd_t {
    if (comptime !has_posix_descriptor_controls) return error.OperationNotSupported;

    while (true) {
        const result = std.posix.system.dup2(old_fd, new_fd);
        switch (std.posix.errno(result)) {
            .SUCCESS => return new_fd,
            .BUSY, .INTR => continue,
            .BADF => return error.InvalidFileDescriptor,
            .INVAL => return error.InvalidArgument,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

// I/O control
pub fn ioctl(fd: std.posix.fd_t, request: u32, arg: usize) !void {
    if (comptime !has_posix_descriptor_controls) return error.OperationNotSupported;

    while (true) {
        const result = if (comptime builtin.os.tag == .linux and !builtin.link_libc)
            std.posix.system.ioctl(fd, request, arg)
        else
            std.posix.system.ioctl(fd, @bitCast(request), arg);
        switch (std.posix.errno(result)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.IoctlFailed,
        }
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
    if (comptime !has_posix_descriptor_controls) return error.OperationNotSupported;

    const raw_cmd: c_int = switch (cmd) {
        .get_flags => std.posix.F.GETFL,
        .set_flags => std.posix.F.SETFL,
        .get_fd_flags => std.posix.F.GETFD,
        .set_fd_flags => std.posix.F.SETFD,
    };

    while (true) {
        const result = if (comptime builtin.os.tag == .linux and !builtin.link_libc)
            std.posix.system.fcntl(fd, raw_cmd, arg)
        else
            std.posix.system.fcntl(fd, raw_cmd, @as(c_int, @bitCast(arg)));
        switch (std.posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            else => return error.FcntlFailed,
        }
    }
}

test "descriptor data and control operations" {
    const testing = std.testing;
    const io = testing.io;

    if (comptime !has_posix_descriptor_controls) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "descriptor-io", .{ .read = true });
    defer file.close(io);

    try testing.expectEqual(@as(usize, 6), try write(file.handle, "abcdef"));
    try testing.expectEqual(@as(u64, 0), try lseek(file.handle, 0, .start));

    var streaming: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try readWithIo(io, file.handle, &streaming));
    try testing.expectEqualStrings("ab", &streaming);

    var positional: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try pread(file.handle, &positional, 3));
    try testing.expectEqualStrings("de", &positional);
    try testing.expectEqual(@as(u64, 2), try lseek(file.handle, 0, .current));

    try testing.expectEqual(@as(usize, 2), try pwrite(file.handle, "XY", 2));
    var contents: [6]u8 = undefined;
    try testing.expectEqual(@as(usize, contents.len), try preadWithIo(io, file.handle, &contents, 0));
    try testing.expectEqualStrings("abXYef", &contents);
    try testing.expectEqual(@as(u64, 3), try lseek(file.handle, 1, .current));
    try testing.expectEqual(@as(u64, 5), try lseek(file.handle, -1, .end));

    var end: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try readWithIo(io, file.handle, &end));
    try testing.expectEqualStrings("f", &end);
    try testing.expectEqual(@as(usize, 0), try read(file.handle, &end));

    const dup_fd = try dup(file.handle);
    defer fileFromDescriptor(dup_fd).close(io);
    try testing.expect(dup_fd != file.handle);

    const target_fd = try dup(file.handle);
    defer fileFromDescriptor(target_fd).close(io);
    try testing.expectEqual(target_fd, try dup2(file.handle, target_fd));

    const descriptor_flags = try fcntl(file.handle, .get_fd_flags, 0);
    _ = try fcntl(file.handle, .set_fd_flags, descriptor_flags);

    try testing.expectError(error.IoctlFailed, ioctl(@as(std.posix.fd_t, -1), 0, 0));
}

test {
    std.testing.refAllDecls(@This());
}
