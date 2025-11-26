const std = @import("std");
const ast = @import("ast");
const types = @import("types");

/// Incremental compilation manager
/// Tracks compilation artifacts, dependencies, and invalidation
pub const IncrementalCompiler = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    modules: std.StringHashMap(ModuleInfo),
    dependency_graph: std.StringHashMap(std.ArrayList([]const u8)),

    pub const ModuleInfo = struct {
        path: []const u8,
        fingerprint: [32]u8, // SHA-256 hash of source content
        last_modified: i64,
        dependencies: []const []const u8,
        artifacts: ArtifactInfo,

        pub const ArtifactInfo = struct {
            ir_path: ?[]const u8 = null,
            object_path: ?[]const u8 = null,
            metadata_path: ?[]const u8 = null,
        };
    };

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8) !IncrementalCompiler {
        // Ensure cache directory exists
        std.fs.cwd().makeDir(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return .{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .modules = std.StringHashMap(ModuleInfo).init(allocator),
            .dependency_graph = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *IncrementalCompiler) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.path);
            self.allocator.free(entry.value_ptr.dependencies);
            if (entry.value_ptr.artifacts.ir_path) |path| {
                self.allocator.free(path);
            }
            if (entry.value_ptr.artifacts.object_path) |path| {
                self.allocator.free(path);
            }
            if (entry.value_ptr.artifacts.metadata_path) |path| {
                self.allocator.free(path);
            }
        }
        self.modules.deinit();

        var dep_it = self.dependency_graph.iterator();
        while (dep_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| {
                self.allocator.free(dep);
            }
            entry.value_ptr.deinit();
        }
        self.dependency_graph.deinit();

        self.allocator.free(self.cache_dir);
    }

    /// Compute content-based fingerprint (SHA-256) for a source file
    pub fn computeFingerprint(self: *IncrementalCompiler, file_path: []const u8) ![32]u8 {
        _ = self;
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(content);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(content);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        return hash;
    }

    /// Check if a module needs recompilation
    pub fn needsRecompilation(self: *IncrementalCompiler, file_path: []const u8) !bool {
        const current_fingerprint = try self.computeFingerprint(file_path);

        if (self.modules.get(file_path)) |module_info| {
            // Check if fingerprint changed
            if (!std.mem.eql(u8, &module_info.fingerprint, &current_fingerprint)) {
                return true;
            }

            // Check if any dependency changed
            for (module_info.dependencies) |dep_path| {
                if (try self.needsRecompilation(dep_path)) {
                    return true;
                }
            }

            // Check if artifacts exist
            if (module_info.artifacts.ir_path) |ir_path| {
                std.fs.cwd().access(ir_path, .{}) catch {
                    return true; // Artifact missing
                };
            } else {
                return true; // No artifacts cached
            }

            return false; // Module is up-to-date
        }

        return true; // Module not in cache
    }

    /// Register a compiled module
    pub fn registerModule(
        self: *IncrementalCompiler,
        file_path: []const u8,
        dependencies: []const []const u8,
        artifacts: ModuleInfo.ArtifactInfo,
    ) !void {
        const fingerprint = try self.computeFingerprint(file_path);
        const stat = try std.fs.cwd().statFile(file_path);

        const path_copy = try self.allocator.dupe(u8, file_path);

        var deps_copy = try self.allocator.alloc([]const u8, dependencies.len);
        for (dependencies, 0..) |dep, i| {
            deps_copy[i] = try self.allocator.dupe(u8, dep);
        }

        const module_info = ModuleInfo{
            .path = path_copy,
            .fingerprint = fingerprint,
            .last_modified = stat.mtime,
            .dependencies = deps_copy,
            .artifacts = artifacts,
        };

        try self.modules.put(path_copy, module_info);

        // Update dependency graph
        var dependents = try self.dependency_graph.getOrPut(path_copy);
        if (!dependents.found_existing) {
            dependents.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }
    }

    /// Invalidate a module and all its dependents
    pub fn invalidate(self: *IncrementalCompiler, file_path: []const u8) !void {
        // Remove from modules cache
        if (self.modules.fetchRemove(file_path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.path);
            for (entry.value.dependencies) |dep| {
                self.allocator.free(dep);
            }
            self.allocator.free(entry.value.dependencies);
            if (entry.value.artifacts.ir_path) |path| {
                self.allocator.free(path);
            }
            if (entry.value.artifacts.object_path) |path| {
                self.allocator.free(path);
            }
            if (entry.value.artifacts.metadata_path) |path| {
                self.allocator.free(path);
            }
        }

        // Invalidate all dependents recursively
        if (self.dependency_graph.get(file_path)) |dependents| {
            for (dependents.items) |dependent| {
                try self.invalidate(dependent);
            }
        }
    }

    /// Get cached artifact paths for a module
    pub fn getCachedArtifacts(self: *IncrementalCompiler, file_path: []const u8) ?ModuleInfo.ArtifactInfo {
        if (self.modules.get(file_path)) |module_info| {
            return module_info.artifacts;
        }
        return null;
    }

    /// Load cached metadata from disk
    pub fn loadMetadata(self: *IncrementalCompiler, file_path: []const u8) !?[]const u8 {
        if (self.modules.get(file_path)) |module_info| {
            if (module_info.artifacts.metadata_path) |metadata_path| {
                const file = std.fs.cwd().openFile(metadata_path, .{}) catch |err| {
                    if (err == error.FileNotFound) return null;
                    return err;
                };
                defer file.close();

                return try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
            }
        }
        return null;
    }

    /// Save metadata to disk
    pub fn saveMetadata(
        self: *IncrementalCompiler,
        file_path: []const u8,
        metadata: []const u8,
    ) !void {
        const metadata_path = try self.getMetadataPath(file_path);
        defer self.allocator.free(metadata_path);

        const file = try std.fs.cwd().createFile(metadata_path, .{});
        defer file.close();

        try file.writeAll(metadata);
    }

    /// Get path for metadata cache file
    fn getMetadataPath(self: *IncrementalCompiler, file_path: []const u8) ![]const u8 {
        const fingerprint = try self.computeFingerprint(file_path);
        var fingerprint_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&fingerprint_hex, "{s}", .{std.fmt.fmtSliceHexLower(&fingerprint)}) catch unreachable;

        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}.metadata",
            .{ self.cache_dir, fingerprint_hex },
        );
    }

    /// Clean old cache entries (LRU eviction)
    pub fn cleanCache(self: *IncrementalCompiler, max_size_mb: usize) !void {
        _ = max_size_mb;

        var entries = std.ArrayList(CacheEntry).init(self.allocator);
        defer entries.deinit();

        var it = self.modules.iterator();
        while (it.next()) |entry| {
            try entries.append(.{
                .path = entry.key_ptr.*,
                .last_modified = entry.value_ptr.last_modified,
            });
        }

        // Sort by last modified time (oldest first)
        std.mem.sort(CacheEntry, entries.items, {}, CacheEntry.lessThan);

        // TODO: Calculate total cache size and remove oldest entries until under limit
        // For now, just keep all entries
    }

    const CacheEntry = struct {
        path: []const u8,
        last_modified: i64,

        fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
            return a.last_modified < b.last_modified;
        }
    };

    /// Get compilation statistics
    pub fn getStats(self: *IncrementalCompiler) Stats {
        return .{
            .total_modules = self.modules.count(),
            .cached_modules = self.modules.count(),
        };
    }

    pub const Stats = struct {
        total_modules: usize,
        cached_modules: usize,
    };
};
