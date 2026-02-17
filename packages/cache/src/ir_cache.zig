const std = @import("std");
const Io = std.Io;

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
    io: ?Io = null,

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8, io: ?Io) !IRCache {
        // Ensure cache directory exists
        const io_val = io orelse return error.IoNotAvailable;
        Io.Dir.cwd().createDirPath(io_val, cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return .{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .cache = std.StringHashMap(*IR).init(allocator),
            .io = io,
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
        const io_val = self.io orelse return error.IoNotAvailable;
        const cache_path = try self.getCachePath(cache_key);
        defer self.allocator.free(cache_path);

        const file = try Io.Dir.cwd().createFile(io_val, cache_path, .{});
        defer file.close(io_val);

        // Write cache file format:
        // [source_hash: u64][timestamp: i64][ast_len: u64][type_len: u64][ast_data][type_data]
        try file.writeInt(u64, ir.source_hash, .little);
        try file.writeInt(i64, ir.timestamp, .little);
        try file.writeInt(u64, ir.ast_data.len, .little);
        try file.writeInt(u64, ir.type_info.len, .little);
        try file.writeStreamingAll(io_val, ir.ast_data);
        try file.writeStreamingAll(io_val, ir.type_info);
    }

    fn loadFromDisk(self: *IRCache, cache_key: []const u8) !*IR {
        const io_val = self.io orelse return error.IoNotAvailable;
        const cache_path = try self.getCachePath(cache_key);
        defer self.allocator.free(cache_path);

        const file = try Io.Dir.cwd().openFile(io_val, cache_path, .{});
        defer file.close(io_val);

        // Read metadata (4 x u64/i64 = 32 bytes)
        var metadata: [32]u8 = undefined;
        const metadata_read = try file.readPositionalAll(io_val, &metadata, 0);
        if (metadata_read < metadata.len) return error.UnexpectedEndOfFile;

        const source_hash = std.mem.readInt(u64, metadata[0..8], .little);
        const timestamp = std.mem.readInt(i64, metadata[8..16], .little);
        const ast_len = std.mem.readInt(u64, metadata[16..24], .little);
        const type_len = std.mem.readInt(u64, metadata[24..32], .little);

        const ast_data = try self.allocator.alloc(u8, ast_len);
        errdefer self.allocator.free(ast_data);
        const ast_read = try file.readPositionalAll(io_val, ast_data, 32);
        if (ast_read < ast_data.len) return error.UnexpectedEndOfFile;

        const type_info = try self.allocator.alloc(u8, type_len);
        errdefer self.allocator.free(type_info);
        const type_read = try file.readPositionalAll(io_val, type_info, 32 + ast_len);
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
        const io_val = self.io orelse return error.IoNotAvailable;
        var dir = try Io.Dir.cwd().openDir(io_val, self.cache_dir, .{ .iterate = true });
        defer dir.close(io_val);

        var it = dir.iterate();
        while (try it.next(io_val)) |entry| {
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

/// Compiled Output Cache for storing generated machine code
pub const CompiledCache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    dependency_graph: std.StringHashMap([]const []const u8),
    modified_times: std.StringHashMap(i128),
    io: ?Io = null,

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8, io: ?Io) !CompiledCache {
        // Ensure cache directory exists
        const io_val = io orelse return error.IoNotAvailable;
        Io.Dir.cwd().createDirPath(io_val, cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return .{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .dependency_graph = std.StringHashMap([]const []const u8).init(allocator),
            .modified_times = std.StringHashMap(i128).init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *CompiledCache) void {
        var dep_it = self.dependency_graph.iterator();
        while (dep_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |dep| {
                self.allocator.free(dep);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.dependency_graph.deinit();

        var time_it = self.modified_times.iterator();
        while (time_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.modified_times.deinit();

        self.allocator.free(self.cache_dir);
    }

    /// Check if a file needs recompilation
    pub fn needsRecompile(self: *CompiledCache, file_path: []const u8) !bool {
        const io_val = self.io orelse return error.IoNotAvailable;
        const obj_path = try self.getObjectPath(file_path);
        defer self.allocator.free(obj_path);

        // Check if object file exists
        const obj_stat = Io.Dir.cwd().statFile(io_val, obj_path, .{}) catch return true;

        // Check if source file is newer than object file
        const source_stat = Io.Dir.cwd().statFile(io_val, file_path, .{}) catch return true;

        // Use mtime for comparison (simple approach)
        const obj_mtime = obj_stat.mtime.nanoseconds;
        const src_mtime = source_stat.mtime.nanoseconds;

        // If source is newer than object, needs recompile
        if (src_mtime > obj_mtime) {
            return true;
        }

        // Check dependencies
        if (self.dependency_graph.get(file_path)) |deps| {
            for (deps) |dep| {
                const dep_stat = Io.Dir.cwd().statFile(io_val, dep, .{}) catch continue;
                if (dep_stat.mtime.nanoseconds > obj_mtime) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Store compiled object file
    pub fn storeObject(self: *CompiledCache, file_path: []const u8, object_data: []const u8) !void {
        const io_val = self.io orelse return error.IoNotAvailable;
        const obj_path = try self.getObjectPath(file_path);
        defer self.allocator.free(obj_path);

        try Io.Dir.cwd().writeFile(io_val, .{
            .sub_path = obj_path,
            .data = object_data,
        });
    }

    /// Load cached object file
    pub fn loadObject(self: *CompiledCache, file_path: []const u8) ![]const u8 {
        const io_val = self.io orelse return error.IoNotAvailable;
        const obj_path = try self.getObjectPath(file_path);
        defer self.allocator.free(obj_path);

        return try Io.Dir.cwd().readFileAlloc(io_val, obj_path, self.allocator, Io.Limit.unlimited);
    }

    /// Register file dependencies for incremental tracking
    pub fn registerDependencies(self: *CompiledCache, file_path: []const u8, deps: []const []const u8) !void {
        const key = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(key);

        var deps_copy = try self.allocator.alloc([]const u8, deps.len);
        errdefer self.allocator.free(deps_copy);

        for (deps, 0..) |dep, i| {
            deps_copy[i] = try self.allocator.dupe(u8, dep);
        }

        // Remove old entry if exists
        if (self.dependency_graph.fetchRemove(file_path)) |old| {
            self.allocator.free(old.key);
            for (old.value) |dep| {
                self.allocator.free(dep);
            }
            self.allocator.free(old.value);
        }

        try self.dependency_graph.put(key, deps_copy);
    }

    fn getObjectPath(self: *CompiledCache, file_path: []const u8) ![]const u8 {
        const basename = std.fs.path.basename(file_path);
        const hash = hashSource(file_path);
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}_{x}.o",
            .{ self.cache_dir, basename, hash },
        );
    }

    /// Get list of files that need recompilation
    pub fn getFilesToRecompile(self: *CompiledCache, files: []const []const u8) ![]const []const u8 {
        var to_recompile = std.ArrayList([]const u8).init(self.allocator);
        errdefer to_recompile.deinit();

        for (files) |file| {
            if (try self.needsRecompile(file)) {
                try to_recompile.append(try self.allocator.dupe(u8, file));
            }
        }

        return try to_recompile.toOwnedSlice();
    }
};

/// File watcher for hot reloading (uses polling for cross-platform support)
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watch_paths: std.StringHashMap(i96),
    callback: ?*const fn (path: []const u8) void,
    poll_interval_ms: u64,
    running: bool,
    io: ?Io = null,

    pub fn init(allocator: std.mem.Allocator, poll_interval_ms: u64, io: ?Io) FileWatcher {
        return .{
            .allocator = allocator,
            .watch_paths = std.StringHashMap(i96).init(allocator),
            .callback = null,
            .poll_interval_ms = poll_interval_ms,
            .running = false,
            .io = io,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        self.running = false;
        var it = self.watch_paths.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.watch_paths.deinit();
    }

    /// Add a file to watch
    pub fn watch(self: *FileWatcher, path: []const u8) !void {
        const mtime = try self.getModTime(path);
        const key = try self.allocator.dupe(u8, path);
        try self.watch_paths.put(key, mtime);
    }

    /// Remove a file from watch
    pub fn unwatch(self: *FileWatcher, path: []const u8) void {
        if (self.watch_paths.fetchRemove(path)) |old| {
            self.allocator.free(old.key);
        }
    }

    /// Set callback for file changes
    pub fn setCallback(self: *FileWatcher, callback: *const fn (path: []const u8) void) void {
        self.callback = callback;
    }

    /// Check for changes once (non-blocking)
    pub fn checkOnce(self: *FileWatcher) ![]const []const u8 {
        var changed = std.ArrayList([]const u8).init(self.allocator);
        errdefer changed.deinit();

        var it = self.watch_paths.iterator();
        while (it.next()) |entry| {
            const current_mtime = self.getModTime(entry.key_ptr.*) catch continue;
            if (current_mtime != entry.value_ptr.*) {
                entry.value_ptr.* = current_mtime;
                try changed.append(try self.allocator.dupe(u8, entry.key_ptr.*));

                if (self.callback) |cb| {
                    cb(entry.key_ptr.*);
                }
            }
        }

        return try changed.toOwnedSlice();
    }

    fn getModTime(self: *FileWatcher, path: []const u8) !i96 {
        const io_val = self.io orelse return error.IoNotAvailable;
        const stat = try Io.Dir.cwd().statFile(io_val, path, .{});
        return stat.mtime.nanoseconds;
    }
};

/// Incremental Compilation Manager - coordinates all caching and recompilation
pub const IncrementalCompiler = struct {
    allocator: std.mem.Allocator,
    ir_cache: IRCache,
    compiled_cache: CompiledCache,
    file_watcher: ?FileWatcher,
    verbose: bool,
    io: ?Io = null,

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8, enable_watch: bool, io: ?Io) !IncrementalCompiler {
        return .{
            .allocator = allocator,
            .ir_cache = try IRCache.init(allocator, cache_dir, io),
            .compiled_cache = try CompiledCache.init(allocator, cache_dir, io),
            .file_watcher = if (enable_watch) FileWatcher.init(allocator, 100, io) else null,
            .verbose = false,
            .io = io,
        };
    }

    pub fn deinit(self: *IncrementalCompiler) void {
        self.ir_cache.deinit();
        self.compiled_cache.deinit();
        if (self.file_watcher) |*w| w.deinit();
    }

    /// Check if a file can use cached compilation
    pub fn canUseCached(self: *IncrementalCompiler, file_path: []const u8, source: []const u8) !bool {
        // First check IR cache
        if (!try self.ir_cache.isCacheValid(file_path, source)) {
            return false;
        }

        // Then check if object file needs recompile
        if (try self.compiled_cache.needsRecompile(file_path)) {
            return false;
        }

        return true;
    }

    /// Get cached object or null if not available
    pub fn getCachedObject(self: *IncrementalCompiler, file_path: []const u8) !?[]const u8 {
        if (try self.compiled_cache.needsRecompile(file_path)) {
            return null;
        }
        return self.compiled_cache.loadObject(file_path) catch null;
    }

    /// Store compilation results
    pub fn storeCompilation(
        self: *IncrementalCompiler,
        file_path: []const u8,
        source: []const u8,
        ast_data: []const u8,
        type_info: []const u8,
        object_data: []const u8,
        dependencies: []const []const u8,
    ) !void {
        try self.ir_cache.put(file_path, source, ast_data, type_info);
        try self.compiled_cache.storeObject(file_path, object_data);
        try self.compiled_cache.registerDependencies(file_path, dependencies);
    }

    /// Enable file watching for hot reload
    pub fn enableWatch(self: *IncrementalCompiler, file_path: []const u8) !void {
        if (self.file_watcher) |*w| {
            try w.watch(file_path);
        }
    }

    /// Check for changed files (for hot reload)
    pub fn getChangedFiles(self: *IncrementalCompiler) ![]const []const u8 {
        if (self.file_watcher) |*w| {
            return try w.checkOnce();
        }
        return &[_][]const u8{};
    }

    /// Clear all caches
    pub fn clearAll(self: *IncrementalCompiler) !void {
        const io_val = self.io orelse return error.IoNotAvailable;
        try self.ir_cache.clear();
        // Also clear compiled objects
        var dir = Io.Dir.cwd().openDir(io_val, self.compiled_cache.cache_dir, .{ .iterate = true }) catch return;
        defer dir.close(io_val);

        var it = dir.iterate();
        while (try it.next(io_val)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".o")) {
                dir.deleteFile(entry.name) catch {};
            }
        }
    }
};
