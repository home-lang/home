const std = @import("std");
const posix = std.posix;

// Re-export drivers
pub const local = @import("local.zig");
pub const s3 = @import("s3_driver.zig");
pub const memory = @import("memory.zig");

/// File visibility
pub const Visibility = enum {
    public,
    private,

    pub fn toString(self: Visibility) []const u8 {
        return switch (self) {
            .public => "public",
            .private => "private",
        };
    }
};

/// File metadata
pub const FileMetadata = struct {
    path: []const u8,
    size: u64,
    last_modified: i64,
    mime_type: ?[]const u8 = null,
    visibility: Visibility = .private,
    etag: ?[]const u8 = null,
    extra: ?std.StringHashMap([]const u8) = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FileMetadata) void {
        self.allocator.free(self.path);
        if (self.mime_type) |mt| self.allocator.free(mt);
        if (self.etag) |et| self.allocator.free(et);
        if (self.extra) |*e| e.deinit();
    }
};

/// Directory listing entry
pub const DirectoryEntry = struct {
    path: []const u8,
    is_directory: bool,
    size: u64,
    last_modified: i64,
};

/// Storage driver interface
pub const StorageDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, path: []const u8, contents: []const u8) anyerror!void,
        get: *const fn (ptr: *anyopaque, path: []const u8) anyerror!?[]const u8,
        exists: *const fn (ptr: *anyopaque, path: []const u8) bool,
        delete: *const fn (ptr: *anyopaque, path: []const u8) anyerror!bool,
        copy: *const fn (ptr: *anyopaque, source: []const u8, dest: []const u8) anyerror!void,
        move: *const fn (ptr: *anyopaque, source: []const u8, dest: []const u8) anyerror!void,
        size: *const fn (ptr: *anyopaque, path: []const u8) anyerror!u64,
        lastModified: *const fn (ptr: *anyopaque, path: []const u8) anyerror!i64,
        metadata: *const fn (ptr: *anyopaque, path: []const u8) anyerror!FileMetadata,
        url: *const fn (ptr: *anyopaque, path: []const u8) anyerror![]const u8,
        temporaryUrl: *const fn (ptr: *anyopaque, path: []const u8, expiration: i64) anyerror![]const u8,
        setVisibility: *const fn (ptr: *anyopaque, path: []const u8, visibility: Visibility) anyerror!void,
        getVisibility: *const fn (ptr: *anyopaque, path: []const u8) anyerror!Visibility,
        makeDirectory: *const fn (ptr: *anyopaque, path: []const u8) anyerror!void,
        deleteDirectory: *const fn (ptr: *anyopaque, path: []const u8) anyerror!void,
        listContents: *const fn (ptr: *anyopaque, path: []const u8, recursive: bool) anyerror![]DirectoryEntry,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn put(self: StorageDriver, path: []const u8, contents: []const u8) !void {
        return self.vtable.put(self.ptr, path, contents);
    }

    pub fn get(self: StorageDriver, path: []const u8) !?[]const u8 {
        return self.vtable.get(self.ptr, path);
    }

    pub fn exists(self: StorageDriver, path: []const u8) bool {
        return self.vtable.exists(self.ptr, path);
    }

    pub fn delete(self: StorageDriver, path: []const u8) !bool {
        return self.vtable.delete(self.ptr, path);
    }

    pub fn copy(self: StorageDriver, source: []const u8, dest: []const u8) !void {
        return self.vtable.copy(self.ptr, source, dest);
    }

    pub fn move(self: StorageDriver, source: []const u8, dest: []const u8) !void {
        return self.vtable.move(self.ptr, source, dest);
    }

    pub fn size(self: StorageDriver, path: []const u8) !u64 {
        return self.vtable.size(self.ptr, path);
    }

    pub fn lastModified(self: StorageDriver, path: []const u8) !i64 {
        return self.vtable.lastModified(self.ptr, path);
    }

    pub fn metadata(self: StorageDriver, path: []const u8) !FileMetadata {
        return self.vtable.metadata(self.ptr, path);
    }

    pub fn url(self: StorageDriver, path: []const u8) ![]const u8 {
        return self.vtable.url(self.ptr, path);
    }

    pub fn temporaryUrl(self: StorageDriver, path: []const u8, expiration: i64) ![]const u8 {
        return self.vtable.temporaryUrl(self.ptr, path, expiration);
    }

    pub fn setVisibility(self: StorageDriver, path: []const u8, visibility: Visibility) !void {
        return self.vtable.setVisibility(self.ptr, path, visibility);
    }

    pub fn getVisibility(self: StorageDriver, path: []const u8) !Visibility {
        return self.vtable.getVisibility(self.ptr, path);
    }

    pub fn makeDirectory(self: StorageDriver, path: []const u8) !void {
        return self.vtable.makeDirectory(self.ptr, path);
    }

    pub fn deleteDirectory(self: StorageDriver, path: []const u8) !void {
        return self.vtable.deleteDirectory(self.ptr, path);
    }

    pub fn listContents(self: StorageDriver, path: []const u8, recursive: bool) ![]DirectoryEntry {
        return self.vtable.listContents(self.ptr, path, recursive);
    }

    pub fn deinit(self: StorageDriver) void {
        return self.vtable.deinit(self.ptr);
    }
};

