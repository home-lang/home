const std = @import("std");
const posix = std.posix;
const storage = @import("storage.zig");

/// Helper to get current timestamp (Zig 0.16 compatible)
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// In-memory storage driver (useful for testing)
pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap(FileEntry),
    directories: std.StringHashMap(void),
    visibility_map: std.StringHashMap(storage.Visibility),

    const Self = @This();

    const FileEntry = struct {
        contents: []const u8,
        created_at: i64,
        modified_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .files = std.StringHashMap(FileEntry).init(allocator),
            .directories = std.StringHashMap(void).init(allocator),
            .visibility_map = std.StringHashMap(storage.Visibility).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Free all stored content
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.contents);
        }
        self.files.deinit();

        // Free directory paths
        var dir_it = self.directories.keyIterator();
        while (dir_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.directories.deinit();

        // Free visibility map keys
        var vis_it = self.visibility_map.keyIterator();
        while (vis_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.visibility_map.deinit();

        self.allocator.destroy(self);
    }

    /// Get the StorageDriver interface
    pub fn driver(self: *Self) storage.StorageDriver {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // VTable implementations

    fn put(ptr: *anyopaque, path: []const u8, contents: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const now = getTimestamp();

        // Remove old entry if exists
        if (self.files.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.contents);
        }

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const contents_copy = try self.allocator.dupe(u8, contents);
        errdefer self.allocator.free(contents_copy);

        try self.files.put(path_copy, .{
            .contents = contents_copy,
            .created_at = now,
            .modified_at = now,
        });

        // Ensure parent directories exist
        var dir_path = storage.Path.dirname(path);
        while (dir_path.len > 0) {
            if (!self.directories.contains(dir_path)) {
                const dir_copy = try self.allocator.dupe(u8, dir_path);
                try self.directories.put(dir_copy, {});
            }
            dir_path = storage.Path.dirname(dir_path);
        }
    }

    fn get(ptr: *anyopaque, path: []const u8) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const entry = self.files.get(path) orelse return null;
        return try self.allocator.dupe(u8, entry.contents);
    }

    fn exists(ptr: *anyopaque, path: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.files.contains(path);
    }

    fn deleteFn(ptr: *anyopaque, path: []const u8) anyerror!bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.files.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.contents);
            return true;
        }
        return false;
    }

    fn copy(ptr: *anyopaque, source: []const u8, dest: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const entry = self.files.get(source) orelse return error.FileNotFound;
        try put(ptr, dest, entry.contents);

        // Copy visibility if set
        if (self.visibility_map.get(source)) |vis| {
            const dest_copy = try self.allocator.dupe(u8, dest);
            try self.visibility_map.put(dest_copy, vis);
        }
    }

    fn move(ptr: *anyopaque, source: []const u8, dest: []const u8) anyerror!void {
        try copy(ptr, source, dest);
        _ = try deleteFn(ptr, source);
    }

    fn size(ptr: *anyopaque, path: []const u8) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return error.FileNotFound;
        return entry.contents.len;
    }

    fn lastModified(ptr: *anyopaque, path: []const u8) anyerror!i64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return error.FileNotFound;
        return entry.modified_at;
    }

    fn metadata(ptr: *anyopaque, path: []const u8) anyerror!storage.FileMetadata {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const entry = self.files.get(path) orelse return error.FileNotFound;

        const mime = if (storage.Path.extension(path)) |ext|
            storage.MimeType.fromExtension(ext)
        else
            "application/octet-stream";

        const visibility = self.visibility_map.get(path) orelse .private;

        return storage.FileMetadata{
            .path = try self.allocator.dupe(u8, path),
            .size = entry.contents.len,
            .last_modified = entry.modified_at,
            .mime_type = try self.allocator.dupe(u8, mime),
            .visibility = visibility,
            .allocator = self.allocator,
        };
    }

    fn url(ptr: *anyopaque, path: []const u8) anyerror![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const prefix = "memory://";
        const result = try self.allocator.alloc(u8, prefix.len + path.len);
        @memcpy(result[0..prefix.len], prefix);
        @memcpy(result[prefix.len..], path);

        return result;
    }

    fn temporaryUrl(ptr: *anyopaque, path: []const u8, expiration: i64) anyerror![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = expiration;

        const prefix = "memory://";
        const suffix = "?temp=true";
        const result = try self.allocator.alloc(u8, prefix.len + path.len + suffix.len);
        @memcpy(result[0..prefix.len], prefix);
        @memcpy(result[prefix.len .. prefix.len + path.len], path);
        @memcpy(result[prefix.len + path.len ..], suffix);

        return result;
    }

    fn setVisibility(ptr: *anyopaque, path: []const u8, visibility: storage.Visibility) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (!self.files.contains(path)) {
            return error.FileNotFound;
        }

        // Remove old visibility entry if exists
        if (self.visibility_map.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
        }

        const path_copy = try self.allocator.dupe(u8, path);
        try self.visibility_map.put(path_copy, visibility);
    }

    fn getVisibility(ptr: *anyopaque, path: []const u8) anyerror!storage.Visibility {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (!self.files.contains(path)) {
            return error.FileNotFound;
        }

        return self.visibility_map.get(path) orelse .private;
    }

    fn makeDirectory(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (!self.directories.contains(path)) {
            const path_copy = try self.allocator.dupe(u8, path);
            try self.directories.put(path_copy, {});
        }
    }

    fn deleteDirectory(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Collect keys to delete
        var keys_to_delete: [1024][]const u8 = undefined;
        var delete_count: usize = 0;

        var it = self.files.keyIterator();
        while (it.next()) |key| {
            if (std.mem.startsWith(u8, key.*, path)) {
                if (delete_count < keys_to_delete.len) {
                    keys_to_delete[delete_count] = key.*;
                    delete_count += 1;
                }
            }
        }

        // Delete collected keys
        for (keys_to_delete[0..delete_count]) |key| {
            _ = try deleteFn(ptr, key);
        }

        // Delete directory itself
        if (self.directories.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
        }
    }

    fn listContents(ptr: *anyopaque, path: []const u8, recursive: bool) anyerror![]storage.DirectoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Use fixed buffer
        var entries_buf: [1024]storage.DirectoryEntry = undefined;
        var entries_count: usize = 0;

        const prefix = if (path.len > 0 and !std.mem.endsWith(u8, path, "/"))
            try std.fmt.allocPrint(self.allocator, "{s}/", .{path})
        else
            try self.allocator.dupe(u8, path);
        defer self.allocator.free(prefix);

        // Add files
        var file_it = self.files.iterator();
        while (file_it.next()) |entry| {
            if (entries_count >= entries_buf.len) break;

            const key = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, key, prefix)) continue;

            const relative = key[prefix.len..];

            // Check if it's a direct child or nested
            if (!recursive) {
                if (std.mem.indexOf(u8, relative, "/") != null) continue;
            }

            entries_buf[entries_count] = .{
                .path = try self.allocator.dupe(u8, key),
                .is_directory = false,
                .size = entry.value_ptr.contents.len,
                .last_modified = entry.value_ptr.modified_at,
            };
            entries_count += 1;
        }

        // Add directories
        var dir_it = self.directories.keyIterator();
        while (dir_it.next()) |key| {
            if (entries_count >= entries_buf.len) break;

            if (!std.mem.startsWith(u8, key.*, prefix)) continue;

            const relative = key.*[prefix.len..];

            if (!recursive) {
                if (std.mem.indexOf(u8, relative, "/") != null) continue;
            }

            entries_buf[entries_count] = .{
                .path = try self.allocator.dupe(u8, key.*),
                .is_directory = true,
                .size = 0,
                .last_modified = 0,
            };
            entries_count += 1;
        }

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

