// Home Programming Language - FAT32 File System Driver
// FAT32 filesystem support for compatibility

const Basics = @import("basics");
const vfs = @import("vfs.zig");
const block = @import("block.zig");

// ============================================================================
// FAT32 Boot Sector
// ============================================================================

pub const Fat32BootSector = extern struct {
    jump_boot: [3]u8,
    oem_name: [8]u8,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    num_fats: u8,
    root_entries: u16,
    total_sectors_16: u16,
    media_type: u8,
    fat_size_16: u16,
    sectors_per_track: u16,
    num_heads: u16,
    hidden_sectors: u32,
    total_sectors_32: u32,

    // FAT32 Extended Boot Record
    fat_size_32: u32,
    ext_flags: u16,
    fs_version: u16,
    root_cluster: u32,
    fs_info_sector: u16,
    backup_boot_sector: u16,
    reserved: [12]u8,
    drive_number: u8,
    reserved1: u8,
    boot_signature: u8,
    volume_id: u32,
    volume_label: [11]u8,
    fs_type: [8]u8,

    pub fn validate(self: *const Fat32BootSector) bool {
        // Check boot signature
        if (self.boot_signature != 0x29) return false;

        // Check FAT type
        const fs_type = "FAT32   ";
        if (!Basics.mem.eql(u8, &self.fs_type, fs_type)) return false;

        return true;
    }

    pub fn getFatSize(self: *const Fat32BootSector) u32 {
        if (self.fat_size_16 != 0) {
            return self.fat_size_16;
        }
        return self.fat_size_32;
    }

    pub fn getTotalSectors(self: *const Fat32BootSector) u32 {
        if (self.total_sectors_16 != 0) {
            return self.total_sectors_16;
        }
        return self.total_sectors_32;
    }

    pub fn getClusterSize(self: *const Fat32BootSector) u32 {
        return @as(u32, self.bytes_per_sector) * @as(u32, self.sectors_per_cluster);
    }
};

// ============================================================================
// FAT32 Directory Entry
// ============================================================================

pub const Fat32DirEntry = extern struct {
    name: [11]u8,
    attributes: u8,
    reserved: u8,
    creation_time_tenths: u8,
    creation_time: u16,
    creation_date: u16,
    last_access_date: u16,
    first_cluster_high: u16,
    modification_time: u16,
    modification_date: u16,
    first_cluster_low: u16,
    file_size: u32,

    pub const ATTR_READ_ONLY: u8 = 0x01;
    pub const ATTR_HIDDEN: u8 = 0x02;
    pub const ATTR_SYSTEM: u8 = 0x04;
    pub const ATTR_VOLUME_ID: u8 = 0x08;
    pub const ATTR_DIRECTORY: u8 = 0x10;
    pub const ATTR_ARCHIVE: u8 = 0x20;

    pub fn getFirstCluster(self: *const Fat32DirEntry) u32 {
        return (@as(u32, self.first_cluster_high) << 16) | self.first_cluster_low;
    }

    pub fn isDirectory(self: *const Fat32DirEntry) bool {
        return (self.attributes & ATTR_DIRECTORY) != 0;
    }

    pub fn isDeleted(self: *const Fat32DirEntry) bool {
        return self.name[0] == 0xE5;
    }

    pub fn isEmpty(self: *const Fat32DirEntry) bool {
        return self.name[0] == 0x00;
    }

    pub fn isLongName(self: *const Fat32DirEntry) bool {
        return self.attributes == 0x0F;
    }

    pub fn getName(self: *const Fat32DirEntry, buffer: []u8) []const u8 {
        var len: usize = 0;

        // Copy name (8 chars)
        for (self.name[0..8]) |c| {
            if (c == ' ') break;
            buffer[len] = c;
            len += 1;
        }

        // Check for extension
        const has_ext = self.name[8] != ' ';
        if (has_ext) {
            buffer[len] = '.';
            len += 1;

            for (self.name[8..11]) |c| {
                if (c == ' ') break;
                buffer[len] = c;
                len += 1;
            }
        }

        return buffer[0..len];
    }
};