/// Storage disk type
pub const DiskType = enum {
    local,
    s3,
    memory,
    ftp,
    sftp,
};

/// Storage configuration
pub const StorageConfig = struct {
    disk_type: DiskType,
    root: []const u8 = "",
    url_base: ?[]const u8 = null,
    visibility: Visibility = .private,

    // Local disk options
    permissions_file: u32 = 0o644,
    permissions_dir: u32 = 0o755,

    // S3 options
    s3_bucket: ?[]const u8 = null,
    s3_region: ?[]const u8 = null,
    s3_access_key: ?[]const u8 = null,
    s3_secret_key: ?[]const u8 = null,
    s3_endpoint: ?[]const u8 = null,
    s3_use_path_style: bool = false,

    pub fn localDisk(root: []const u8) StorageConfig {
        return .{
            .disk_type = .local,
            .root = root,
        };
    }

    pub fn s3Disk(bucket: []const u8, region: []const u8, access_key: []const u8, secret_key: []const u8) StorageConfig {
        return .{
            .disk_type = .s3,
            .s3_bucket = bucket,
            .s3_region = region,
            .s3_access_key = access_key,
            .s3_secret_key = secret_key,
        };
    }

    pub fn memoryDisk() StorageConfig {
        return .{
            .disk_type = .memory,
        };
    }
};

/// Storage manager - facade for multiple disks
pub const Storage = struct {
    allocator: std.mem.Allocator,
    disks: std.StringHashMap(StorageDriver),
    default_disk: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .disks = std.StringHashMap(StorageDriver).init(allocator),
            .default_disk = "local",
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.disks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.disks.deinit();
    }

    /// Add a disk
    pub fn addDisk(self: *Self, name: []const u8, config: StorageConfig) !void {
        const driver = switch (config.disk_type) {
            .local => blk: {
                const d = try local.LocalDriver.init(self.allocator, config);
                break :blk d.driver();
            },
            .s3 => blk: {
                const d = try s3.S3Driver.init(self.allocator, config);
                break :blk d.driver();
            },
            .memory => blk: {
                const d = try memory.MemoryDriver.init(self.allocator);
                break :blk d.driver();
            },
            else => return error.UnsupportedDiskType,
        };

        try self.disks.put(name, driver);
    }

    /// Set the default disk
    pub fn setDefaultDisk(self: *Self, name: []const u8) void {
        self.default_disk = name;
    }

    /// Get a specific disk
    pub fn disk(self: *Self, name: []const u8) ?StorageDriver {
        return self.disks.get(name);
    }

    /// Get the default disk
    pub fn getDefault(self: *Self) ?StorageDriver {
        return self.disks.get(self.default_disk);
    }

    // Convenience methods that use the default disk

    pub fn put(self: *Self, path: []const u8, contents: []const u8) !void {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.put(path, contents);
    }

    pub fn get(self: *Self, path: []const u8) !?[]const u8 {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.get(path);
    }

    pub fn exists(self: *Self, path: []const u8) bool {
        const d = self.getDefault() orelse return false;
        return d.exists(path);
    }

    pub fn delete(self: *Self, path: []const u8) !bool {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.delete(path);
    }

    pub fn copy(self: *Self, source: []const u8, dest: []const u8) !void {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.copy(source, dest);
    }

    pub fn move(self: *Self, source: []const u8, dest: []const u8) !void {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.move(source, dest);
    }

    pub fn url(self: *Self, path: []const u8) ![]const u8 {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.url(path);
    }

    pub fn temporaryUrl(self: *Self, path: []const u8, expiration: i64) ![]const u8 {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.temporaryUrl(path, expiration);
    }

    pub fn makeDirectory(self: *Self, path: []const u8) !void {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.makeDirectory(path);
    }

    pub fn deleteDirectory(self: *Self, path: []const u8) !void {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.deleteDirectory(path);
    }

    pub fn listContents(self: *Self, path: []const u8, recursive: bool) ![]DirectoryEntry {
        const d = self.getDefault() orelse return error.NoDiskConfigured;
        return d.listContents(path, recursive);
    }
};

