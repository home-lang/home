// Home Programming Language - Aggressive IR Cache
// Content-addressed caching with dependency tracking

const std = @import("std");
const crypto = std.crypto;
const fs = std.fs;

// Zig 0.16 compatibility: std.time.timestamp() was removed
fn getTimestamp() i64 {
    const instant = std.time.Instant.now() catch return 0;
    return @as(i64, @intCast(instant.timestamp.sec));
}

// ============================================================================
// Cache Key Generation
// ============================================================================

/// Content hash for cache keys (SHA256)
pub const CacheHash = [32]u8;

/// Generate cache key from source content and dependencies
pub fn generateCacheKey(
    source_content: []const u8,
    dependencies: []const CacheHash,
    compiler_version: []const u8,
    compile_flags: []const u8,
) CacheHash {
    var hasher = crypto.hash.sha2.Sha256.init(.{});

    // Hash source content
    hasher.update(source_content);

    // Hash dependencies in sorted order (for determinism)
    var sorted_deps_buf: [256]CacheHash = undefined;
    const sorted_deps = if (dependencies.len <= sorted_deps_buf.len) blk: {
        @memcpy(sorted_deps_buf[0..dependencies.len], dependencies);
        break :blk sorted_deps_buf[0..dependencies.len];
    } else dependencies;

    std.mem.sort(CacheHash, @constCast(sorted_deps), {}, compareCacheHash);
    for (sorted_deps) |dep_hash| {
        hasher.update(&dep_hash);
    }

    // Hash compiler version
    hasher.update(compiler_version);

    // Hash compile flags
    hasher.update(compile_flags);

    var result: CacheHash = undefined;
    hasher.final(&result);
    return result;
}

fn compareCacheHash(_: void, a: CacheHash, b: CacheHash) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

/// Convert hash to hex string
pub fn hashToHex(hash: CacheHash, buf: []u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        if (i * 2 + 1 >= buf.len) break;
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    const len = @min(hash.len * 2, buf.len);
    return buf[0..len];
}

// ============================================================================
// Cache Entry Metadata
// ============================================================================

pub const CacheEntry = struct {
    /// Cache key (content hash)
    key: CacheHash,
    /// Module name
    module_name: []const u8,
    /// Source file path
    source_path: []const u8,
    /// Source file modification time
    source_mtime: i128,
    /// Dependencies (cache keys)
    dependencies: []CacheHash,
    /// IR file path in cache
    ir_path: []const u8,
    /// Object file path in cache
    object_path: []const u8,
    /// Creation timestamp
    created_at: i64,
    /// Last access timestamp
    last_accessed: i64,
    /// Cache hit count
    hit_count: u32,
    /// Compilation time (ms)
    compile_time_ms: i64,

    pub fn format(
        self: CacheEntry,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        var hash_buf: [64]u8 = undefined;
        const hash_hex = hashToHex(self.key, &hash_buf);
        try writer.print("CacheEntry{{ {s}, hits: {}, time: {}ms }}", .{
            hash_hex[0..16],
            self.hit_count,
            self.compile_time_ms,
        });
    }
};

// ============================================================================
// IR Cache Implementation
// ============================================================================

