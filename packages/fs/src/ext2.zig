// Home Programming Language - ext2 Filesystem Driver
// Second Extended Filesystem (Linux)

const Basics = @import("basics");
const vfs = @import("vfs.zig");
const block = @import("block.zig");

// ============================================================================
// ext2 Superblock
// ============================================================================

pub const Ext2Superblock = extern struct {
    s_inodes_count: u32,
    s_blocks_count: u32,
    s_r_blocks_count: u32,
    s_free_blocks_count: u32,
    s_free_inodes_count: u32,
    s_first_data_block: u32,
    s_log_block_size: u32,
    s_log_frag_size: u32,
    s_blocks_per_group: u32,
    s_frags_per_group: u32,
    s_inodes_per_group: u32,
    s_mtime: u32,
    s_wtime: u32,
    s_mnt_count: u16,
    s_max_mnt_count: u16,
    s_magic: u16,
    s_state: u16,
    s_errors: u16,
    s_minor_rev_level: u16,
    s_lastcheck: u32,
    s_checkinterval: u32,
    s_creator_os: u32,
    s_rev_level: u32,
    s_def_resuid: u16,
    s_def_resgid: u16,

    // Extended superblock fields (rev_level >= 1)
    s_first_ino: u32,
    s_inode_size: u16,
    s_block_group_nr: u16,
    s_feature_compat: u32,
    s_feature_incompat: u32,
    s_feature_ro_compat: u32,
    s_uuid: [16]u8,
    s_volume_name: [16]u8,
    s_last_mounted: [64]u8,
    s_algo_bitmap: u32,

    pub const EXT2_SUPER_MAGIC = 0xEF53;
    pub const EXT2_GOOD_OLD_REV = 0;
    pub const EXT2_DYNAMIC_REV = 1;

    pub fn isValid(self: *const Ext2Superblock) bool {
        return self.s_magic == EXT2_SUPER_MAGIC;
    }

    pub fn getBlockSize(self: *const Ext2Superblock) u32 {
        return @as(u32, 1024) << @intCast(self.s_log_block_size);
    }

    pub fn getInodeSize(self: *const Ext2Superblock) u32 {
        if (self.s_rev_level >= EXT2_DYNAMIC_REV) {
            return self.s_inode_size;
        }
        return 128; // Old revision
    }

    pub fn getGroupCount(self: *const Ext2Superblock) u32 {
        return (self.s_blocks_count + self.s_blocks_per_group - 1) / self.s_blocks_per_group;
    }
};

// ============================================================================
// ext2 Block Group Descriptor
// ============================================================================

pub const Ext2BlockGroupDescriptor = extern struct {
    bg_block_bitmap: u32,
    bg_inode_bitmap: u32,
    bg_inode_table: u32,
    bg_free_blocks_count: u16,
    bg_free_inodes_count: u16,
    bg_used_dirs_count: u16,
    bg_pad: u16,
    bg_reserved: [12]u8,
};

// ============================================================================
// ext2 Inode
// ============================================================================

pub const Ext2Inode = extern struct {
    i_mode: u16,
    i_uid: u16,
    i_size: u32,
    i_atime: u32,
    i_ctime: u32,
    i_mtime: u32,
    i_dtime: u32,
    i_gid: u16,
    i_links_count: u16,
    i_blocks: u32,
    i_flags: u32,
    i_osd1: u32,
    i_block: [15]u32,
    i_generation: u32,
    i_file_acl: u32,
    i_dir_acl: u32,
    i_faddr: u32,
    i_osd2: [12]u8,

    // Inode mode bits
    pub const S_IFMT = 0xF000;
    pub const S_IFSOCK = 0xC000;
    pub const S_IFLNK = 0xA000;
    pub const S_IFREG = 0x8000;
    pub const S_IFBLK = 0x6000;
    pub const S_IFDIR = 0x4000;
    pub const S_IFCHR = 0x2000;
    pub const S_IFIFO = 0x1000;

    pub fn isDirectory(self: *const Ext2Inode) bool {
        return (self.i_mode & S_IFMT) == S_IFDIR;
    }

    pub fn isRegularFile(self: *const Ext2Inode) bool {
        return (self.i_mode & S_IFMT) == S_IFREG;
    }

    pub fn isSymlink(self: *const Ext2Inode) bool {
        return (self.i_mode & S_IFMT) == S_IFLNK;
    }

    pub fn getSize(self: *const Ext2Inode) u64 {
        return self.i_size;
    }
};

// ============================================================================
// ext2 Directory Entry
// ============================================================================

pub const Ext2DirEntry = extern struct {
    inode: u32,
    rec_len: u16,
    name_len: u8,
    file_type: u8,
    // name follows

    pub const FT_UNKNOWN = 0;
    pub const FT_REG_FILE = 1;
    pub const FT_DIR = 2;
    pub const FT_CHRDEV = 3;
    pub const FT_BLKDEV = 4;
    pub const FT_FIFO = 5;
    pub const FT_SOCK = 6;
    pub const FT_SYMLINK = 7;

    pub fn getName(self: *const Ext2DirEntry) []const u8 {
        const name_ptr = @as([*]const u8, @ptrCast(self)) + @sizeOf(Ext2DirEntry);
        return name_ptr[0..self.name_len];
    }
};

