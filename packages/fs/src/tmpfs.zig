// Home Programming Language - tmpfs (Temporary File System)
// In-memory file system for /tmp and ramdisks

const Basics = @import("basics");
const vfs = @import("vfs.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// ============================================================================
// tmpfs Inode Data
// ============================================================================

pub const TmpfsInodeData = struct {
    data: ?[]u8,
    capacity: usize,
    allocator: Basics.Allocator,
    lock: sync.RwLock,

    pub fn init(allocator: Basics.Allocator) TmpfsInodeData {
        return .{
            .data = null,
            .capacity = 0,
            .allocator = allocator,
            .lock = sync.RwLock.init(),
        };
    }

    pub fn deinit(self: *TmpfsInodeData) void {
        if (self.data) |data| {
            self.allocator.free(data);
        }
    }

    pub fn resize(self: *TmpfsInodeData, new_size: usize) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (new_size == 0) {
            if (self.data) |data| {
                self.allocator.free(data);
            }
            self.data = null;
            self.capacity = 0;
            return;
        }

        if (self.data) |old_data| {
            if (new_size <= self.capacity) {
                return; // Current capacity sufficient
            }

            const new_data = try self.allocator.alloc(u8, new_size);
            @memcpy(new_data[0..old_data.len], old_data);
            self.allocator.free(old_data);
            self.data = new_data;
            self.capacity = new_size;
        } else {
            self.data = try self.allocator.alloc(u8, new_size);
            self.capacity = new_size;
        }
    }

    pub fn read(self: *TmpfsInodeData, offset: u64, buffer: []u8) !usize {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        const data = self.data orelse return 0;

        if (offset >= data.len) return 0;

        const available = data.len - offset;
        const to_read = Basics.math.min(buffer.len, available);

        @memcpy(buffer[0..to_read], data[offset..][0..to_read]);
        return to_read;
    }

    pub fn write(self: *TmpfsInodeData, offset: u64, data: []const u8) !usize {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const end_pos = offset + data.len;

        // Resize if needed
        if (self.data == null or end_pos > self.capacity) {
            const new_capacity = Basics.mem.alignForward(usize, end_pos, 4096);
            try self.resize(new_capacity);
        }

        const buffer = self.data.?;
        @memcpy(buffer[offset..][0..data.len], data);

        return data.len;
    }
};

// ============================================================================
// tmpfs Directory Entry
// ============================================================================

pub const TmpfsDirEntry = struct {
    name: [256]u8,
    name_len: usize,
    ino: u64,

    pub fn init(name: []const u8, ino: u64) TmpfsDirEntry {
        var entry_name: [256]u8 = undefined;
        const len = Basics.math.min(name.len, 255);
        @memcpy(entry_name[0..len], name[0..len]);

        return .{
            .name = entry_name,
            .name_len = len,
            .ino = ino,
        };
    }

    pub fn getName(self: *const TmpfsDirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const TmpfsDir = struct {
    entries: Basics.ArrayList(TmpfsDirEntry),
    lock: sync.RwLock,

    pub fn init(allocator: Basics.Allocator) TmpfsDir {
        return .{
            .entries = Basics.ArrayList(TmpfsDirEntry).init(allocator),
            .lock = sync.RwLock.init(),
        };
    }

    pub fn deinit(self: *TmpfsDir) void {
        self.entries.deinit();
    }

    pub fn addEntry(self: *TmpfsDir, name: []const u8, ino: u64) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const entry = TmpfsDirEntry.init(name, ino);
        try self.entries.append(entry);
    }

    pub fn removeEntry(self: *TmpfsDir, name: []const u8) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        for (self.entries.items, 0..) |*entry, i| {
            if (Basics.mem.eql(u8, entry.getName(), name)) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
        return error.FileNotFound;
    }

    pub fn lookup(self: *TmpfsDir, name: []const u8) ?u64 {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.entries.items) |*entry| {
            if (Basics.mem.eql(u8, entry.getName(), name)) {
                return entry.ino;
            }
        }
        return null;
    }
};

// ============================================================================
// tmpfs Superblock
// ============================================================================

