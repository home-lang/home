const std = @import("std");
const builtin = @import("builtin");
const storage = @import("storage.zig");
const Io = std.Io;

/// Local filesystem storage driver
pub const LocalDriver = struct {
    allocator: std.mem.Allocator,
    io: Io,
    root: []const u8,
    url_base: ?[]const u8,
    permissions_file: u32,
    permissions_dir: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: storage.StorageConfig) !*Self {
        return initWithIo(allocator, Io.Threaded.global_single_threaded.io(), config);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: Io, config: storage.StorageConfig) !*Self {
        if (!std.fs.path.isAbsolute(config.root)) return error.InvalidStorageRoot;
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        const root = try std.fs.path.resolveAlloc(allocator, &.{config.root});
        errdefer allocator.free(root);
        const url_base: ?[]const u8 = if (config.url_base) |u| try allocator.dupe(u8, u) else null;
        self.* = .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .url_base = url_base,
            .permissions_file = config.permissions_file,
            .permissions_dir = config.permissions_dir,
        };
        return self;
    }

    fn permissions(mode: u32, fallback: Io.File.Permissions) Io.File.Permissions {
        if (comptime builtin.os.tag == .windows) return fallback;
        return Io.File.Permissions.fromMode(@intCast(mode));
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
        // This confines lexical paths. Symlink-safe confinement needs
        // handle-relative traversal and is not provided by absolute opens.
        if (std.fs.path.isAbsolute(path)) return error.PathOutsideRoot;
        var components = std.mem.tokenizeAny(u8, path, if (builtin.os.tag == .windows) "/\\" else "/");
        while (components.next()) |component| {
            if (std.mem.eql(u8, component, "..")) return error.PathOutsideRoot;
        }
        const full = try std.fs.path.resolveAlloc(self.allocator, &.{ self.root, path });
        errdefer self.allocator.free(full);
        if (std.mem.eql(u8, full, self.root)) return full;
        if (!std.mem.startsWith(u8, full, self.root)) return error.PathOutsideRoot;
        if (!std.fs.path.isSep(self.root[self.root.len - 1]) and
            (full.len <= self.root.len or !std.fs.path.isSep(full[self.root.len])))
        {
            return error.PathOutsideRoot;
        }
        return full;
    }

    // VTable implementations

    fn put(ptr: *anyopaque, path: []const u8, contents: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const io = self.io;
        // Ensure directory exists
        const dir_path = storage.Path.dirname(full);
        if (dir_path.len > 0) {
            try makeDirectoryRecursive(io, dir_path, permissions(self.permissions_dir, .default_dir));
        }

        const file = try Io.Dir.createFileAbsolute(io, full, .{
            .truncate = true,
            .permissions = permissions(self.permissions_file, .default_file),
        });
        defer file.close(io);

        try file.writeStreamingAll(io, contents);
    }

    fn get(ptr: *anyopaque, path: []const u8) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const io = self.io;
        const file = Io.Dir.openFileAbsolute(io, full, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const byte_count = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const buffer = try self.allocator.alloc(u8, byte_count);
        errdefer self.allocator.free(buffer);

        const bytes_read = try file.readPositionalAll(io, buffer, 0);
        if (bytes_read != byte_count) return error.IncompleteRead;

        return buffer;
    }

    fn exists(ptr: *anyopaque, path: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = self.fullPath(path) catch return false;
        defer self.allocator.free(full);

        Io.Dir.accessAbsolute(self.io, full, .{}) catch return false;
        return true;
    }

    fn deleteFn(ptr: *anyopaque, path: []const u8) anyerror!bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        Io.Dir.deleteFileAbsolute(self.io, full) catch |err| {
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

        const file = try Io.Dir.openFileAbsolute(self.io, full, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        return stat.size;
    }

    fn lastModified(ptr: *anyopaque, path: []const u8) anyerror!i64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = try Io.Dir.openFileAbsolute(self.io, full, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        return stat.mtime.toSeconds();
    }

    fn metadata(ptr: *anyopaque, path: []const u8) anyerror!storage.FileMetadata {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = try Io.Dir.openFileAbsolute(self.io, full, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);

        // Detect MIME type from extension
        const mime = if (storage.Path.extension(path)) |ext|
            storage.MimeType.fromExtension(ext)
        else
            "application/octet-stream";

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const mime_copy = try self.allocator.dupe(u8, mime);
        return storage.FileMetadata{
            .path = path_copy,
            .size = stat.size,
            .last_modified = stat.mtime.toSeconds(),
            .mime_type = mime_copy,
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

        const file = try Io.Dir.openFileAbsolute(self.io, full, .{});
        defer file.close(self.io);

        const mode: u32 = switch (visibility) {
            .public => 0o644,
            .private => 0o600,
        };

        try file.setPermissions(self.io, permissions(mode, .default_file));
    }

    fn getVisibility(ptr: *anyopaque, path: []const u8) anyerror!storage.Visibility {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        const file = try Io.Dir.openFileAbsolute(self.io, full, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (comptime builtin.os.tag == .windows) {
            return if (stat.permissions.toAttributes().READONLY) .private else .public;
        }
        const mode = stat.permissions.toMode();

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

        try makeDirectoryRecursive(self.io, full, permissions(self.permissions_dir, .default_dir));
    }

    fn deleteDirectory(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);
        if (std.mem.eql(u8, full, self.root)) return error.CannotDeleteStorageRoot;

        const parent_path = std.fs.path.dirname(full) orelse return error.InvalidPath;
        const parent = try Io.Dir.openDirAbsolute(self.io, parent_path, .{});
        defer parent.close(self.io);
        try parent.deleteTree(self.io, std.fs.path.basename(full));
    }

    fn listContents(ptr: *anyopaque, path: []const u8, recursive: bool) anyerror![]storage.DirectoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const full = try self.fullPath(path);
        defer self.allocator.free(full);

        var entries: std.ArrayList(storage.DirectoryEntry) = .empty;
        errdefer {
            for (entries.items) |entry| self.allocator.free(entry.path);
            entries.deinit(self.allocator);
        }
        try listDirectoryContents(self.allocator, self.io, full, path, recursive, &entries);
        return entries.toOwnedSlice(self.allocator);
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

fn makeDirectoryRecursive(io: Io, path: []const u8, mode: Io.File.Permissions) !void {
    _ = try Io.Dir.cwd().createDirPathStatus(io, path, mode);
}

fn listDirectoryContents(
    allocator: std.mem.Allocator,
    io: Io,
    full_path: []const u8,
    relative_path: []const u8,
    recursive: bool,
    entries: *std.ArrayList(storage.DirectoryEntry),
) !void {
    const dir = Io.Dir.openDirAbsolute(io, full_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return;
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const entry_path = try storage.Path.join(allocator, &[_][]const u8{ relative_path, entry.name });
        var retained = false;
        defer if (!retained) allocator.free(entry_path);

        const is_dir = entry.kind == .directory;
        var file_size: u64 = 0;
        var mtime: i64 = 0;

        if (!is_dir) {
            const entry_full = try storage.Path.join(allocator, &[_][]const u8{ full_path, entry.name });
            defer allocator.free(entry_full);

            const file = Io.Dir.openFileAbsolute(io, entry_full, .{}) catch continue;
            defer file.close(io);

            const stat = file.stat(io) catch continue;
            file_size = stat.size;
            mtime = stat.mtime.toSeconds();
        }
        try entries.append(allocator, .{
            .path = entry_path,
            .is_directory = is_dir,
            .size = file_size,
            .last_modified = mtime,
        });
        retained = true;

        if (recursive and is_dir) {
            const subdir_full = try storage.Path.join(allocator, &[_][]const u8{ full_path, entry.name });
            defer allocator.free(subdir_full);

            try listDirectoryContents(allocator, io, subdir_full, entry_path, recursive, entries);
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

fn initWithAllocationFailure(allocator: std.mem.Allocator) !void {
    var config = storage.StorageConfig.localDisk("/tmp/test-storage");
    config.url_base = "https://example.test/files";
    const drv = try LocalDriver.initWithIo(allocator, Io.Threaded.global_single_threaded.io(), config);
    drv.deinit();
}

test "local driver initialization releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initWithAllocationFailure, .{});
}

test "local driver put and get" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const config = storage.StorageConfig.localDisk(root_buf[0..root_len]);

    const drv = try LocalDriver.initWithIo(allocator, io, config);
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

test "local driver preserves filesystem root and rejects lexical escapes" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    const root = if (builtin.os.tag == .windows) "C:\\" else "/";
    const drv = try LocalDriver.initWithIo(allocator, io, storage.StorageConfig.localDisk(root));
    defer drv.deinit();
    const root_path = try drv.fullPath("example.txt");
    defer allocator.free(root_path);
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "C:\\example.txt" else "/example.txt", root_path);
    try std.testing.expectError(error.PathOutsideRoot, drv.fullPath("../outside.txt"));
    try std.testing.expectError(error.PathOutsideRoot, drv.fullPath(if (builtin.os.tag == .windows) "C:\\outside.txt" else "/etc/passwd"));
    try std.testing.expectError(error.InvalidStorageRoot, LocalDriver.initWithIo(allocator, io, storage.StorageConfig.localDisk("relative")));
}

test "local driver metadata visibility copy move and recursive deletion" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const drv = try LocalDriver.initWithIo(allocator, io, storage.StorageConfig.localDisk(root_buf[0..root_len]));
    defer drv.deinit();
    const d = drv.driver();

    try std.testing.expectError(error.CannotDeleteStorageRoot, d.deleteDirectory("."));

    try d.put("nested/child/first.txt", "payload");
    try std.testing.expectEqual(@as(u64, 7), try d.size("nested/child/first.txt"));
    try std.testing.expect((try d.lastModified("nested/child/first.txt")) > 0);
    var info = try d.metadata("nested/child/first.txt");
    defer info.deinit();
    try std.testing.expectEqualStrings("text/plain", info.mime_type.?);
    try std.testing.expectEqual(@as(u64, 7), info.size);

    try d.setVisibility("nested/child/first.txt", .public);
    try std.testing.expectEqual(storage.Visibility.public, try d.getVisibility("nested/child/first.txt"));
    try d.setVisibility("nested/child/first.txt", .private);
    try std.testing.expectEqual(storage.Visibility.private, try d.getVisibility("nested/child/first.txt"));

    try d.copy("nested/child/first.txt", "nested/child/copied.txt");
    try d.move("nested/child/copied.txt", "nested/child/moved.txt");
    try std.testing.expect(!d.exists("nested/child/copied.txt"));
    try std.testing.expect(d.exists("nested/child/moved.txt"));

    const entries = try d.listContents("nested", true);
    defer {
        for (entries) |entry| allocator.free(entry.path);
        allocator.free(entries);
    }
    var saw_first = false;
    var saw_moved = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.path, "nested/child/first.txt")) saw_first = true;
        if (std.mem.eql(u8, entry.path, "nested/child/moved.txt")) saw_moved = true;
    }
    try std.testing.expect(saw_first and saw_moved);

    try d.deleteDirectory("nested");
    try std.testing.expect(!d.exists("nested/child/first.txt"));
    try std.testing.expect(!d.exists("nested/child/moved.txt"));
}

test "local driver lists more than 1024 entries without truncation" {
    const allocator = std.testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const drv = try LocalDriver.initWithIo(allocator, io, storage.StorageConfig.localDisk(root_buf[0..root_len]));
    defer drv.deinit();
    const d = drv.driver();

    for (0..1025) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "many/{d}.txt", .{i});
        try d.put(name, "x");
    }
    const entries = try d.listContents("many", false);
    defer {
        for (entries) |entry| allocator.free(entry.path);
        allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1025), entries.len);
}
