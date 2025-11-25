// Home OS Kernel - RAM Filesystem (ramfs/tmpfs)
// In-memory filesystem implementation

const Basics = @import("basics");
const vfs = @import("vfs.zig");
const vfs_sync = @import("vfs_sync.zig");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const timer = @import("timer.zig");

// ============================================================================
// Ramfs Inode Data
// ============================================================================

const RamfsInodeData = struct {
    /// For regular files: file content
    data: ?[]u8,
    /// For symlinks: target path
    symlink_target: ?[]const u8,
    /// For directories: child entries
    entries: Basics.ArrayList(DirectoryEntry),
    /// Allocator used for this inode
    allocator: Basics.Allocator,

    const DirectoryEntry = struct {
        name: [256]u8,
        name_len: u8,
        inode: *vfs.Inode,
    };

    pub fn init(allocator: Basics.Allocator) RamfsInodeData {
        return .{
            .data = null,
            .symlink_target = null,
            .entries = Basics.ArrayList(DirectoryEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RamfsInodeData) void {
        if (self.data) |d| {
            self.allocator.free(d);
        }
        if (self.symlink_target) |t| {
            self.allocator.free(t);
        }
        self.entries.deinit();
    }
};

// ============================================================================
// Ramfs Superblock Data
// ============================================================================

const RamfsSuperblockData = struct {
    /// Next inode number
    next_ino: atomic.AtomicU64,
    /// Total bytes used
    bytes_used: atomic.AtomicU64,
    /// Maximum bytes allowed (0 = unlimited)
    max_bytes: u64,
    /// Allocator
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, max_bytes: u64) RamfsSuperblockData {
        return .{
            .next_ino = atomic.AtomicU64.init(2), // 1 is root
            .bytes_used = atomic.AtomicU64.init(0),
            .max_bytes = max_bytes,
            .allocator = allocator,
        };
    }

    pub fn allocIno(self: *RamfsSuperblockData) u64 {
        return self.next_ino.fetchAdd(1, .Monotonic);
    }
};

// ============================================================================
// Ramfs Inode Operations
// ============================================================================

fn ramfsLookup(dir: *vfs.Inode, name: []const u8) anyerror!?*vfs.Dentry {
    const data: *RamfsInodeData = @ptrCast(@alignCast(dir.private_data));

    for (data.entries.items) |entry| {
        const entry_name = entry.name[0..entry.name_len];
        if (Basics.mem.eql(u8, entry_name, name)) {
            // Create and return dentry
            const dentry = try vfs.Dentry.init(dir.sb, null, name, entry.inode);
            _ = entry.inode.refcount.acquire();
            return dentry;
        }
    }

    return null;
}

fn ramfsCreate(dir: *vfs.Inode, name: []const u8, mode: vfs.FileMode) anyerror!*vfs.Inode {
    const sb_data: *RamfsSuperblockData = @ptrCast(@alignCast(dir.sb.private_data));
    const dir_data: *RamfsInodeData = @ptrCast(@alignCast(dir.private_data));

    // Create new inode
    const inode = try dir.sb.allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(dir.sb, sb_data.allocIno(), .Regular, &ramfs_inode_ops);
    inode.mode = mode;
    inode.uid = dir.uid;
    inode.gid = dir.gid;

    // Create inode data
    const inode_data = try dir.sb.allocator.create(RamfsInodeData);
    inode_data.* = RamfsInodeData.init(dir.sb.allocator);
    inode.private_data = inode_data;

    // Add to directory
    var entry = RamfsInodeData.DirectoryEntry{
        .name = undefined,
        .name_len = @intCast(name.len),
        .inode = inode,
    };
    @memcpy(entry.name[0..name.len], name);
    try dir_data.entries.append(entry);

    // Update directory timestamps
    const now = timer.getTicks();
    dir.mtime = now;
    dir.ctime = now;

    return inode;
}

fn ramfsMkdir(dir: *vfs.Inode, name: []const u8, mode: vfs.FileMode) anyerror!*vfs.Inode {
    const sb_data: *RamfsSuperblockData = @ptrCast(@alignCast(dir.sb.private_data));
    const dir_data: *RamfsInodeData = @ptrCast(@alignCast(dir.private_data));

    // Create new directory inode
    const inode = try dir.sb.allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(dir.sb, sb_data.allocIno(), .Directory, &ramfs_inode_ops);
    inode.mode = mode;
    inode.uid = dir.uid;
    inode.gid = dir.gid;
    inode.nlink = 2; // . and parent's entry

    // Create inode data
    const inode_data = try dir.sb.allocator.create(RamfsInodeData);
    inode_data.* = RamfsInodeData.init(dir.sb.allocator);
    inode.private_data = inode_data;

    // Add . and .. entries
    var dot_entry = RamfsInodeData.DirectoryEntry{
        .name = undefined,
        .name_len = 1,
        .inode = inode,
    };
    dot_entry.name[0] = '.';
    try inode_data.entries.append(dot_entry);

    var dotdot_entry = RamfsInodeData.DirectoryEntry{
        .name = undefined,
        .name_len = 2,
        .inode = dir,
    };
    dotdot_entry.name[0] = '.';
    dotdot_entry.name[1] = '.';
    try inode_data.entries.append(dotdot_entry);

    // Add to parent directory
    var entry = RamfsInodeData.DirectoryEntry{
        .name = undefined,
        .name_len = @intCast(name.len),
        .inode = inode,
    };
    @memcpy(entry.name[0..name.len], name);
    try dir_data.entries.append(entry);

    dir.nlink += 1;
    dir.mtime = 0;
    dir.ctime = 0;

    return inode;
}

fn ramfsUnlink(dir: *vfs.Inode, name: []const u8) anyerror!void {
    const dir_data: *RamfsInodeData = @ptrCast(@alignCast(dir.private_data));

    // Find and remove entry
    for (dir_data.entries.items, 0..) |entry, i| {
        const entry_name = entry.name[0..entry.name_len];
        if (Basics.mem.eql(u8, entry_name, name)) {
            const inode = entry.inode;

            // Remove from directory
            _ = dir_data.entries.orderedRemove(i);

            // Decrement link count
            inode.nlink -= 1;
            if (inode.nlink == 0) {
                // Free inode data
                if (inode.private_data) |pd| {
                    const inode_data: *RamfsInodeData = @ptrCast(@alignCast(pd));
                    inode_data.deinit();
                    inode.sb.allocator.destroy(inode_data);
                }
            }

            dir.mtime = 0;
            dir.ctime = 0;
            return;
        }
    }

    return error.FileNotFound;
}

fn ramfsRmdir(dir: *vfs.Inode, name: []const u8) anyerror!void {
    const dir_data: *RamfsInodeData = @ptrCast(@alignCast(dir.private_data));

    // Find entry
    for (dir_data.entries.items, 0..) |entry, i| {
        const entry_name = entry.name[0..entry.name_len];
        if (Basics.mem.eql(u8, entry_name, name)) {
            const inode = entry.inode;

            if (inode.inode_type != .Directory) {
                return error.NotADirectory;
            }

            // Check if directory is empty (only . and ..)
            const inode_data: *RamfsInodeData = @ptrCast(@alignCast(inode.private_data));
            if (inode_data.entries.items.len > 2) {
                return error.DirectoryNotEmpty;
            }

            // Remove from parent
            _ = dir_data.entries.orderedRemove(i);

            // Cleanup
            inode_data.deinit();
            inode.sb.allocator.destroy(inode_data);

            dir.nlink -= 1;
            dir.mtime = 0;
            dir.ctime = 0;
            return;
        }
    }

    return error.FileNotFound;
}

fn ramfsSymlink(dir: *vfs.Inode, name: []const u8, target: []const u8) anyerror!*vfs.Inode {
    const sb_data: *RamfsSuperblockData = @ptrCast(@alignCast(dir.sb.private_data));
    const dir_data: *RamfsInodeData = @ptrCast(@alignCast(dir.private_data));

    // Create symlink inode
    const inode = try dir.sb.allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(dir.sb, sb_data.allocIno(), .Symlink, &ramfs_inode_ops);
    inode.mode = vfs.FileMode.fromU16(0o777);
    inode.uid = dir.uid;
    inode.gid = dir.gid;
    inode.size = target.len;

    // Create inode data with symlink target
    const inode_data = try dir.sb.allocator.create(RamfsInodeData);
    inode_data.* = RamfsInodeData.init(dir.sb.allocator);

    const target_copy = try dir.sb.allocator.alloc(u8, target.len);
    @memcpy(target_copy, target);
    inode_data.symlink_target = target_copy;

    inode.private_data = inode_data;

    // Add to directory
    var entry = RamfsInodeData.DirectoryEntry{
        .name = undefined,
        .name_len = @intCast(name.len),
        .inode = inode,
    };
    @memcpy(entry.name[0..name.len], name);
    try dir_data.entries.append(entry);

    _ = sb_data.bytes_used.fetchAdd(target.len, .Release);

    return inode;
}

fn ramfsReadlink(inode: *vfs.Inode, buffer: []u8) anyerror!usize {
    const data: *RamfsInodeData = @ptrCast(@alignCast(inode.private_data));
    const target = data.symlink_target orelse return error.InvalidArgument;

    const copy_len = @min(buffer.len, target.len);
    @memcpy(buffer[0..copy_len], target[0..copy_len]);
    return copy_len;
}

fn ramfsTruncate(inode: *vfs.Inode, size: u64) anyerror!void {
    const data: *RamfsInodeData = @ptrCast(@alignCast(inode.private_data));
    const sb_data: *RamfsSuperblockData = @ptrCast(@alignCast(inode.sb.private_data));

    const old_size = inode.size;

    if (size == 0) {
        if (data.data) |d| {
            _ = sb_data.bytes_used.fetchSub(d.len, .Release);
            data.allocator.free(d);
            data.data = null;
        }
    } else if (size > old_size) {
        // Extend file
        const new_data = try data.allocator.alloc(u8, size);
        if (data.data) |d| {
            @memcpy(new_data[0..d.len], d);
            @memset(new_data[d.len..], 0);
            _ = sb_data.bytes_used.fetchSub(d.len, .Release);
            data.allocator.free(d);
        } else {
            @memset(new_data, 0);
        }
        data.data = new_data;
        _ = sb_data.bytes_used.fetchAdd(size, .Release);
    } else {
        // Shrink file
        const new_data = try data.allocator.alloc(u8, size);
        if (data.data) |d| {
            @memcpy(new_data, d[0..size]);
            _ = sb_data.bytes_used.fetchSub(d.len, .Release);
            data.allocator.free(d);
        }
        data.data = new_data;
        _ = sb_data.bytes_used.fetchAdd(size, .Release);
    }

    inode.size = size;
    inode.mtime = 0;
    inode.ctime = 0;
}

fn ramfsDestroy(inode: *vfs.Inode) void {
    if (inode.private_data) |pd| {
        const data: *RamfsInodeData = @ptrCast(@alignCast(pd));
        data.deinit();
        inode.sb.allocator.destroy(data);
    }
}

const ramfs_inode_ops = vfs.InodeOperations{
    .lookup = ramfsLookup,
    .create = ramfsCreate,
    .mkdir = ramfsMkdir,
    .unlink = ramfsUnlink,
    .rmdir = ramfsRmdir,
    .symlink = ramfsSymlink,
    .readlink = ramfsReadlink,
    .truncate = ramfsTruncate,
    .destroy = ramfsDestroy,
};

// ============================================================================
// Ramfs File Operations
// ============================================================================

fn ramfsRead(file: *vfs.File, buffer: []u8, offset: u64) anyerror!usize {
    const inode = file.dentry.inode;
    const data: *RamfsInodeData = @ptrCast(@alignCast(inode.private_data));

    const file_data = data.data orelse return 0;
    if (offset >= file_data.len) return 0;

    const available = file_data.len - offset;
    const copy_len = @min(buffer.len, available);

    @memcpy(buffer[0..copy_len], file_data[offset..][0..copy_len]);
    return copy_len;
}

fn ramfsWrite(file: *vfs.File, write_data: []const u8, offset: u64) anyerror!usize {
    const inode = file.dentry.inode;
    const data: *RamfsInodeData = @ptrCast(@alignCast(inode.private_data));
    const sb_data: *RamfsSuperblockData = @ptrCast(@alignCast(inode.sb.private_data));

    const end_offset = offset + write_data.len;

    // Check quota
    if (sb_data.max_bytes > 0) {
        const current_used = sb_data.bytes_used.load(.Acquire);
        if (current_used + write_data.len > sb_data.max_bytes) {
            return error.NoSpace;
        }
    }

    // Extend file if necessary
    if (data.data == null or end_offset > data.data.?.len) {
        const new_size = end_offset;
        const new_data = try data.allocator.alloc(u8, new_size);

        if (data.data) |d| {
            @memcpy(new_data[0..d.len], d);
            @memset(new_data[d.len..offset], 0);
            _ = sb_data.bytes_used.fetchSub(d.len, .Release);
            data.allocator.free(d);
        } else {
            @memset(new_data[0..offset], 0);
        }

        data.data = new_data;
        _ = sb_data.bytes_used.fetchAdd(new_size, .Release);
    }

    // Write data
    @memcpy(data.data.?[offset..][0..write_data.len], write_data);

    if (end_offset > inode.size) {
        inode.size = end_offset;
    }

    return write_data.len;
}

fn ramfsReaddir(file: *vfs.File, callback: *const fn (name: []const u8, ino: u64, itype: vfs.InodeType) bool) anyerror!void {
    const inode = file.dentry.inode;
    const data: *RamfsInodeData = @ptrCast(@alignCast(inode.private_data));

    for (data.entries.items) |entry| {
        const name = entry.name[0..entry.name_len];
        if (!callback(name, entry.inode.ino, entry.inode.inode_type)) {
            break;
        }
    }
}

const ramfs_file_ops = vfs.FileOperations{
    .read = ramfsRead,
    .write = ramfsWrite,
    .readdir = ramfsReaddir,
};

// ============================================================================
// Ramfs Superblock Operations
// ============================================================================

fn ramfsAllocInode(sb: *vfs.Superblock) anyerror!*vfs.Inode {
    const sb_data: *RamfsSuperblockData = @ptrCast(@alignCast(sb.private_data));

    const inode = try sb.allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(sb, sb_data.allocIno(), .Regular, &ramfs_inode_ops);

    const inode_data = try sb.allocator.create(RamfsInodeData);
    inode_data.* = RamfsInodeData.init(sb.allocator);
    inode.private_data = inode_data;

    return inode;
}

fn ramfsFreeInode(sb: *vfs.Superblock, inode: *vfs.Inode) void {
    if (inode.private_data) |pd| {
        const data: *RamfsInodeData = @ptrCast(@alignCast(pd));
        data.deinit();
        sb.allocator.destroy(data);
    }
    sb.allocator.destroy(inode);
}

fn ramfsStatfs(sb: *vfs.Superblock, buf: *vfs.StatFs) anyerror!void {
    const sb_data: *RamfsSuperblockData = @ptrCast(@alignCast(sb.private_data));

    buf.* = .{
        .fs_type = 0x858458f6, // RAMFS_MAGIC
        .block_size = 4096,
        .blocks = if (sb_data.max_bytes > 0) sb_data.max_bytes / 4096 else 0,
        .blocks_free = if (sb_data.max_bytes > 0) (sb_data.max_bytes - sb_data.bytes_used.load(.Acquire)) / 4096 else 0,
        .blocks_avail = if (sb_data.max_bytes > 0) (sb_data.max_bytes - sb_data.bytes_used.load(.Acquire)) / 4096 else 0,
        .files = 0,
        .files_free = 0,
        .fsid = .{ 0, 0 },
        .namelen = 255,
        .frsize = 4096,
    };
}

const ramfs_sb_ops = vfs.SuperblockOperations{
    .alloc_inode = ramfsAllocInode,
    .free_inode = ramfsFreeInode,
    .statfs = ramfsStatfs,
};

// ============================================================================
// Ramfs Mount
// ============================================================================

fn ramfsMount(fs_type: *vfs.FilesystemType, source: ?[]const u8, flags: vfs.MountFlags, data: ?*anyopaque) anyerror!*vfs.Superblock {
    _ = source;
    _ = data;

    // Parse mount options for size limit
    const max_bytes: u64 = 0; // TODO: Parse from data

    // Use page allocator for ramfs
    const allocator = Basics.heap.page_allocator;

    // Create superblock
    const sb = try allocator.create(vfs.Superblock);
    sb.* = vfs.Superblock.init(allocator, fs_type);
    sb.ops = &ramfs_sb_ops;
    sb.block_size = 4096;
    sb.flags.read_only = flags.read_only;

    // Create superblock data
    const sb_data = try allocator.create(RamfsSuperblockData);
    sb_data.* = RamfsSuperblockData.init(allocator, max_bytes);
    sb.private_data = sb_data;

    // Create root inode
    const root_inode = try allocator.create(vfs.Inode);
    root_inode.* = vfs.Inode.init(sb, 1, .Directory, &ramfs_inode_ops);
    root_inode.mode = vfs.FileMode.fromU16(0o755);
    root_inode.nlink = 2;

    const root_data = try allocator.create(RamfsInodeData);
    root_data.* = RamfsInodeData.init(allocator);
    root_inode.private_data = root_data;

    // Create root dentry
    const root_dentry = try vfs.Dentry.init(sb, null, "/", root_inode);
    sb.root = root_dentry;

    // Add . entry to root
    var dot_entry = RamfsInodeData.DirectoryEntry{
        .name = undefined,
        .name_len = 1,
        .inode = root_inode,
    };
    dot_entry.name[0] = '.';
    try root_data.entries.append(dot_entry);

    return sb;
}

fn ramfsKillSb(sb: *vfs.Superblock) void {
    // Free all inodes
    if (sb.private_data) |pd| {
        const sb_data: *RamfsSuperblockData = @ptrCast(@alignCast(pd));
        sb.allocator.destroy(sb_data);
    }

    // Free superblock
    sb.allocator.destroy(sb);
}

// ============================================================================
// Filesystem Type Registration
// ============================================================================

pub var ramfs_type = vfs.FilesystemType{
    .name = undefined,
    .name_len = 5,
    .flags = .{},
    .mount = ramfsMount,
    .kill_sb = ramfsKillSb,
    .next = null,
};

/// Initialize ramfs
pub fn init() void {
    const name = "ramfs";
    @memcpy(ramfs_type.name[0..name.len], name);
    vfs.registerFilesystem(&ramfs_type);
}

// Also register as tmpfs (alias)
pub var tmpfs_type = vfs.FilesystemType{
    .name = undefined,
    .name_len = 5,
    .flags = .{},
    .mount = ramfsMount,
    .kill_sb = ramfsKillSb,
    .next = null,
};

pub fn initTmpfs() void {
    const name = "tmpfs";
    @memcpy(tmpfs_type.name[0..name.len], name);
    vfs.registerFilesystem(&tmpfs_type);
}

// ============================================================================
// Tests
// ============================================================================

test "ramfs create and read file" {
    const allocator = Basics.testing.allocator;

    // Create superblock
    var sb = vfs.Superblock.init(allocator, &ramfs_type);
    var sb_data = RamfsSuperblockData.init(allocator, 0);
    sb.private_data = &sb_data;

    // Create root inode
    var root_inode = vfs.Inode.init(&sb, 1, .Directory, &ramfs_inode_ops);
    var root_data = RamfsInodeData.init(allocator);
    root_inode.private_data = &root_data;
    defer root_data.deinit();

    // Create a file
    const file_inode = try ramfsCreate(&root_inode, "test.txt", vfs.FileMode.fromU16(0o644));
    defer {
        if (file_inode.private_data) |pd| {
            const data: *RamfsInodeData = @ptrCast(@alignCast(pd));
            data.deinit();
        }
    }

    try Basics.testing.expectEqual(vfs.InodeType.Regular, file_inode.inode_type);
}