pub const TmpfsSuperblock = struct {
    next_ino: atomic.AtomicU64,
    inodes: Basics.HashMap(u64, *vfs.Inode, Basics.hash_map.AutoContext(u64), 80),
    allocator: Basics.Allocator,
    lock: sync.Spinlock,

    pub fn init(allocator: Basics.Allocator) !*TmpfsSuperblock {
        const sb = try allocator.create(TmpfsSuperblock);
        sb.* = .{
            .next_ino = atomic.AtomicU64.init(2), // 1 is reserved for root
            .inodes = Basics.HashMap(u64, *vfs.Inode, Basics.hash_map.AutoContext(u64), 80).init(allocator),
            .allocator = allocator,
            .lock = sync.Spinlock.init(),
        };
        return sb;
    }

    pub fn deinit(self: *TmpfsSuperblock) void {
        var it = self.inodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.release(self.allocator);
        }
        self.inodes.deinit();
        self.allocator.destroy(self);
    }

    pub fn allocateIno(self: *TmpfsSuperblock) u64 {
        return self.next_ino.fetchAdd(1, .Monotonic);
    }

    pub fn registerInode(self: *TmpfsSuperblock, inode: *vfs.Inode) !void {
        self.lock.acquire();
        defer self.lock.release();

        try self.inodes.put(inode.ino, inode);
    }

    pub fn getInode(self: *TmpfsSuperblock, ino: u64) ?*vfs.Inode {
        self.lock.acquire();
        defer self.lock.release();

        return self.inodes.get(ino);
    }
};

// ============================================================================
// tmpfs Operations
// ============================================================================

const tmpfs_inode_ops = vfs.InodeOps{
    .lookup = tmpfsLookup,
    .create = tmpfsCreate,
    .mkdir = tmpfsMkdir,
    .rmdir = tmpfsRmdir,
    .unlink = tmpfsUnlink,
    .symlink = null,
    .rename = null,
    .readlink = null,
    .truncate = tmpfsTruncate,
    .destroy = tmpfsDestroyInode,
};

fn tmpfsLookup(inode: *vfs.Inode, name: []const u8) !*vfs.Inode {
    if (!inode.isDirectory()) return error.NotADirectory;

    const dir: *TmpfsDir = @ptrCast(@alignCast(inode.fs_data.?));
    const ino = dir.lookup(name) orelse return error.FileNotFound;

    // Get superblock from somewhere
    const sb: *TmpfsSuperblock = @ptrCast(@alignCast(inode.fs_data.?));
    const child_inode = sb.getInode(ino) orelse return error.FileNotFound;

    child_inode.acquire();
    return child_inode;
}

fn tmpfsCreate(parent: *vfs.Inode, name: []const u8, mode: vfs.FileMode) !*vfs.Inode {
    _ = mode;

    const dir: *TmpfsDir = @ptrCast(@alignCast(parent.fs_data.?));
    const sb: *TmpfsSuperblock = @ptrCast(@alignCast(parent.fs_data.?));

    const ino = sb.allocateIno();
    const inode = try sb.allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(ino, .Regular, &tmpfs_inode_ops);

    const inode_data = try sb.allocator.create(TmpfsInodeData);
    inode_data.* = TmpfsInodeData.init(sb.allocator);
    inode.fs_data = inode_data;

    try sb.registerInode(inode);
    try dir.addEntry(name, ino);

    return inode;
}

fn tmpfsMkdir(parent: *vfs.Inode, name: []const u8, mode: vfs.FileMode) !*vfs.Inode {
    _ = mode;

    const dir: *TmpfsDir = @ptrCast(@alignCast(parent.fs_data.?));
    const sb: *TmpfsSuperblock = @ptrCast(@alignCast(parent.fs_data.?));

    const ino = sb.allocateIno();
    const inode = try sb.allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(ino, .Directory, &tmpfs_inode_ops);

    const new_dir = try sb.allocator.create(TmpfsDir);
    new_dir.* = TmpfsDir.init(sb.allocator);
    inode.fs_data = new_dir;

    try sb.registerInode(inode);
    try dir.addEntry(name, ino);

    return inode;
}

fn tmpfsRmdir(parent: *vfs.Inode, name: []const u8) !void {
    const dir: *TmpfsDir = @ptrCast(@alignCast(parent.fs_data.?));
    try dir.removeEntry(name);
}