/// File upload handling
pub const UploadedFile = struct {
    name: []const u8,
    original_name: []const u8,
    mime_type: []const u8,
    size: u64,
    temp_path: []const u8,
    error_code: ?UploadError = null,
    allocator: std.mem.Allocator,

    pub const UploadError = enum {
        ok,
        exceeds_max_size,
        partial_upload,
        no_file_uploaded,
        missing_temp_folder,
        failed_to_write,
        extension_blocked,
    };

    pub fn deinit(self: *UploadedFile) void {
        self.allocator.free(self.name);
        self.allocator.free(self.original_name);
        self.allocator.free(self.mime_type);
        self.allocator.free(self.temp_path);
    }

    /// Store the uploaded file to a path
    pub fn store(self: *UploadedFile, storage: *Storage, path: []const u8) ![]const u8 {
        return self.storeAs(storage, path, self.name);
    }

    /// Store with a custom name
    pub fn storeAs(self: *UploadedFile, storage: *Storage, path: []const u8, name: []const u8) ![]const u8 {
        // Read temp file
        const file = try std.fs.openFileAbsolute(self.temp_path, .{});
        defer file.close();

        const stat = try file.stat();
        const contents = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(contents);

        _ = try file.preadAll(contents, 0);

        // Build full path
        var full_path = std.ArrayList(u8).init(self.allocator);
        defer full_path.deinit();

        if (path.len > 0) {
            try full_path.appendSlice(path);
            if (!std.mem.endsWith(u8, path, "/")) {
                try full_path.appendSlice("/");
            }
        }
        try full_path.appendSlice(name);

        const final_path = try full_path.toOwnedSlice();

        // Store
        try storage.put(final_path, contents);

        return final_path;
    }

    /// Get file extension
    pub fn extension(self: *UploadedFile) ?[]const u8 {
        if (std.mem.lastIndexOf(u8, self.original_name, ".")) |idx| {
            return self.original_name[idx + 1 ..];
        }
        return null;
    }

    /// Check if upload was successful
    pub fn isValid(self: *UploadedFile) bool {
        return self.error_code == null or self.error_code == .ok;
    }

    /// Get hash of file contents
    pub fn hashName(self: *UploadedFile) ![]const u8 {
        const file = try std.fs.openFileAbsolute(self.temp_path, .{});
        defer file.close();

        const stat = try file.stat();
        const contents = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(contents);

        _ = try file.preadAll(contents, 0);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(contents, &hash, .{});

        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;

        // Add extension
        if (self.extension()) |ext| {
            var result = try self.allocator.alloc(u8, 64 + 1 + ext.len);
            @memcpy(result[0..64], &hex);
            result[64] = '.';
            @memcpy(result[65..], ext);
            return result;
        }

        return try self.allocator.dupe(u8, &hex);
    }
};

