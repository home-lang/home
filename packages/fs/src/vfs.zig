// Home Programming Language - Virtual File System (VFS)
// Unified file system abstraction layer

const Basics = @import("basics");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// ============================================================================
// File Types
// ============================================================================

pub const FileType = enum(u8) {
    Unknown,
    Regular,
    Directory,
    Symlink,
    CharDevice,
    BlockDevice,
    Fifo,
    Socket,
};

// ============================================================================
// File Permissions
// ============================================================================

pub const FileMode = packed struct(u16) {
    other_execute: bool = false,
    other_write: bool = false,
    other_read: bool = false,
    group_execute: bool = false,
    group_write: bool = false,
    group_read: bool = false,
    user_execute: bool = false,
    user_write: bool = false,
    user_read: bool = false,
    sticky: bool = false,
    setgid: bool = false,
    setuid: bool = false,
    _padding: u4 = 0,

    pub fn fromOctal(mode: u16) FileMode {
        return @bitCast(mode);
    }

    pub fn toOctal(self: FileMode) u16 {
        return @bitCast(self);
    }
};

// ============================================================================
// Inode (Index Node)
// ============================================================================

pub const Inode = struct {
    ino: u64,
    file_type: FileType,
    mode: FileMode,
    uid: u32,
    gid: u32,
    size: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    nlinks: atomic.AtomicU32,
    blocks: u64,
    ops: *const InodeOps,
    fs_data: ?*anyopaque,
    lock: sync.RwLock,
    refcount: atomic.AtomicU32,

    pub fn init(ino: u64, file_type: FileType, ops: *const InodeOps) Inode {
        return .{
            .ino = ino,
            .file_type = file_type,
            .mode = .{ .user_read = true, .user_write = true },
            .uid = 0,
            .gid = 0,
            .size = 0,
            .atime = 0,
            .mtime = 0,
            .ctime = 0,
            .nlinks = atomic.AtomicU32.init(1),
            .blocks = 0,
            .ops = ops,
            .fs_data = null,
            .lock = sync.RwLock.init(),
            .refcount = atomic.AtomicU32.init(1),
        };
    }

    pub fn acquire(self: *Inode) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    pub fn release(self: *Inode, allocator: Basics.Allocator) void {
        const old = self.refcount.fetchSub(1, .Release);
        if (old == 1) {
            if (self.ops.destroy) |destroy| {
                destroy(self);
            }
            allocator.destroy(self);
        }
    }

    pub fn isDirectory(self: *const Inode) bool {
        return self.file_type == .Directory;
    }

    pub fn isRegularFile(self: *const Inode) bool {
        return self.file_type == .Regular;
    }
};

// ============================================================================
// Inode Operations
// ============================================================================

pub const InodeOps = struct {
    lookup: ?*const fn (*Inode, []const u8) anyerror!*Inode,
    create: ?*const fn (*Inode, []const u8, FileMode) anyerror!*Inode,
    mkdir: ?*const fn (*Inode, []const u8, FileMode) anyerror!*Inode,
    rmdir: ?*const fn (*Inode, []const u8) anyerror!void,
    unlink: ?*const fn (*Inode, []const u8) anyerror!void,
    symlink: ?*const fn (*Inode, []const u8, []const u8) anyerror!*Inode,
    rename: ?*const fn (*Inode, []const u8, *Inode, []const u8) anyerror!void,
    readlink: ?*const fn (*Inode, []u8) anyerror!usize,
    truncate: ?*const fn (*Inode, u64) anyerror!void,
    destroy: ?*const fn (*Inode) void,
};

// ============================================================================
// Directory Entry (Dentry)
// ============================================================================

