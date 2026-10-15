// Home Programming Language - File System Operations
// Cross-platform file system syscall wrappers

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const has_posix_metadata = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

pub const FileType = enum {
    regular,
    directory,
    symlink,
    block_device,
    character_device,
    fifo,
    socket,
    unknown,

    pub fn fromMode(mode: u32) FileType {
        const S_IFMT: u32 = 0o170000;
        const S_IFREG: u32 = 0o100000;
        const S_IFDIR: u32 = 0o040000;
        const S_IFLNK: u32 = 0o120000;
        const S_IFBLK: u32 = 0o060000;
        const S_IFCHR: u32 = 0o020000;
        const S_IFIFO: u32 = 0o010000;
        const S_IFSOCK: u32 = 0o140000;

        return switch (mode & S_IFMT) {
            S_IFREG => .regular,
            S_IFDIR => .directory,
            S_IFLNK => .symlink,
            S_IFBLK => .block_device,
            S_IFCHR => .character_device,
            S_IFIFO => .fifo,
            S_IFSOCK => .socket,
            else => .unknown,
        };
    }
};

pub const FilePermissions = struct {
    owner_read: bool,
    owner_write: bool,
    owner_execute: bool,
    group_read: bool,
    group_write: bool,
    group_execute: bool,
    other_read: bool,
    other_write: bool,
    other_execute: bool,

    pub fn fromMode(mode: u32) FilePermissions {
        return .{
            .owner_read = (mode & 0o400) != 0,
            .owner_write = (mode & 0o200) != 0,
            .owner_execute = (mode & 0o100) != 0,
            .group_read = (mode & 0o040) != 0,
            .group_write = (mode & 0o020) != 0,
            .group_execute = (mode & 0o010) != 0,
            .other_read = (mode & 0o004) != 0,
            .other_write = (mode & 0o002) != 0,
            .other_execute = (mode & 0o001) != 0,
        };
    }

    pub fn toMode(self: FilePermissions) u32 {
        var mode: u32 = 0;
        if (self.owner_read) mode |= 0o400;
        if (self.owner_write) mode |= 0o200;
        if (self.owner_execute) mode |= 0o100;
        if (self.group_read) mode |= 0o040;
        if (self.group_write) mode |= 0o020;
        if (self.group_execute) mode |= 0o010;
        if (self.other_read) mode |= 0o004;
        if (self.other_write) mode |= 0o002;
        if (self.other_execute) mode |= 0o001;
        return mode;
    }

    pub fn octal(self: FilePermissions) u32 {
        return self.toMode();
    }
};

pub const FileStat = struct {
    file_type: FileType,
    permissions: FilePermissions,
    size: u64,
    uid: u32,
    gid: u32,
    atime: i128, // nanoseconds since epoch
    mtime: i128,
    ctime: i128,
    inode: u64,
    nlink: u64,
    dev: u64,
    rdev: u64,
    blksize: u64,
    blocks: u64,
};

fn fileTypeFromKind(kind: File.Kind) FileType {
    return switch (kind) {
        .file => .regular,
        .directory => .directory,
        .sym_link => .symlink,
        .block_device => .block_device,
        .character_device => .character_device,
        .named_pipe => .fifo,
        .unix_domain_socket => .socket,
        else => .unknown,
    };
}

fn timestampNanoseconds(timestamp: Io.Timestamp) i128 {
    return timestamp.toNanoseconds();
}

fn permissionsReadOnly(permissions: File.Permissions) bool {
    return if (comptime builtin.os.tag == .windows)
        permissions.toAttributes().READONLY
    else
        permissions.readOnly();
}

const PosixMetadata = struct {
    mode: u32,
    uid: u32,
    gid: u32,
    atime: i128,
    mtime: i128,
    ctime: i128,
    inode: u64,
    nlink: u64,
    dev: u64,
    rdev: u64,
    blksize: u64,
    blocks: u64,
};

fn linuxDevice(major: u32, minor: u32) u64 {
    return (@as(u64, major & 0xfffff000) << 32) |
        (@as(u64, major & 0x00000fff) << 8) |
        (@as(u64, minor & 0xffffff00) << 12) |
        @as(u64, minor & 0x000000ff);
}

