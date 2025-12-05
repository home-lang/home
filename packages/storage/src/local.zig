const std = @import("std");
const storage = @import("storage.zig");

/// Local filesystem storage driver
pub const LocalDriver = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    url_base: ?[]const u8,
    permissions_file: u32,
    permissions_dir: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: storage.StorageConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, config.root),
            .url_base = if (config.url_base) |u| try allocator.dupe(u8, u) else null,
            .permissions_file = config.permissions_file,
            .permissions_dir = config.permissions_dir,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.root);
        if (self.url_base) |u| self.allocator.free(u);
        self.allocator.destroy(self);
    }

    /// Get the StorageDriver interface
    pub fn driver(self: *Self) storage.StorageDriver {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn fullPath(self: *Self, path: []const u8) ![]const u8 {
        return storage.Path.join(self.allocator, &[_][]const u8{ self.root, path });
    }

    // VTable implementations

    fn put(ptr: *anyopaque, path: []const u8, contents: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        // Ensure directory exists
        const dir_path = storage.Path.dirname(full);
        if (dir_path.len > 0) {
            std.fs.makeDirAbsolute(dir_path) catch |err| {
                if (err != error.PathAlreadyExists) {
                    // Try to create parent directories
                    try makeDirectoryRecursive(dir_path);
                }
            };
        }

        const file = try std.fs.createFileAbsolute(full, .{
            .truncate = true,
        });
        defer file.close();

        try file.writeAll(contents);
    }

    fn get(ptr: *anyopaque, path: []const u8) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = std.fs.openFileAbsolute(full, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const buffer = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(buffer);

        const bytes_read = try file.preadAll(buffer, 0);
        if (bytes_read != stat.size) {
            self.allocator.free(buffer);
            return error.IncompleteRead;
        }

        return buffer;
    }

    fn exists(ptr: *anyopaque, path: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = self.fullPath(path) catch return false;
        defer self.allocator.free(full);

        std.fs.accessAbsolute(full, .{}) catch return false;
        return true;
    }

    fn deleteFn(ptr: *anyopaque, path: []const u8) anyerror!bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        std.fs.deleteFileAbsolute(full) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        return true;
    }

    fn copy(ptr: *anyopaque, source: []const u8, dest: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const contents = try get(ptr, source) orelse return error.FileNotFound;
        defer self.allocator.free(contents);

        try put(ptr, dest, contents);
    }

    fn move(ptr: *anyopaque, source: []const u8, dest: []const u8) anyerror!void {
        try copy(ptr, source, dest);
        _ = try deleteFn(ptr, source);
    }

    fn size(ptr: *anyopaque, path: []const u8) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = try std.fs.openFileAbsolute(full, .{});
        defer file.close();

        const stat = try file.stat();
        return stat.size;
    }

    fn lastModified(ptr: *anyopaque, path: []const u8) anyerror!i64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = try std.fs.openFileAbsolute(full, .{});
        defer file.close();

        const stat = try file.stat();
        // mtime is a Timestamp struct in Zig 0.16
        return stat.mtime.sec;
    }

    fn metadata(ptr: *anyopaque, path: []const u8) anyerror!storage.FileMetadata {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = try std.fs.openFileAbsolute(full, .{});
        defer file.close();

        const stat = try file.stat();

        // Detect MIME type from extension
        const mime = if (storage.Path.extension(path)) |ext|
            storage.MimeType.fromExtension(ext)
        else
            "application/octet-stream";

        return storage.FileMetadata{
            .path = try self.allocator.dupe(u8, path),
            .size = stat.size,
            .last_modified = stat.mtime.sec,
            .mime_type = try self.allocator.dupe(u8, mime),
            .allocator = self.allocator,
        };
    }

    fn url(ptr: *anyopaque, path: []const u8) anyerror![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.url_base) |base| {
            return storage.Path.join(self.allocator, &[_][]const u8{ base, path });
        }

        // Return file:// URL
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        // Build URL manually
        const prefix = "file://";
        const result = try self.allocator.alloc(u8, prefix.len + full.len);
        @memcpy(result[0..prefix.len], prefix);
        @memcpy(result[prefix.len..], full);

        return result;
    }

    fn temporaryUrl(ptr: *anyopaque, path: []const u8, expiration: i64) anyerror![]const u8 {
        _ = expiration;
        // Local files don't have temporary URLs, just return the regular URL
        return url(ptr, path);
    }

    fn setVisibility(ptr: *anyopaque, path: []const u8, visibility: storage.Visibility) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = try std.fs.openFileAbsolute(full, .{});
        defer file.close();

        const mode: std.posix.mode_t = switch (visibility) {
            .public => 0o644,
            .private => 0o600,
        };

        try file.chmod(mode);
    }

    fn getVisibility(ptr: *anyopaque, path: []const u8) anyerror!storage.Visibility {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = try std.fs.openFileAbsolute(full, .{});
        defer file.close();

        const stat = try file.stat();
        const mode = stat.mode;

        // Check if others can read
        if (mode & 0o004 != 0) {
            return .public;
        }
        return .private;
    }

    fn makeDirectory(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        try makeDirectoryRecursive(full);
    }

    fn deleteDirectory(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        try std.fs.deleteTreeAbsolute(full);
    }

    fn listContents(ptr: *anyopaque, path: []const u8, recursive: bool) anyerror![]storage.DirectoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        // Use a fixed-size buffer for entries
        var entries_buf: [1024]storage.DirectoryEntry = undefined;
        var entries_count: usize = 0;

        try listDirectoryContents(self.allocator, full, path, recursive, &entries_buf, &entries_count);

        // Copy to heap
        const result = try self.allocator.alloc(storage.DirectoryEntry, entries_count);
        @memcpy(result, entries_buf[0..entries_count]);

        return result;
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = storage.StorageDriver.VTable{
        .put = put,
        .get = get,
        .exists = exists,
        .delete = deleteFn,
        .copy = copy,
        .move = move,
        .size = size,
        .lastModified = lastModified,
        .metadata = metadata,
        .url = url,
        .temporaryUrl = temporaryUrl,
        .setVisibility = setVisibility,
        .getVisibility = getVisibility,
        .makeDirectory = makeDirectory,
        .deleteDirectory = deleteDirectory,
        .listContents = listContents,
        .deinit = deinitFn,
    };
};