pub const Dentry = struct {
    name: [256]u8,
    name_len: usize,
    inode: ?*Inode,
    parent: ?*Dentry,
    children: Basics.ArrayList(*Dentry),
    lock: sync.RwLock,
    refcount: atomic.AtomicU32,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, name: []const u8, inode: ?*Inode) !*Dentry {
        const dentry = try allocator.create(Dentry);
        errdefer allocator.destroy(dentry);

        var dentry_name: [256]u8 = undefined;
        const len = Basics.math.min(name.len, 255);
        @memcpy(dentry_name[0..len], name[0..len]);

        dentry.* = .{
            .name = dentry_name,
            .name_len = len,
            .inode = inode,
            .parent = null,
            .children = Basics.ArrayList(*Dentry).init(allocator),
            .lock = sync.RwLock.init(),
            .refcount = atomic.AtomicU32.init(1),
            .allocator = allocator,
        };

        if (inode) |ino| {
            ino.acquire();
        }

        return dentry;
    }

    pub fn deinit(self: *Dentry) void {
        for (self.children.items) |child| {
            child.release();
        }
        self.children.deinit();

        if (self.inode) |inode| {
            inode.release(self.allocator);
        }

        self.allocator.destroy(self);
    }

    pub fn getName(self: *const Dentry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn addChild(self: *Dentry, child: *Dentry) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        child.parent = self;
        child.acquire();
        try self.children.append(child);
    }

    pub fn removeChild(self: *Dentry, child: *Dentry) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.swapRemove(i);
                child.release();
                break;
            }
        }
    }

    pub fn findChild(self: *Dentry, name: []const u8) ?*Dentry {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.children.items) |child| {
            if (Basics.mem.eql(u8, child.getName(), name)) {
                child.acquire();
                return child;
            }
        }
        return null;
    }

    pub fn acquire(self: *Dentry) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    pub fn release(self: *Dentry) void {
        const old = self.refcount.fetchSub(1, .Release);
        if (old == 1) {
            self.deinit();
        }
    }
};

// ============================================================================
// File Operations
// ============================================================================

pub const FileOps = struct {
    read: *const fn (*File, []u8, u64) anyerror!usize,
    write: *const fn (*File, []const u8, u64) anyerror!usize,
    seek: ?*const fn (*File, i64, SeekWhence) anyerror!u64,
    ioctl: ?*const fn (*File, u32, ?*anyopaque) anyerror!usize,
    mmap: ?*const fn (*File, u64, usize, u32) anyerror!u64,
    flush: ?*const fn (*File) anyerror!void,
};

pub const SeekWhence = enum {
    Set,
    Current,
    End,
};

// ============================================================================
// File Descriptor
// ============================================================================

pub const OpenFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    append: bool = false,
    create: bool = false,
    truncate: bool = false,
    exclusive: bool = false,
    nonblock: bool = false,
    _padding: u25 = 0,
};

pub const File = struct {
    dentry: *Dentry,
    inode: *Inode,
    position: atomic.AtomicU64,
    flags: OpenFlags,
    ops: *const FileOps,
    private_data: ?*anyopaque,
    lock: sync.Spinlock,
    refcount: atomic.AtomicU32,

    pub fn init(dentry: *Dentry, flags: OpenFlags, ops: *const FileOps) !*File {
        const inode = dentry.inode orelse return error.NoInode;

        const file = try dentry.allocator.create(File);
        file.* = .{
            .dentry = dentry,
            .inode = inode,
            .position = atomic.AtomicU64.init(0),
            .flags = flags,
            .ops = ops,
            .private_data = null,
            .lock = sync.Spinlock.init(),
            .refcount = atomic.AtomicU32.init(1),
        };

        dentry.acquire();
        inode.acquire();

        return file;
    }

    pub fn deinit(self: *File) void {
        self.inode.release(self.dentry.allocator);
        self.dentry.release();
        self.dentry.allocator.destroy(self);
    }

    pub fn read(self: *File, buffer: []u8) !usize {
        const pos = self.position.load(.Acquire);
        const n = try self.ops.read(self, buffer, pos);
        _ = self.position.fetchAdd(n, .Release);
        return n;
    }

    pub fn write(self: *File, data: []const u8) !usize {
        var pos = self.position.load(.Acquire);
        if (self.flags.append) {
            pos = self.inode.size;
        }
        const n = try self.ops.write(self, data, pos);
        _ = self.position.fetchAdd(n, .Release);
        return n;
    }

    pub fn seek(self: *File, offset: i64, whence: SeekWhence) !u64 {
        if (self.ops.seek) |seek_fn| {
            const new_pos = try seek_fn(self, offset, whence);
            self.position.store(new_pos, .Release);
            return new_pos;
        }

        // Default implementation
        const current_pos = self.position.load(.Acquire);
        const new_pos: u64 = switch (whence) {
            .Set => @intCast(offset),
            .Current => if (offset >= 0)
                current_pos + @as(u64, @intCast(offset))
            else
                current_pos - @as(u64, @intCast(-offset)),
            .End => if (offset >= 0)
                self.inode.size + @as(u64, @intCast(offset))
            else
                self.inode.size - @as(u64, @intCast(-offset)),
        };

        self.position.store(new_pos, .Release);
        return new_pos;
    }

    pub fn acquire(self: *File) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    pub fn release(self: *File) void {
        const old = self.refcount.fetchSub(1, .Release);
        if (old == 1) {
            self.deinit();
        }
    }
};

