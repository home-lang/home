// Home OS Kernel - Virtual File System (VFS)
// Core filesystem abstraction layer

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const vfs_sync = @import("vfs_sync.zig");
const vfs_advanced = @import("vfs_advanced.zig");
const process = @import("process.zig");
const timer = @import("timer.zig");

pub const MAX_PATH_LEN: usize = 4096;

// ============================================================================
// Inode Types and Flags
// ============================================================================

pub const InodeType = enum(u8) {
    Regular = 0,
    Directory = 1,
    Symlink = 2,
    CharDevice = 3,
    BlockDevice = 4,
    Fifo = 5,
    Socket = 6,
    Unknown = 255,
};

pub const InodeFlags = packed struct(u32) {
    /// Inode has been modified
    dirty: bool = false,
    /// Inode is being deleted
    deleted: bool = false,
    /// Inode is immutable (cannot be modified)
    immutable: bool = false,
    /// Inode is append-only
    append_only: bool = false,
    /// Do not update access time
    no_atime: bool = false,
    /// Synchronous updates
    sync: bool = false,
    /// Encrypted content
    encrypted: bool = false,
    /// Compressed content
    compressed: bool = false,
    _padding: u24 = 0,
};

pub const FileMode = packed struct(u16) {
    /// Execute permission for others
    other_exec: bool = false,
    /// Write permission for others
    other_write: bool = false,
    /// Read permission for others
    other_read: bool = false,
    /// Execute permission for group
    group_exec: bool = false,
    /// Write permission for group
    group_write: bool = false,
    /// Read permission for group
    group_read: bool = false,
    /// Execute permission for owner
    owner_exec: bool = false,
    /// Write permission for owner
    owner_write: bool = false,
    /// Read permission for owner
    owner_read: bool = false,
    /// Sticky bit
    sticky: bool = false,
    /// Set GID
    setgid: bool = false,
    /// Set UID
    setuid: bool = false,
    _padding: u4 = 0,

    pub fn fromU16(mode: u16) FileMode {
        return @bitCast(mode);
    }

    pub fn toU16(self: FileMode) u16 {
        return @bitCast(self);
    }

    /// Check if user has read permission
    pub fn canRead(self: FileMode, uid: u32, gid: u32, file_uid: u32, file_gid: u32) bool {
        if (uid == 0) return true; // Root can read anything
        if (uid == file_uid and self.owner_read) return true;
        if (gid == file_gid and self.group_read) return true;
        return self.other_read;
    }

    /// Check if user has write permission
    pub fn canWrite(self: FileMode, uid: u32, gid: u32, file_uid: u32, file_gid: u32) bool {
        if (uid == 0) return true;
        if (uid == file_uid and self.owner_write) return true;
        if (gid == file_gid and self.group_write) return true;
        return self.other_write;
    }

    /// Check if user has execute permission
    pub fn canExecute(self: FileMode, uid: u32, gid: u32, file_uid: u32, file_gid: u32) bool {
        if (uid == 0) return true;
        if (uid == file_uid and self.owner_exec) return true;
        if (gid == file_gid and self.group_exec) return true;
        return self.other_exec;
    }
};

// ============================================================================
// Inode Structure
// ============================================================================