/// MIME type detection
pub const MimeType = struct {
    /// Detect MIME type from file extension
    pub fn fromExtension(ext: []const u8) []const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            // Images
            .{ "jpg", "image/jpeg" },
            .{ "jpeg", "image/jpeg" },
            .{ "png", "image/png" },
            .{ "gif", "image/gif" },
            .{ "webp", "image/webp" },
            .{ "svg", "image/svg+xml" },
            .{ "ico", "image/x-icon" },
            .{ "bmp", "image/bmp" },
            // Documents
            .{ "pdf", "application/pdf" },
            .{ "doc", "application/msword" },
            .{ "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
            .{ "xls", "application/vnd.ms-excel" },
            .{ "xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
            .{ "ppt", "application/vnd.ms-powerpoint" },
            .{ "pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
            // Text
            .{ "txt", "text/plain" },
            .{ "html", "text/html" },
            .{ "htm", "text/html" },
            .{ "css", "text/css" },
            .{ "js", "application/javascript" },
            .{ "json", "application/json" },
            .{ "xml", "application/xml" },
            .{ "csv", "text/csv" },
            .{ "md", "text/markdown" },
            // Archives
            .{ "zip", "application/zip" },
            .{ "tar", "application/x-tar" },
            .{ "gz", "application/gzip" },
            .{ "rar", "application/vnd.rar" },
            .{ "7z", "application/x-7z-compressed" },
            // Audio
            .{ "mp3", "audio/mpeg" },
            .{ "wav", "audio/wav" },
            .{ "ogg", "audio/ogg" },
            .{ "flac", "audio/flac" },
            .{ "m4a", "audio/mp4" },
            // Video
            .{ "mp4", "video/mp4" },
            .{ "webm", "video/webm" },
            .{ "avi", "video/x-msvideo" },
            .{ "mov", "video/quicktime" },
            .{ "mkv", "video/x-matroska" },
            // Fonts
            .{ "woff", "font/woff" },
            .{ "woff2", "font/woff2" },
            .{ "ttf", "font/ttf" },
            .{ "otf", "font/otf" },
            .{ "eot", "application/vnd.ms-fontobject" },
        });

        return map.get(ext) orelse "application/octet-stream";
    }

    /// Detect MIME type from file contents (magic bytes)
    pub fn fromContents(contents: []const u8) []const u8 {
        if (contents.len < 4) return "application/octet-stream";

        // PNG
        if (contents.len >= 8 and std.mem.eql(u8, contents[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) {
            return "image/png";
        }

        // JPEG
        if (contents[0] == 0xFF and contents[1] == 0xD8 and contents[2] == 0xFF) {
            return "image/jpeg";
        }

        // GIF
        if (std.mem.startsWith(u8, contents, "GIF87a") or std.mem.startsWith(u8, contents, "GIF89a")) {
            return "image/gif";
        }

        // PDF
        if (std.mem.startsWith(u8, contents, "%PDF")) {
            return "application/pdf";
        }

        // ZIP
        if (contents[0] == 0x50 and contents[1] == 0x4B and (contents[2] == 0x03 or contents[2] == 0x05 or contents[2] == 0x07)) {
            return "application/zip";
        }

        // GZIP
        if (contents[0] == 0x1F and contents[1] == 0x8B) {
            return "application/gzip";
        }

        // WebP
        if (contents.len >= 12 and std.mem.eql(u8, contents[0..4], "RIFF") and std.mem.eql(u8, contents[8..12], "WEBP")) {
            return "image/webp";
        }

        // MP4/MOV
        if (contents.len >= 8) {
            if (std.mem.eql(u8, contents[4..8], "ftyp")) {
                return "video/mp4";
            }
        }

        return "application/octet-stream";
    }
};

/// Path utilities
pub const Path = struct {
    /// Normalize a path (remove . and ..)
    pub fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // Use fixed-size buffer for parts
        var parts_buf: [128][]const u8 = undefined;
        var parts_count: usize = 0;

        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) {
                continue;
            }
            if (std.mem.eql(u8, part, "..")) {
                if (parts_count > 0) {
                    parts_count -= 1;
                }
                continue;
            }
            if (parts_count < parts_buf.len) {
                parts_buf[parts_count] = part;
                parts_count += 1;
            }
        }

        if (parts_count == 0) {
            return try allocator.dupe(u8, "");
        }

        // Calculate total length
        var total_len: usize = 0;
        for (0..parts_count) |i| {
            if (i > 0) total_len += 1; // for '/'
            total_len += parts_buf[i].len;
        }

        // Allocate and build result
        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (0..parts_count) |i| {
            if (i > 0) {
                result[pos] = '/';
                pos += 1;
            }
            @memcpy(result[pos .. pos + parts_buf[i].len], parts_buf[i]);
            pos += parts_buf[i].len;
        }

        return result;
    }

    /// Get the directory name
    pub fn dirname(path: []const u8) []const u8 {
        if (std.mem.lastIndexOf(u8, path, "/")) |idx| {
            return path[0..idx];
        }
        return "";
    }

    /// Get the base name
    pub fn basename(path: []const u8) []const u8 {
        if (std.mem.lastIndexOf(u8, path, "/")) |idx| {
            return path[idx + 1 ..];
        }
        return path;
    }

    /// Get the extension
    pub fn extension(path: []const u8) ?[]const u8 {
        const base = basename(path);
        if (std.mem.lastIndexOf(u8, base, ".")) |idx| {
            return base[idx + 1 ..];
        }
        return null;
    }

    /// Join paths
    pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
        // Calculate total length first
        var total_len: usize = 0;
        var first_non_empty: bool = true;

        for (parts) |part| {
            var p = part;
            if (p.len == 0) continue;

            // Strip leading slash if not first
            if (!first_non_empty and std.mem.startsWith(u8, p, "/")) {
                p = p[1..];
            }
            // Strip trailing slash
            if (std.mem.endsWith(u8, p, "/")) {
                p = p[0 .. p.len - 1];
            }

            if (p.len == 0) continue;

            if (!first_non_empty) {
                total_len += 1; // for '/'
            }
            total_len += p.len;
            first_non_empty = false;
        }

        if (total_len == 0) {
            return try allocator.dupe(u8, "");
        }

        // Build result
        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        first_non_empty = true;

        for (parts) |part| {
            var p = part;
            if (p.len == 0) continue;

            if (!first_non_empty and std.mem.startsWith(u8, p, "/")) {
                p = p[1..];
            }
            if (std.mem.endsWith(u8, p, "/")) {
                p = p[0 .. p.len - 1];
            }

            if (p.len == 0) continue;

            if (!first_non_empty) {
                result[pos] = '/';
                pos += 1;
            }

            @memcpy(result[pos .. pos + p.len], p);
            pos += p.len;
            first_non_empty = false;
        }

        return result;
    }
};

