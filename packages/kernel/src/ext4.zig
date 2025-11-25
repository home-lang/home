// Home OS Kernel - ext4 Filesystem Driver
// Read-only ext4 filesystem implementation

const Basics = @import("basics");
const vfs = @import("vfs.zig");
const block = @import("block.zig");
const sync = @import("sync.zig");

// ============================================================================
// ext4 On-Disk Structures
// ============================================================================

/// ext4 Superblock (1024 bytes at offset 1024)
pub const Ext4Superblock = extern struct {
    s_inodes_count: u32, // Total inodes
    s_blocks_count_lo: u32, // Total blocks (low 32 bits)
    s_r_blocks_count_lo: u32, // Reserved blocks (low)
    s_free_blocks_count_lo: u32, // Free blocks (low)
    s_free_inodes_count: u32, // Free inodes
    s_first_data_block: u32, // First data block
    s_log_block_size: u32, // Block size = 1024 << s_log_block_size
    s_log_cluster_size: u32, // Cluster size
    s_blocks_per_group: u32, // Blocks per group
    s_clusters_per_group: u32, // Clusters per group
    s_inodes_per_group: u32, // Inodes per group
    s_mtime: u32, // Mount time
    s_wtime: u32, // Write time
    s_mnt_count: u16, // Mount count
    s_max_mnt_count: u16, // Max mount count
    s_magic: u16, // Magic number (0xEF53)
    s_state: u16, // Filesystem state
    s_errors: u16, // Error behavior
    s_minor_rev_level: u16, // Minor revision level
    s_lastcheck: u32, // Last check time
    s_checkinterval: u32, // Check interval
    s_creator_os: u32, // Creator OS
    s_rev_level: u32, // Revision level
    s_def_resuid: u16, // Default UID for reserved blocks
    s_def_resgid: u16, // Default GID for reserved blocks

    // ext4 dynamic revision fields
    s_first_ino: u32, // First non-reserved inode
    s_inode_size: u16, // Inode size
    s_block_group_nr: u16, // Block group number of this superblock
    s_feature_compat: u32, // Compatible feature flags
    s_feature_incompat: u32, // Incompatible feature flags
    s_feature_ro_compat: u32, // Read-only compatible feature flags
    s_uuid: [16]u8, // UUID
    s_volume_name: [16]u8, // Volume name
    s_last_mounted: [64]u8, // Last mount path
    s_algorithm_usage_bitmap: u32, // Compression algorithm bitmap

    // Performance hints
    s_prealloc_blocks: u8, // Blocks to preallocate
    s_prealloc_dir_blocks: u8, // Blocks to preallocate for directories
    s_reserved_gdt_blocks: u16, // Reserved GDT blocks for growth

    // Journaling support
    s_journal_uuid: [16]u8, // Journal UUID
    s_journal_inum: u32, // Journal inode
    s_journal_dev: u32, // Journal device
    s_last_orphan: u32, // Head of orphan inode list

    // Directory indexing support
    s_hash_seed: [4]u32, // HTREE hash seed
    s_def_hash_version: u8, // Default hash version
    s_jnl_backup_type: u8, // Journal backup type
    s_desc_size: u16, // Group descriptor size

    // Default mount options
    s_default_mount_opts: u32,
    s_first_meta_bg: u32, // First metablock block group
    s_mkfs_time: u32, // Filesystem creation time
    s_jnl_blocks: [17]u32, // Journal backup blocks

    // 64-bit support
    s_blocks_count_hi: u32, // Total blocks (high 32 bits)
    s_r_blocks_count_hi: u32, // Reserved blocks (high)
    s_free_blocks_count_hi: u32, // Free blocks (high)
    s_min_extra_isize: u16, // Min extra inode size
    s_want_extra_isize: u16, // Desired extra inode size
    s_flags: u32, // Misc flags
    s_raid_stride: u16, // RAID stride
    s_mmp_interval: u16, // MMP interval
    s_mmp_block: u64, // MMP block
    s_raid_stripe_width: u32, // RAID stripe width
    s_log_groups_per_flex: u8, // Flex block group size
    s_checksum_type: u8, // Checksum algorithm
    s_reserved_pad: u16,
    s_kbytes_written: u64, // KB written
    s_snapshot_inum: u32, // Snapshot inode
    s_snapshot_id: u32, // Snapshot ID
    s_snapshot_r_blocks_count: u64, // Reserved blocks for snapshot
    s_snapshot_list: u32, // Snapshot list head inode
    s_error_count: u32, // Error count
    s_first_error_time: u32, // First error time
    s_first_error_ino: u32, // First error inode
    s_first_error_block: u64, // First error block
    s_first_error_func: [32]u8, // First error function
    s_first_error_line: u32, // First error line
    s_last_error_time: u32, // Last error time
    s_last_error_ino: u32, // Last error inode
    s_last_error_line: u32, // Last error line
    s_last_error_block: u64, // Last error block
    s_last_error_func: [32]u8, // Last error function
    s_mount_opts: [64]u8, // Mount options
    s_usr_quota_inum: u32, // User quota inode
    s_grp_quota_inum: u32, // Group quota inode
    s_overhead_blocks: u32, // Overhead blocks
    s_backup_bgs: [2]u32, // Backup block groups
    s_encrypt_algos: [4]u8, // Encryption algorithms
    s_encrypt_pw_salt: [16]u8, // Encryption password salt
    s_lpf_ino: u32, // Lost+found inode
    s_prj_quota_inum: u32, // Project quota inode
    s_checksum_seed: u32, // Checksum seed
    s_reserved: [98]u32, // Padding
    s_checksum: u32, // Superblock checksum

    pub fn getBlockSize(self: *const Ext4Superblock) u32 {
        return @as(u32, 1024) << @intCast(self.s_log_block_size);
    }

    pub fn getTotalBlocks(self: *const Ext4Superblock) u64 {
        return (@as(u64, self.s_blocks_count_hi) << 32) | self.s_blocks_count_lo;
    }

    pub fn getBlockGroupCount(self: *const Ext4Superblock) u32 {
        const total_blocks = self.getTotalBlocks();
        return @intCast((total_blocks + self.s_blocks_per_group - 1) / self.s_blocks_per_group);
    }

    pub fn isValid(self: *const Ext4Superblock) bool {
        return self.s_magic == 0xEF53;
    }
};