fn tmpfsUnlink(parent: *vfs.Inode, name: []const u8) !void {
    const dir: *TmpfsDir = @ptrCast(@alignCast(parent.fs_data.?));
    try dir.removeEntry(name);
}

fn tmpfsTruncate(inode: *vfs.Inode, new_size: u64) !void {
    const data: *TmpfsInodeData = @ptrCast(@alignCast(inode.fs_data.?));
    try data.resize(new_size);
    inode.size = new_size;
}

fn tmpfsDestroyInode(inode: *vfs.Inode) void {
    if (inode.isDirectory()) {
        const dir: *TmpfsDir = @ptrCast(@alignCast(inode.fs_data.?));
        dir.deinit();
    } else {
        const data: *TmpfsInodeData = @ptrCast(@alignCast(inode.fs_data.?));
        data.deinit();
    }
}

// ============================================================================
// tmpfs File Operations
// ============================================================================

const tmpfs_file_ops = vfs.FileOps{
    .read = tmpfsFileRead,
    .write = tmpfsFileWrite,
    .seek = null,
    .ioctl = null,
    .mmap = null,
    .flush = null,
};

fn tmpfsFileRead(file: *vfs.File, buffer: []u8, offset: u64) !usize {
    const data: *TmpfsInodeData = @ptrCast(@alignCast(file.inode.fs_data.?));
    return data.read(offset, buffer);
}

fn tmpfsFileWrite(file: *vfs.File, data_to_write: []const u8, offset: u64) !usize {
    const data: *TmpfsInodeData = @ptrCast(@alignCast(file.inode.fs_data.?));
    const written = try data.write(offset, data_to_write);

    // Update file size
    const new_size = offset + written;
    if (new_size > file.inode.size) {
        file.inode.size = new_size;
    }

    return written;
}

// ============================================================================
// tmpfs Mount
// ============================================================================

pub fn mount(allocator: Basics.Allocator) !*vfs.Superblock {
    const tmpfs_sb = try TmpfsSuperblock.init(allocator);

    // Create root inode
    const root_inode = try allocator.create(vfs.Inode);
    root_inode.* = vfs.Inode.init(1, .Directory, &tmpfs_inode_ops);

    const root_dir = try allocator.create(TmpfsDir);
    root_dir.* = TmpfsDir.init(allocator);
    root_inode.fs_data = root_dir;

    try tmpfs_sb.registerInode(root_inode);

    const sb = try allocator.create(vfs.Superblock);
    sb.* = vfs.Superblock.init("tmpfs", 4096, root_inode, &tmpfs_sb_ops);
    sb.fs_data = tmpfs_sb;

    return sb;
}

const tmpfs_sb_ops = vfs.SuperblockOps{
    .alloc_inode = tmpfsAllocInode,
    .destroy_inode = tmpfsDestroyInodeSb,
    .write_inode = null,
    .sync_fs = null,
    .statfs = tmpfsStatFs,
};

fn tmpfsAllocInode(sb: *vfs.Superblock) !*vfs.Inode {
    const tmpfs_sb: *TmpfsSuperblock = @ptrCast(@alignCast(sb.fs_data.?));
    const ino = tmpfs_sb.allocateIno();

    const inode = try tmpfs_sb.allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(ino, .Regular, &tmpfs_inode_ops);

    return inode;
}

fn tmpfsDestroyInodeSb(sb: *vfs.Superblock, inode: *vfs.Inode) void {
    const tmpfs_sb: *TmpfsSuperblock = @ptrCast(@alignCast(sb.fs_data.?));
    inode.release(tmpfs_sb.allocator);
}

fn tmpfsStatFs(sb: *vfs.Superblock, statfs: *vfs.StatFs) !void {
    _ = sb;
    statfs.* = .{
        .block_size = 4096,
        .total_blocks = 0,
        .free_blocks = 0,
        .available_blocks = 0,
        .total_inodes = 0,
        .free_inodes = 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "tmpfs basic" {
    const allocator = Basics.testing.allocator;

    const sb = try mount(allocator);
    defer {
        const tmpfs_sb: *TmpfsSuperblock = @ptrCast(@alignCast(sb.fs_data.?));
        tmpfs_sb.deinit();
        allocator.destroy(sb);
    }

    try Basics.testing.expect(sb.root_inode.isDirectory());
}