pub const Inode = struct {
    /// Inode number (unique within filesystem)
    ino: u64,
    /// Inode type
    inode_type: InodeType,
    /// File mode/permissions
    mode: FileMode,
    /// Number of hard links
    nlink: u32,
    /// Owner user ID
    uid: u32,
    /// Owner group ID
    gid: u32,
    /// File size in bytes
    size: u64,
    /// Device ID (for char/block devices)
    rdev: u64,
    /// Block size for I/O
    blksize: u32,
    /// Number of blocks allocated
    blocks: u64,
    /// Access time (nanoseconds since epoch)
    atime: u64,
    /// Modification time (nanoseconds since epoch)
    mtime: u64,
    /// Change time (nanoseconds since epoch)
    ctime: u64,
    /// Creation time (nanoseconds since epoch)
    crtime: u64,
    /// Flags
    flags: InodeFlags,
    /// Generation number (for NFS)
    generation: vfs_sync.InodeGeneration,
    /// Reference count
    refcount: vfs_sync.RefCount,
    /// Lock for inode data
    lock: sync.RwLock,
    /// Operations for this inode
    ops: *const InodeOperations,
    /// Filesystem-specific data
    private_data: ?*anyopaque,
    /// Owning superblock
    sb: *Superblock,
    /// Extended attributes
    xattrs: vfs_advanced.XattrStore,
    /// Dentry list (all dentries pointing to this inode)
    dentry_list: ?*Dentry,
    /// Next inode in hash list
    hash_next: ?*Inode,

    pub fn init(sb: *Superblock, ino: u64, inode_type: InodeType, ops: *const InodeOperations) Inode {
        return .{
            .ino = ino,
            .inode_type = inode_type,
            .mode = .{},
            .nlink = 1,
            .uid = 0,
            .gid = 0,
            .size = 0,
            .rdev = 0,
            .blksize = 4096,
            .blocks = 0,
            .atime = 0,
            .mtime = 0,
            .ctime = 0,
            .crtime = 0,
            .flags = .{},
            .generation = vfs_sync.InodeGeneration.init(),
            .refcount = vfs_sync.RefCount.init(1),
            .lock = sync.RwLock.init(),
            .ops = ops,
            .private_data = null,
            .sb = sb,
            .xattrs = vfs_advanced.XattrStore.init(),
            .dentry_list = null,
            .hash_next = null,
        };
    }

    /// Acquire a reference
    pub fn get(self: *Inode) *Inode {
        _ = self.refcount.acquire();
        return self;
    }

    /// Release a reference
    pub fn put(self: *Inode) void {
        if (self.refcount.release()) {
            // Last reference - cleanup
            if (self.ops.destroy) |destroy| {
                destroy(self);
            }
        }
    }

    /// Mark inode as dirty
    pub fn markDirty(self: *Inode) void {
        self.flags.dirty = true;
        self.ctime = getCurrentTime();
    }

    /// Update access time
    pub fn touchAtime(self: *Inode) void {
        if (!self.flags.no_atime) {
            self.atime = getCurrentTime();
        }
    }

    /// Update modification time
    pub fn touchMtime(self: *Inode) void {
        self.mtime = getCurrentTime();
        self.ctime = getCurrentTime();
        self.flags.dirty = true;
    }
};

// ============================================================================
// Inode Operations
// ============================================================================

pub const InodeOperations = struct {
    /// Look up a name in a directory
    lookup: ?*const fn (dir: *Inode, name: []const u8) anyerror!?*Dentry = null,
    /// Create a regular file
    create: ?*const fn (dir: *Inode, name: []const u8, mode: FileMode) anyerror!*Inode = null,
    /// Create a directory
    mkdir: ?*const fn (dir: *Inode, name: []const u8, mode: FileMode) anyerror!*Inode = null,
    /// Remove a name from a directory
    unlink: ?*const fn (dir: *Inode, name: []const u8) anyerror!void = null,
    /// Remove a directory
    rmdir: ?*const fn (dir: *Inode, name: []const u8) anyerror!void = null,
    /// Create a symbolic link
    symlink: ?*const fn (dir: *Inode, name: []const u8, target: []const u8) anyerror!*Inode = null,
    /// Read a symbolic link
    readlink: ?*const fn (inode: *Inode, buffer: []u8) anyerror!usize = null,
    /// Create a hard link
    link: ?*const fn (old_dentry: *Dentry, dir: *Inode, name: []const u8) anyerror!void = null,
    /// Rename a file
    rename: ?*const fn (old_dir: *Inode, old_name: []const u8, new_dir: *Inode, new_name: []const u8) anyerror!void = null,
    /// Get file attributes
    getattr: ?*const fn (inode: *Inode, stat: *Stat) anyerror!void = null,
    /// Set file attributes
    setattr: ?*const fn (inode: *Inode, attr: *const SetAttr) anyerror!void = null,
    /// Truncate file
    truncate: ?*const fn (inode: *Inode, size: u64) anyerror!void = null,
    /// Destroy inode (cleanup)
    destroy: ?*const fn (inode: *Inode) void = null,
};