/// Group Descriptor (32 or 64 bytes)
pub const Ext4GroupDesc = extern struct {
    bg_block_bitmap_lo: u32, // Block bitmap block (low)
    bg_inode_bitmap_lo: u32, // Inode bitmap block (low)
    bg_inode_table_lo: u32, // Inode table block (low)
    bg_free_blocks_count_lo: u16, // Free blocks count (low)
    bg_free_inodes_count_lo: u16, // Free inodes count (low)
    bg_used_dirs_count_lo: u16, // Used directories count (low)
    bg_flags: u16, // Flags
    bg_exclude_bitmap_lo: u32, // Exclude bitmap (low)
    bg_block_bitmap_csum_lo: u16, // Block bitmap checksum (low)
    bg_inode_bitmap_csum_lo: u16, // Inode bitmap checksum (low)
    bg_itable_unused_lo: u16, // Unused inodes count (low)
    bg_checksum: u16, // Group descriptor checksum

    // 64-bit fields (if s_desc_size > 32)
    bg_block_bitmap_hi: u32, // Block bitmap block (high)
    bg_inode_bitmap_hi: u32, // Inode bitmap block (high)
    bg_inode_table_hi: u32, // Inode table block (high)
    bg_free_blocks_count_hi: u16, // Free blocks count (high)
    bg_free_inodes_count_hi: u16, // Free inodes count (high)
    bg_used_dirs_count_hi: u16, // Used directories count (high)
    bg_itable_unused_hi: u16, // Unused inodes count (high)
    bg_exclude_bitmap_hi: u32, // Exclude bitmap (high)
    bg_block_bitmap_csum_hi: u16, // Block bitmap checksum (high)
    bg_inode_bitmap_csum_hi: u16, // Inode bitmap checksum (high)
    bg_reserved: u32,

    pub fn getInodeTable(self: *const Ext4GroupDesc) u64 {
        return (@as(u64, self.bg_inode_table_hi) << 32) | self.bg_inode_table_lo;
    }

    pub fn getBlockBitmap(self: *const Ext4GroupDesc) u64 {
        return (@as(u64, self.bg_block_bitmap_hi) << 32) | self.bg_block_bitmap_lo;
    }

    pub fn getInodeBitmap(self: *const Ext4GroupDesc) u64 {
        return (@as(u64, self.bg_inode_bitmap_hi) << 32) | self.bg_inode_bitmap_lo;
    }
};

