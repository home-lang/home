const std = @import("std");

/// Intermediate Representation for caching
pub const IR = struct {
    module_name: []const u8,
    source_hash: u64,
    timestamp: i64,
    ast_data: []const u8, // Serialized AST
    type_info: []const u8, // Serialized type information
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IR) void {
        self.allocator.free(self.module_name);
        self.allocator.free(self.ast_data);
        self.allocator.free(self.type_info);
    }
};

/// IR Cache manager for fast incremental compilation
pub const IRCache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    cache: std.StringHashMap(*IR),

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8) !IRCache {
        // Ensure cache directory exists
        std.fs.cwd().makePath(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return .{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .cache = std.StringHashMap(*IR).init(allocator),
        };
    }

    pub fn deinit(self: *IRCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.deinit();
        self.allocator.free(self.cache_dir);
    }

    /// Check if a cached IR is valid for the given source file
    pub fn isCacheValid(self: *IRCache, file_path: []const u8, source: []const u8) !bool {
        const cache_key = try self.getCacheKey(file_path);
        defer self.allocator.free(cache_key);

        // Try to load from disk cache
        const ir = self.loadFromDisk(cache_key) catch return false;
        defer {
            ir.deinit();
            self.allocator.destroy(ir);
        }

        // Check source hash - this is sufficient for cache validation
        // (if source hash matches, file hasn't changed)
        const current_hash = hashSource(source);
        if (ir.source_hash != current_hash) {
            return false;
        }

        return true;
    }

    /// Get cached IR for a file
    pub fn get(self: *IRCache, file_path: []const u8) !?*IR {
        const cache_key = try self.getCacheKey(file_path);
        defer self.allocator.free(cache_key);

        // Check memory cache first
        if (self.cache.get(cache_key)) |ir| {
            return ir;
        }

        // Try to load from disk
        const ir = self.loadFromDisk(cache_key) catch return null;

        // Store in memory cache
        const key_copy = try self.allocator.dupe(u8, cache_key);
        try self.cache.put(key_copy, ir);

        return ir;
    }

    /// Store IR in cache
    pub fn put(
        self: *IRCache,
        file_path: []const u8,
        source: []const u8,
        ast_data: []const u8,
        type_info: []const u8,
    ) !void {
        const cache_key = try self.getCacheKey(file_path);
        defer self.allocator.free(cache_key);

        const ir = try self.allocator.create(IR);
        errdefer self.allocator.destroy(ir);

        const module_name = try self.allocator.dupe(u8, cache_key);
        errdefer self.allocator.free(module_name);

        const ast_data_copy = try self.allocator.dupe(u8, ast_data);
        errdefer self.allocator.free(ast_data_copy);

        const type_info_copy = try self.allocator.dupe(u8, type_info);
        errdefer self.allocator.free(type_info_copy);

        // Get current timestamp for cache - using 0 as a simple approach
        // (cache invalidation relies more on source_hash than timestamp)
        const current_timestamp: i64 = 0;

        ir.* = .{
            .module_name = module_name,
            .source_hash = hashSource(source),
            .timestamp = current_timestamp,
            .ast_data = ast_data_copy,
            .type_info = type_info_copy,
            .allocator = self.allocator,
        };

        // Store in memory cache
        const key_copy = try self.allocator.dupe(u8, cache_key);
        errdefer self.allocator.free(key_copy);
        try self.cache.put(key_copy, ir);

        // Write to disk
        try self.saveToDisk(cache_key, ir);
    }

    fn getCacheKey(self: *IRCache, file_path: []const u8) ![]const u8 {
        // Use basename as cache key
        const basename = std.fs.path.basename(file_path);
        // Remove .home or .hm extension
        if (std.mem.endsWith(u8, basename, ".home")) {
            return std.fmt.allocPrint(self.allocator, "{s}", .{basename[0 .. basename.len - 5]});
        } else if (std.mem.endsWith(u8, basename, ".hm")) {
            return std.fmt.allocPrint(self.allocator, "{s}", .{basename[0 .. basename.len - 3]});
        }
        return std.fmt.allocPrint(self.allocator, "{s}", .{basename});
    }

    fn getCachePath(self: *IRCache, cache_key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.irc", // .irc = Home Cache
            .{ self.cache_dir, cache_key },
        );
    }

    fn saveToDisk(self: *IRCache, cache_key: []const u8, ir: *IR) !void {
        const cache_path = try self.getCachePath(cache_key);
        defer self.allocator.free(cache_path);

        const file = try std.fs.cwd().createFile(cache_path, .{});
        defer file.close();

        // Write cache file format:
        // [source_hash: u64][timestamp: i64][ast_len: u64][type_len: u64][ast_data][type_data]
        try file.writeInt(u64, ir.source_hash, .little);
        try file.writeInt(i64, ir.timestamp, .little);
        try file.writeInt(u64, ir.ast_data.len, .little);
        try file.writeInt(u64, ir.type_info.len, .little);
        try file.writeAll(ir.ast_data);
        try file.writeAll(ir.type_info);
    }

    fn loadFromDisk(self: *IRCache, cache_key: []const u8) !*IR {
        const cache_path = try self.getCachePath(cache_key);
        defer self.allocator.free(cache_path);

        const file = try std.fs.cwd().openFile(cache_path, .{});
        defer file.close();

        // Read metadata (4 x u64/i64 = 32 bytes)
        var metadata: [32]u8 = undefined;
        const metadata_read = try file.pread(&metadata, 0);
        if (metadata_read < metadata.len) return error.UnexpectedEndOfFile;

        const source_hash = std.mem.readInt(u64, metadata[0..8], .little);
        const timestamp = std.mem.readInt(i64, metadata[8..16], .little);
        const ast_len = std.mem.readInt(u64, metadata[16..24], .little);
        const type_len = std.mem.readInt(u64, metadata[24..32], .little);

        const ast_data = try self.allocator.alloc(u8, ast_len);
        errdefer self.allocator.free(ast_data);
        const ast_read = try file.pread(ast_data, 32);
        if (ast_read < ast_data.len) return error.UnexpectedEndOfFile;

        const type_info = try self.allocator.alloc(u8, type_len);
        errdefer self.allocator.free(type_info);
        const type_read = try file.pread(type_info, 32 + ast_len);
        if (type_read < type_info.len) return error.UnexpectedEndOfFile;

        const ir = try self.allocator.create(IR);
        errdefer self.allocator.destroy(ir);

        const module_name = try self.allocator.dupe(u8, cache_key);
        errdefer self.allocator.free(module_name);

        ir.* = .{
            .module_name = module_name,
            .source_hash = source_hash,
            .timestamp = timestamp,
            .ast_data = ast_data,
            .type_info = type_info,
            .allocator = self.allocator,
        };

        return ir;
    }

    /// Clear all cached data
    pub fn clear(self: *IRCache) !void {
        var dir = try std.fs.cwd().openDir(self.cache_dir, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".irc")) {
                try dir.deleteFile(entry.name);
            }
        }

        // Clear memory cache
        var cache_it = self.cache.iterator();
        while (cache_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.clearRetainingCapacity();
    }
};

/// Hash source code for cache validation
fn hashSource(source: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(source);
    return hasher.final();
}
