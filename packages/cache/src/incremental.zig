const std = @import("std");
const Io = std.Io;

/// Incremental compilation manager.
/// Tracks source fingerprints, dependency invalidation, and artifact metadata.
pub const IncrementalCompiler = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    modules: std.StringHashMap(ModuleInfo),
    /// Maps a dependency path to the modules that depend on it. Keys and list
    /// entries are owned independently from `modules`.
    dependency_graph: std.StringHashMap(std.ArrayList([]const u8)),

    pub const ModuleInfo = struct {
        path: []const u8,
        fingerprint: [32]u8,
        last_modified: i96,
        dependencies: []const []const u8,
        artifacts: ArtifactInfo,

        pub const ArtifactInfo = struct {
            ir_path: ?[]const u8 = null,
            object_path: ?[]const u8 = null,
            metadata_path: ?[]const u8 = null,
        };
    };

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8, io: Io) !IncrementalCompiler {
        try Io.Dir.cwd().createDirPath(io, cache_dir);

        return .{
            .allocator = allocator,
            .io = io,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .modules = std.StringHashMap(ModuleInfo).init(allocator),
            .dependency_graph = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
        };
    }

    pub fn deinit(self: *IncrementalCompiler) void {
        var module_it = self.modules.iterator();
        while (module_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.deinitModuleInfo(entry.value_ptr);
        }
        self.modules.deinit();

        var dep_it = self.dependency_graph.iterator();
        while (dep_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dependent| self.allocator.free(dependent);
            entry.value_ptr.deinit(self.allocator);
        }
        self.dependency_graph.deinit();
        self.allocator.free(self.cache_dir);
    }

    fn deinitArtifacts(self: *IncrementalCompiler, artifacts: *ModuleInfo.ArtifactInfo) void {
        if (artifacts.ir_path) |path| self.allocator.free(path);
        if (artifacts.object_path) |path| self.allocator.free(path);
        if (artifacts.metadata_path) |path| self.allocator.free(path);
    }

    fn deinitModuleInfo(self: *IncrementalCompiler, info: *ModuleInfo) void {
        self.allocator.free(info.path);
        for (info.dependencies) |dependency| self.allocator.free(dependency);
        self.allocator.free(info.dependencies);
        self.deinitArtifacts(&info.artifacts);
    }

    fn cloneOptionalPath(self: *IncrementalCompiler, path: ?[]const u8) !?[]const u8 {
        return if (path) |value| try self.allocator.dupe(u8, value) else null;
    }

    fn cloneArtifacts(self: *IncrementalCompiler, artifacts: ModuleInfo.ArtifactInfo) !ModuleInfo.ArtifactInfo {
        var result: ModuleInfo.ArtifactInfo = .{};
        errdefer self.deinitArtifacts(&result);
        result.ir_path = try self.cloneOptionalPath(artifacts.ir_path);
        result.object_path = try self.cloneOptionalPath(artifacts.object_path);
        result.metadata_path = try self.cloneOptionalPath(artifacts.metadata_path);
        return result;
    }

    fn cloneDependencies(self: *IncrementalCompiler, dependencies: []const []const u8) ![]const []const u8 {
        const result = try self.allocator.alloc([]const u8, dependencies.len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |dependency| self.allocator.free(dependency);
            self.allocator.free(result);
        }
        for (dependencies, 0..) |dependency, index| {
            result[index] = try self.allocator.dupe(u8, dependency);
            initialized += 1;
        }
        return result;
    }

    /// Compute a content-based fingerprint for a source file.
    pub fn computeFingerprint(self: *IncrementalCompiler, file_path: []const u8) ![32]u8 {
        const content = try Io.Dir.cwd().readFileAlloc(
            self.io,
            file_path,
            self.allocator,
            .limited(10 * 1024 * 1024),
        );
        defer self.allocator.free(content);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(content);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }

    /// Check whether a source, any transitive dependency, or its artifact has
    /// changed. Dependency cycles are visited once rather than recursing forever.
    pub fn needsRecompilation(self: *IncrementalCompiler, file_path: []const u8) !bool {
        var visiting = std.StringHashMap(void).init(self.allocator);
        defer visiting.deinit();
        return self.needsRecompilationInner(file_path, &visiting);
    }

    fn needsRecompilationInner(
        self: *IncrementalCompiler,
        file_path: []const u8,
        visiting: *std.StringHashMap(void),
    ) !bool {
        const info = self.modules.get(file_path) orelse return true;
        const visit = try visiting.getOrPut(file_path);
        if (visit.found_existing) return false;
        defer _ = visiting.remove(file_path);

        const fingerprint = try self.computeFingerprint(file_path);
        if (!std.mem.eql(u8, &info.fingerprint, &fingerprint)) return true;

        for (info.dependencies) |dependency| {
            if (try self.needsRecompilationInner(dependency, visiting)) return true;
        }

        const artifact_path = info.artifacts.ir_path orelse info.artifacts.object_path orelse return true;
        _ = Io.Dir.cwd().statFile(self.io, artifact_path, .{}) catch return true;
        return false;
    }

    fn addDependent(self: *IncrementalCompiler, dependency: []const u8, module_path: []const u8) !void {
        const entry = try self.dependency_graph.getOrPut(dependency);
        if (!entry.found_existing) {
            const key = self.allocator.dupe(u8, dependency) catch |err| {
                _ = self.dependency_graph.remove(dependency);
                return err;
            };
            entry.key_ptr.* = key;
            entry.value_ptr.* = .empty;
        }
        for (entry.value_ptr.items) |dependent| {
            if (std.mem.eql(u8, dependent, module_path)) return;
        }

        const dependent = self.allocator.dupe(u8, module_path) catch |err| {
            if (!entry.found_existing) {
                const removed = self.dependency_graph.fetchRemove(dependency).?;
                self.allocator.free(removed.key);
                var list = removed.value;
                list.deinit(self.allocator);
            }
            return err;
        };
        entry.value_ptr.append(self.allocator, dependent) catch |err| {
            self.allocator.free(dependent);
            if (!entry.found_existing) {
                const removed = self.dependency_graph.fetchRemove(dependency).?;
                self.allocator.free(removed.key);
                var list = removed.value;
                list.deinit(self.allocator);
            }
            return err;
        };
    }

    fn removeDependent(self: *IncrementalCompiler, dependency: []const u8, module_path: []const u8) void {
        const dependents = self.dependency_graph.getPtr(dependency) orelse return;
        for (dependents.items, 0..) |dependent, index| {
            if (std.mem.eql(u8, dependent, module_path)) {
                self.allocator.free(dependent);
                _ = dependents.orderedRemove(index);
                break;
            }
        }
        if (dependents.items.len == 0) {
            const removed = self.dependency_graph.fetchRemove(dependency).?;
            self.allocator.free(removed.key);
            var list = removed.value;
            list.deinit(self.allocator);
        }
    }

    fn removeModule(self: *IncrementalCompiler, file_path: []const u8) void {
        const removed = self.modules.fetchRemove(file_path) orelse return;
        for (removed.value.dependencies) |dependency| self.removeDependent(dependency, file_path);
        self.allocator.free(removed.key);
        var info = removed.value;
        self.deinitModuleInfo(&info);
    }

    /// Register or atomically replace a compiled module and its dependency
    /// edges. All caller-provided strings are copied.
    pub fn registerModule(
        self: *IncrementalCompiler,
        file_path: []const u8,
        dependencies: []const []const u8,
        artifacts: ModuleInfo.ArtifactInfo,
    ) !void {
        const fingerprint = try self.computeFingerprint(file_path);
        const stat = try Io.Dir.cwd().statFile(self.io, file_path, .{});

        var module_inserted = false;
        const map_key = try self.allocator.dupe(u8, file_path);
        errdefer if (!module_inserted) self.allocator.free(map_key);
        const path = try self.allocator.dupe(u8, file_path);
        errdefer if (!module_inserted) self.allocator.free(path);
        const dependency_copies = try self.cloneDependencies(dependencies);
        errdefer if (!module_inserted) {
            for (dependency_copies) |dependency| self.allocator.free(dependency);
            self.allocator.free(dependency_copies);
        };
        var artifact_copies = try self.cloneArtifacts(artifacts);
        errdefer if (!module_inserted) self.deinitArtifacts(&artifact_copies);

        self.removeModule(file_path);
        try self.modules.put(map_key, .{
            .path = path,
            .fingerprint = fingerprint,
            .last_modified = stat.mtime.nanoseconds,
            .dependencies = dependency_copies,
            .artifacts = artifact_copies,
        });
        module_inserted = true;

        for (dependencies) |dependency| {
            self.addDependent(dependency, file_path) catch |err| {
                self.removeModule(file_path);
                return err;
            };
        }
    }

    /// Invalidate a module and every module that depends on it.
    pub fn invalidate(self: *IncrementalCompiler, file_path: []const u8) !void {
        var dependent_copies: std.ArrayList([]const u8) = .empty;
        defer {
            for (dependent_copies.items) |dependent| self.allocator.free(dependent);
            dependent_copies.deinit(self.allocator);
        }

        if (self.dependency_graph.get(file_path)) |dependents| {
            for (dependents.items) |dependent| {
                const copy = try self.allocator.dupe(u8, dependent);
                dependent_copies.append(self.allocator, copy) catch |err| {
                    self.allocator.free(copy);
                    return err;
                };
            }
        }

        if (self.modules.get(file_path)) |info| self.deleteArtifacts(info.artifacts);
        self.removeModule(file_path);
        if (self.dependency_graph.fetchRemove(file_path)) |removed| {
            self.allocator.free(removed.key);
            var dependents = removed.value;
            for (dependents.items) |dependent| self.allocator.free(dependent);
            dependents.deinit(self.allocator);
        }

        for (dependent_copies.items) |dependent| try self.invalidate(dependent);
    }

    pub fn getCachedArtifacts(self: *IncrementalCompiler, file_path: []const u8) ?ModuleInfo.ArtifactInfo {
        return if (self.modules.get(file_path)) |info| info.artifacts else null;
    }

    pub fn loadMetadata(self: *IncrementalCompiler, file_path: []const u8) !?[]const u8 {
        const metadata_path = try self.getMetadataPath(file_path);
        defer self.allocator.free(metadata_path);
        return Io.Dir.cwd().readFileAlloc(
            self.io,
            metadata_path,
            self.allocator,
            .limited(10 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |other| return other,
        };
    }

    pub fn saveMetadata(self: *IncrementalCompiler, file_path: []const u8, metadata: []const u8) !void {
        const metadata_path = try self.getMetadataPath(file_path);
        defer self.allocator.free(metadata_path);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = metadata_path, .data = metadata });
    }

    fn getMetadataPath(self: *IncrementalCompiler, file_path: []const u8) ![]const u8 {
        const fingerprint = try self.computeFingerprint(file_path);
        var fingerprint_hex: [64]u8 = undefined;
        const digits = "0123456789abcdef";
        for (fingerprint, 0..) |byte, index| {
            fingerprint_hex[index * 2] = digits[byte >> 4];
            fingerprint_hex[index * 2 + 1] = digits[byte & 0x0f];
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.metadata", .{ self.cache_dir, fingerprint_hex });
    }

    fn artifactSize(self: *IncrementalCompiler, artifacts: ModuleInfo.ArtifactInfo) usize {
        var total: usize = 0;
        const paths = [_]?[]const u8{ artifacts.ir_path, artifacts.object_path, artifacts.metadata_path };
        for (paths) |maybe_path| {
            if (maybe_path) |path| {
                const stat = Io.Dir.cwd().statFile(self.io, path, .{}) catch continue;
                total = std.math.add(usize, total, @intCast(stat.size)) catch return std.math.maxInt(usize);
            }
        }
        return total;
    }

    fn deleteArtifacts(self: *IncrementalCompiler, artifacts: ModuleInfo.ArtifactInfo) void {
        const paths = [_]?[]const u8{ artifacts.ir_path, artifacts.object_path, artifacts.metadata_path };
        for (paths) |maybe_path| {
            if (maybe_path) |path| Io.Dir.cwd().deleteFile(self.io, path) catch {};
        }
    }

    /// Remove the oldest module artifacts until their combined size is at or
    /// below `max_size_mb`.
    pub fn cleanCache(self: *IncrementalCompiler, max_size_mb: usize) !void {
        const max_bytes = std.math.mul(usize, max_size_mb, 1024 * 1024) catch std.math.maxInt(usize);
        var entries: std.ArrayList(CacheEntry) = .empty;
        defer {
            for (entries.items) |entry| self.allocator.free(entry.path);
            entries.deinit(self.allocator);
        }

        var total_size: usize = 0;
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            const size = self.artifactSize(entry.value_ptr.artifacts);
            total_size = std.math.add(usize, total_size, size) catch std.math.maxInt(usize);
            const path = try self.allocator.dupe(u8, entry.key_ptr.*);
            entries.append(self.allocator, .{
                .path = path,
                .last_modified = entry.value_ptr.last_modified,
                .size = size,
            }) catch |err| {
                self.allocator.free(path);
                return err;
            };
        }
        if (total_size <= max_bytes) return;

        std.mem.sort(CacheEntry, entries.items, {}, CacheEntry.lessThan);
        for (entries.items) |entry| {
            if (total_size <= max_bytes) break;
            try self.invalidate(entry.path);
            total_size -|= entry.size;
        }
    }

    const CacheEntry = struct {
        path: []const u8,
        last_modified: i96,
        size: usize,

        fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
            return a.last_modified < b.last_modified;
        }
    };

    pub fn getStats(self: *IncrementalCompiler) Stats {
        return .{ .total_modules = self.modules.count(), .cached_modules = self.modules.count() };
    }

    pub const Stats = struct {
        total_modules: usize,
        cached_modules: usize,
    };
};