/// Inode structure (typically 256 bytes in ext4)
pub const Ext4Inode = extern struct {
    i_mode: u16, // File mode
    i_uid: u16, // Owner UID (low)
    i_size_lo: u32, // Size (low)
    i_atime: u32, // Access time
    i_ctime: u32, // Inode change time
    i_mtime: u32, // Modification time
    i_dtime: u32, // Deletion time
    i_gid: u16, // Owner GID (low)
    i_links_count: u16, // Links count
    i_blocks_lo: u32, // Blocks count (low)
    i_flags: u32, // Flags
    i_osd1: u32, // OS-dependent 1
    i_block: [15]u32, // Block pointers / extent tree
    i_generation: u32, // File generation
    i_file_acl_lo: u32, // File ACL (low)
    i_size_high: u32, // Size (high for regular files)
    i_obso_faddr: u32, // Obsolete fragment address
    i_osd2: [12]u8, // OS-dependent 2
    i_extra_isize: u16, // Extra inode size
    i_checksum_hi: u16, // Checksum (high)
    i_ctime_extra: u32, // Extra change time
    i_mtime_extra: u32, // Extra modification time
    i_atime_extra: u32, // Extra access time
    i_crtime: u32, // Creation time
    i_crtime_extra: u32, // Extra creation time
    i_version_hi: u32, // Version (high)
    i_projid: u32, // Project ID

    pub fn getSize(self: *const Ext4Inode) u64 {
        return (@as(u64, self.i_size_high) << 32) | self.i_size_lo;
    }

    pub fn isDirectory(self: *const Ext4Inode) bool {
        return (self.i_mode & 0xF000) == 0x4000;
    }

    pub fn isRegularFile(self: *const Ext4Inode) bool {
        return (self.i_mode & 0xF000) == 0x8000;
    }

    pub fn isSymlink(self: *const Ext4Inode) bool {
        return (self.i_mode & 0xF000) == 0xA000;
    }

    pub fn usesExtents(self: *const Ext4Inode) bool {
        return (self.i_flags & EXT4_EXTENTS_FL) != 0;
    }
};

// Inode flags
pub const EXT4_EXTENTS_FL = 0x00080000;

/// Extent header
pub const Ext4ExtentHeader = extern struct {
    eh_magic: u16, // Magic number (0xF30A)
    eh_entries: u16, // Number of valid entries
    eh_max: u16, // Max entries
    eh_depth: u16, // Depth (0 = leaf)
    eh_generation: u32, // Generation
};

/// Extent index (internal node)
pub const Ext4ExtentIdx = extern struct {
    ei_block: u32, // Logical block
    ei_leaf_lo: u32, // Physical block (low)
    ei_leaf_hi: u16, // Physical block (high)
    ei_unused: u16,

    pub fn getLeaf(self: *const Ext4ExtentIdx) u64 {
        return (@as(u64, self.ei_leaf_hi) << 32) | self.ei_leaf_lo;
    }
};

/// Extent (leaf node)
pub const Ext4Extent = extern struct {
    ee_block: u32, // First logical block
    ee_len: u16, // Number of blocks
    ee_start_hi: u16, // Physical block (high)
    ee_start_lo: u32, // Physical block (low)

    pub fn getStart(self: *const Ext4Extent) u64 {
        return (@as(u64, self.ee_start_hi) << 32) | self.ee_start_lo;
    }

    pub fn getLength(self: *const Ext4Extent) u32 {
        // High bit indicates uninitialized extent
        return self.ee_len & 0x7FFF;
    }
};

/// Directory entry
pub const Ext4DirEntry = extern struct {
    inode: u32, // Inode number
    rec_len: u16, // Record length
    name_len: u8, // Name length
    file_type: u8, // File type
    // name follows (variable length)
};