// ============================================================================
// File Structure
// ============================================================================

pub const OpenFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    append: bool = false,
    create: bool = false,
    truncate: bool = false,
    exclusive: bool = false,
    no_follow: bool = false,
    directory: bool = false,
    no_ctty: bool = false,
    nonblock: bool = false,
    sync: bool = false,
    _padding: u21 = 0,

    pub const O_RDONLY: OpenFlags = .{ .read = true };
    pub const O_WRONLY: OpenFlags = .{ .write = true };
    pub const O_RDWR: OpenFlags = .{ .read = true, .write = true };
};

pub const SeekWhence = enum(u8) {
    SET = 0,
    CUR = 1,
    END = 2,
};

pub const File = struct {
    /// Reference count
    refcount: vfs_sync.RefCount,
    /// Open flags
    flags: OpenFlags,
    /// Current position
    pos: atomic.AtomicU64,
    /// Associated dentry
    dentry: *Dentry,
    /// File operations
    ops: *const FileOperations,
    /// Filesystem-specific data
    private_data: ?*anyopaque,
    /// Lock for file operations
    lock: sync.Mutex,

    pub fn init(dentry: *Dentry, flags: OpenFlags, ops: *const FileOperations) File {
        return .{
            .refcount = vfs_sync.RefCount.init(1),
            .flags = flags,
            .pos = atomic.AtomicU64.init(0),
            .dentry = dentry,
            .ops = ops,
            .private_data = null,
            .lock = sync.Mutex.init(),
        };
    }

    /// Get a reference
    pub fn get(self: *File) *File {
        _ = self.refcount.acquire();
        return self;
    }

    /// Release a reference
    pub fn put(self: *File, allocator: Basics.Allocator) void {
        if (self.refcount.release()) {
            if (self.ops.release) |release| {
                release(self);
            }
            self.dentry.put(allocator);
            allocator.destroy(self);
        }
    }

    /// Read from file
    pub fn read(self: *File, buffer: []u8) !usize {
        if (!self.flags.read) return error.BadFileDescriptor;

        const read_fn = self.ops.read orelse return error.NotSupported;
        const pos = self.pos.load(.Acquire);
        const bytes_read = try read_fn(self, buffer, pos);

        if (bytes_read > 0) {
            _ = self.pos.fetchAdd(bytes_read, .Release);
            self.dentry.inode.touchAtime();
        }

        return bytes_read;
    }

    /// Write to file
    pub fn write(self: *File, data: []const u8) !usize {
        if (!self.flags.write) return error.BadFileDescriptor;

        const write_fn = self.ops.write orelse return error.NotSupported;

        var pos = self.pos.load(.Acquire);
        if (self.flags.append) {
            pos = self.dentry.inode.size;
        }

        const bytes_written = try write_fn(self, data, pos);

        if (bytes_written > 0) {
            _ = self.pos.fetchAdd(bytes_written, .Release);
            self.dentry.inode.touchMtime();
        }

        return bytes_written;
    }

    /// Seek in file
    pub fn seek(self: *File, offset: i64, whence: SeekWhence) !u64 {
        const current = self.pos.load(.Acquire);
        const size = self.dentry.inode.size;

        const new_pos: i64 = switch (whence) {
            .SET => offset,
            .CUR => @as(i64, @intCast(current)) + offset,
            .END => @as(i64, @intCast(size)) + offset,
        };

        if (new_pos < 0) return error.InvalidArgument;

        const final_pos: u64 = @intCast(new_pos);
        self.pos.store(final_pos, .Release);
        return final_pos;
    }
};

// ============================================================================
// File Operations
// ============================================================================