// ============================================================================
// Superblock
// ============================================================================

pub const Superblock = struct {
    fs_type: []const u8,
    block_size: u32,
    root_inode: *Inode,
    ops: *const SuperblockOps,
    fs_data: ?*anyopaque,
    lock: sync.Spinlock,

    pub fn init(
        fs_type: []const u8,
        block_size: u32,
        root_inode: *Inode,
        ops: *const SuperblockOps,
    ) Superblock {
        return .{
            .fs_type = fs_type,
            .block_size = block_size,
            .root_inode = root_inode,
            .ops = ops,
            .fs_data = null,
            .lock = sync.Spinlock.init(),
        };
    }
};

pub const SuperblockOps = struct {
    alloc_inode: *const fn (*Superblock) anyerror!*Inode,
    destroy_inode: *const fn (*Superblock, *Inode) void,
    write_inode: ?*const fn (*Superblock, *Inode) anyerror!void,
    sync_fs: ?*const fn (*Superblock) anyerror!void,
    statfs: ?*const fn (*Superblock, *StatFs) anyerror!void,
};

pub const StatFs = struct {
    block_size: u32,
    total_blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
    total_inodes: u64,
    free_inodes: u64,
};

// ============================================================================
// Mount Point
// ============================================================================

pub const Mount = struct {
    dentry: *Dentry,
    sb: *Superblock,
    flags: u32,
    next: ?*Mount,

    pub fn init(dentry: *Dentry, sb: *Superblock, flags: u32) Mount {
        return .{
            .dentry = dentry,
            .sb = sb,
            .flags = flags,
            .next = null,
        };
    }
};

// ============================================================================
// Path Resolution
// ============================================================================

pub fn resolvePath(
    allocator: Basics.Allocator,
    root: *Dentry,
    path: []const u8,
) !*Dentry {
    if (path.len == 0) return error.InvalidPath;

    var current = root;
    current.acquire();

    var it = Basics.mem.split(u8, path, "/");
    while (it.next()) |component| {
        if (component.len == 0) continue;

        if (Basics.mem.eql(u8, component, ".")) {
            continue;
        }

        if (Basics.mem.eql(u8, component, "..")) {
            if (current.parent) |parent| {
                const old = current;
                current = parent;
                current.acquire();
                old.release();
            }
            continue;
        }

        // Lookup in current directory
        const inode = current.inode orelse return error.NoInode;
        if (!inode.isDirectory()) return error.NotADirectory;

        // Try cache first
        if (current.findChild(component)) |child| {
            const old = current;
            current = child;
            old.release();
            continue;
        }

        // Lookup in filesystem
        if (inode.ops.lookup) |lookup| {
            const child_inode = try lookup(inode, component);
            const child_dentry = try Dentry.init(allocator, component, child_inode);
            try current.addChild(child_dentry);

            const old = current;
            current = child_dentry;
            current.acquire();
            old.release();
        } else {
            current.release();
            return error.FileNotFound;
        }
    }

    return current;
}

// ============================================================================
// Tests
// ============================================================================

test "file mode" {
    const mode = FileMode{ .user_read = true, .user_write = true, .user_execute = true };
    const octal = mode.toOctal();
    const restored = FileMode.fromOctal(octal);

    try Basics.testing.expect(restored.user_read);
    try Basics.testing.expect(restored.user_write);
    try Basics.testing.expect(restored.user_execute);
}

test "inode refcount" {
    const allocator = Basics.testing.allocator;

    const ops = InodeOps{
        .lookup = null,
        .create = null,
        .mkdir = null,
        .rmdir = null,
        .unlink = null,
        .symlink = null,
        .rename = null,
        .readlink = null,
        .truncate = null,
        .destroy = null,
    };

    const inode = try allocator.create(Inode);
    inode.* = Inode.init(1, .Regular, &ops);

    try Basics.testing.expectEqual(@as(u32, 1), inode.refcount.load(.Acquire));

    inode.acquire();
    try Basics.testing.expectEqual(@as(u32, 2), inode.refcount.load(.Acquire));

    inode.release(allocator);
    try Basics.testing.expectEqual(@as(u32, 1), inode.refcount.load(.Acquire));

    inode.release(allocator);
}