// Tests
test "mime type from extension" {
    try std.testing.expectEqualStrings("image/png", MimeType.fromExtension("png"));
    try std.testing.expectEqualStrings("application/pdf", MimeType.fromExtension("pdf"));
    try std.testing.expectEqualStrings("video/mp4", MimeType.fromExtension("mp4"));
    try std.testing.expectEqualStrings("application/octet-stream", MimeType.fromExtension("unknown"));
}

test "path utilities" {
    const allocator = std.testing.allocator;

    // Test normalize
    const normalized = try Path.normalize(allocator, "foo/bar/../baz");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("foo/baz", normalized);

    // Test dirname/basename
    try std.testing.expectEqualStrings("foo/bar", Path.dirname("foo/bar/baz.txt"));
    try std.testing.expectEqualStrings("baz.txt", Path.basename("foo/bar/baz.txt"));
    try std.testing.expectEqualStrings("txt", Path.extension("foo/bar/baz.txt").?);

    // Test join
    const joined = try Path.join(allocator, &[_][]const u8{ "foo", "bar", "baz" });
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("foo/bar/baz", joined);
}

test "visibility toString" {
    try std.testing.expectEqualStrings("public", Visibility.public.toString());
    try std.testing.expectEqualStrings("private", Visibility.private.toString());
}