pub const FileOperations = struct {
    /// Read from file
    read: ?*const fn (file: *File, buffer: []u8, offset: u64) anyerror!usize = null,
    /// Write to file
    write: ?*const fn (file: *File, data: []const u8, offset: u64) anyerror!usize = null,
    /// Memory map file
    mmap: ?*const fn (file: *File, addr: u64, length: usize, prot: u32, flags: u32, offset: u64) anyerror!u64 = null,
    /// Flush file buffers
    flush: ?*const fn (file: *File) anyerror!void = null,
    /// Release file (on close)
    release: ?*const fn (file: *File) void = null,
    /// File sync (fsync)
    fsync: ?*const fn (file: *File, datasync: bool) anyerror!void = null,
    /// Read directory entries
    readdir: ?*const fn (file: *File, callback: *const fn (name: []const u8, ino: u64, itype: InodeType) bool) anyerror!void = null,
    /// IO control
    ioctl: ?*const fn (file: *File, cmd: u32, arg: u64) anyerror!i64 = null,
    /// Poll for events
    poll: ?*const fn (file: *File) u32 = null,
};

// ============================================================================
// Dentry (Directory Entry) Cache
// ============================================================================

pub const DentryFlags = packed struct(u16) {
    /// Negative dentry (name doesn't exist)
    negative: bool = false,
    /// Dentry is root of a mount
    mounted: bool = false,
    /// Dentry has been referenced
    referenced: bool = false,
    /// Dentry needs revalidation
    need_revalidate: bool = false,
    _padding: u12 = 0,
};

pub const Dentry = struct {
    /// Name of this entry
    name: [256]u8,
    name_len: u8,
    /// Parent directory
    parent: ?*Dentry,
    /// Inode (null for negative dentries)
    inode: *Inode,
    /// Reference count
    refcount: vfs_sync.RefCount,
    /// Flags
    flags: DentryFlags,
    /// Children (for directories)
    children: ?*Dentry,
    /// Next sibling
    next_sibling: ?*Dentry,
    /// Hash table collision chain
    hash_next: ?*Dentry,
    /// Superblock
    sb: *Superblock,
    /// Operations
    ops: *const DentryOperations,

    pub fn init(sb: *Superblock, parent: ?*Dentry, name: []const u8, inode: *Inode) !*Dentry {
        const dentry = try sb.allocator.create(Dentry);
        dentry.* = .{
            .name = undefined,
            .name_len = @intCast(name.len),
            .parent = parent,
            .inode = inode,
            .refcount = vfs_sync.RefCount.init(1),
            .flags = .{},
            .children = null,
            .next_sibling = null,
            .hash_next = null,
            .sb = sb,
            .ops = &default_dentry_ops,
        };

        @memcpy(dentry.name[0..name.len], name);
        return dentry;
    }

    /// Get name slice
    pub fn getName(self: *const Dentry) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Get a reference
    pub fn get(self: *Dentry) *Dentry {
        _ = self.refcount.acquire();
        return self;
    }

    /// Release a reference
    pub fn put(self: *Dentry, allocator: Basics.Allocator) void {
        if (self.refcount.release()) {
            // Remove from parent's children list
            if (self.parent) |parent| {
                var prev: ?*Dentry = null;
                var curr = parent.children;
                while (curr) |c| {
                    if (c == self) {
                        if (prev) |p| {
                            p.next_sibling = c.next_sibling;
                        } else {
                            parent.children = c.next_sibling;
                        }
                        break;
                    }
                    prev = c;
                    curr = c.next_sibling;
                }
            }

            self.inode.put();
            allocator.destroy(self);
        }
    }

    /// Add child dentry
    pub fn addChild(self: *Dentry, child: *Dentry) void {
        child.next_sibling = self.children;
        self.children = child;
        child.parent = self;
    }
};

pub const DentryOperations = struct {
    /// Revalidate dentry (check if still valid)
    revalidate: ?*const fn (dentry: *Dentry) bool = null,
    /// Delete dentry
    delete: ?*const fn (dentry: *Dentry) bool = null,
    /// Compare names
    compare: ?*const fn (dentry: *Dentry, name: []const u8) bool = null,
};

const default_dentry_ops = DentryOperations{};

// ============================================================================
// Superblock (Filesystem Instance)
// ============================================================================

