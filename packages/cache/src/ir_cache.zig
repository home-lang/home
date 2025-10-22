const std = @import("std");
const ast = @import("../ast/ast.zig");

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

        // Check source hash
        const current_hash = hashSource(source);
        if (ir.source_hash != current_hash) {
            return false;
        }

        // Check file modification time
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const stat = try file.stat();

        if (stat.mtime > ir.timestamp) {
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
        ir.* = .{
            .module_name = try self.allocator.dupe(u8, cache_key),
            .source_hash = hashSource(source),
            .timestamp = std.time.timestamp(),
            .ast_data = try self.allocator.dupe(u8, ast_data),
            .type_info = try self.allocator.dupe(u8, type_info),
            .allocator = self.allocator,
        };

        // Store in memory cache
        const key_copy = try self.allocator.dupe(u8, cache_key);
        try self.cache.put(key_copy, ir);

        // Write to disk
        try self.saveToDisk(cache_key, ir);
    }

    fn getCacheKey(self: *IRCache, file_path: []const u8) ![]const u8 {
        _ = self;
        // Use basename as cache key
        const basename = std.fs.path.basename(file_path);
        // Remove .ion extension
        if (std.mem.endsWith(u8, basename, ".ion")) {
            return std.fmt.allocPrint(self.allocator, "{s}", .{basename[0 .. basename.len - 4]});
        }
        return std.fmt.allocPrint(self.allocator, "{s}", .{basename});
    }

    fn getCachePath(self: *IRCache, cache_key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.irc", // .irc = Ion Cache
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

        const source_hash = try file.reader().readInt(u64, .little);
        const timestamp = try file.reader().readInt(i64, .little);
        const ast_len = try file.reader().readInt(u64, .little);
        const type_len = try file.reader().readInt(u64, .little);

        const ast_data = try self.allocator.alloc(u8, ast_len);
        errdefer self.allocator.free(ast_data);
        _ = try file.readAll(ast_data);

        const type_info = try self.allocator.alloc(u8, type_len);
        errdefer self.allocator.free(type_info);
        _ = try file.readAll(type_info);

        const ir = try self.allocator.create(IR);
        ir.* = .{
            .module_name = try self.allocator.dupe(u8, cache_key),
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
