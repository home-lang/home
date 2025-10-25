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
// Permission Checking
// ============================================================================

/// Permission bits
pub const PERM_READ: u32 = 0x4;
pub const PERM_WRITE: u32 = 0x2;
pub const PERM_EXECUTE: u32 = 0x1;

/// Check if current process has permission to access inode
pub fn checkPermission(inode: *Inode, requested: u32) !void {
    const process = @import("../kernel/src/process.zig");
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    // Root bypasses all permission checks
    if (current.euid == 0) return;

    var perm: u32 = 0;
    const mode_bits = inode.mode.toOctal();

    // Check user bits (owner)
    if (inode.uid == current.euid) {
        perm = (mode_bits >> 6) & 0x7;
    }
    // Check group bits
    else if (inode.gid == current.egid or inSupplementaryGroups(current, inode.gid)) {
        perm = (mode_bits >> 3) & 0x7;
    }
    // Check other bits
    else {
        perm = mode_bits & 0x7;
    }

    // Verify requested permission is granted
    if ((perm & requested) != requested) {
        return error.AccessDenied;
    }
}

/// Check if process is in supplementary group
fn inSupplementaryGroups(proc: *const @import("../kernel/src/process.zig").Process, gid: u32) bool {
    for (proc.groups[0..proc.num_groups]) |group| {
        if (group == gid) return true;
    }
    return false;
}

// ============================================================================
// Symlink Security (TOCTOU Prevention)
// ============================================================================

/// File open flags
pub const O_RDONLY: i32 = 0x0000;
pub const O_WRONLY: i32 = 0x0001;
pub const O_RDWR: i32 = 0x0002;
pub const O_CREAT: i32 = 0x0040;
pub const O_EXCL: i32 = 0x0080;
pub const O_NOFOLLOW: i32 = 0x0100; // Don't follow symlinks
pub const O_DIRECTORY: i32 = 0x0200; // Must be directory
pub const O_TRUNC: i32 = 0x0400;

/// Check if symlink can be safely followed
pub fn checkSymlinkSafety(symlink_inode: *Inode, parent_dir: *Inode) !void {
    const process_mod = @import("../kernel/src/process.zig");
    const current = process_mod.getCurrentProcess() orelse return error.NoProcess;

    // Symlinks owned by root are always safe
    if (symlink_inode.uid == 0) return;

    // Symlink must be owned by the current user or parent directory owner
    if (symlink_inode.uid != current.uid and symlink_inode.uid != parent_dir.uid) {
        // Also check if current user is root
        if (current.euid != 0) {
            return error.SymlinkNotTrusted;
        }
    }

    // Check that parent directory is not world-writable (sticky bit check)
    const parent_mode = parent_dir.mode.toOctal();
    const world_write = (parent_mode & 0x2) != 0;
    const sticky = parent_dir.mode.sticky;

    // If parent is world-writable and doesn't have sticky bit, it's dangerous
    if (world_write and !sticky) {
        return error.UnsafeSymlinkLocation;
    }
}

/// Path resolution options
pub const PathResolutionFlags = struct {
    /// Don't follow symlinks at all
    no_follow: bool = false,
    /// Must be a directory
    must_be_dir: bool = false,
    /// Follow symlinks except the final component
    no_follow_final: bool = false,
    /// Maximum symlink depth
    max_symlink_depth: u32 = 40,
}