pub const Superblock = struct {
    /// Filesystem type
    fs_type: *FilesystemType,
    /// Device major number
    dev_major: u32,
    /// Device minor number
    dev_minor: u32,
    /// Block size
    block_size: u32,
    /// Maximum file size
    max_file_size: u64,
    /// Flags
    flags: SuperblockFlags,
    /// Root dentry
    root: ?*Dentry,
    /// Allocator
    allocator: Basics.Allocator,
    /// Operations
    ops: *const SuperblockOperations,
    /// Filesystem-specific data
    private_data: ?*anyopaque,
    /// Lock
    lock: sync.RwLock,
    /// Mount count
    mount_count: atomic.AtomicU32,
    /// List of all inodes
    inode_list: ?*Inode,

    pub fn init(allocator: Basics.Allocator, fs_type: *FilesystemType) Superblock {
        return .{
            .fs_type = fs_type,
            .dev_major = 0,
            .dev_minor = 0,
            .block_size = 4096,
            .max_file_size = 0xFFFF_FFFF_FFFF_FFFF,
            .flags = .{},
            .root = null,
            .allocator = allocator,
            .ops = &default_sb_ops,
            .private_data = null,
            .lock = sync.RwLock.init(),
            .mount_count = atomic.AtomicU32.init(0),
            .inode_list = null,
        };
    }
};

pub const SuperblockFlags = packed struct(u32) {
    read_only: bool = false,
    no_suid: bool = false,
    no_dev: bool = false,
    no_exec: bool = false,
    synchronous: bool = false,
    _padding: u27 = 0,
};

pub const SuperblockOperations = struct {
    /// Allocate new inode
    alloc_inode: ?*const fn (sb: *Superblock) anyerror!*Inode = null,
    /// Free inode
    free_inode: ?*const fn (sb: *Superblock, inode: *Inode) void = null,
    /// Write inode to disk
    write_inode: ?*const fn (inode: *Inode, sync: bool) anyerror!void = null,
    /// Delete inode
    delete_inode: ?*const fn (inode: *Inode) void = null,
    /// Sync filesystem
    sync_fs: ?*const fn (sb: *Superblock, wait: bool) anyerror!void = null,
    /// Get filesystem statistics
    statfs: ?*const fn (sb: *Superblock, buf: *StatFs) anyerror!void = null,
    /// Remount filesystem
    remount: ?*const fn (sb: *Superblock, flags: SuperblockFlags) anyerror!void = null,
    /// Unmount filesystem
    umount: ?*const fn (sb: *Superblock) void = null,
};

const default_sb_ops = SuperblockOperations{};

// ============================================================================
// Mount Point Management
// ============================================================================

pub const Mount = struct {
    /// Mounted filesystem superblock
    sb: *Superblock,
    /// Mount point dentry
    mountpoint: *Dentry,
    /// Root of mounted filesystem
    root: *Dentry,
    /// Parent mount
    parent: ?*Mount,
    /// Children mounts
    children: ?*Mount,
    /// Next sibling mount
    next_sibling: ?*Mount,
    /// Mount flags
    flags: MountFlags,
    /// Reference count
    refcount: vfs_sync.RefCount,

    pub fn init(sb: *Superblock, mountpoint: *Dentry, root: *Dentry) Mount {
        return .{
            .sb = sb,
            .mountpoint = mountpoint,
            .root = root,
            .parent = null,
            .children = null,
            .next_sibling = null,
            .flags = .{},
            .refcount = vfs_sync.RefCount.init(1),
        };
    }
};

pub const MountFlags = packed struct(u32) {
    read_only: bool = false,
    no_suid: bool = false,
    no_dev: bool = false,
    no_exec: bool = false,
    bind: bool = false,
    move: bool = false,
    recursive: bool = false,
    _padding: u25 = 0,
};

// ============================================================================
// Filesystem Type Registration
// ============================================================================

