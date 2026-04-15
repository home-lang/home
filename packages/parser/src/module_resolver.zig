const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const ast = @import("ast");
const Io = std.Io;

/// Module resolution error types
pub const ModuleError = error{
    ModuleNotFound,
    InvalidModulePath,
    CircularDependency,
} || std.mem.Allocator.Error || anyerror;

/// Resolved module information
pub const ResolvedModule = struct {
    /// Module path segments (e.g., ["basics", "os", "serial"])
    path: []const []const u8,
    /// Absolute file path to the module
    file_path: []const u8,
    /// Module name (last segment)
    name: []const u8,
    /// Is this a Zig module that needs FFI bridging?
    is_zig: bool,

    pub fn deinit(self: *ResolvedModule, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
    }
};

/// Smart module resolver with automatic path detection
pub const ModuleResolver = struct {
    allocator: std.mem.Allocator,
    /// Cache of resolved modules
    module_cache: std.StringHashMap(ResolvedModule),
    /// Home packages root directory
    packages_root: []const u8,
    /// Source file root directory (for resolving relative imports)
    source_root: ?[]const u8,
    /// Directory of the file currently being parsed. Used by the
    /// string-path import resolver so `../core/foo.home` is relative
    /// to the importer, not the project root.
    current_file_dir: ?[]const u8,
    /// I/O context for file system operations (null when io is not available)
    io: ?Io,

    pub fn init(allocator: std.mem.Allocator, io: ?Io) !ModuleResolver {
        // Auto-detect Home packages directory
        const packages_root = if (io) |io_val| blk: {
            const home_root = getHomeRoot(allocator, io_val) catch {
                break :blk try allocator.dupe(u8, "packages");
            };
            defer allocator.free(home_root);
            var packages_path = std.ArrayList(u8).empty;
            try packages_path.appendSlice(allocator, home_root);
            try packages_path.appendSlice(allocator, "/packages");
            break :blk try packages_path.toOwnedSlice(allocator);
        } else try allocator.dupe(u8, "packages");

        return .{
            .allocator = allocator,
            .module_cache = std.StringHashMap(ResolvedModule).init(allocator),
            .packages_root = packages_root,
            .source_root = null,
            .current_file_dir = null,
            .io = io,
        };
    }

    /// Set the source root directory based on the main source file being compiled
    pub fn setSourceRoot(self: *ModuleResolver, source_file: []const u8) !void {
        // Find the project root by looking for src/ directory or use file's parent
        var dir_path = std.ArrayList(u8).empty;
        defer dir_path.deinit(self.allocator);

        // Get the directory containing the source file
        if (std.mem.lastIndexOf(u8, source_file, "/")) |last_slash| {
            try dir_path.appendSlice(self.allocator, source_file[0..last_slash]);
        } else {
            try dir_path.appendSlice(self.allocator, ".");
        }

        // Record the file's own directory so string-path imports can
        // resolve `../foo` relative to the importing file. Allocate the
        // new value FIRST so a failed dupe doesn't leave current_file_dir
        // pointing at freed memory.
        const new_dir = try self.allocator.dupe(u8, dir_path.items);
        if (self.current_file_dir) |old| self.allocator.free(old);
        self.current_file_dir = new_dir;

        // Check if we're in a src/ directory and go up to project root
        const dir_str = dir_path.items;
        if (std.mem.endsWith(u8, dir_str, "/src") or std.mem.endsWith(u8, dir_str, "/src/math") or
            std.mem.indexOf(u8, dir_str, "/src/") != null)
        {
            // Find the project root (parent of src/). Allocate first so a
            // failed dupe doesn't leave source_root dangling.
            if (std.mem.indexOf(u8, dir_str, "/src")) |src_pos| {
                const new_root = try self.allocator.dupe(u8, dir_str[0..src_pos]);
                if (self.source_root) |old| self.allocator.free(old);
                self.source_root = new_root;
                return;
            }
        }

        // Use the file's directory as root
        if (self.source_root) |old| self.allocator.free(old);
        self.source_root = try dir_path.toOwnedSlice(self.allocator);
    }

    /// Set the source root directly (without extracting from a file path)
    pub fn setSourceRootDirect(self: *ModuleResolver, root: []const u8) !void {
        // Allocate first so a failed dupe doesn't leave source_root
        // pointing at freed memory.
        const new_root = try self.allocator.dupe(u8, root);
        if (self.source_root) |old| self.allocator.free(old);
        self.source_root = new_root;
    }

    pub fn deinit(self: *ModuleResolver) void {
        // Free all cached module file paths
        var value_it = self.module_cache.valueIterator();
        while (value_it.next()) |module| {
            self.allocator.free(module.file_path);
        }

        // Free all cache keys
        var key_it = self.module_cache.keyIterator();
        while (key_it.next()) |key| {
            self.allocator.free(key.*);
        }

        self.module_cache.deinit();
        self.allocator.free(self.packages_root);
        if (self.source_root) |root| self.allocator.free(root);
        if (self.current_file_dir) |dir| self.allocator.free(dir);
    }

    /// Resolve a module path to an actual file
    /// Examples:
    ///   basics/os/serial → /Users/.../home/packages/basics/src/os/serial.zig
    ///   myapp/utils → ./myapp/utils.home
    pub fn resolve(self: *ModuleResolver, path_segments: []const []const u8) ModuleError!ResolvedModule {
        // Create cache key
        const cache_key = try self.pathKey(path_segments);
        errdefer self.allocator.free(cache_key);

        // Check cache
        if (self.module_cache.get(cache_key)) |cached| {
            self.allocator.free(cache_key);
            return cached;
        }

        // String-path form: `import "../core/foundation.home" as foo`.
        // The parser hands this to us as a single segment containing a
        // relative or absolute file path. We resolve it against the
        // source file's directory rather than the package root.
        if (path_segments.len == 1 and isFilePathLike(path_segments[0])) {
            if (try self.resolveFilePath(path_segments)) |module| {
                errdefer self.allocator.free(module.file_path);
                try self.module_cache.put(cache_key, module);
                return module;
            }
        }

        // Try resolving as standard library module
        if (try self.resolveStdLib(path_segments)) |module| {
            errdefer self.allocator.free(module.file_path);
            try self.module_cache.put(cache_key, module);
            return module;
        }

        // Try resolving as local module
        if (try self.resolveLocal(path_segments)) |module| {
            errdefer self.allocator.free(module.file_path);
            try self.module_cache.put(cache_key, module);
            return module;
        }

        // Module not found - errdefer will free cache_key
        return error.ModuleNotFound;
    }

    /// Heuristic for string-path imports: the segment contains a `/`, a
    /// path-relative prefix (`./` or `../`), an absolute path, or ends in
    /// a known source extension.
    fn isFilePathLike(segment: []const u8) bool {
        if (segment.len == 0) return false;
        if (segment[0] == '/') return true;
        if (std.mem.startsWith(u8, segment, "./")) return true;
        if (std.mem.startsWith(u8, segment, "../")) return true;
        if (std.mem.indexOf(u8, segment, "/") != null) return true;
        if (std.mem.endsWith(u8, segment, ".home")) return true;
        if (std.mem.endsWith(u8, segment, ".hm")) return true;
        if (std.mem.endsWith(u8, segment, ".zig")) return true;
        return false;
    }

    /// Resolve an explicit file-path import against source_root (dir of
    /// the file doing the import).
    fn resolveFilePath(self: *ModuleResolver, path_segments: []const []const u8) !?ResolvedModule {
        const raw = path_segments[0];

        // Try as absolute path first.
        if (raw.len > 0 and raw[0] == '/') {
            if (try self.fileExists(raw)) {
                return ResolvedModule{
                    .path = path_segments,
                    .file_path = try self.allocator.dupe(u8, raw),
                    .name = basename(raw),
                    .is_zig = std.mem.endsWith(u8, raw, ".zig"),
                };
            }
            return null;
        }

        // Resolve against the importing file's own directory first,
        // then the project root, then cwd.
        const bases: [3]?[]const u8 = .{ self.current_file_dir, self.source_root, "." };
        for (bases) |base_opt| {
            const base = base_opt orelse continue;
            var path_buf = std.ArrayList(u8).empty;
            defer path_buf.deinit(self.allocator);
            try path_buf.appendSlice(self.allocator, base);
            if (base.len > 0 and base[base.len - 1] != '/') {
                try path_buf.append(self.allocator, '/');
            }
            try path_buf.appendSlice(self.allocator, raw);

            if (try self.fileExists(path_buf.items)) {
                return ResolvedModule{
                    .path = path_segments,
                    .file_path = try self.allocator.dupe(u8, path_buf.items),
                    .name = basename(raw),
                    .is_zig = std.mem.endsWith(u8, raw, ".zig"),
                };
            }
        }

        return null;
    }

    /// Resolve standard library module
    fn resolveStdLib(self: *ModuleResolver, path_segments: []const []const u8) !?ResolvedModule {
        if (path_segments.len == 0) return null;

        // Standard library modules start with a known package name
        const known_packages = [_][]const u8{ "basics", "std", "core" };
        const first_segment = path_segments[0];

        var is_stdlib = false;
        for (known_packages) |pkg| {
            if (std.mem.eql(u8, first_segment, pkg)) {
                is_stdlib = true;
                break;
            }
        }

        if (!is_stdlib) return null;

        // Build path: packages/{package}/src/{rest of path}
        var path_buf = std.ArrayList(u8).empty;
        defer path_buf.deinit(self.allocator);

        try path_buf.appendSlice(self.allocator, self.packages_root);
        try path_buf.append(self.allocator, '/');
        try path_buf.appendSlice(self.allocator, path_segments[0]);  // Package name
        try path_buf.appendSlice(self.allocator, "/src");

        // Add remaining path segments
        for (path_segments[1..]) |segment| {
            try path_buf.append(self.allocator, '/');
            try path_buf.appendSlice(self.allocator, segment);
        }

        // Try .zig extension first (for now, since basics/os/* are in Zig)
        const zig_path = try std.fmt.allocPrint(self.allocator, "{s}.zig", .{path_buf.items});
        defer self.allocator.free(zig_path);

        if (try self.fileExists(zig_path)) {
            return ResolvedModule{
                .path = path_segments,
                .file_path = try self.allocator.dupe(u8, zig_path),
                .name = path_segments[path_segments.len - 1],
                .is_zig = true,
            };
        }

        // Try .home extension
        const home_path = try std.fmt.allocPrint(self.allocator, "{s}.home", .{path_buf.items});
        defer self.allocator.free(home_path);

        if (try self.fileExists(home_path)) {
            return ResolvedModule{
                .path = path_segments,
                .file_path = try self.allocator.dupe(u8, home_path),
                .name = path_segments[path_segments.len - 1],
                .is_zig = false,
            };
        }

        // Try .hm extension
        const hm_path = try std.fmt.allocPrint(self.allocator, "{s}.hm", .{path_buf.items});
        defer self.allocator.free(hm_path);

        if (try self.fileExists(hm_path)) {
            return ResolvedModule{
                .path = path_segments,
                .file_path = try self.allocator.dupe(u8, hm_path),
                .name = path_segments[path_segments.len - 1],
                .is_zig = false,
            };
        }

        return null;
    }

    /// Resolve local/relative module
    fn resolveLocal(self: *ModuleResolver, path_segments: []const []const u8) !?ResolvedModule {
        // Build relative path
        var path_buf = std.ArrayList(u8).empty;
        defer path_buf.deinit(self.allocator);

        for (path_segments, 0..) |segment, i| {
            if (i > 0) try path_buf.append(self.allocator, '/');
            try path_buf.appendSlice(self.allocator, segment);
        }

        // Prefixes to search for local modules (current dir, src/, lib/)
        const search_prefixes = [_][]const u8{ "", "src/", "lib/" };

        // First, try searching relative to the source root (if set)
        if (self.source_root) |root| {
            for (search_prefixes) |prefix| {
                // Try .home extension
                const home_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.home", .{ root, prefix, path_buf.items });
                defer self.allocator.free(home_path);

                if (try self.fileExists(home_path)) {
                    return ResolvedModule{
                        .path = path_segments,
                        .file_path = try self.allocator.dupe(u8, home_path),
                        .name = path_segments[path_segments.len - 1],
                        .is_zig = false,
                    };
                }

                // Try .hm extension
                const hm_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.hm", .{ root, prefix, path_buf.items });
                defer self.allocator.free(hm_path);

                if (try self.fileExists(hm_path)) {
                    return ResolvedModule{
                        .path = path_segments,
                        .file_path = try self.allocator.dupe(u8, hm_path),
                        .name = path_segments[path_segments.len - 1],
                        .is_zig = false,
                    };
                }
            }
        }

        // Then try searching relative to current working directory
        for (search_prefixes) |prefix| {
            // Try .home extension
            const home_path = try std.fmt.allocPrint(self.allocator, "{s}{s}.home", .{ prefix, path_buf.items });
            defer self.allocator.free(home_path);

            if (try self.fileExists(home_path)) {
                return ResolvedModule{
                    .path = path_segments,
                    .file_path = try self.allocator.dupe(u8, home_path),
                    .name = path_segments[path_segments.len - 1],
                    .is_zig = false,
                };
            }

            // Try .hm extension
            const hm_path = try std.fmt.allocPrint(self.allocator, "{s}{s}.hm", .{ prefix, path_buf.items });
            defer self.allocator.free(hm_path);

            if (try self.fileExists(hm_path)) {
                return ResolvedModule{
                    .path = path_segments,
                    .file_path = try self.allocator.dupe(u8, hm_path),
                    .name = path_segments[path_segments.len - 1],
                    .is_zig = false,
                };
            }
        }

        return null;
    }

    /// Check if file exists. Falls back to libc `access()` when the Io
    /// context is null so the resolver works during early parse before
    /// g_io is plumbed through.
    fn fileExists(self: *ModuleResolver, path: []const u8) !bool {
        if (self.io) |io| {
            Io.Dir.cwd().access(io, path, .{}) catch |err| {
                if (err == error.FileNotFound) return false;
                return err;
            };
            return true;
        }
        // Sync fallback via libc access(F_OK).
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= buf.len) return false;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const rc = std.c.access(@ptrCast(&buf[0]), 0); // F_OK = 0
        return rc == 0;
    }

    /// Return the portion of `path` after its last `/`. Used to derive
    /// a module name from a file-path import.
    fn basename(path: []const u8) []const u8 {
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/') return path[i + 1 ..];
        }
        return path;
    }

    /// Create cache key from path segments
    fn pathKey(self: *ModuleResolver, segments: []const []const u8) ![]const u8 {
        var key = std.ArrayList(u8).empty;
        for (segments, 0..) |segment, i| {
            if (i > 0) try key.append(self.allocator, '/');
            try key.appendSlice(self.allocator, segment);
        }
        return key.toOwnedSlice(self.allocator);
    }

    /// Auto-detect Home root directory
    fn getHomeRoot(allocator: std.mem.Allocator, io: Io) ![]const u8 {
        // Try environment variable first (cross-platform)
        if (comptime native_os != .windows and native_os != .linux) {
            if (std.c.getenv("HOME_ROOT")) |home_root_c| {
                return try allocator.dupe(u8, std.mem.span(home_root_c));
            }
        }

        // Try to find it relative to the current executable
        const self_exe_path = try std.process.executableDirPathAlloc(io, allocator);
        defer allocator.free(self_exe_path);

        // Assume Home executable is in ~/Code/home/zig-out/bin/home
        // So go up to ~/Code/home
        var path_buf = std.ArrayList(u8).empty;
        try path_buf.appendSlice(allocator, self_exe_path);
        try path_buf.appendSlice(allocator, "/../..");

        // Resolve to absolute path
        var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try Io.Dir.realPathFileAbsolute(io, path_buf.items, &real_buf);
        path_buf.deinit(allocator);

        return try allocator.dupe(u8, real_buf[0..n]);
    }
};

// Tests
test "module resolver basics" {
    const allocator = std.testing.allocator;

    var resolver = try ModuleResolver.init(allocator);
    defer resolver.deinit();

    // Test that packages_root is set
    try std.testing.expect(resolver.packages_root.len > 0);
}

test "path key generation" {
    const allocator = std.testing.allocator;

    var resolver = try ModuleResolver.init(allocator);
    defer resolver.deinit();

    const segments = [_][]const u8{ "basics", "os", "serial" };
    const key = try resolver.pathKey(&segments);
    defer allocator.free(key);

    try std.testing.expectEqualStrings("basics/os/serial", key);
}