/// Resolve a path to an inode, respecting symlink security
pub fn resolvePath(start: *Inode, path: []const u8, flags: PathResolutionFlags) !*Inode {
    // Validate and sanitize path
    const sanitized = try sanitizePath(path);

    // Track symlink depth to prevent infinite loops
    var symlink_depth: u32 = 0;
    var current = start;
    current.acquire();

    // Split path into components
    var path_iter = Basics.mem.splitScalar(u8, sanitized, '/');
    var is_final = false;

    while (path_iter.next()) |component| {
        // Skip empty components (from leading/trailing slashes)
        if (component.len == 0) continue;

        // Check if this is the final component
        const remaining = path_iter.rest();
        is_final = remaining.len == 0;

        // Check if current is a directory
        if (!current.isDirectory()) {
            current.release(current.allocator);
            return error.NotADirectory;
        }

        // Check read permission on directory
        try checkPermission(current, PERM_READ);

        // Look up the component
        if (current.ops.lookup) |lookup_fn| {
            const next = lookup_fn(current, component) catch |err| {
                current.release(current.allocator);
                return err;
            };

            // Check if it's a symlink
            if (next.isSymlink()) {
                // Check if we should follow symlinks
                if (flags.no_follow or (is_final and flags.no_follow_final)) {
                    current.release(current.allocator);
                    return error.SymlinkNotAllowed;
                }

                // Check symlink depth limit
                if (symlink_depth >= flags.max_symlink_depth) {
                    next.release(next.allocator);
                    current.release(current.allocator);
                    return error.TooManySymlinks;
                }

                // Security: Check symlink safety
                try checkSymlinkSafety(next, current);

                // Read symlink target
                var target_buf: [4096]u8 = undefined;
                const target_len = if (next.ops.readlink) |readlink_fn|
                    readlink_fn(next, &target_buf) catch {
                        next.release(next.allocator);
                        current.release(current.allocator);
                        return error.InvalidSymlink;
                    }
                else {
                    next.release(next.allocator);
                    current.release(current.allocator);
                    return error.InvalidSymlink;
                };

                const target = target_buf[0..target_len];

                // Release the symlink inode
                next.release(next.allocator);

                // Increment symlink depth
                symlink_depth += 1;

                // Recursively resolve the symlink target
                const resolved = resolvePath(current, target, flags) catch |err| {
                    current.release(current.allocator);
                    return err;
                };

                current.release(current.allocator);
                current = resolved;
            } else {
                // Not a symlink, move to next component
                current.release(current.allocator);
                current = next;
            }
        } else {
            current.release(current.allocator);
            return error.NotSupported;
        }
    }

    // Final checks
    if (flags.must_be_dir and !current.isDirectory()) {
        current.release(current.allocator);
        return error.NotADirectory;
    }

    return current;
}

/// Helper to resolve path from flags
pub fn resolvePathFromFlags(start: *Inode, path: []const u8, open_flags: i32) !*Inode {
    var flags = PathResolutionFlags{};

    if (open_flags & O_NOFOLLOW != 0) {
        flags.no_follow_final = true;
    }

    if (open_flags & O_DIRECTORY != 0) {
        flags.must_be_dir = true;
    }

    return resolvePath(start, path, flags);
}

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
// Inode Cache and Eviction
// ============================================================================

pub const InodeCache = struct {
    inodes: Basics.HashMap(u64, *Inode, Basics.hash_map.AutoContext(u64), 80),
    lock: sync.RwLock,
    max_inodes: usize,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, max_inodes: usize) !InodeCache {
        return .{
            .inodes = Basics.HashMap(u64, *Inode, Basics.hash_map.AutoContext(u64), 80).init(allocator),
            .lock = sync.RwLock.init(),
            .max_inodes = max_inodes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InodeCache) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var it = self.inodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.release(self.allocator);
        }
        self.inodes.deinit();
    }

    /// Get inode from cache or null if not found
    pub fn get(self: *InodeCache, ino: u64) ?*Inode {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        if (self.inodes.get(ino)) |inode| {
            inode.acquire();
            return inode;
        }
        return null;
    }

    /// Add inode to cache
    pub fn add(self: *InodeCache, inode: *Inode) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Evict if cache is full
        if (self.inodes.count() >= self.max_inodes) {
            try self.evictOne();
        }

        inode.acquire();
        try self.inodes.put(inode.ino, inode);
    }

    /// Remove inode from cache
    pub fn remove(self: *InodeCache, ino: u64) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (self.inodes.fetchRemove(ino)) |entry| {
            entry.value.release(self.allocator);
        }
    }

    /// Evict one inode from cache (LRU-like, removes first with refcount==1)
    fn evictOne(self: *InodeCache) !void {
        var it = self.inodes.iterator();
        while (it.next()) |entry| {
            const inode = entry.value_ptr.*;
            // Only evict if refcount == 1 (only cache has reference)
            if (inode.refcount.load(.Acquire) == 1) {
                const ino = entry.key_ptr.*;
                _ = self.inodes.remove(ino);
                inode.release(self.allocator);
                return;
            }
        }

        // If no evictable inodes, expand cache temporarily
        return error.CacheFull;
    }

    /// Evict all unused inodes (refcount == 1)
    pub fn evictUnused(self: *InodeCache) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var to_remove = Basics.ArrayList(u64).init(self.allocator);
        defer to_remove.deinit();

        var it = self.inodes.iterator();
        while (it.next()) |entry| {
            const inode = entry.value_ptr.*;
            if (inode.refcount.load(.Acquire) == 1) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |ino| {
            if (self.inodes.fetchRemove(ino)) |entry| {
                entry.value.release(self.allocator);
            }
        }
    }
};