pub const FilesystemType = struct {
    name: [32]u8,
    name_len: u8,
    flags: FilesystemFlags,
    /// Mount a filesystem
    mount: *const fn (fs_type: *FilesystemType, source: ?[]const u8, flags: MountFlags, data: ?*anyopaque) anyerror!*Superblock,
    /// Unmount a filesystem
    kill_sb: *const fn (sb: *Superblock) void,
    /// Next in list
    next: ?*FilesystemType,

    pub fn getName(self: *const FilesystemType) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const FilesystemFlags = packed struct(u32) {
    /// Requires a block device
    requires_dev: bool = false,
    /// Can be mounted multiple times
    allow_multi: bool = false,
    /// Supports large files (>2GB)
    large_files: bool = false,
    _padding: u29 = 0,
};

var registered_filesystems: ?*FilesystemType = null;
var fs_lock: sync.Mutex = sync.Mutex.init();

/// Register a filesystem type
pub fn registerFilesystem(fs_type: *FilesystemType) void {
    fs_lock.lock();
    defer fs_lock.unlock();

    fs_type.next = registered_filesystems;
    registered_filesystems = fs_type;
}

/// Find a filesystem type by name
pub fn findFilesystem(name: []const u8) ?*FilesystemType {
    fs_lock.lock();
    defer fs_lock.unlock();

    var fs = registered_filesystems;
    while (fs) |f| {
        if (Basics.mem.eql(u8, f.getName(), name)) {
            return f;
        }
        fs = f.next;
    }
    return null;
}

// ============================================================================
// Path Resolution
// ============================================================================

pub const PathLookupFlags = packed struct(u16) {
    /// Follow symbolic links
    follow: bool = true,
    /// Path must be directory
    directory: bool = false,
    /// Don't automount
    no_automount: bool = false,
    /// Path must be regular file
    regular: bool = false,
    _padding: u12 = 0,
};

/// Resolve a path to a dentry
pub fn pathLookup(path: []const u8, flags: PathLookupFlags, root: *Dentry, cwd: *Dentry) !*Dentry {
    var current: *Dentry = undefined;

    // Determine starting point
    if (path.len > 0 and path[0] == '/') {
        current = root.get();
    } else {
        current = cwd.get();
    }

    // Parse path components
    var start: usize = 0;
    var i: usize = 0;

    while (i <= path.len) {
        if (i == path.len or path[i] == '/') {
            const component = path[start..i];

            if (component.len > 0 and !Basics.mem.eql(u8, component, ".")) {
                if (Basics.mem.eql(u8, component, "..")) {
                    // Go to parent
                    if (current.parent) |parent| {
                        const new = parent.get();
                        current.put(current.sb.allocator);
                        current = new;
                    }
                } else {
                    // Look up child
                    if (current.inode.inode_type != .Directory) {
                        current.put(current.sb.allocator);
                        return error.NotADirectory;
                    }

                    const lookup_fn = current.inode.ops.lookup orelse {
                        current.put(current.sb.allocator);
                        return error.NotSupported;
                    };

                    const child_dentry = try lookup_fn(current.inode, component) orelse {
                        current.put(current.sb.allocator);
                        return error.FileNotFound;
                    };

                    // Handle symlinks
                    if (flags.follow and child_dentry.inode.inode_type == .Symlink) {
                        // Follow symlink by reading target and recursively resolving
                        if (child_dentry.inode.ops.readlink) |readlink_fn| {
                            var target_buf: [MAX_PATH_LEN]u8 = undefined;
                            const target_len = readlink_fn(child_dentry.inode, &target_buf) catch 0;
                            if (target_len > 0) {
                                // Recursively resolve symlink target
                                const target_path = target_buf[0..target_len];
                                child_dentry.put(child_dentry.sb.allocator);
                                return pathLookup(target_path, flags);
                            }
                        }
                    }

                    current.put(current.sb.allocator);
                    current = child_dentry;
                }
            }

            start = i + 1;
        }
        i += 1;
    }

    // Verify final result
    if (flags.directory and current.inode.inode_type != .Directory) {
        current.put(current.sb.allocator);
        return error.NotADirectory;
    }

    if (flags.regular and current.inode.inode_type != .Regular) {
        current.put(current.sb.allocator);
        return error.InvalidArgument;
    }

    return current;
}

// ============================================================================
// High-Level File Operations
// ============================================================================

/// Open a file
pub fn open(path: []const u8, flags: OpenFlags, mode: u16, proc: *process.Process) !*File {
    const root = proc.fs_root orelse return error.NoRootFilesystem;
    const cwd = proc.fs_cwd orelse root;

    // Resolve path
    var lookup_flags = PathLookupFlags{};
    if (flags.no_follow) lookup_flags.follow = false;
    if (flags.directory) lookup_flags.directory = true;

    const dentry = pathLookup(path, lookup_flags, root, cwd) catch |err| {
        if (err == error.FileNotFound and flags.create) {
            // Create new file
            return createFile(path, flags, FileMode.fromU16(mode), proc);
        }
        return err;
    };
    errdefer dentry.put(dentry.sb.allocator);

    // Check permissions
    if (flags.read and !dentry.inode.mode.canRead(proc.euid, proc.egid, dentry.inode.uid, dentry.inode.gid)) {
        dentry.put(dentry.sb.allocator);
        return error.PermissionDenied;
    }

    if (flags.write and !dentry.inode.mode.canWrite(proc.euid, proc.egid, dentry.inode.uid, dentry.inode.gid)) {
        dentry.put(dentry.sb.allocator);
        return error.PermissionDenied;
    }

    // Handle truncate
    if (flags.truncate and flags.write) {
        if (dentry.inode.ops.truncate) |truncate| {
            try truncate(dentry.inode, 0);
        }
    }

    // Create file object
    const file_ops = getFileOps(dentry.inode) orelse return error.NotSupported;
    const file = try dentry.sb.allocator.create(File);
    file.* = File.init(dentry, flags, file_ops);

    return file;
}

/// Create a new file
fn createFile(path: []const u8, flags: OpenFlags, mode: FileMode, proc: *process.Process) !*File {
    _ = flags;

    const root = proc.fs_root orelse return error.NoRootFilesystem;
    const cwd = proc.fs_cwd orelse root;

    // Find parent directory
    const last_slash = Basics.mem.lastIndexOf(u8, path, "/");
    const dir_path = if (last_slash) |idx| path[0..idx] else ".";
    const file_name = if (last_slash) |idx| path[idx + 1 ..] else path;

    const parent = try pathLookup(dir_path, .{ .directory = true }, root, cwd);
    errdefer parent.put(parent.sb.allocator);

    // Create inode
    const create_fn = parent.inode.ops.create orelse return error.NotSupported;
    const new_inode = try create_fn(parent.inode, file_name, mode);

    // Create dentry
    const dentry = try Dentry.init(parent.sb, parent, file_name, new_inode);

    // Create file object
    const file_ops = getFileOps(new_inode) orelse return error.NotSupported;
    const file = try parent.sb.allocator.create(File);
    file.* = File.init(dentry, .{ .read = true, .write = true }, file_ops);

    return file;
}

fn getFileOps(inode: *Inode) ?*const FileOperations {
    _ = inode;
    // Return appropriate file operations based on inode type
    return &default_file_ops;
}

const default_file_ops = FileOperations{};

// ============================================================================
// Stat Structures
// ============================================================================

pub const Stat = struct {
    dev: u64,
    ino: u64,
    mode: u16,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u64,
    size: u64,
    blksize: u32,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
};

pub const StatFs = struct {
    fs_type: u64,
    block_size: u64,
    blocks: u64,
    blocks_free: u64,
    blocks_avail: u64,
    files: u64,
    files_free: u64,
    fsid: [2]u64,
    namelen: u64,
    frsize: u64,
};

pub const SetAttr = struct {
    valid: SetAttrValid,
    mode: ?FileMode,
    uid: ?u32,
    gid: ?u32,
    size: ?u64,
    atime: ?u64,
    mtime: ?u64,
};

pub const SetAttrValid = packed struct(u16) {
    mode: bool = false,
    uid: bool = false,
    gid: bool = false,
    size: bool = false,
    atime: bool = false,
    mtime: bool = false,
    _padding: u10 = 0,
};

/// Get file statistics
pub fn stat(path: []const u8, proc: *process.Process) !Stat {
    const root = proc.fs_root orelse return error.NoRootFilesystem;
    const cwd = proc.fs_cwd orelse root;

    const dentry = try pathLookup(path, .{}, root, cwd);
    defer dentry.put(dentry.sb.allocator);

    const inode = dentry.inode;
    return Stat{
        .dev = (@as(u64, inode.sb.dev_major) << 32) | inode.sb.dev_minor,
        .ino = inode.ino,
        .mode = inode.mode.toU16(),
        .nlink = inode.nlink,
        .uid = inode.uid,
        .gid = inode.gid,
        .rdev = inode.rdev,
        .size = inode.size,
        .blksize = inode.blksize,
        .blocks = inode.blocks,
        .atime = inode.atime,
        .mtime = inode.mtime,
        .ctime = inode.ctime,
    };
}

// ============================================================================
// Helper Functions
// ============================================================================

fn getCurrentTime() u64 {
    // Get current time in milliseconds since boot from timer subsystem
    return timer.getTicks();
}

// ============================================================================
// Global Mount Table
// ============================================================================

var root_mount: ?*Mount = null;
var mount_lock: sync.RwLock = sync.RwLock.init();

/// Get root mount
pub fn getRootMount() ?*Mount {
    mount_lock.acquireRead();
    defer mount_lock.releaseRead();
    return root_mount;
}

/// Set root mount
pub fn setRootMount(mnt: *Mount) void {
    mount_lock.acquireWrite();
    defer mount_lock.releaseWrite();
    root_mount = mnt;
}

/// Mount a filesystem
pub fn mount(
    source: ?[]const u8,
    target: []const u8,
    fs_type_name: []const u8,
    flags: MountFlags,
    data: ?*anyopaque,
    proc: *process.Process,
) !void {
    // Find filesystem type
    const fs_type = findFilesystem(fs_type_name) orelse return error.UnknownFilesystem;

    // Mount the filesystem
    const sb = try fs_type.mount(fs_type, source, flags, data);

    // Find target dentry
    const root = proc.fs_root orelse return error.NoRootFilesystem;
    const target_dentry = try pathLookup(target, .{ .directory = true }, root, root);

    // Create mount structure
    const mnt = try sb.allocator.create(Mount);
    mnt.* = Mount.init(sb, target_dentry, sb.root.?);

    // Mark dentry as mount point
    target_dentry.flags.mounted = true;

    // If this is root mount, set it
    if (target.len == 1 and target[0] == '/') {
        setRootMount(mnt);
        proc.fs_root = sb.root;
    }
}

/// Unmount a filesystem
pub fn umount(target: []const u8, proc: *process.Process) !void {
    const root = proc.fs_root orelse return error.NoRootFilesystem;
    const target_dentry = try pathLookup(target, .{ .directory = true }, root, root);

    if (!target_dentry.flags.mounted) {
        target_dentry.put(target_dentry.sb.allocator);
        return error.NotMounted;
    }

    // Find and remove mount from mount table
    // First sync the filesystem to ensure data is written
    if (target_dentry.sb.ops.sync) |sync_fn| {
        try sync_fn(target_dentry.sb);
    }

    // Clear mounted flag and update mount point
    target_dentry.flags.mounted = false;
    target_dentry.put(target_dentry.sb.allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "FileMode permissions" {
    var mode = FileMode{
        .owner_read = true,
        .owner_write = true,
        .group_read = true,
        .other_read = true,
    };

    // Owner can read and write
    try Basics.testing.expect(mode.canRead(1000, 1000, 1000, 1000));
    try Basics.testing.expect(mode.canWrite(1000, 1000, 1000, 1000));

    // Group can only read
    try Basics.testing.expect(mode.canRead(1001, 1000, 1000, 1000));
    try Basics.testing.expect(!mode.canWrite(1001, 1000, 1000, 1000));

    // Others can only read
    try Basics.testing.expect(mode.canRead(2000, 2000, 1000, 1000));
    try Basics.testing.expect(!mode.canWrite(2000, 2000, 1000, 1000));

    // Root can do anything
    try Basics.testing.expect(mode.canRead(0, 0, 1000, 1000));
    try Basics.testing.expect(mode.canWrite(0, 0, 1000, 1000));
}

test "OpenFlags constants" {
    const rdonly = OpenFlags.O_RDONLY;
    try Basics.testing.expect(rdonly.read);
    try Basics.testing.expect(!rdonly.write);

    const rdwr = OpenFlags.O_RDWR;
    try Basics.testing.expect(rdwr.read);
    try Basics.testing.expect(rdwr.write);
}
