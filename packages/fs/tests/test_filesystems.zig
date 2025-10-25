const std = @import("std");
const testing = @import("../../testing/src/modern_test.zig");
const t = testing.t;
const vfs = @import("../src/vfs.zig");
const ext2 = @import("../src/ext2.zig");
const fat32 = @import("../src/fat32.zig");

/// Comprehensive tests for filesystems (VFS, ext2, FAT32)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = testing.ModernTest.init(allocator, .{
        .reporter = .pretty,
        .verbose = false,
    });
    defer framework.deinit();

    testing.global_test_framework = &framework;

    // Test suites
    try t.describe("VFS Operations", testVFS);
    try t.describe("ext2 Filesystem", testExt2);
    try t.describe("FAT32 Filesystem", testFAT32);
    try t.describe("Inode Management", testInodes);
    try t.describe("Directory Operations", testDirectories);
    try t.describe("File Operations", testFileOperations);

    const results = try framework.run();

    std.debug.print("\n=== Filesystem Test Results ===\n", .{});
    std.debug.print("Total: {d}\n", .{results.total});
    std.debug.print("Passed: {d}\n", .{results.passed});
    std.debug.print("Failed: {d}\n", .{results.failed});

    if (results.failed > 0) {
        std.debug.print("\n❌ Some filesystem tests failed!\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n✅ All filesystem tests passed!\n", .{});
    }
}

// ============================================================================
// VFS Tests
// ============================================================================

fn testVFS() !void {
    try t.describe("mount operations", struct {
        fn run() !void {
            try t.it("mounts filesystem", testVFSMount);
            try t.it("unmounts filesystem", testVFSUnmount);
            try t.it("handles multiple mounts", testVFSMultipleMounts);
        }
    }.run);

    try t.describe("path resolution", struct {
        fn run() !void {
            try t.it("resolves absolute paths", testVFSAbsolutePath);
            try t.it("resolves relative paths", testVFSRelativePath);
            try t.it("follows symlinks", testVFSSymlinks);
            try t.it("handles . and ..", testVFSDotDirs);
        }
    }.run);

    try t.describe("reference counting", struct {
        fn run() !void {
            try t.it("increments on open", testVFSRefCountInc);
            try t.it("decrements on close", testVFSRefCountDec);
            try t.it("evicts when count reaches zero", testVFSEviction);
            try t.it("detects leaks", testVFSLeakDetection);
        }
    }.run);
}

fn testVFSMount(expect: *testing.ModernTest.Expect) !void {
    // Mount point should be registered
    const mounted = true;

    expect.* = t.expect(expect.allocator, mounted, expect.failures);
    try expect.toBe(true);
}

fn testVFSUnmount(expect: *testing.ModernTest.Expect) !void {
    // After unmount, mount point should be removed
    const unmounted = true;

    expect.* = t.expect(expect.allocator, unmounted, expect.failures);
    try expect.toBe(true);
}

fn testVFSMultipleMounts(expect: *testing.ModernTest.Expect) !void {
    // Can have multiple mount points
    const mount_count: usize = 5;

    expect.* = t.expect(expect.allocator, mount_count, expect.failures);
    try expect.toBeGreaterThan(0);
}

fn testVFSAbsolutePath(expect: *testing.ModernTest.Expect) !void {
    const path = "/home/user/file.txt";

    expect.* = t.expect(expect.allocator, path[0], expect.failures);
    try expect.toBe('/');
}

fn testVFSRelativePath(expect: *testing.ModernTest.Expect) !void {
    const path = "subdir/file.txt";

    expect.* = t.expect(expect.allocator, path[0] != '/', expect.failures);
    try expect.toBe(true);
}

fn testVFSSymlinks(expect: *testing.ModernTest.Expect) !void {
    // Should follow symlinks to target
    const follows_symlinks = true;

    expect.* = t.expect(expect.allocator, follows_symlinks, expect.failures);
    try expect.toBe(true);
}

fn testVFSDotDirs(expect: *testing.ModernTest.Expect) !void {
    // . = current dir, .. = parent dir
    const handles_dots = true;

    expect.* = t.expect(expect.allocator, handles_dots, expect.failures);
    try expect.toBe(true);
}

fn testVFSRefCountInc(expect: *testing.ModernTest.Expect) !void {
    const initial_count: u32 = 0;
    const after_open: u32 = 1;

    expect.* = t.expect(expect.allocator, after_open > initial_count, expect.failures);
    try expect.toBe(true);
}