// Directory entry file types
pub const EXT4_FT_UNKNOWN = 0;
pub const EXT4_FT_REG_FILE = 1;
pub const EXT4_FT_DIR = 2;
pub const EXT4_FT_CHRDEV = 3;
pub const EXT4_FT_BLKDEV = 4;
pub const EXT4_FT_FIFO = 5;
pub const EXT4_FT_SOCK = 6;
pub const EXT4_FT_SYMLINK = 7;

// ============================================================================
// ext4 Filesystem Implementation
// ============================================================================

pub const Ext4Filesystem = struct {
    allocator: Basics.Allocator,
    device: *block.BlockDevice,
    superblock: Ext4Superblock,
    block_size: u32,
    group_desc_size: u16,
    inodes_per_group: u32,
    inode_size: u16,
    groups_count: u32,
    lock: sync.RwLock,

    pub fn mount(allocator: Basics.Allocator, device: *block.BlockDevice) !*Ext4Filesystem {
        const fs = try allocator.create(Ext4Filesystem);
        errdefer allocator.destroy(fs);

        fs.allocator = allocator;
        fs.device = device;
        fs.lock = sync.RwLock.init();

        // Read superblock (at byte offset 1024)
        var sb_buffer: [1024]u8 = undefined;
        try device.read(1024 / device.block_size, &sb_buffer);

        fs.superblock = @as(*const Ext4Superblock, @ptrCast(@alignCast(&sb_buffer))).*;

        // Validate superblock
        if (!fs.superblock.isValid()) {
            return error.InvalidFilesystem;
        }

        // Cache important values
        fs.block_size = fs.superblock.getBlockSize();
        fs.group_desc_size = if (fs.superblock.s_desc_size > 0) fs.superblock.s_desc_size else 32;
        fs.inodes_per_group = fs.superblock.s_inodes_per_group;
        fs.inode_size = fs.superblock.s_inode_size;
        fs.groups_count = fs.superblock.getBlockGroupCount();

        return fs;
    }

    pub fn unmount(self: *Ext4Filesystem) void {
        self.allocator.destroy(self);
    }

    /// Read an inode from disk
    pub fn readInode(self: *Ext4Filesystem, ino: u32) !Ext4Inode {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        if (ino == 0) return error.InvalidInode;

        // Calculate which block group the inode is in
        const group = (ino - 1) / self.inodes_per_group;
        const index = (ino - 1) % self.inodes_per_group;

        // Read group descriptor
        const gd = try self.readGroupDescriptor(group);

        // Calculate inode table block and offset
        const inode_table_block = gd.getInodeTable();
        const inodes_per_block = self.block_size / self.inode_size;
        const block_offset = index / inodes_per_block;
        const inode_offset = (index % inodes_per_block) * self.inode_size;

        // Read the block containing the inode
        const buffer = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(buffer);

        try self.readBlock(inode_table_block + block_offset, buffer);

        // Extract inode
        const inode_ptr: *const Ext4Inode = @ptrCast(@alignCast(buffer[inode_offset..].ptr));
        return inode_ptr.*;
    }

    /// Read a block from the device
    pub fn readBlock(self: *Ext4Filesystem, block_num: u64, buffer: []u8) !void {
        const sectors_per_block = self.block_size / self.device.block_size;
        const start_sector = block_num * sectors_per_block;

        try self.device.read(start_sector, buffer[0..self.block_size]);
    }

    /// Read a group descriptor
    fn readGroupDescriptor(self: *Ext4Filesystem, group: u32) !Ext4GroupDesc {
        // Group descriptors start at block 1 (or 2 if block_size = 1024)
        const gd_start_block: u64 = if (self.block_size == 1024) 2 else 1;
        const gd_per_block = self.block_size / self.group_desc_size;
        const gd_block = gd_start_block + (group / gd_per_block);
        const gd_offset = (group % gd_per_block) * self.group_desc_size;

        const buffer = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(buffer);

        try self.readBlock(gd_block, buffer);

        const gd_ptr: *const Ext4GroupDesc = @ptrCast(@alignCast(buffer[gd_offset..].ptr));
        return gd_ptr.*;
    }

    /// Read file data using extent tree
    pub fn readFileData(self: *Ext4Filesystem, inode: *const Ext4Inode, offset: u64, buffer: []u8) !usize {
        if (!inode.usesExtents()) {
            return self.readFileDataDirect(inode, offset, buffer);
        }

        return self.readFileDataExtents(inode, offset, buffer);
    }

    /// Read file data using extent tree
    fn readFileDataExtents(self: *Ext4Filesystem, inode: *const Ext4Inode, offset: u64, buffer: []u8) !usize {
        const file_size = inode.getSize();
        if (offset >= file_size) return 0;

        const to_read = @min(buffer.len, file_size - offset);
        var bytes_read: usize = 0;

        // Parse extent header from i_block
        const header: *const Ext4ExtentHeader = @ptrCast(@alignCast(&inode.i_block));

        if (header.eh_magic != 0xF30A) {
            return error.InvalidExtentHeader;
        }

        // Read data by traversing extent tree
        const logical_block = offset / self.block_size;
        const block_offset = offset % self.block_size;

        const phys_block = try self.lookupExtent(header, &inode.i_block, logical_block);
        if (phys_block == 0) return 0;

        // Read the block
        const block_buffer = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(block_buffer);

        try self.readBlock(phys_block, block_buffer);

        // Copy data
        const available = self.block_size - block_offset;
        const copy_len = @min(to_read, available);
        @memcpy(buffer[0..copy_len], block_buffer[block_offset..][0..copy_len]);
        bytes_read += copy_len;

        return bytes_read;
    }

    /// Look up physical block from extent tree
    fn lookupExtent(self: *Ext4Filesystem, header: *const Ext4ExtentHeader, block_data: *const [15]u32, logical_block: u64) !u64 {
        if (header.eh_depth == 0) {
            // Leaf node - search extents
            const extents_ptr: [*]const Ext4Extent = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(header)) + @sizeOf(Ext4ExtentHeader)));

            for (0..header.eh_entries) |i| {
                const ext = extents_ptr[i];
                const start = ext.ee_block;
                const len = ext.getLength();

                if (logical_block >= start and logical_block < start + len) {
                    const offset = logical_block - start;
                    return ext.getStart() + offset;
                }
            }
            return 0;
        } else {
            // Internal node - search indices and recurse
            _ = block_data;
            // For simplicity, only support depth 0 for now
            return error.UnsupportedExtentDepth;
        }
    }

    /// Read file data using direct/indirect blocks (legacy)
    fn readFileDataDirect(self: *Ext4Filesystem, inode: *const Ext4Inode, offset: u64, buffer: []u8) !usize {
        const file_size = inode.getSize();
        if (offset >= file_size) return 0;

        const to_read = @min(buffer.len, file_size - offset);
        const logical_block = offset / self.block_size;
        const block_offset = offset % self.block_size;

        // Direct blocks (0-11)
        if (logical_block < 12) {
            const phys_block = inode.i_block[logical_block];
            if (phys_block == 0) return 0;

            const block_buffer = try self.allocator.alloc(u8, self.block_size);
            defer self.allocator.free(block_buffer);

            try self.readBlock(phys_block, block_buffer);

            const available = self.block_size - block_offset;
            const copy_len = @min(to_read, available);
            @memcpy(buffer[0..copy_len], block_buffer[block_offset..][0..copy_len]);

            return copy_len;
        }

        // Indirect blocks not implemented for simplicity
        return error.UnsupportedBlockType;
    }

    /// Read directory entries
    pub fn readDirectory(self: *Ext4Filesystem, inode: *const Ext4Inode, callback: *const fn (name: []const u8, ino: u32, file_type: u8) bool) !void {
        if (!inode.isDirectory()) {
            return error.NotADirectory;
        }

        const dir_size = inode.getSize();
        var offset: u64 = 0;

        const block_buffer = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(block_buffer);

        while (offset < dir_size) {
            const bytes_read = try self.readFileData(inode, offset, block_buffer);
            if (bytes_read == 0) break;

            var pos: usize = 0;
            while (pos < bytes_read) {
                const entry: *const Ext4DirEntry = @ptrCast(@alignCast(block_buffer[pos..].ptr));

                if (entry.inode != 0 and entry.name_len > 0) {
                    const name = block_buffer[pos + 8 ..][0..entry.name_len];
                    if (!callback(name, entry.inode, entry.file_type)) {
                        return;
                    }
                }

                if (entry.rec_len == 0) break;
                pos += entry.rec_len;
            }

            offset += bytes_read;
        }
    }
};

