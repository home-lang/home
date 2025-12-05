const std = @import("std");
const posix = std.posix;
const storage = @import("storage.zig");

/// Helper to get current timestamp (Zig 0.16 compatible)
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// S3 storage driver
pub const S3Driver = struct {
    allocator: std.mem.Allocator,
    bucket: []const u8,
    region: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    endpoint: ?[]const u8,
    use_path_style: bool,
    url_base: ?[]const u8,
    root: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: storage.StorageConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .bucket = try allocator.dupe(u8, config.s3_bucket orelse return error.MissingBucket),
            .region = try allocator.dupe(u8, config.s3_region orelse "us-east-1"),
            .access_key = try allocator.dupe(u8, config.s3_access_key orelse return error.MissingAccessKey),
            .secret_key = try allocator.dupe(u8, config.s3_secret_key orelse return error.MissingSecretKey),
            .endpoint = if (config.s3_endpoint) |e| try allocator.dupe(u8, e) else null,
            .use_path_style = config.s3_use_path_style,
            .url_base = if (config.url_base) |u| try allocator.dupe(u8, u) else null,
            .root = try allocator.dupe(u8, config.root),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bucket);
        self.allocator.free(self.region);
        self.allocator.free(self.access_key);
        self.allocator.free(self.secret_key);
        if (self.endpoint) |e| self.allocator.free(e);
        if (self.url_base) |u| self.allocator.free(u);
        self.allocator.free(self.root);
        self.allocator.destroy(self);
    }

    /// Get the StorageDriver interface
    pub fn driver(self: *Self) storage.StorageDriver {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn fullKey(self: *Self, path: []const u8) ![]const u8 {
        if (self.root.len == 0) {
            return try self.allocator.dupe(u8, path);
        }
        return storage.Path.join(self.allocator, &[_][]const u8{ self.root, path });
    }

    fn getHost(self: *Self) ![]const u8 {
        if (self.endpoint) |ep| {
            return try self.allocator.dupe(u8, ep);
        }

        if (self.use_path_style) {
            return try std.fmt.allocPrint(self.allocator, "s3.{s}.amazonaws.com", .{self.region});
        }

        return try std.fmt.allocPrint(self.allocator, "{s}.s3.{s}.amazonaws.com", .{ self.bucket, self.region });
    }

    // VTable implementations

    fn put(ptr: *anyopaque, path: []const u8, contents: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        // In a real implementation, this would:
        // 1. Build the request with AWS Signature V4
        // 2. Send PUT request to S3
        // For now, we'll store in a mock manner (log only)
        _ = contents;

        // Log the operation
        std.log.debug("S3: PUT s3://{s}/{s}", .{ self.bucket, key });
    }

    fn get(ptr: *anyopaque, path: []const u8) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        // In a real implementation, this would:
        // 1. Build the request with AWS Signature V4
        // 2. Send GET request to S3
        // 3. Return the response body
        std.log.debug("S3: GET s3://{s}/{s}", .{ self.bucket, key });

        return null; // Would return actual contents
    }

    fn exists(ptr: *anyopaque, path: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = self.fullKey(path) catch return false;
        defer self.allocator.free(key);

        // In a real implementation, this would do a HEAD request
        std.log.debug("S3: HEAD s3://{s}/{s}", .{ self.bucket, key });

        return false;
    }

    fn deleteFn(ptr: *anyopaque, path: []const u8) anyerror!bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        std.log.debug("S3: DELETE s3://{s}/{s}", .{ self.bucket, key });

        return true;
    }

    fn copy(ptr: *anyopaque, source: []const u8, dest: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const source_key = try self.fullKey(source);
        defer self.allocator.free(source_key);

        const dest_key = try self.fullKey(dest);
        defer self.allocator.free(dest_key);

        std.log.debug("S3: COPY s3://{s}/{s} -> s3://{s}/{s}", .{ self.bucket, source_key, self.bucket, dest_key });
    }

    fn move(ptr: *anyopaque, source: []const u8, dest: []const u8) anyerror!void {
        try copy(ptr, source, dest);
        _ = try deleteFn(ptr, source);
    }

    fn size(ptr: *anyopaque, path: []const u8) anyerror!u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        std.log.debug("S3: HEAD (size) s3://{s}/{s}", .{ self.bucket, key });

        return 0; // Would return actual size
    }

    fn lastModified(ptr: *anyopaque, path: []const u8) anyerror!i64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        std.log.debug("S3: HEAD (lastModified) s3://{s}/{s}", .{ self.bucket, key });

        return getTimestamp();
    }

    fn metadata(ptr: *anyopaque, path: []const u8) anyerror!storage.FileMetadata {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        std.log.debug("S3: HEAD (metadata) s3://{s}/{s}", .{ self.bucket, key });

        const mime = if (storage.Path.extension(path)) |ext|
            storage.MimeType.fromExtension(ext)
        else
            "application/octet-stream";

        return storage.FileMetadata{
            .path = try self.allocator.dupe(u8, path),
            .size = 0,
            .last_modified = getTimestamp(),
            .mime_type = try self.allocator.dupe(u8, mime),
            .allocator = self.allocator,
        };
    }

    fn url(ptr: *anyopaque, path: []const u8) anyerror![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        if (self.url_base) |base| {
            return storage.Path.join(self.allocator, &[_][]const u8{ base, key });
        }

        const host = try self.getHost();
        defer self.allocator.free(host);

        if (self.use_path_style) {
            return try std.fmt.allocPrint(self.allocator, "https://{s}/{s}/{s}", .{ host, self.bucket, key });
        }

        return try std.fmt.allocPrint(self.allocator, "https://{s}/{s}", .{ host, key });
    }

    fn temporaryUrl(ptr: *anyopaque, path: []const u8, expiration: i64) anyerror![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        const host = try self.getHost();
        defer self.allocator.free(host);

        // In a real implementation, this would generate a presigned URL with AWS Signature V4
        // For now, return a mock presigned URL
        const base_url = if (self.use_path_style)
            try std.fmt.allocPrint(self.allocator, "https://{s}/{s}/{s}", .{ host, self.bucket, key })
        else
            try std.fmt.allocPrint(self.allocator, "https://{s}/{s}", .{ host, key });
        defer self.allocator.free(base_url);

        // Add query params (simplified)
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires={d}",
            .{ base_url, @as(u64, @intCast(expiration - getTimestamp())) },
        );
    }

    fn setVisibility(ptr: *anyopaque, path: []const u8, visibility: storage.Visibility) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        const acl = switch (visibility) {
            .public => "public-read",
            .private => "private",
        };

        std.log.debug("S3: PUT ACL s3://{s}/{s} -> {s}", .{ self.bucket, key, acl });
    }

    fn getVisibility(ptr: *anyopaque, path: []const u8) anyerror!storage.Visibility {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        std.log.debug("S3: GET ACL s3://{s}/{s}", .{ self.bucket, key });

        return .private;
    }

    fn makeDirectory(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        // S3 doesn't have real directories, but we can create a placeholder
        const dir_marker = try std.fmt.allocPrint(self.allocator, "{s}/", .{key});
        defer self.allocator.free(dir_marker);

        std.log.debug("S3: PUT (directory) s3://{s}/{s}", .{ self.bucket, dir_marker });
    }

    fn deleteDirectory(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const key = try self.fullKey(path);
        defer self.allocator.free(key);

        // Would need to list all objects with prefix and delete them
        std.log.debug("S3: DELETE (directory) s3://{s}/{s}/", .{ self.bucket, key });
    }

    fn listContents(ptr: *anyopaque, path: []const u8, recursive: bool) anyerror![]storage.DirectoryEntry {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const prefix = try self.fullKey(path);
        defer self.allocator.free(prefix);

        const delimiter = if (recursive) "" else "/";

        std.log.debug("S3: LIST s3://{s}/{s} (delimiter={s})", .{ self.bucket, prefix, delimiter });

        // Would use ListObjectsV2 API
        return &[_]storage.DirectoryEntry{};
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
test "s3 driver init" {
    const allocator = std.testing.allocator;
    const config = storage.StorageConfig.s3Disk(
        "my-bucket",
        "us-west-2",
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    );

    const drv = try S3Driver.init(allocator, config);
    defer drv.deinit();

    try std.testing.expectEqualStrings("my-bucket", drv.bucket);
    try std.testing.expectEqualStrings("us-west-2", drv.region);
}

test "s3 driver url generation" {
    const allocator = std.testing.allocator;
    const config = storage.StorageConfig.s3Disk(
        "my-bucket",
        "us-west-2",
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    );

    const drv = try S3Driver.init(allocator, config);
    defer drv.deinit();

    var d = drv.driver();

    const file_url = try d.url("photos/image.jpg");
    defer allocator.free(file_url);

    try std.testing.expect(std.mem.indexOf(u8, file_url, "my-bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_url, "photos/image.jpg") != null);
}

test "s3 driver temporary url" {
    const allocator = std.testing.allocator;
    const config = storage.StorageConfig.s3Disk(
        "my-bucket",
        "us-west-2",
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    );

    const drv = try S3Driver.init(allocator, config);
    defer drv.deinit();

    var d = drv.driver();

    const expiration = getTimestamp() + 3600; // 1 hour
    const temp_url = try d.temporaryUrl("private/doc.pdf", expiration);
    defer allocator.free(temp_url);

    try std.testing.expect(std.mem.indexOf(u8, temp_url, "X-Amz-Algorithm") != null);
    try std.testing.expect(std.mem.indexOf(u8, temp_url, "X-Amz-Expires") != null);
}