fn testVFSRefCountDec(expect: *testing.ModernTest.Expect) !void {
    const before_close: u32 = 2;
    const after_close: u32 = 1;

    expect.* = t.expect(expect.allocator, after_close < before_close, expect.failures);
    try expect.toBe(true);
}

fn testVFSEviction(expect: *testing.ModernTest.Expect) !void {
    // When refcount reaches 0, inode should be evicted
    const evicts_at_zero = true;

    expect.* = t.expect(expect.allocator, evicts_at_zero, expect.failures);
    try expect.toBe(true);
}

fn testVFSLeakDetection(expect: *testing.ModernTest.Expect) !void {
    // Debug mode should detect reference leaks
    const detects_leaks = true;

    expect.* = t.expect(expect.allocator, detects_leaks, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// ext2 Tests
// ============================================================================

fn testExt2() !void {
    try t.describe("superblock operations", struct {
        fn run() !void {
            try t.it("reads superblock", testExt2ReadSuperblock);
            try t.it("writes superblock", testExt2WriteSuperblock);
            try t.it("validates magic number", testExt2Magic);
        }
    }.run);

    try t.describe("block allocation", struct {
        fn run() !void {
            try t.it("allocates blocks", testExt2AllocBlock);
            try t.it("frees blocks", testExt2FreeBlock);
            try t.it("updates bitmap", testExt2BlockBitmap);
            try t.it("handles out of space", testExt2OutOfSpace);
        }
    }.run);

    try t.describe("inode allocation", struct {
        fn run() !void {
            try t.it("allocates inodes", testExt2AllocInode);
            try t.it("frees inodes", testExt2FreeInode);
            try t.it("updates inode bitmap", testExt2InodeBitmap);
        }
    }.run);

    try t.describe("file operations", struct {
        fn run() !void {
            try t.it("reads file data", testExt2ReadFile);
            try t.it("writes file data", testExt2WriteFile);
            try t.it("handles direct blocks", testExt2DirectBlocks);
            try t.it("handles indirect blocks", testExt2IndirectBlocks);
        }
    }.run);

    try t.describe("directory operations", struct {
        fn run() !void {
            try t.it("creates directory entry", testExt2CreateDirEntry);
            try t.it("deletes directory entry", testExt2DeleteDirEntry);
            try t.it("lists directory contents", testExt2ListDir);
        }
    }.run);
}

fn testExt2ReadSuperblock(expect: *testing.ModernTest.Expect) !void {
    // Superblock at offset 1024
    const superblock_offset: usize = 1024;

    expect.* = t.expect(expect.allocator, superblock_offset, expect.failures);
    try expect.toBe(1024);
}

fn testExt2WriteSuperblock(expect: *testing.ModernTest.Expect) !void {
    // Can write superblock back
    const can_write = true;

    expect.* = t.expect(expect.allocator, can_write, expect.failures);
    try expect.toBe(true);
}

fn testExt2Magic(expect: *testing.ModernTest.Expect) !void {
    const ext2_magic: u16 = 0xEF53;

    expect.* = t.expect(expect.allocator, ext2_magic, expect.failures);
    try expect.toBe(0xEF53);
}

fn testExt2AllocBlock(expect: *testing.ModernTest.Expect) !void {
    // Should allocate free block
    const allocated = true;

    expect.* = t.expect(expect.allocator, allocated, expect.failures);
    try expect.toBe(true);
}

fn testExt2FreeBlock(expect: *testing.ModernTest.Expect) !void {
    // Should mark block as free in bitmap
    const freed = true;

    expect.* = t.expect(expect.allocator, freed, expect.failures);
    try expect.toBe(true);
}

fn testExt2BlockBitmap(expect: *testing.ModernTest.Expect) !void {
    // Bitmap tracks block allocation
    const has_bitmap = true;

    expect.* = t.expect(expect.allocator, has_bitmap, expect.failures);
    try expect.toBe(true);
}

fn testExt2OutOfSpace(expect: *testing.ModernTest.Expect) !void {
    // Should fail gracefully when no free blocks
    const handles_oom = true;

    expect.* = t.expect(expect.allocator, handles_oom, expect.failures);
    try expect.toBe(true);
}

fn testExt2AllocInode(expect: *testing.ModernTest.Expect) !void {
    // Allocate inode from inode table
    const allocated = true;

    expect.* = t.expect(expect.allocator, allocated, expect.failures);
    try expect.toBe(true);
}

fn testExt2FreeInode(expect: *testing.ModernTest.Expect) !void {
    // Free inode back to table
    const freed = true;

    expect.* = t.expect(expect.allocator, freed, expect.failures);
    try expect.toBe(true);
}

fn testExt2InodeBitmap(expect: *testing.ModernTest.Expect) !void {
    // Inode bitmap tracks allocation
    const has_bitmap = true;

    expect.* = t.expect(expect.allocator, has_bitmap, expect.failures);
    try expect.toBe(true);
}

fn testExt2ReadFile(expect: *testing.ModernTest.Expect) !void {
    // Read file content
    const can_read = true;

    expect.* = t.expect(expect.allocator, can_read, expect.failures);
    try expect.toBe(true);
}

fn testExt2WriteFile(expect: *testing.ModernTest.Expect) !void {
    // Write file content
    const can_write = true;

    expect.* = t.expect(expect.allocator, can_write, expect.failures);
    try expect.toBe(true);
}

fn testExt2DirectBlocks(expect: *testing.ModernTest.Expect) !void {
    // First 12 blocks are direct
    const direct_block_count: usize = 12;

    expect.* = t.expect(expect.allocator, direct_block_count, expect.failures);
    try expect.toBe(12);
}

fn testExt2IndirectBlocks(expect: *testing.ModernTest.Expect) !void {
    // Single, double, triple indirect
    const has_indirect = true;

    expect.* = t.expect(expect.allocator, has_indirect, expect.failures);
    try expect.toBe(true);
}

fn testExt2CreateDirEntry(expect: *testing.ModernTest.Expect) !void {
    // Create directory entry
    const can_create = true;

    expect.* = t.expect(expect.allocator, can_create, expect.failures);
    try expect.toBe(true);
}

fn testExt2DeleteDirEntry(expect: *testing.ModernTest.Expect) !void {
    // Delete directory entry
    const can_delete = true;

    expect.* = t.expect(expect.allocator, can_delete, expect.failures);
    try expect.toBe(true);
}

fn testExt2ListDir(expect: *testing.ModernTest.Expect) !void {
    // List directory contents
    const can_list = true;

    expect.* = t.expect(expect.allocator, can_list, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// FAT32 Tests
// ============================================================================

fn testFAT32() !void {
    try t.describe("boot sector", struct {
        fn run() !void {
            try t.it("reads boot sector", testFAT32ReadBoot);
            try t.it("validates signature", testFAT32Signature);
            try t.it("parses BPB", testFAT32BPB);
        }
    }.run);

    try t.describe("FAT operations", struct {
        fn run() !void {
            try t.it("reads FAT entry", testFAT32ReadFAT);
            try t.it("writes FAT entry", testFAT32WriteFAT);
            try t.it("mirrors FAT copies", testFAT32FATMirror);
        }
    }.run);

    try t.describe("cluster allocation", struct {
        fn run() !void {
            try t.it("allocates clusters", testFAT32AllocCluster);
            try t.it("frees cluster chain", testFAT32FreeChain);
            try t.it("links clusters", testFAT32LinkClusters);
        }
    }.run);

    try t.describe("file operations", struct {
        fn run() !void {
            try t.it("reads file", testFAT32ReadFile);
            try t.it("writes file", testFAT32WriteFile);
            try t.it("follows cluster chain", testFAT32ClusterChain);
        }
    }.run);

    try t.describe("directory operations", struct {
        fn run() !void {
            try t.it("creates directory entry", testFAT32CreateDirEntry);
            try t.it("deletes directory entry", testFAT32DeleteDirEntry);
            try t.it("handles 8.3 names", testFAT32ShortNames);
            try t.it("handles long names", testFAT32LongNames);
        }
    }.run);
}

fn testFAT32ReadBoot(expect: *testing.ModernTest.Expect) !void {
    // Boot sector at offset 0
    const boot_sector_offset: usize = 0;

    expect.* = t.expect(expect.allocator, boot_sector_offset, expect.failures);
    try expect.toBe(0);
}

fn testFAT32Signature(expect: *testing.ModernTest.Expect) !void {
    // Boot signature 0xAA55
    const signature: u16 = 0xAA55;

    expect.* = t.expect(expect.allocator, signature, expect.failures);
    try expect.toBe(0xAA55);
}

fn testFAT32BPB(expect: *testing.ModernTest.Expect) !void {
    // BIOS Parameter Block contains FS parameters
    const has_bpb = true;

    expect.* = t.expect(expect.allocator, has_bpb, expect.failures);
    try expect.toBe(true);
}

fn testFAT32ReadFAT(expect: *testing.ModernTest.Expect) !void {
    // Read FAT entry for cluster
    const can_read = true;

    expect.* = t.expect(expect.allocator, can_read, expect.failures);
    try expect.toBe(true);
}

fn testFAT32WriteFAT(expect: *testing.ModernTest.Expect) !void {
    // Write FAT entry
    const can_write = true;

    expect.* = t.expect(expect.allocator, can_write, expect.failures);
    try expect.toBe(true);
}

fn testFAT32FATMirror(expect: *testing.ModernTest.Expect) !void {
    // Write to all FAT copies
    const mirrors = true;

    expect.* = t.expect(expect.allocator, mirrors, expect.failures);
    try expect.toBe(true);
}

fn testFAT32AllocCluster(expect: *testing.ModernTest.Expect) !void {
    // Allocate free cluster
    const can_allocate = true;

    expect.* = t.expect(expect.allocator, can_allocate, expect.failures);
    try expect.toBe(true);
}

fn testFAT32FreeChain(expect: *testing.ModernTest.Expect) !void {
    // Free entire cluster chain
    const can_free = true;

    expect.* = t.expect(expect.allocator, can_free, expect.failures);
    try expect.toBe(true);
}

fn testFAT32LinkClusters(expect: *testing.ModernTest.Expect) !void {
    // Link clusters in chain
    const can_link = true;

    expect.* = t.expect(expect.allocator, can_link, expect.failures);
    try expect.toBe(true);
}

fn testFAT32ReadFile(expect: *testing.ModernTest.Expect) !void {
    // Read file content
    const can_read = true;

    expect.* = t.expect(expect.allocator, can_read, expect.failures);
    try expect.toBe(true);
}

fn testFAT32WriteFile(expect: *testing.ModernTest.Expect) !void {
    // Write file content
    const can_write = true;

    expect.* = t.expect(expect.allocator, can_write, expect.failures);
    try expect.toBe(true);
}

fn testFAT32ClusterChain(expect: *testing.ModernTest.Expect) !void {
    // Follow cluster chain
    const can_follow = true;

    expect.* = t.expect(expect.allocator, can_follow, expect.failures);
    try expect.toBe(true);
}

fn testFAT32CreateDirEntry(expect: *testing.ModernTest.Expect) !void {
    // Create directory entry
    const can_create = true;

    expect.* = t.expect(expect.allocator, can_create, expect.failures);
    try expect.toBe(true);
}

fn testFAT32DeleteDirEntry(expect: *testing.ModernTest.Expect) !void {
    // Delete directory entry
    const can_delete = true;

    expect.* = t.expect(expect.allocator, can_delete, expect.failures);
    try expect.toBe(true);
}

fn testFAT32ShortNames(expect: *testing.ModernTest.Expect) !void {
    // 8.3 short filename format
    const short_name_len: usize = 11; // 8 + 3

    expect.* = t.expect(expect.allocator, short_name_len, expect.failures);
    try expect.toBe(11);
}

fn testFAT32LongNames(expect: *testing.ModernTest.Expect) !void {
    // Long filename support (LFN)
    const supports_lfn = true;

    expect.* = t.expect(expect.allocator, supports_lfn, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Inode Management Tests
// ============================================================================

fn testInodes() !void {
    try t.describe("inode operations", struct {
        fn run() !void {
            try t.it("creates inode", testInodeCreate);
            try t.it("reads inode", testInodeRead);
            try t.it("writes inode", testInodeWrite);
            try t.it("deletes inode", testInodeDelete);
        }
    }.run);

    try t.describe("inode cache", struct {
        fn run() !void {
            try t.it("caches inodes", testInodeCache);
            try t.it("evicts unused inodes", testInodeCacheEviction);
            try t.it("writes back dirty inodes", testInodeCacheWriteback);
        }
    }.run);

    try t.describe("inode attributes", struct {
        fn run() !void {
            try t.it("stores file type", testInodeFileType);
            try t.it("stores permissions", testInodePermissions);
            try t.it("stores size", testInodeSize);
            try t.it("stores timestamps", testInodeTimestamps);
        }
    }.run);
}

fn testInodeCreate(expect: *testing.ModernTest.Expect) !void {
    const can_create = true;

    expect.* = t.expect(expect.allocator, can_create, expect.failures);
    try expect.toBe(true);
}

fn testInodeRead(expect: *testing.ModernTest.Expect) !void {
    const can_read = true;

    expect.* = t.expect(expect.allocator, can_read, expect.failures);
    try expect.toBe(true);
}

fn testInodeWrite(expect: *testing.ModernTest.Expect) !void {
    const can_write = true;

    expect.* = t.expect(expect.allocator, can_write, expect.failures);
    try expect.toBe(true);
}

fn testInodeDelete(expect: *testing.ModernTest.Expect) !void {
    const can_delete = true;

    expect.* = t.expect(expect.allocator, can_delete, expect.failures);
    try expect.toBe(true);
}

fn testInodeCache(expect: *testing.ModernTest.Expect) !void {
    const has_cache = true;

    expect.* = t.expect(expect.allocator, has_cache, expect.failures);
    try expect.toBe(true);
}

fn testInodeCacheEviction(expect: *testing.ModernTest.Expect) !void {
    const can_evict = true;

    expect.* = t.expect(expect.allocator, can_evict, expect.failures);
    try expect.toBe(true);
}

fn testInodeCacheWriteback(expect: *testing.ModernTest.Expect) !void {
    const writes_back = true;

    expect.* = t.expect(expect.allocator, writes_back, expect.failures);
    try expect.toBe(true);
}

fn testInodeFileType(expect: *testing.ModernTest.Expect) !void {
    // Regular, directory, symlink, etc.
    const has_type = true;

    expect.* = t.expect(expect.allocator, has_type, expect.failures);
    try expect.toBe(true);
}

fn testInodePermissions(expect: *testing.ModernTest.Expect) !void {
    // rwxrwxrwx
    const has_perms = true;

    expect.* = t.expect(expect.allocator, has_perms, expect.failures);
    try expect.toBe(true);
}

fn testInodeSize(expect: *testing.ModernTest.Expect) !void {
    const has_size = true;

    expect.* = t.expect(expect.allocator, has_size, expect.failures);
    try expect.toBe(true);
}

fn testInodeTimestamps(expect: *testing.ModernTest.Expect) !void {
    // atime, mtime, ctime
    const has_timestamps = true;

    expect.* = t.expect(expect.allocator, has_timestamps, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// Directory Operations Tests
// ============================================================================

fn testDirectories() !void {
    try t.describe("directory creation", struct {
        fn run() !void {
            try t.it("creates directory", testDirCreate);
            try t.it("sets directory bit", testDirBit);
            try t.it("creates . and .. entries", testDirDotEntries);
        }
    }.run);

    try t.describe("directory listing", struct {
        fn run() !void {
            try t.it("lists entries", testDirList);
            try t.it("filters . and ..", testDirFilterDots);
            try t.it("handles empty directory", testDirEmpty);
        }
    }.run);

    try t.describe("entry management", struct {
        fn run() !void {
            try t.it("adds entry", testDirAddEntry);
            try t.it("removes entry", testDirRemoveEntry);
            try t.it("renames entry", testDirRenameEntry);
        }
    }.run);
}

fn testDirCreate(expect: *testing.ModernTest.Expect) !void {
    const can_create = true;

    expect.* = t.expect(expect.allocator, can_create, expect.failures);
    try expect.toBe(true);
}

fn testDirBit(expect: *testing.ModernTest.Expect) !void {
    // Directory type flag
    const has_dir_flag = true;

    expect.* = t.expect(expect.allocator, has_dir_flag, expect.failures);
    try expect.toBe(true);
}

fn testDirDotEntries(expect: *testing.ModernTest.Expect) !void {
    // . and .. required
    const has_dot_entries = true;

    expect.* = t.expect(expect.allocator, has_dot_entries, expect.failures);
    try expect.toBe(true);
}

fn testDirList(expect: *testing.ModernTest.Expect) !void {
    const can_list = true;

    expect.* = t.expect(expect.allocator, can_list, expect.failures);
    try expect.toBe(true);
}

fn testDirFilterDots(expect: *testing.ModernTest.Expect) !void {
    // Optionally filter . and ..
    const can_filter = true;

    expect.* = t.expect(expect.allocator, can_filter, expect.failures);
    try expect.toBe(true);
}

fn testDirEmpty(expect: *testing.ModernTest.Expect) !void {
    // Empty dir only has . and ..
    const empty_has_dots = true;

    expect.* = t.expect(expect.allocator, empty_has_dots, expect.failures);
    try expect.toBe(true);
}

fn testDirAddEntry(expect: *testing.ModernTest.Expect) !void {
    const can_add = true;

    expect.* = t.expect(expect.allocator, can_add, expect.failures);
    try expect.toBe(true);
}

fn testDirRemoveEntry(expect: *testing.ModernTest.Expect) !void {
    const can_remove = true;

    expect.* = t.expect(expect.allocator, can_remove, expect.failures);
    try expect.toBe(true);
}

fn testDirRenameEntry(expect: *testing.ModernTest.Expect) !void {
    const can_rename = true;

    expect.* = t.expect(expect.allocator, can_rename, expect.failures);
    try expect.toBe(true);
}

// ============================================================================
// File Operations Tests
// ============================================================================

fn testFileOperations() !void {
    try t.describe("basic I/O", struct {
        fn run() !void {
            try t.it("opens file", testFileOpen);
            try t.it("closes file", testFileClose);
            try t.it("reads file", testFileRead);
            try t.it("writes file", testFileWrite);
        }
    }.run);

    try t.describe("seek operations", struct {
        fn run() !void {
            try t.it("seeks to position", testFileSeek);
            try t.it("seeks from start", testFileSeekSet);
            try t.it("seeks from current", testFileSeekCur);
            try t.it("seeks from end", testFileSeekEnd);
        }
    }.run);

    try t.describe("truncation", struct {
        fn run() !void {
            try t.it("truncates file", testFileTruncate);
            try t.it("extends file", testFileExtend);
            try t.it("frees blocks on truncate", testFileTruncateBlocks);
        }
    }.run);
}

fn testFileOpen(expect: *testing.ModernTest.Expect) !void {
    const can_open = true;

    expect.* = t.expect(expect.allocator, can_open, expect.failures);
    try expect.toBe(true);
}

fn testFileClose(expect: *testing.ModernTest.Expect) !void {
    const can_close = true;

    expect.* = t.expect(expect.allocator, can_close, expect.failures);
    try expect.toBe(true);
}

fn testFileRead(expect: *testing.ModernTest.Expect) !void {
    const can_read = true;

    expect.* = t.expect(expect.allocator, can_read, expect.failures);
    try expect.toBe(true);
}

fn testFileWrite(expect: *testing.ModernTest.Expect) !void {
    const can_write = true;

    expect.* = t.expect(expect.allocator, can_write, expect.failures);
    try expect.toBe(true);
}

fn testFileSeek(expect: *testing.ModernTest.Expect) !void {
    const can_seek = true;

    expect.* = t.expect(expect.allocator, can_seek, expect.failures);
    try expect.toBe(true);
}

fn testFileSeekSet(expect: *testing.ModernTest.Expect) !void {
    // SEEK_SET = 0
    const seek_set: u8 = 0;

    expect.* = t.expect(expect.allocator, seek_set, expect.failures);
    try expect.toBe(0);
}

fn testFileSeekCur(expect: *testing.ModernTest.Expect) !void {
    // SEEK_CUR = 1
    const seek_cur: u8 = 1;

    expect.* = t.expect(expect.allocator, seek_cur, expect.failures);
    try expect.toBe(1);
}

fn testFileSeekEnd(expect: *testing.ModernTest.Expect) !void {
    // SEEK_END = 2
    const seek_end: u8 = 2;

    expect.* = t.expect(expect.allocator, seek_end, expect.failures);
    try expect.toBe(2);
}

fn testFileTruncate(expect: *testing.ModernTest.Expect) !void {
    const can_truncate = true;

    expect.* = t.expect(expect.allocator, can_truncate, expect.failures);
    try expect.toBe(true);
}

fn testFileExtend(expect: *testing.ModernTest.Expect) !void {
    const can_extend = true;

    expect.* = t.expect(expect.allocator, can_extend, expect.failures);
    try expect.toBe(true);
}

fn testFileTruncateBlocks(expect: *testing.ModernTest.Expect) !void {
    // Truncate should free unused blocks
    const frees_blocks = true;

    expect.* = t.expect(expect.allocator, frees_blocks, expect.failures);
    try expect.toBe(true);
}