// ============================================================================
// FAT32 Filesystem
// ============================================================================

pub const Fat32Fs = struct {
    device: *block.BlockDevice,
    boot_sector: Fat32BootSector,
    fat_start_sector: u32,
    cluster_begin_sector: u32,
    sectors_per_cluster: u32,
    bytes_per_cluster: u32,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, device: *block.BlockDevice) !*Fat32Fs {
        const fs = try allocator.create(Fat32Fs);

        // Read boot sector
        var boot_buffer: [512]u8 = undefined;
        try device.read(0, 1, &boot_buffer);

        const boot_sector: *const Fat32BootSector = @ptrCast(&boot_buffer);
        if (!boot_sector.validate()) {
            return error.InvalidFat32;
        }

        fs.* = .{
            .device = device,
            .boot_sector = boot_sector.*,
            .fat_start_sector = boot_sector.reserved_sectors,
            .cluster_begin_sector = undefined,
            .sectors_per_cluster = boot_sector.sectors_per_cluster,
            .bytes_per_cluster = boot_sector.getClusterSize(),
            .allocator = allocator,
        };

        // Calculate cluster begin sector
        const fat_size = boot_sector.getFatSize();
        const root_dir_sectors = ((boot_sector.root_entries * 32) + (boot_sector.bytes_per_sector - 1)) / boot_sector.bytes_per_sector;
        fs.cluster_begin_sector = boot_sector.reserved_sectors + (boot_sector.num_fats * fat_size) + root_dir_sectors;

        return fs;
    }

    pub fn deinit(self: *Fat32Fs) void {
        self.allocator.destroy(self);
    }

    pub fn clusterToSector(self: *const Fat32Fs, cluster: u32) u32 {
        return self.cluster_begin_sector + (cluster - 2) * self.sectors_per_cluster;
    }

    pub fn readCluster(self: *Fat32Fs, cluster: u32, buffer: []u8) !void {
        if (buffer.len < self.bytes_per_cluster) {
            return error.BufferTooSmall;
        }

        const sector = self.clusterToSector(cluster);
        try self.device.read(sector, self.sectors_per_cluster, buffer);
    }

    pub fn readFatEntry(self: *Fat32Fs, cluster: u32) !u32 {
        const fat_offset = cluster * 4;
        const fat_sector = self.fat_start_sector + (fat_offset / self.boot_sector.bytes_per_sector);
        const entry_offset = fat_offset % self.boot_sector.bytes_per_sector;

        var sector_buffer: [512]u8 = undefined;
        try self.device.read(fat_sector, 1, &sector_buffer);

        const entry_ptr: *const u32 = @ptrCast(@alignCast(&sector_buffer[entry_offset]));
        return entry_ptr.* & 0x0FFFFFFF;
    }

    pub fn isEndOfChain(cluster: u32) bool {
        return cluster >= 0x0FFFFFF8;
    }

    // ========================================================================
    // Write Support
    // ========================================================================

    /// Write a cluster to disk
    pub fn writeCluster(self: *Fat32Fs, cluster: u32, data: []const u8) !void {
        if (data.len < self.bytes_per_cluster) {
            return error.BufferTooSmall;
        }

        const sector = self.clusterToSector(cluster);
        try self.device.write(sector, self.sectors_per_cluster, data);
    }

    /// Write a FAT entry
    pub fn writeFatEntry(self: *Fat32Fs, cluster: u32, value: u32) !void {
        const fat_offset = cluster * 4;
        const fat_sector = self.fat_start_sector + (fat_offset / self.boot_sector.bytes_per_sector);
        const entry_offset = fat_offset % self.boot_sector.bytes_per_sector;

        // Read sector
        var sector_buffer: [512]u8 = undefined;
        try self.device.read(fat_sector, 1, &sector_buffer);

        // Modify entry (preserve top 4 bits)
        const entry_ptr: *u32 = @ptrCast(@alignCast(&sector_buffer[entry_offset]));
        const masked_value = value & 0x0FFFFFFF;
        entry_ptr.* = (entry_ptr.* & 0xF0000000) | masked_value;

        // Write back
        try self.device.write(fat_sector, 1, &sector_buffer);

        // Write to all FAT copies
        var fat_num: u32 = 1;
        while (fat_num < self.boot_sector.num_fats) : (fat_num += 1) {
            const mirror_sector = fat_sector + (fat_num * self.boot_sector.getFatSize());
            try self.device.write(mirror_sector, 1, &sector_buffer);
        }
    }

    /// Allocate a free cluster
    pub fn allocateCluster(self: *Fat32Fs) !u32 {
        // Start search from cluster 2 (first valid data cluster)
        var cluster: u32 = 2;
        const max_cluster = self.boot_sector.getTotalSectors() / self.sectors_per_cluster;

        while (cluster < max_cluster) : (cluster += 1) {
            const entry = try self.readFatEntry(cluster);
            if (entry == 0) {
                // Found free cluster, mark as end of chain
                try self.writeFatEntry(cluster, 0x0FFFFFFF);
                return cluster;
            }
        }

        return error.NoSpaceLeft;
    }

    /// Free a cluster chain starting from given cluster
    pub fn freeClusterChain(self: *Fat32Fs, start_cluster: u32) !void {
        var cluster = start_cluster;

        while (!isEndOfChain(cluster)) {
            const next_cluster = try self.readFatEntry(cluster);
            try self.writeFatEntry(cluster, 0); // Mark as free
            cluster = next_cluster;
        }

        // Free the last cluster in chain
        try self.writeFatEntry(cluster, 0);
    }

    /// Link two clusters in the FAT
    pub fn linkClusters(self: *Fat32Fs, cluster: u32, next_cluster: u32) !void {
        try self.writeFatEntry(cluster, next_cluster);
    }

    /// Write data to a file starting at given cluster
    pub fn writeFile(self: *Fat32Fs, start_cluster: u32, data: []const u8) !u32 {
        var bytes_written: usize = 0;
        var current_cluster = start_cluster;
        var prev_cluster: u32 = 0;

        while (bytes_written < data.len) {
            // Allocate new cluster if needed
            if (current_cluster == 0 or isEndOfChain(current_cluster)) {
                const new_cluster = try self.allocateCluster();
                if (prev_cluster != 0) {
                    try self.linkClusters(prev_cluster, new_cluster);
                }
                current_cluster = new_cluster;
            }

            // Write data to cluster
            const bytes_to_write = Basics.math.min(self.bytes_per_cluster, data.len - bytes_written);
            var cluster_buffer: [65536]u8 = undefined; // Max cluster size

            // Read existing data if partial write
            if (bytes_to_write < self.bytes_per_cluster) {
                try self.readCluster(current_cluster, cluster_buffer[0..self.bytes_per_cluster]);
            }

            // Copy new data
            @memcpy(cluster_buffer[0..bytes_to_write], data[bytes_written..][0..bytes_to_write]);
            try self.writeCluster(current_cluster, cluster_buffer[0..self.bytes_per_cluster]);

            bytes_written += bytes_to_write;
            prev_cluster = current_cluster;

            // Get next cluster
            if (bytes_written < data.len) {
                const next = try self.readFatEntry(current_cluster);
                if (next == 0 or isEndOfChain(next)) {
                    current_cluster = 0; // Will allocate on next iteration
                } else {
                    current_cluster = next;
                }
            }
        }

        // Mark end of chain
        if (current_cluster != 0 and !isEndOfChain(current_cluster)) {
            try self.writeFatEntry(current_cluster, 0x0FFFFFFF);
        }

        return start_cluster;
    }

    /// Create a directory entry
    pub fn createDirEntry(self: *Fat32Fs, dir_cluster: u32, name: []const u8, attributes: u8, first_cluster: u32, size: u32) !void {
        var cluster = dir_cluster;

        while (!isEndOfChain(cluster)) {
            var dir_buffer: [65536]u8 = undefined;
            try self.readCluster(cluster, dir_buffer[0..self.bytes_per_cluster]);

            // Find free entry (first byte == 0x00 or 0xE5)
            var offset: usize = 0;
            while (offset < self.bytes_per_cluster) : (offset += 32) {
                const entry: *Fat32DirEntry = @ptrCast(@alignCast(&dir_buffer[offset]));

                if (entry.name[0] == 0x00 or entry.name[0] == 0xE5) {
                    // Found free entry, create new one
                    var short_name: [11]u8 = [_]u8{' '} ** 11;
                    const copy_len = Basics.math.min(name.len, 11);
                    @memcpy(short_name[0..copy_len], name[0..copy_len]);

                    entry.* = .{
                        .name = short_name,
                        .attributes = attributes,
                        .reserved = 0,
                        .creation_time_tenths = 0,
                        .creation_time = 0,
                        .creation_date = 0,
                        .last_access_date = 0,
                        .first_cluster_high = @intCast(first_cluster >> 16),
                        .modification_time = 0,
                        .modification_date = 0,
                        .first_cluster_low = @intCast(first_cluster & 0xFFFF),
                        .file_size = size,
                    };

                    // Write directory cluster back
                    try self.writeCluster(cluster, dir_buffer[0..self.bytes_per_cluster]);
                    return;
                }
            }

            // Move to next cluster in directory
            cluster = try self.readFatEntry(cluster);
        }

        return error.DirectoryFull;
    }

    /// Delete a directory entry by name
    pub fn deleteDirEntry(self: *Fat32Fs, dir_cluster: u32, name: []const u8) !void {
        var cluster = dir_cluster;

        while (!isEndOfChain(cluster)) {
            var dir_buffer: [65536]u8 = undefined;
            try self.readCluster(cluster, dir_buffer[0..self.bytes_per_cluster]);

            var offset: usize = 0;
            while (offset < self.bytes_per_cluster) : (offset += 32) {
                const entry: *Fat32DirEntry = @ptrCast(@alignCast(&dir_buffer[offset]));

                if (entry.name[0] == 0x00) break; // End of directory

                if (entry.name[0] != 0xE5) {
                    const entry_name = entry.getShortName();
                    if (Basics.mem.startsWith(u8, entry_name, name)) {
                        // Mark as deleted
                        entry.name[0] = 0xE5;

                        // Write directory cluster back
                        try self.writeCluster(cluster, dir_buffer[0..self.bytes_per_cluster]);

                        // Free the file's cluster chain
                        const file_cluster = entry.getFirstCluster();
                        if (file_cluster != 0) {
                            try self.freeClusterChain(file_cluster);
                        }

                        return;
                    }
                }
            }

            cluster = try self.readFatEntry(cluster);
        }

        return error.FileNotFound;
    }
};

// ============================================================================
// FAT32 VFS Integration
// ============================================================================

pub fn mount(allocator: Basics.Allocator, device: *block.BlockDevice) !*vfs.Superblock {
    const fs = try Fat32Fs.init(allocator, device);

    // Create root inode from root cluster
    const root_inode = try allocator.create(vfs.Inode);
    const inode_ops = vfs.InodeOps{
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
    root_inode.* = vfs.Inode.init(fs.boot_sector.root_cluster, .Directory, &inode_ops);

    const sb_ops = vfs.SuperblockOps{
        .alloc_inode = undefined,
        .destroy_inode = undefined,
        .write_inode = null,
        .sync_fs = null,
        .statfs = null,
    };

    const sb = try allocator.create(vfs.Superblock);
    sb.* = vfs.Superblock.init("fat32", fs.bytes_per_cluster, root_inode, &sb_ops);
    sb.fs_data = fs;

    return sb;
}

// ============================================================================
// Tests
// ============================================================================

test "FAT32 boot sector" {
    var boot: Fat32BootSector = undefined;
    boot.boot_signature = 0x29;
    boot.fs_type = "FAT32   ".*;

    try Basics.testing.expect(boot.validate());
}