fn statLinux(path_z: [:0]const u8, follow_symlinks: bool) !PosixMetadata {
    const linux = std.os.linux;
    const flags: u32 = linux.AT.NO_AUTOMOUNT |
        @as(u32, if (follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW);

    while (true) {
        var result = std.mem.zeroes(linux.Statx);
        switch (linux.errno(linux.statx(Dir.cwd().handle, path_z, flags, .BASIC_STATS, &result))) {
            .SUCCESS => {
                const actual: u32 = @bitCast(result.mask);
                const required: u32 = @bitCast(linux.STATX.BASIC_STATS);
                if ((actual & required) != required) return error.Unexpected;
                return .{
                    .mode = result.mode,
                    .uid = result.uid,
                    .gid = result.gid,
                    .atime = @as(i128, result.atime.sec) * std.time.ns_per_s + result.atime.nsec,
                    .mtime = @as(i128, result.mtime.sec) * std.time.ns_per_s + result.mtime.nsec,
                    .ctime = @as(i128, result.ctime.sec) * std.time.ns_per_s + result.ctime.nsec,
                    .inode = result.ino,
                    .nlink = result.nlink,
                    .dev = linuxDevice(result.dev_major, result.dev_minor),
                    .rdev = linuxDevice(result.rdev_major, result.rdev_minor),
                    .blksize = result.blksize,
                    .blocks = result.blocks,
                };
            },
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .ILSEQ => return error.BadPathName,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn statPosix(path: []const u8, follow_symlinks: bool) !PosixMetadata {
    if (comptime !has_posix_metadata) unreachable;

    var path_buffer: [std.posix.PATH_MAX]u8 = undefined;
    if (path.len >= path_buffer.len) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    const path_z: [:0]const u8 = path_buffer[0..path.len :0];
    if (comptime builtin.os.tag == .linux) return statLinux(path_z, follow_symlinks);

    const fstatat = if (std.posix.lfs64_abi) std.posix.system.fstatat64 else std.posix.system.fstatat;
    const flags: u32 = if (follow_symlinks) 0 else std.posix.AT.SYMLINK_NOFOLLOW;

    while (true) {
        var result = std.mem.zeroes(std.posix.Stat);
        switch (std.posix.errno(fstatat(Dir.cwd().handle, path_z, &result, flags))) {
            .SUCCESS => {
                const atime = result.atime();
                const mtime = result.mtime();
                const ctime = result.ctime();
                return .{
                    .mode = @intCast(result.mode),
                    .uid = @intCast(result.uid),
                    .gid = @intCast(result.gid),
                    .atime = @as(i128, atime.sec) * std.time.ns_per_s + atime.nsec,
                    .mtime = @as(i128, mtime.sec) * std.time.ns_per_s + mtime.nsec,
                    .ctime = @as(i128, ctime.sec) * std.time.ns_per_s + ctime.nsec,
                    .inode = @intCast(result.ino),
                    .nlink = @intCast(result.nlink),
                    .dev = @intCast(result.dev),
                    .rdev = @intCast(result.rdev),
                    .blksize = @intCast(result.blksize),
                    .blocks = @intCast(result.blocks),
                };
            },
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .ILSEQ => return error.BadPathName,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn statWithOptions(io: Io, path: []const u8, follow_symlinks: bool) !FileStat {
    const portable = try Dir.cwd().statFile(io, path, .{ .follow_symlinks = follow_symlinks });

    if (comptime has_posix_metadata) {
        const raw = try statPosix(path, follow_symlinks);
        return .{
            .file_type = fileTypeFromKind(portable.kind),
            .permissions = .fromMode(@intCast(raw.mode)),
            .size = portable.size,
            .uid = raw.uid,
            .gid = raw.gid,
            .atime = raw.atime,
            .mtime = raw.mtime,
            .ctime = raw.ctime,
            .inode = raw.inode,
            .nlink = raw.nlink,
            .dev = raw.dev,
            .rdev = raw.rdev,
            .blksize = raw.blksize,
            .blocks = raw.blocks,
        };
    }

    return .{
        .file_type = fileTypeFromKind(portable.kind),
        .permissions = .{
            .owner_read = true,
            .owner_write = !permissionsReadOnly(portable.permissions),
            .owner_execute = false,
            .group_read = true,
            .group_write = !permissionsReadOnly(portable.permissions),
            .group_execute = false,
            .other_read = true,
            .other_write = !permissionsReadOnly(portable.permissions),
            .other_execute = false,
        },
        .size = portable.size,
        .uid = 0,
        .gid = 0,
        .atime = timestampNanoseconds(portable.atime orelse .zero),
        .mtime = timestampNanoseconds(portable.mtime),
        .ctime = timestampNanoseconds(portable.ctime),
        .inode = @bitCast(portable.inode),
        .nlink = portable.nlink,
        .dev = 0,
        .rdev = 0,
        .blksize = portable.block_size,
        .blocks = if (portable.block_size == 0) 0 else std.math.divCeil(u64, portable.size, portable.block_size) catch 0,
    };
}

// Get file status
pub fn stat(path: []const u8) !FileStat {
    return statWithIo(compat.io(), path);
}

pub fn statWithIo(io: Io, path: []const u8) !FileStat {
    return statWithOptions(io, path, true);
}

// Check if file exists
pub fn exists(path: []const u8) bool {
    return existsWithIo(compat.io(), path);
}

pub fn existsWithIo(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// Check if path is a directory
pub fn isDirectory(path: []const u8) !bool {
    return isDirectoryWithIo(compat.io(), path);
}

pub fn isDirectoryWithIo(io: Io, path: []const u8) !bool {
    const s = try statWithIo(io, path);
    return s.file_type == .directory;
}

// Check if path is a file
pub fn isFile(path: []const u8) !bool {
    return isFileWithIo(compat.io(), path);
}

pub fn isFileWithIo(io: Io, path: []const u8) !bool {
    const s = try statWithIo(io, path);
    return s.file_type == .regular;
}

// Check if path is a symlink
pub fn isSymlink(path: []const u8) !bool {
    return isSymlinkWithIo(compat.io(), path);
}

pub fn isSymlinkWithIo(io: Io, path: []const u8) !bool {
    const s = try statWithOptions(io, path, false);
    return s.file_type == .symlink;
}

// Create directory
pub fn mkdir(path: []const u8, mode: u32) !void {
    return mkdirWithIo(compat.io(), path, mode);
}

pub fn mkdirWithIo(io: Io, path: []const u8, mode: u32) !void {
    const permissions: File.Permissions = if (comptime builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(@intCast(mode));
    try Dir.cwd().createDir(io, path, permissions);
}

// Create directory recursively
pub fn mkdirAll(path: []const u8, mode: u32) !void {
    return mkdirAllWithIo(compat.io(), path, mode);
}

pub fn mkdirAllWithIo(io: Io, path: []const u8, mode: u32) !void {
    const permissions: File.Permissions = if (comptime builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(@intCast(mode));
    _ = try Dir.cwd().createDirPathStatus(io, path, permissions);
}

// Remove file
pub fn unlink(path: []const u8) !void {
    return unlinkWithIo(compat.io(), path);
}

pub fn unlinkWithIo(io: Io, path: []const u8) !void {
    try Dir.cwd().deleteFile(io, path);
}

// Remove directory
pub fn rmdir(path: []const u8) !void {
    return rmdirWithIo(compat.io(), path);
}

pub fn rmdirWithIo(io: Io, path: []const u8) !void {
    try Dir.cwd().deleteDir(io, path);
}

// Remove directory recursively
pub fn rmAll(path: []const u8) !void {
    return rmAllWithIo(compat.io(), path);
}

pub fn rmAllWithIo(io: Io, path: []const u8) !void {
    try Dir.cwd().deleteTree(io, path);
}

// Change file permissions (Unix-specific)
pub fn chmod(path: []const u8, mode: u32) !void {
    return chmodWithIo(compat.io(), path, mode);
}

pub fn chmodWithIo(io: Io, path: []const u8, mode: u32) !void {
    if (comptime builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }
    try Dir.cwd().setFilePermissions(io, path, .fromMode(@intCast(mode)), .{});
}

// Change file owner (Unix-specific)
pub fn chown(path: []const u8, uid: u32, gid: u32) !void {
    return chownWithIo(compat.io(), path, uid, gid);
}

pub fn chownWithIo(io: Io, path: []const u8, uid: u32, gid: u32) !void {
    if (comptime builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }
    try Dir.cwd().setFileOwner(io, path, @intCast(uid), @intCast(gid), .{});
}

// Rename file
pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    return renameWithIo(compat.io(), old_path, new_path);
}

pub fn renameWithIo(io: Io, old_path: []const u8, new_path: []const u8) !void {
    try Dir.rename(.cwd(), old_path, .cwd(), new_path, io);
}

// Create symlink
pub fn symlink(target: []const u8, link_path: []const u8) !void {
    return symlinkWithIo(compat.io(), target, link_path);
}

pub fn symlinkWithIo(io: Io, target: []const u8, link_path: []const u8) !void {
    try Dir.cwd().symLink(io, target, link_path, .{});
}

// Read symlink
pub fn readlink(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readlinkWithIo(compat.io(), allocator, path);
}

pub fn readlinkWithIo(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const scratch = try allocator.alloc(u8, Dir.max_path_bytes);
    defer allocator.free(scratch);
    const len = try Dir.cwd().readLink(io, path, scratch);
    return allocator.dupe(u8, scratch[0..len]);
}

// Create hard link
pub fn link(old_path: []const u8, new_path: []const u8) !void {
    return linkWithIo(compat.io(), old_path, new_path);
}

pub fn linkWithIo(io: Io, old_path: []const u8, new_path: []const u8) !void {
    try Dir.hardLink(.cwd(), old_path, .cwd(), new_path, io, .{});
}

// Get current working directory
pub fn getcwd(allocator: std.mem.Allocator) ![]u8 {
    return getcwdWithIo(compat.io(), allocator);
}

pub fn getcwdWithIo(io: Io, allocator: std.mem.Allocator) ![]u8 {
    const sentinel_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(sentinel_path);
    return allocator.dupe(u8, sentinel_path);
}

// Change current working directory
pub fn chdir(path: []const u8) !void {
    return chdirWithIo(compat.io(), path);
}

pub fn chdirWithIo(io: Io, path: []const u8) !void {
    const dir = try Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    try std.process.setCurrentDir(io, dir);
}

// List directory entries
pub const DirectoryEntry = struct {
    name: []const u8,
    file_type: FileType,
};

pub fn listDir(allocator: std.mem.Allocator, path: []const u8) ![]DirectoryEntry {
    return listDirWithIo(compat.io(), allocator, path);
}

pub fn listDirWithIo(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]DirectoryEntry {
    const dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var entries = std.ArrayList(DirectoryEntry).empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        entries.append(allocator, .{
            .name = name,
            .file_type = fileTypeFromKind(entry.kind),
        }) catch |err| {
            allocator.free(name);
            return err;
        };
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn freeDirectoryEntries(allocator: std.mem.Allocator, entries: []DirectoryEntry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

// Truncate file
pub fn truncate(path: []const u8, length: u64) !void {
    return truncateWithIo(compat.io(), path, length);
}

pub fn truncateWithIo(io: Io, path: []const u8, length: u64) !void {
    const file = try Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setLength(io, length);
}

// Sync file to disk
pub fn sync(path: []const u8) !void {
    return syncWithIo(compat.io(), path);
}

pub fn syncWithIo(io: Io, path: []const u8) !void {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.sync(io);
}

test "file permissions" {
    const testing = std.testing;

    const perms = FilePermissions.fromMode(0o755);
    try testing.expect(perms.owner_read);
    try testing.expect(perms.owner_write);
    try testing.expect(perms.owner_execute);
    try testing.expect(perms.group_read);
    try testing.expect(!perms.group_write);
    try testing.expect(perms.group_execute);
    try testing.expect(perms.other_read);
    try testing.expect(!perms.other_write);
    try testing.expect(perms.other_execute);

    try testing.expectEqual(@as(u32, 0o755), perms.toMode());
}

test "filesystem operations use explicit Io and preserve metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const single_dir = try std.fs.path.join(allocator, &.{ root, "single" });
    defer allocator.free(single_dir);
    const nested_dir = try std.fs.path.join(allocator, &.{ root, "nested", "child" });
    defer allocator.free(nested_dir);
    const nested_parent = try std.fs.path.join(allocator, &.{ root, "nested" });
    defer allocator.free(nested_parent);
    const file_path = try std.fs.path.join(allocator, &.{ root, "file.txt" });
    defer allocator.free(file_path);
    const renamed_path = try std.fs.path.join(allocator, &.{ root, "renamed.txt" });
    defer allocator.free(renamed_path);
    const hard_link_path = try std.fs.path.join(allocator, &.{ root, "hard-link.txt" });
    defer allocator.free(hard_link_path);
    const sym_link_path = try std.fs.path.join(allocator, &.{ root, "symbolic-link.txt" });
    defer allocator.free(sym_link_path);

    try mkdirWithIo(io, single_dir, 0o755);
    try testing.expect(try isDirectoryWithIo(io, single_dir));
    try mkdirAllWithIo(io, nested_dir, 0o750);
    try testing.expect(try isDirectoryWithIo(io, nested_dir));

    try Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "hello, Home" });
    try testing.expect(existsWithIo(io, file_path));
    try testing.expect(try isFileWithIo(io, file_path));

    try chmodWithIo(io, file_path, 0o600);
    const initial_stat = try statWithIo(io, file_path);
    try testing.expectEqual(@as(u64, 11), initial_stat.size);
    try testing.expect(initial_stat.permissions.owner_read);
    try testing.expect(initial_stat.permissions.owner_write);
    try testing.expect(!initial_stat.permissions.group_read);
    if (comptime has_posix_metadata) {
        try testing.expect(initial_stat.inode > 0);
        try testing.expect(initial_stat.nlink > 0);
        try testing.expect(initial_stat.blksize > 0);
    }

    const entries = try listDirWithIo(io, allocator, root);
    defer freeDirectoryEntries(allocator, entries);
    var found_file = false;
    var found_single = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "file.txt")) {
            found_file = entry.file_type == .regular;
        } else if (std.mem.eql(u8, entry.name, "single")) {
            found_single = entry.file_type == .directory;
        }
    }
    try testing.expect(found_file);
    try testing.expect(found_single);

    try truncateWithIo(io, file_path, 5);
    try syncWithIo(io, file_path);
    try testing.expectEqual(@as(u64, 5), (try statWithIo(io, file_path)).size);

    try renameWithIo(io, file_path, renamed_path);
    try testing.expect(!existsWithIo(io, file_path));
    try testing.expect(existsWithIo(io, renamed_path));

    try linkWithIo(io, renamed_path, hard_link_path);
    try testing.expectEqual((try statWithIo(io, renamed_path)).inode, (try statWithIo(io, hard_link_path)).inode);

    if (comptime builtin.os.tag != .windows) {
        try symlinkWithIo(io, "renamed.txt", sym_link_path);
        try testing.expect(try isSymlinkWithIo(io, sym_link_path));
        try testing.expect(try isFileWithIo(io, sym_link_path));
        const target = try readlinkWithIo(io, allocator, sym_link_path);
        defer allocator.free(target);
        try testing.expectEqualStrings("renamed.txt", target);
        try unlinkWithIo(io, sym_link_path);
    }

    try unlinkWithIo(io, hard_link_path);
    try unlinkWithIo(io, renamed_path);
    try rmdirWithIo(io, single_dir);
    try rmAllWithIo(io, nested_parent);
    try testing.expect(!existsWithIo(io, single_dir));
    try testing.expect(!existsWithIo(io, nested_dir));
}

test "default Io wrappers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cwd = try getcwd(allocator);
    defer allocator.free(cwd);

    try testing.expect(cwd.len > 0);
    try testing.expect(exists(cwd));
    try testing.expect(try isDirectory(cwd));
}