// ============================================================================
// ext2 Filesystem
// ============================================================================

pub const Ext2Filesystem = struct {
    block_device: *block.BlockDevice,
    superblock: Ext2Superblock,
    block_size: u32,
    block_groups: []Ext2BlockGroupDescriptor,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, device: *block.BlockDevice) !*Ext2Filesystem {
        const fs = try allocator.create(Ext2Filesystem);
        errdefer allocator.destroy(fs);

        // Read superblock (at offset 1024)
        var sb_buffer: [1024]u8 = undefined;
        const bytes_read = try device.read(2, &sb_buffer); // Block 2 (512-byte blocks)
        if (bytes_read < @sizeOf(Ext2Superblock)) {
            return error.InvalidSuperblock;
        }

        const superblock = @as(*const Ext2Superblock, @ptrCast(@alignCast(&sb_buffer))).*;

        if (!superblock.isValid()) {
            return error.InvalidMagic;
        }

        const block_size = superblock.getBlockSize();
        const group_count = superblock.getGroupCount();

        // Read block group descriptors
        const bgd_blocks = (group_count * @sizeOf(Ext2BlockGroupDescriptor) + block_size - 1) / block_size;
        const bgd_buffer = try allocator.alloc(u8, bgd_blocks * block_size);
        errdefer allocator.free(bgd_buffer);

        const bgd_start_block = if (block_size == 1024) 2 else 1;
        _ = try device.read(bgd_start_block * (block_size / 512), bgd_buffer);

        const bgd_array = @as([*]Ext2BlockGroupDescriptor, @ptrCast(@alignCast(bgd_buffer.ptr)))[0..group_count];

        fs.* = .{
            .block_device = device,
            .superblock = superblock,
            .block_size = block_size,
            .block_groups = bgd_array,
            .allocator = allocator,
        };

        return fs;
    }

    pub fn deinit(self: *Ext2Filesystem) void {
        self.allocator.free(@as([*]u8, @ptrCast(self.block_groups.ptr))[0 .. self.block_groups.len * @sizeOf(Ext2BlockGroupDescriptor)]);
        self.allocator.destroy(self);
    }

    pub fn readInode(self: *Ext2Filesystem, inode_num: u32) !Ext2Inode {
        if (inode_num == 0 or inode_num > self.superblock.s_inodes_count) {
            return error.InvalidInode;
        }

        // Calculate inode location
        const group = (inode_num - 1) / self.superblock.s_inodes_per_group;
        const index = (inode_num - 1) % self.superblock.s_inodes_per_group;
        const inode_size = self.superblock.getInodeSize();

        const bgd = &self.block_groups[group];
        const inode_table_block = bgd.bg_inode_table;
        const inode_offset = index * inode_size;
        const block_offset = inode_offset / self.block_size;
        const offset_in_block = inode_offset % self.block_size;

        // Read inode
        var buffer: [512]u8 = undefined;
        const lba = (inode_table_block + block_offset) * (self.block_size / 512);
        _ = try self.block_device.read(lba, &buffer);

        const inode = @as(*const Ext2Inode, @ptrCast(@alignCast(buffer[offset_in_block..].ptr))).*;
        return inode;
    }

    pub fn readBlock(self: *Ext2Filesystem, block_num: u32, buffer: []u8) !void {
        if (buffer.len < self.block_size) {
            return error.BufferTooSmall;
        }

        const lba = block_num * (self.block_size / 512);
        _ = try self.block_device.read(lba, buffer[0..self.block_size]);
    }

    pub fn readInodeData(self: *Ext2Filesystem, inode: *const Ext2Inode, offset: u64, buffer: []u8) !usize {
        const file_size = inode.getSize();
        if (offset >= file_size) {
            return 0;
        }

        const to_read = Basics.math.min(buffer.len, @as(usize, @intCast(file_size - offset)));
        var bytes_read: usize = 0;

        var current_offset = offset;
        while (bytes_read < to_read) {
            const block_index = current_offset / self.block_size;
            const offset_in_block = current_offset % self.block_size;
            const bytes_in_block = Basics.math.min(self.block_size - @as(u32, @intCast(offset_in_block)), @as(u32, @intCast(to_read - bytes_read)));

            const block_num = try self.getInodeBlock(inode, @intCast(block_index));
            if (block_num == 0) break; // Sparse file

            var block_buffer: [4096]u8 = undefined;
            try self.readBlock(block_num, &block_buffer);

            @memcpy(buffer[bytes_read .. bytes_read + bytes_in_block], block_buffer[offset_in_block .. offset_in_block + bytes_in_block]);

            bytes_read += bytes_in_block;
            current_offset += bytes_in_block;
        }

        return bytes_read;
    }

    fn getInodeBlock(self: *Ext2Filesystem, inode: *const Ext2Inode, block_index: u32) !u32 {
        // Direct blocks (0-11)
        if (block_index < 12) {
            return inode.i_block[block_index];
        }

        const blocks_per_indirect = self.block_size / 4;

        // Single indirect (12)
        if (block_index < 12 + blocks_per_indirect) {
            const indirect_block = inode.i_block[12];
            if (indirect_block == 0) return 0;

            var indirect_buffer: [4096]u8 = undefined;
            try self.readBlock(indirect_block, &indirect_buffer);

            const indirect_table = @as([*]const u32, @ptrCast(@alignCast(&indirect_buffer)));
            return indirect_table[block_index - 12];
        }

        // Double indirect (13)
        if (block_index < 12 + blocks_per_indirect + blocks_per_indirect * blocks_per_indirect) {
            const double_indirect_block = inode.i_block[13];
            if (double_indirect_block == 0) return 0;

            var indirect_buffer: [4096]u8 = undefined;
            try self.readBlock(double_indirect_block, &indirect_buffer);

            const adjusted_index = block_index - 12 - blocks_per_indirect;
            const indirect_index = adjusted_index / blocks_per_indirect;
            const block_in_indirect = adjusted_index % blocks_per_indirect;

            const indirect_table = @as([*]const u32, @ptrCast(@alignCast(&indirect_buffer)));
            const indirect_block = indirect_table[indirect_index];
            if (indirect_block == 0) return 0;

            try self.readBlock(indirect_block, &indirect_buffer);
            const block_table = @as([*]const u32, @ptrCast(@alignCast(&indirect_buffer)));
            return block_table[block_in_indirect];
        }

        // Triple indirect not implemented
        return error.BlockIndexTooLarge;
    }

    pub fn readDirectory(self: *Ext2Filesystem, inode: *const Ext2Inode, allocator: Basics.Allocator) ![]Ext2DirEntry {
        if (!inode.isDirectory()) {
            return error.NotADirectory;
        }

        const dir_size = inode.getSize();
        const dir_data = try allocator.alloc(u8, @intCast(dir_size));
        defer allocator.free(dir_data);

        _ = try self.readInodeData(inode, 0, dir_data);

        var entries = Basics.ArrayList(Ext2DirEntry).init(allocator);
        var offset: usize = 0;

        while (offset < dir_size) {
            const entry = @as(*const Ext2DirEntry, @ptrCast(@alignCast(dir_data[offset..].ptr))).*;
            if (entry.inode != 0) {
                try entries.append(entry);
            }

            offset += entry.rec_len;
            if (entry.rec_len == 0) break; // Safety check
        }

        return entries.toOwnedSlice();
    }

    pub fn findInDirectory(self: *Ext2Filesystem, dir_inode: *const Ext2Inode, name: []const u8) !u32 {
        const entries = try self.readDirectory(dir_inode, self.allocator);
        defer self.allocator.free(entries);

        for (entries) |entry| {
            if (Basics.mem.eql(u8, entry.getName(), name)) {
                return entry.inode;
            }
        }

        return error.NotFound;
    }

    pub fn getRootInode(self: *Ext2Filesystem) !Ext2Inode {
        return try self.readInode(2); // Root inode is always 2
    }
};

