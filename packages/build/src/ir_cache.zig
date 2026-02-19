// Home Programming Language - Aggressive IR Cache
// Content-addressed caching with dependency tracking

const std = @import("std");
const crypto = std.crypto;
const fs = std.fs;
const Io = std.Io;

// Zig 0.16 compatibility: std.time.Instant was removed
fn getTimestamp() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec));
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
// JSON Serialization Types
// ============================================================================

/// JSON representation of cache entry
const EntryJson = struct {
    key: []const u8,
    module_name: []const u8,
    source_path: []const u8,
    source_mtime: i128,
    dependencies: []const []const u8,
    ir_path: []const u8,
    object_path: []const u8,
    created_at: i64,
    last_accessed: i64,
    hit_count: u32,
    compile_time_ms: i64,
};

/// JSON representation of cache stats
const StatsJson = struct {
    cache_hits: u64,
    cache_misses: u64,
    cache_stores: u64,
    cache_invalidations: u64,
    cache_evictions: u64,
};

/// JSON metadata file format
const MetadataJson = struct {
    version: u32,
    entries: []const EntryJson,
    stats: StatsJson,
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
    io: ?Io,

    const METADATA_FILE = "cache_metadata.json";
    const DEFAULT_MAX_SIZE_MB = 1024; // 1GB

    pub fn init(
        allocator: std.mem.Allocator,
        cache_dir: []const u8,
        aggressive: bool,
        io: ?Io,
    ) !IRCache {
        // Create cache directory
        if (io) |io_val| {
            Io.Dir.cwd().createDirPath(io_val, cache_dir) catch {};
        }

        const metadata_path = try fs.path.join(allocator, &[_][]const u8{ cache_dir, METADATA_FILE });

        var cache = IRCache{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .metadata_file = metadata_path,
            .entries = std.AutoHashMap(CacheHash, CacheEntry).init(allocator),
            .stats = CacheStats{},
            .max_cache_size_mb = DEFAULT_MAX_SIZE_MB,
            .aggressive_mode = aggressive,
            .io = io,
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
    pub fn isSourceModified(self: *IRCache, source_path: []const u8, cached_mtime: i128) !bool {
        const io_val = self.io orelse return error.IoNotAvailable;
        const file = try Io.Dir.cwd().openFile(io_val, source_path, .{});
        defer file.close(io_val);

        const stat = try file.stat(io_val);
        return stat.mtime != cached_mtime;
    }

    /// Invalidate cache entry
    pub fn invalidate(self: *IRCache, key: CacheHash) !void {
        if (self.entries.fetchRemove(key)) |entry| {
            // Delete cached files
            if (self.io) |io_val| {
                Io.Dir.cwd().deleteFile(io_val, entry.value.ir_path) catch {};
                Io.Dir.cwd().deleteFile(io_val, entry.value.object_path) catch {};
            }

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
            if (self.io) |io_val| {
                Io.Dir.cwd().deleteFile(io_val, entry.value_ptr.ir_path) catch {};
                Io.Dir.cwd().deleteFile(io_val, entry.value_ptr.object_path) catch {};
            }

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
        const io_val = self.io orelse return error.IoNotAvailable;
        const file = try Io.Dir.cwd().openFile(io_val, path, .{});
        defer file.close(io_val);
        const stat = try file.stat(io_val);
        return stat.size;
    }

    fn fileExists(self: *IRCache, path: []const u8) bool {
        const io_val = self.io orelse return false;
        Io.Dir.cwd().access(io_val, path, .{}) catch return false;
        return true;
    }

    fn writeFile(self: *IRCache, path: []const u8, content: []const u8) !void {
        const io_val = self.io orelse return error.IoNotAvailable;
        const file = try Io.Dir.cwd().createFile(io_val, path, .{});
        defer file.close(io_val);
        try file.writeStreamingAll(io_val, content);
    }

    fn loadMetadata(self: *IRCache) !void {
        const io_val = self.io orelse return error.IoNotAvailable;
        const data = Io.Dir.cwd().readFileAlloc(io_val, self.metadata_file, self.allocator, .limited(100 * 1024 * 1024)) catch |err| {
            // If file doesn't exist, start with empty cache
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(data);

        // Parse JSON metadata
        const parsed = std.json.parseFromSlice(
            MetadataJson,
            self.allocator,
            data,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("Warning: Failed to parse cache metadata: {}\n", .{err});
            return;
        };
        defer parsed.deinit();

        const metadata = parsed.value;

        // Restore cache entries
        for (metadata.entries) |entry_json| {
            // Parse cache hash from hex string
            var cache_hash: CacheHash = undefined;
            _ = std.fmt.hexToBytes(&cache_hash, entry_json.key) catch continue;

            // Parse dependency hashes
            var dependencies = try self.allocator.alloc(CacheHash, entry_json.dependencies.len);
            var dep_count: usize = 0;
            for (entry_json.dependencies) |dep_hex| {
                var dep_hash: CacheHash = undefined;
                if (std.fmt.hexToBytes(&dep_hash, dep_hex)) |_| {
                    dependencies[dep_count] = dep_hash;
                    dep_count += 1;
                } else |_| {}
            }
            const final_dependencies = dependencies[0..dep_count];

            const entry = CacheEntry{
                .key = cache_hash,
                .module_name = try self.allocator.dupe(u8, entry_json.module_name),
                .source_path = try self.allocator.dupe(u8, entry_json.source_path),
                .source_mtime = entry_json.source_mtime,
                .dependencies = try self.allocator.dupe(CacheHash, final_dependencies),
                .ir_path = try self.allocator.dupe(u8, entry_json.ir_path),
                .object_path = try self.allocator.dupe(u8, entry_json.object_path),
                .created_at = entry_json.created_at,
                .last_accessed = entry_json.last_accessed,
                .hit_count = @intCast(entry_json.hit_count),
                .compile_time_ms = entry_json.compile_time_ms,
            };

            self.allocator.free(dependencies);

            try self.entries.put(cache_hash, entry);
        }

        // Restore stats
        self.stats.cache_hits = metadata.stats.cache_hits;
        self.stats.cache_misses = metadata.stats.cache_misses;
        self.stats.cache_stores = metadata.stats.cache_stores;
        self.stats.cache_invalidations = metadata.stats.cache_invalidations;
        self.stats.cache_evictions = metadata.stats.cache_evictions;
    }

    fn saveMetadata(self: *IRCache) !void {
        const io_val = self.io orelse return error.IoNotAvailable;
        const file = try Io.Dir.cwd().createFile(io_val, self.metadata_file, .{});
        defer file.close(io_val);

        // Serialize entries to JSON
        const entry_count = self.entries.count();
        var entries_json_array = try self.allocator.alloc(EntryJson, entry_count);
        defer self.allocator.free(entries_json_array);

        var idx: usize = 0;
        var entry_iter = self.entries.iterator();
        while (entry_iter.next()) |kv| : (idx += 1) {
            const entry = kv.value_ptr.*;

            // Convert cache hash to hex string
            var key_buf: [64]u8 = undefined;
            const key_hex = hashToHex(entry.key, &key_buf);

            // Convert dependency hashes to hex strings
            const deps_hex = try self.allocator.alloc([]const u8, entry.dependencies.len);
            for (entry.dependencies, 0..) |dep_hash, dep_idx| {
                const dep_buf = try self.allocator.alloc(u8, 64);
                const dep_hex = hashToHex(dep_hash, dep_buf);
                deps_hex[dep_idx] = try self.allocator.dupe(u8, dep_hex);
            }

            entries_json_array[idx] = EntryJson{
                .key = try self.allocator.dupe(u8, key_hex),
                .module_name = entry.module_name,
                .source_path = entry.source_path,
                .source_mtime = entry.source_mtime,
                .dependencies = deps_hex,
                .ir_path = entry.ir_path,
                .object_path = entry.object_path,
                .created_at = entry.created_at,
                .last_accessed = entry.last_accessed,
                .hit_count = entry.hit_count,
                .compile_time_ms = entry.compile_time_ms,
            };
        }

        // Write JSON to file using simple manual JSON serialization
        // Format: { "version": 1, "entries": [...], "stats": {...} }

        try file.writeStreamingAll(io_val, "{");
        try file.writeStreamingAll(io_val, "\n  \"version\": 1,\n  \"entries\": [\n");

        // Write entries
        for (entries_json_array, 0..) |entry, i| {
            try file.writeStreamingAll(io_val, "    {\n");

            const key_line = try std.fmt.allocPrint(self.allocator, "      \"key\": \"{s}\",\n", .{entry.key});
            defer self.allocator.free(key_line);
            try file.writeStreamingAll(io_val, key_line);

            const module_line = try std.fmt.allocPrint(self.allocator, "      \"module_name\": \"{s}\",\n", .{entry.module_name});
            defer self.allocator.free(module_line);
            try file.writeStreamingAll(io_val, module_line);

            const source_line = try std.fmt.allocPrint(self.allocator, "      \"source_path\": \"{s}\",\n", .{entry.source_path});
            defer self.allocator.free(source_line);
            try file.writeStreamingAll(io_val, source_line);

            const mtime_line = try std.fmt.allocPrint(self.allocator, "      \"source_mtime\": {},\n", .{entry.source_mtime});
            defer self.allocator.free(mtime_line);
            try file.writeStreamingAll(io_val, mtime_line);

            try file.writeStreamingAll(io_val, "      \"dependencies\": [");
            for (entry.dependencies, 0..) |dep, j| {
                const dep_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{dep});
                defer self.allocator.free(dep_str);
                try file.writeStreamingAll(io_val, dep_str);
                if (j < entry.dependencies.len - 1) try file.writeStreamingAll(io_val, ", ");
            }
            try file.writeStreamingAll(io_val, "],\n");

            const ir_line = try std.fmt.allocPrint(self.allocator, "      \"ir_path\": \"{s}\",\n", .{entry.ir_path});
            defer self.allocator.free(ir_line);
            try file.writeStreamingAll(io_val, ir_line);

            const obj_line = try std.fmt.allocPrint(self.allocator, "      \"object_path\": \"{s}\",\n", .{entry.object_path});
            defer self.allocator.free(obj_line);
            try file.writeStreamingAll(io_val, obj_line);

            const created_line = try std.fmt.allocPrint(self.allocator, "      \"created_at\": {},\n", .{entry.created_at});
            defer self.allocator.free(created_line);
            try file.writeStreamingAll(io_val, created_line);

            const accessed_line = try std.fmt.allocPrint(self.allocator, "      \"last_accessed\": {},\n", .{entry.last_accessed});
            defer self.allocator.free(accessed_line);
            try file.writeStreamingAll(io_val, accessed_line);

            const hits_line = try std.fmt.allocPrint(self.allocator, "      \"hit_count\": {},\n", .{entry.hit_count});
            defer self.allocator.free(hits_line);
            try file.writeStreamingAll(io_val, hits_line);

            const compile_line = try std.fmt.allocPrint(self.allocator, "      \"compile_time_ms\": {}\n", .{entry.compile_time_ms});
            defer self.allocator.free(compile_line);
            try file.writeStreamingAll(io_val, compile_line);

            try file.writeStreamingAll(io_val, "    }");
            if (i < entries_json_array.len - 1) try file.writeStreamingAll(io_val, ",");
            try file.writeStreamingAll(io_val, "\n");
        }

        try file.writeStreamingAll(io_val, "  ],\n  \"stats\": {\n");

        const hits_line = try std.fmt.allocPrint(self.allocator, "    \"cache_hits\": {},\n", .{self.stats.cache_hits});
        defer self.allocator.free(hits_line);
        try file.writeStreamingAll(io_val, hits_line);

        const misses_line = try std.fmt.allocPrint(self.allocator, "    \"cache_misses\": {},\n", .{self.stats.cache_misses});
        defer self.allocator.free(misses_line);
        try file.writeStreamingAll(io_val, misses_line);

        const stores_line = try std.fmt.allocPrint(self.allocator, "    \"cache_stores\": {},\n", .{self.stats.cache_stores});
        defer self.allocator.free(stores_line);
        try file.writeStreamingAll(io_val, stores_line);

        const inval_line = try std.fmt.allocPrint(self.allocator, "    \"cache_invalidations\": {},\n", .{self.stats.cache_invalidations});
        defer self.allocator.free(inval_line);
        try file.writeStreamingAll(io_val, inval_line);

        const evict_line = try std.fmt.allocPrint(self.allocator, "    \"cache_evictions\": {}\n", .{self.stats.cache_evictions});
        defer self.allocator.free(evict_line);
        try file.writeStreamingAll(io_val, evict_line);

        try file.writeStreamingAll(io_val, "  }\n}\n");
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
    const hash = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ++ [_]u8{0} ** 28;
    var buf: [64]u8 = undefined;
    const hex = hashToHex(hash, &buf);

    try std.testing.expect(std.mem.startsWith(u8, hex, "deadbeef"));
}

test "cache operations" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cache = try IRCache.init(allocator, ".test_cache", true, io);
    defer cache.deinit();
    defer Io.Dir.cwd().deleteTree(io, ".test_cache") catch {};

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