// ============================================================================
// VFS Integration
// ============================================================================

/// ext4-specific inode data
const Ext4InodeData = struct {
    ino: u32,
    ext4_inode: Ext4Inode,
    fs: *Ext4Filesystem,
};

fn ext4Lookup(dir: *vfs.Inode, name: []const u8) anyerror!?*vfs.Dentry {
    const data: *Ext4InodeData = @ptrCast(@alignCast(dir.private_data));

    var found_ino: u32 = 0;
    var found_type: u8 = 0;

    try data.fs.readDirectory(&data.ext4_inode, struct {
        fn callback(entry_name: []const u8, ino: u32, file_type: u8) bool {
            _ = entry_name;
            _ = ino;
            _ = file_type;
            return true; // Simplified - would need to match name
        }
    }.callback);

    _ = name;
    _ = found_ino;
    _ = found_type;

    // Simplified lookup - full implementation would search for name
    return null;
}

fn ext4Read(file: *vfs.File, buffer: []u8, offset: u64) anyerror!usize {
    const inode = file.dentry.inode;
    const data: *Ext4InodeData = @ptrCast(@alignCast(inode.private_data));

    return data.fs.readFileData(&data.ext4_inode, offset, buffer);
}

fn ext4Readdir(file: *vfs.File, callback: *const fn (name: []const u8, ino: u64, dtype: u8) bool) anyerror!void {
    const inode = file.dentry.inode;
    const data: *Ext4InodeData = @ptrCast(@alignCast(inode.private_data));

    try data.fs.readDirectory(&data.ext4_inode, struct {
        fn inner_callback(name: []const u8, ino: u32, file_type: u8) bool {
            _ = name;
            _ = ino;
            _ = file_type;
            return true; // Would call outer callback
        }
    }.inner_callback);

    _ = callback;
}