pub const IRCache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    metadata_file: []const u8,
    entries: std.AutoHashMap(CacheHash, CacheEntry),
    stats: CacheStats,
    max_cache_size_mb: usize,
    aggressive_mode: bool,

    const METADATA_FILE = "cache_metadata.json";
    const DEFAULT_MAX_SIZE_MB = 1024; // 1GB

    pub fn init(
        allocator: std.mem.Allocator,
        cache_dir: []const u8,
        aggressive: bool,
    ) !IRCache {
        // Create cache directory
        fs.cwd().makePath(cache_dir) catch {};

        const metadata_path = try fs.path.join(allocator, &[_][]const u8{ cache_dir, METADATA_FILE });

        var cache = IRCache{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .metadata_file = metadata_path,
            .entries = std.AutoHashMap(CacheHash, CacheEntry).init(allocator),
            .stats = CacheStats{},
            .max_cache_size_mb = DEFAULT_MAX_SIZE_MB,
            .aggressive_mode = aggressive,
        };

        // Load existing metadata
        cache.loadMetadata() catch |err| {
            if (err != error.FileNotFound) {
                std.debug.print("Warning: Failed to load cache metadata: {}\n", .{err});
            }
        };

        return cache;
    }

    pub fn deinit(self: *IRCache) void {
        // Save metadata before cleanup
        self.saveMetadata() catch |err| {
            std.debug.print("Warning: Failed to save cache metadata: {}\n", .{err});
        };

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.module_name);
            self.allocator.free(entry.value_ptr.source_path);
            self.allocator.free(entry.value_ptr.dependencies);
            self.allocator.free(entry.value_ptr.ir_path);
            self.allocator.free(entry.value_ptr.object_path);
        }
        self.entries.deinit();

        self.allocator.free(self.cache_dir);
        self.allocator.free(self.metadata_file);
    }

    /// Check if cached IR exists and is valid
    pub fn get(self: *IRCache, key: CacheHash) ?*const CacheEntry {
        const entry = self.entries.getPtr(key) orelse return null;

        // Check if cached files still exist
        const ir_exists = self.fileExists(entry.ir_path);
        const obj_exists = self.fileExists(entry.object_path);

        if (!ir_exists or !obj_exists) {
            // Cache entry invalid - remove it
            _ = self.entries.remove(key);
            return null;
        }

        // Update access stats
        entry.last_accessed = getTimestamp();
        entry.hit_count += 1;
        self.stats.cache_hits += 1;

        return entry;
    }

    /// Store compiled IR and object code in cache
    pub fn put(
        self: *IRCache,
        key: CacheHash,
        module_name: []const u8,
        source_path: []const u8,
        source_mtime: i128,
        dependencies: []const CacheHash,
        ir_content: []const u8,
        object_content: []const u8,
        compile_time_ms: i64,
    ) !void {
        // Generate cache file paths
        var hash_buf: [64]u8 = undefined;
        const hash_hex = hashToHex(key, &hash_buf);

        const ir_filename = try std.fmt.allocPrint(self.allocator, "{s}.ir", .{hash_hex});
        defer self.allocator.free(ir_filename);
        const ir_path = try fs.path.join(self.allocator, &[_][]const u8{ self.cache_dir, ir_filename });

        const obj_filename = try std.fmt.allocPrint(self.allocator, "{s}.o", .{hash_hex});
        defer self.allocator.free(obj_filename);
        const obj_path = try fs.path.join(self.allocator, &[_][]const u8{ self.cache_dir, obj_filename });

        // Write IR to cache
        try self.writeFile(ir_path, ir_content);

        // Write object to cache
        try self.writeFile(obj_path, object_content);

        // Store metadata
        const entry = CacheEntry{
            .key = key,
            .module_name = try self.allocator.dupe(u8, module_name),
            .source_path = try self.allocator.dupe(u8, source_path),
            .source_mtime = source_mtime,
            .dependencies = try self.allocator.dupe(CacheHash, dependencies),
            .ir_path = ir_path,
            .object_path = obj_path,
            .created_at = getTimestamp(),
            .last_accessed = getTimestamp(),
            .hit_count = 0,
            .compile_time_ms = compile_time_ms,
        };

        try self.entries.put(key, entry);
        self.stats.cache_stores += 1;

        // Check cache size and evict if needed
        if (self.aggressive_mode) {
            try self.evictIfNeeded();
        }
    }

    /// Check if source file has been modified
    pub fn isSourceModified(_: *IRCache, source_path: []const u8, cached_mtime: i128) !bool {
        const file = try fs.cwd().openFile(source_path, .{});
        defer file.close();

        const stat = try file.stat();
        return stat.mtime != cached_mtime;
    }

    /// Invalidate cache entry
    pub fn invalidate(self: *IRCache, key: CacheHash) !void {
        if (self.entries.fetchRemove(key)) |entry| {
            // Delete cached files
            fs.cwd().deleteFile(entry.value.ir_path) catch {};
            fs.cwd().deleteFile(entry.value.object_path) catch {};

            // Free memory
            self.allocator.free(entry.value.module_name);
            self.allocator.free(entry.value.source_path);
            self.allocator.free(entry.value.dependencies);
            self.allocator.free(entry.value.ir_path);
            self.allocator.free(entry.value.object_path);

            self.stats.cache_invalidations += 1;
        }
    }

    /// Clear entire cache
    pub fn clear(self: *IRCache) !void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            fs.cwd().deleteFile(entry.value_ptr.ir_path) catch {};
            fs.cwd().deleteFile(entry.value_ptr.object_path) catch {};

            self.allocator.free(entry.value_ptr.module_name);
            self.allocator.free(entry.value_ptr.source_path);
            self.allocator.free(entry.value_ptr.dependencies);
            self.allocator.free(entry.value_ptr.ir_path);
            self.allocator.free(entry.value_ptr.object_path);
        }

        self.entries.clearRetainingCapacity();
        self.stats = CacheStats{};
    }

    /// Get cache statistics
    pub fn getStats(self: *IRCache) CacheStats {
        var stats = self.stats;
        stats.cache_entries = self.entries.count();
        stats.cache_size_mb = self.calculateCacheSize() / (1024 * 1024);
        return stats;
    }

    /// Evict least recently used entries if cache is too large
    fn evictIfNeeded(self: *IRCache) !void {
        const cache_size_mb = self.calculateCacheSize() / (1024 * 1024);

        if (cache_size_mb <= self.max_cache_size_mb) {
            return;
        }

        // Sort entries by last access time (LRU)
        var entries_list = try std.ArrayList(CacheEntry).initCapacity(
            self.allocator,
            self.entries.count(),
        );
        defer entries_list.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try entries_list.append(self.allocator, entry.value_ptr.*);
        }

        std.mem.sort(CacheEntry, entries_list.items, {}, lessThanByAccess);

        // Evict oldest 25%
        const evict_count = entries_list.items.len / 4;
        for (entries_list.items[0..evict_count]) |entry| {
            try self.invalidate(entry.key);
        }

        self.stats.cache_evictions += evict_count;
    }

    fn lessThanByAccess(_: void, a: CacheEntry, b: CacheEntry) bool {
        return a.last_accessed < b.last_accessed;
    }

    fn calculateCacheSize(self: *IRCache) usize {
        var total_size: usize = 0;
        var it = self.entries.iterator();

        while (it.next()) |entry| {
            total_size += self.getFileSize(entry.value_ptr.ir_path) catch 0;
            total_size += self.getFileSize(entry.value_ptr.object_path) catch 0;
        }

        return total_size;
    }

    fn getFileSize(self: *IRCache, path: []const u8) !usize {
        _ = self;
        const file = try fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        return stat.size;
    }

    fn fileExists(self: *IRCache, path: []const u8) bool {
        _ = self;
        fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    fn writeFile(self: *IRCache, path: []const u8, content: []const u8) !void {
        _ = self;
        const file = try fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    fn loadMetadata(self: *IRCache) !void {
        const data = try std.fs.cwd().readFileAlloc(self.metadata_file, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024));
        defer self.allocator.free(data);
        // TODO: Parse JSON metadata
        // For now, just note that we attempted to load
    }

    fn saveMetadata(self: *IRCache) !void {
        const file = try fs.cwd().createFile(self.metadata_file, .{});
        defer file.close();

        // TODO: Serialize entries to JSON
        // For now, save basic stats
        const data = try std.fmt.allocPrint(self.allocator, "{{ \"entries\": {}, \"hits\": {}, \"misses\": {} }}\n", .{
            self.entries.count(),
            self.stats.cache_hits,
            self.stats.cache_misses,
        });
        defer self.allocator.free(data);
        try file.writeAll(data);
    }
};

