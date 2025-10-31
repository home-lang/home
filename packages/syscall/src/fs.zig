// Home Programming Language - File System Operations
// Cross-platform file system syscall wrappers

const std = @import("std");
const builtin = @import("builtin");

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

// Get file status
pub fn stat(path: []const u8) !FileStat {
    const s = try std.fs.cwd().statFile(path);

    return .{
        .file_type = switch (s.kind) {
            .file => .regular,
            .directory => .directory,
            .sym_link => .symlink,
            .block_device => .block_device,
            .character_device => .character_device,
            .named_pipe => .fifo,
            .unix_domain_socket => .socket,
            else => .unknown,
        },
        .permissions = FilePermissions.fromMode(@intCast(s.mode)),
        .size = s.size,
        .uid = if (builtin.os.tag != .windows) @intCast(s.uid) else 0,
        .gid = if (builtin.os.tag != .windows) @intCast(s.gid) else 0,
        .atime = s.atime,
        .mtime = s.mtime,
        .ctime = s.ctime,
        .inode = s.inode,
        .nlink = if (builtin.os.tag != .windows) s.nlink else 1,
        .dev = if (builtin.os.tag != .windows) s.dev else 0,
        .rdev = if (builtin.os.tag != .windows) s.rdev else 0,
        .blksize = if (builtin.os.tag != .windows) @intCast(s.blksize) else 0,
        .blocks = if (builtin.os.tag != .windows) @intCast(s.blocks) else 0,
    };
}

// Check if file exists
pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// Check if path is a directory
pub fn isDirectory(path: []const u8) !bool {
    const s = try stat(path);
    return s.file_type == .directory;
}

// Check if path is a file
pub fn isFile(path: []const u8) !bool {
    const s = try stat(path);
    return s.file_type == .regular;
}

// Check if path is a symlink
pub fn isSymlink(path: []const u8) !bool {
    const s = try stat(path);
    return s.file_type == .symlink;
}

// Create directory
pub fn mkdir(path: []const u8, mode: u32) !void {
    try std.fs.cwd().makeDir(path);
    if (builtin.os.tag != .windows) {
        try chmod(path, mode);
    }
}

// Create directory recursively
pub fn mkdirAll(path: []const u8, mode: u32) !void {
    try std.fs.cwd().makePath(path);
    if (builtin.os.tag != .windows) {
        try chmod(path, mode);
    }
}

// Remove file
pub fn unlink(path: []const u8) !void {
    try std.fs.cwd().deleteFile(path);
}

// Remove directory
pub fn rmdir(path: []const u8) !void {
    try std.fs.cwd().deleteDir(path);
}

// Remove directory recursively
pub fn rmAll(path: []const u8) !void {
    try std.fs.cwd().deleteTree(path);
}

// Change file permissions (Unix-specific)
pub fn chmod(path: []const u8, mode: u32) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const path_z = try std.posix.toPosixPath(path);
    try std.posix.chmod(&path_z, mode);
}

// Change file owner (Unix-specific)
pub fn chown(path: []const u8, uid: u32, gid: u32) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const path_z = try std.posix.toPosixPath(path);
    try std.posix.chown(&path_z, uid, gid);
}

// Rename file
pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    try std.fs.cwd().rename(old_path, new_path);
}

// Create symlink
pub fn symlink(target: []const u8, link_path: []const u8) !void {
    try std.fs.cwd().symLink(target, link_path, .{});
}

// Read symlink
pub fn readlink(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readLink(path, allocator);
}

// Create hard link
pub fn link(old_path: []const u8, new_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const old_z = try std.posix.toPosixPath(old_path);
    const new_z = try std.posix.toPosixPath(new_path);

    const c = struct {
        extern "c" fn link([*:0]const u8, [*:0]const u8) c_int;
    };

    const result = c.link(&old_z, &new_z);
    if (result != 0) {
        return error.LinkFailed;
    }
}

// Get current working directory
pub fn getcwd(allocator: std.mem.Allocator) ![]u8 {
    return try std.process.getCwdAlloc(allocator);
}

// Change current working directory
pub fn chdir(path: []const u8) !void {
    try std.process.changeCurDir(path);
}

// List directory entries
pub const DirectoryEntry = struct {
    name: []const u8,
    file_type: FileType,
};

pub fn listDir(allocator: std.mem.Allocator, path: []const u8) ![]DirectoryEntry {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList(DirectoryEntry){};
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        const file_type: FileType = switch (entry.kind) {
            .file => .regular,
            .directory => .directory,
            .sym_link => .symlink,
            .block_device => .block_device,
            .character_device => .character_device,
            .named_pipe => .fifo,
            .unix_domain_socket => .socket,
            else => .unknown,
        };

        try entries.append(allocator, .{
            .name = name,
            .file_type = file_type,
        });
    }

    return try entries.toOwnedSlice(allocator);
}

// Truncate file
pub fn truncate(path: []const u8, length: u64) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();

    try file.setEndPos(length);
}

// Sync file to disk
pub fn sync(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    try file.sync();
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

test "file exists" {
    const testing = std.testing;

    // Test with a file that should exist
    try testing.expect(exists("/") or exists("C:\\"));

    // Test with a file that shouldn't exist
    try testing.expect(!exists("/nonexistent_file_12345.txt"));
}

test "getcwd" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cwd = try getcwd(allocator);
    defer allocator.free(cwd);

    try testing.expect(cwd.len > 0);
}