const ext4_inode_ops = vfs.InodeOperations{
    .lookup = ext4Lookup,
};

const ext4_file_ops = vfs.FileOperations{
    .read = ext4Read,
    .readdir = ext4Readdir,
};

fn ext4Mount(sb: *vfs.Superblock, source: ?[]const u8, _: ?*anyopaque) anyerror!void {
    _ = source;

    // Get block device from source
    // For now, use placeholder
    const device: *block.BlockDevice = undefined;

    const fs = try Ext4Filesystem.mount(sb.allocator, device);

    // Read root inode (always inode 2 in ext4)
    const root_ext4_inode = try fs.readInode(2);

    // Create VFS inode
    const root_inode = try sb.allocator.create(vfs.Inode);
    root_inode.* = vfs.Inode.init(sb, 2, .Directory, &ext4_inode_ops);
    root_inode.size = root_ext4_inode.getSize();
    root_inode.mode = vfs.FileMode.fromU16(root_ext4_inode.i_mode);

    // Create inode data
    const inode_data = try sb.allocator.create(Ext4InodeData);
    inode_data.* = .{
        .ino = 2,
        .ext4_inode = root_ext4_inode,
        .fs = fs,
    };
    root_inode.private_data = inode_data;

    // Create root dentry
    const root_dentry = try sb.allocator.create(vfs.Dentry);
    const root_name = try sb.allocator.alloc(u8, 1);
    root_name[0] = '/';
    root_dentry.* = vfs.Dentry.init(root_name, root_inode, null);

    sb.root = root_dentry;
    sb.fs_data = fs;
}

fn ext4Umount(sb: *vfs.Superblock) void {
    if (sb.fs_data) |fs_ptr| {
        const fs: *Ext4Filesystem = @ptrCast(@alignCast(fs_ptr));
        fs.unmount();
    }
}

const ext4_fs_type = vfs.FilesystemType{
    .name = "ext4",
    .flags = .{},
    .mount = ext4Mount,
    .umount = ext4Umount,
};

/// Initialize ext4 filesystem driver
pub fn init() void {
    vfs.registerFilesystem(&ext4_fs_type);
}