fn makeDirectoryRecursive(path: []const u8) !void {
    var current_path_buf: [4096]u8 = undefined;
    var current_len: usize = 0;

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |part| {
        if (part.len == 0) {
            if (current_len < current_path_buf.len) {
                current_path_buf[current_len] = '/';
                current_len += 1;
            }
            continue;
        }

        if (current_len > 0 and current_path_buf[current_len - 1] != '/') {
            if (current_len < current_path_buf.len) {
                current_path_buf[current_len] = '/';
                current_len += 1;
            }
        }

        const copy_len = @min(part.len, current_path_buf.len - current_len);
        @memcpy(current_path_buf[current_len .. current_len + copy_len], part[0..copy_len]);
        current_len += copy_len;

        std.fs.makeDirAbsolute(current_path_buf[0..current_len]) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
}

fn listDirectoryContents(
    allocator: std.mem.Allocator,
    full_path: []const u8,
    relative_path: []const u8,
    recursive: bool,
    entries_buf: []storage.DirectoryEntry,
    entries_count: *usize,
) !void {
    var dir = std.fs.openDirAbsolute(full_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return;
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entries_count.* >= entries_buf.len) return;

        const entry_path = try storage.Path.join(allocator, &[_][]const u8{ relative_path, entry.name });

        const is_dir = entry.kind == .directory;
        var file_size: u64 = 0;
        var mtime: i64 = 0;

        if (!is_dir) {
            const entry_full = try storage.Path.join(allocator, &[_][]const u8{ full_path, entry.name });
            defer allocator.free(entry_full);

            const file = std.fs.openFileAbsolute(entry_full, .{}) catch continue;
            defer file.close();

            const stat = file.stat() catch continue;
            file_size = stat.size;
            mtime = stat.mtime.sec;
        }

        entries_buf[entries_count.*] = .{
            .path = entry_path,
            .is_directory = is_dir,
            .size = file_size,
            .last_modified = mtime,
        };
        entries_count.* += 1;

        if (recursive and is_dir) {
            const subdir_full = try storage.Path.join(allocator, &[_][]const u8{ full_path, entry.name });
            defer allocator.free(subdir_full);

            try listDirectoryContents(allocator, subdir_full, entry_path, recursive, entries_buf, entries_count);
        }
    }
}

// Tests
test "local driver init" {
    const allocator = std.testing.allocator;
    const config = storage.StorageConfig.localDisk("/tmp/test-storage");

    const drv = try LocalDriver.init(allocator, config);
    defer drv.deinit();

    try std.testing.expectEqualStrings("/tmp/test-storage", drv.root);
}

test "local driver put and get" {
    const allocator = std.testing.allocator;
    const config = storage.StorageConfig.localDisk("/tmp/test-storage-local");

    const drv = try LocalDriver.init(allocator, config);
    defer drv.deinit();

    var d = drv.driver();

    // Put a file
    try d.put("test.txt", "Hello, World!");

    // Get the file
    const contents = try d.get("test.txt") orelse unreachable;
    defer allocator.free(contents);

    try std.testing.expectEqualStrings("Hello, World!", contents);

    // Clean up
    _ = try d.delete("test.txt");
}