// ============================================================================
// Cache Statistics
// ============================================================================

pub const CacheStats = struct {
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cache_stores: u64 = 0,
    cache_invalidations: u64 = 0,
    cache_evictions: u64 = 0,
    cache_entries: usize = 0,
    cache_size_mb: usize = 0,

    pub fn hitRate(self: CacheStats) f64 {
        const total = self.cache_hits + self.cache_misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn print(self: CacheStats) void {
        std.debug.print("\n╔════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║              IR Cache Statistics               ║\n", .{});
        std.debug.print("╠════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Cache hits:         {d:>8}                     ║\n", .{self.cache_hits});
        std.debug.print("║ Cache misses:       {d:>8}                     ║\n", .{self.cache_misses});
        std.debug.print("║ Hit rate:           {d:>7.1}%                   ║\n", .{self.hitRate() * 100});
        std.debug.print("║ Cache stores:       {d:>8}                     ║\n", .{self.cache_stores});
        std.debug.print("║ Invalidations:      {d:>8}                     ║\n", .{self.cache_invalidations});
        std.debug.print("║ Evictions:          {d:>8}                     ║\n", .{self.cache_evictions});
        std.debug.print("║ Active entries:     {d:>8}                     ║\n", .{self.cache_entries});
        std.debug.print("║ Cache size:         {d:>8} MB                 ║\n", .{self.cache_size_mb});
        std.debug.print("╚════════════════════════════════════════════════╝\n", .{});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "cache key generation" {
    const source = "const std = @import(\"std\");";
    const deps = [_]CacheHash{};
    const version = "0.1.0";
    const flags = "-O3";

    const key1 = generateCacheKey(source, &deps, version, flags);
    const key2 = generateCacheKey(source, &deps, version, flags);

    try std.testing.expectEqual(key1, key2);

    // Different source should give different key
    const different_source = "const std = @import(\"basics\");";
    const key3 = generateCacheKey(different_source, &deps, version, flags);

    try std.testing.expect(!std.mem.eql(u8, &key1, &key3));
}

test "hash to hex conversion" {
    const hash = [_]u8{0xDE, 0xAD, 0xBE, 0xEF} ++ [_]u8{0} ** 28;
    var buf: [64]u8 = undefined;
    const hex = hashToHex(hash, &buf);

    try std.testing.expect(std.mem.startsWith(u8, hex, "deadbeef"));
}

test "cache operations" {
    const allocator = std.testing.allocator;

    var cache = try IRCache.init(allocator, ".test_cache", true);
    defer cache.deinit();
    defer std.fs.cwd().deleteTree(".test_cache") catch {};

    const source = "test source";
    const deps = [_]CacheHash{};
    const key = generateCacheKey(source, &deps, "1.0", "");

    // Cache miss initially
    try std.testing.expect(cache.get(key) == null);

    // Store in cache
    try cache.put(
        key,
        "test_module",
        "test.zig",
        0,
        &deps,
        "IR content",
        "object content",
        100,
    );

    // Cache hit
    const entry = cache.get(key);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("test_module", entry.?.module_name);
}