// ============================================================================
// VFS Integration
// ============================================================================

pub fn mount(allocator: Basics.Allocator, device: *block.BlockDevice) !*vfs.Superblock {
    const ext2_fs = try Ext2Filesystem.init(allocator, device);
    errdefer ext2_fs.deinit();

    const sb = try vfs.Superblock.create(allocator);
    sb.fs_type = "ext2";
    sb.private_data = ext2_fs;

    // Create root inode
    const root_ext2_inode = try ext2_fs.getRootInode();
    const root_inode = try vfs.Inode.create(allocator, 2);
    root_inode.mode = root_ext2_inode.i_mode;
    root_inode.size = root_ext2_inode.i_size;
    root_inode.superblock = sb;

    sb.root = root_inode;

    return sb;
}

// ============================================================================
// Tests
// ============================================================================

test "ext2 superblock validation" {
    var sb: Ext2Superblock = undefined;
    sb.s_magic = Ext2Superblock.EXT2_SUPER_MAGIC;

    try Basics.testing.expect(sb.isValid());
}

test "ext2 inode type detection" {
    var inode: Ext2Inode = undefined;

    inode.i_mode = Ext2Inode.S_IFDIR | 0o755;
    try Basics.testing.expect(inode.isDirectory());
    try Basics.testing.expect(!inode.isRegularFile());

    inode.i_mode = Ext2Inode.S_IFREG | 0o644;
    try Basics.testing.expect(!inode.isDirectory());
    try Basics.testing.expect(inode.isRegularFile());
}

test "ext2 block size calculation" {
    var sb: Ext2Superblock = undefined;
    sb.s_log_block_size = 0; // 1024 bytes
    try Basics.testing.expectEqual(@as(u32, 1024), sb.getBlockSize());

    sb.s_log_block_size = 1; // 2048 bytes
    try Basics.testing.expectEqual(@as(u32, 2048), sb.getBlockSize());

    sb.s_log_block_size = 2; // 4096 bytes
    try Basics.testing.expectEqual(@as(u32, 4096), sb.getBlockSize());
}