// ============================================================================
// Reference Leak Detection (Debug Mode)
// ============================================================================

const debug_refcount = Basics.builtin.mode == .Debug;

pub const RefTracker = if (debug_refcount) struct {
    allocations: Basics.HashMap(*anyopaque, StackTrace, Basics.hash_map.AutoContext(*anyopaque), 80),
    lock: sync.Spinlock,
    allocator: Basics.Allocator,

    const StackTrace = struct {
        type_name: []const u8,
        refcount: u32,
        allocated_at: usize,
    };

    pub fn init(allocator: Basics.Allocator) RefTracker {
        return .{
            .allocations = Basics.HashMap(*anyopaque, StackTrace, Basics.hash_map.AutoContext(*anyopaque), 80).init(allocator),
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RefTracker) void {
        self.lock.acquire();
        defer self.lock.release();

        // Report leaks
        var it = self.allocations.iterator();
        var leak_count: usize = 0;
        while (it.next()) |entry| {
            const trace = entry.value_ptr.*;
            if (trace.refcount > 0) {
                Basics.debug.print("LEAK: {s} at 0x{x} (refcount: {})\n",
                    .{trace.type_name, @intFromPtr(entry.key_ptr.*), trace.refcount});
                leak_count += 1;
            }
        }

        if (leak_count > 0) {
            Basics.debug.print("Total reference leaks: {}\n", .{leak_count});
        }

        self.allocations.deinit();
    }

    pub fn track(self: *RefTracker, ptr: *anyopaque, type_name: []const u8) void {
        self.lock.acquire();
        defer self.lock.release();

        self.allocations.put(ptr, .{
            .type_name = type_name,
            .refcount = 1,
            .allocated_at = @returnAddress(),
        }) catch {};
    }

    pub fn acquire(self: *RefTracker, ptr: *anyopaque) void {
        self.lock.acquire();
        defer self.lock.release();

        if (self.allocations.getPtr(ptr)) |trace| {
            trace.refcount += 1;
        }
    }

    pub fn release(self: *RefTracker, ptr: *anyopaque) void {
        self.lock.acquire();
        defer self.lock.release();

        if (self.allocations.getPtr(ptr)) |trace| {
            if (trace.refcount > 0) {
                trace.refcount -= 1;
            }
            if (trace.refcount == 0) {
                _ = self.allocations.remove(ptr);
            }
        }
    }
} else struct {
    pub fn init(_: Basics.Allocator) @This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
    pub fn track(_: *@This(), _: *anyopaque, _: []const u8) void {}
    pub fn acquire(_: *@This(), _: *anyopaque) void {}
    pub fn release(_: *@This(), _: *anyopaque) void {}
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
        const inode = current.inode orelse {
            current.release();
            return error.NoInode;
        };
        if (!inode.isDirectory()) {
            current.release();
            return error.NotADirectory;
        }

        // Try cache first
        if (current.findChild(component)) |child| {
            const old = current;
            current = child;
            old.release();
            continue;
        }

        // Lookup in filesystem
        if (inode.ops.lookup) |lookup| {
            const child_inode = lookup(inode, component) catch |err| {
                current.release();
                return err;
            };
            const child_dentry = Dentry.init(allocator, component, child_inode) catch |err| {
                child_inode.release(allocator);
                current.release();
                return err;
            };
            current.addChild(child_dentry) catch |err| {
                child_dentry.release();
                current.release();
                return err;
            };

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