// Tests
test "memory driver basic operations" {
    const allocator = std.testing.allocator;

    const drv = try MemoryDriver.init(allocator);
    defer drv.deinit();

    var d = drv.driver();

    // Put a file
    try d.put("test.txt", "Hello, Memory!");

    // Check exists
    try std.testing.expect(d.exists("test.txt"));
    try std.testing.expect(!d.exists("nonexistent.txt"));

    // Get the file
    const contents = try d.get("test.txt") orelse unreachable;
    defer allocator.free(contents);

    try std.testing.expectEqualStrings("Hello, Memory!", contents);

    // Get size
    const file_size = try d.size("test.txt");
    try std.testing.expectEqual(@as(u64, 14), file_size);

    // Delete
    const deleted = try d.delete("test.txt");
    try std.testing.expect(deleted);
    try std.testing.expect(!d.exists("test.txt"));
}

test "memory driver copy and move" {
    const allocator = std.testing.allocator;

    const drv = try MemoryDriver.init(allocator);
    defer drv.deinit();

    var d = drv.driver();

    // Put original
    try d.put("original.txt", "Original content");

    // Copy
    try d.copy("original.txt", "copy.txt");
    try std.testing.expect(d.exists("original.txt"));
    try std.testing.expect(d.exists("copy.txt"));

    // Move
    try d.move("original.txt", "moved.txt");
    try std.testing.expect(!d.exists("original.txt"));
    try std.testing.expect(d.exists("moved.txt"));

    // Clean up
    _ = try d.delete("copy.txt");
    _ = try d.delete("moved.txt");
}

test "memory driver visibility" {
    const allocator = std.testing.allocator;

    const drv = try MemoryDriver.init(allocator);
    defer drv.deinit();

    var d = drv.driver();

    try d.put("test.txt", "Test");

    // Default visibility is private
    const vis1 = try d.getVisibility("test.txt");
    try std.testing.expectEqual(storage.Visibility.private, vis1);

    // Set to public
    try d.setVisibility("test.txt", .public);
    const vis2 = try d.getVisibility("test.txt");
    try std.testing.expectEqual(storage.Visibility.public, vis2);

    _ = try d.delete("test.txt");
}
