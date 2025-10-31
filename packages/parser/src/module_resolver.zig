const std = @import("std");
const ast = @import("ast");

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

    pub fn init(allocator: std.mem.Allocator) !ModuleResolver {
        // Auto-detect Home packages directory
        const home_root = try getHomeRoot(allocator);
        defer allocator.free(home_root);

        var packages_path = std.ArrayList(u8){};
        try packages_path.appendSlice(allocator, home_root);
        try packages_path.appendSlice(allocator, "/packages");

        return .{
            .allocator = allocator,
            .module_cache = std.StringHashMap(ResolvedModule).init(allocator),
            .packages_root = try packages_path.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *ModuleResolver) void {
        var it = self.module_cache.valueIterator();
        while (it.next()) |module| {
            self.allocator.free(module.file_path);
        }
        self.module_cache.deinit();
        self.allocator.free(self.packages_root);
    }

    /// Resolve a module path to an actual file
    /// Examples:
    ///   basics/os/serial → /Users/.../home/packages/basics/src/os/serial.zig
    ///   myapp/utils → ./myapp/utils.home
    pub fn resolve(self: *ModuleResolver, path_segments: []const []const u8) ModuleError!ResolvedModule {
        // Create cache key
        const cache_key = try self.pathKey(path_segments);
        defer self.allocator.free(cache_key);

        // Check cache
        if (self.module_cache.get(cache_key)) |cached| {
            return cached;
        }

        // Try resolving as standard library module
        if (try self.resolveStdLib(path_segments)) |module| {
            try self.module_cache.put(cache_key, module);
            return module;
        }

        // Try resolving as local module
        if (try self.resolveLocal(path_segments)) |module| {
            try self.module_cache.put(cache_key, module);
            return module;
        }

        return error.ModuleNotFound;
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
        var path_buf = std.ArrayList(u8){};
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
        var path_buf = std.ArrayList(u8){};
        defer path_buf.deinit(self.allocator);

        for (path_segments, 0..) |segment, i| {
            if (i > 0) try path_buf.append(self.allocator, '/');
            try path_buf.appendSlice(self.allocator, segment);
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

    /// Check if file exists
    fn fileExists(self: *ModuleResolver, path: []const u8) !bool {
        _ = self;
        std.fs.cwd().access(path, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        return true;
    }

    /// Create cache key from path segments
    fn pathKey(self: *ModuleResolver, segments: []const []const u8) ![]const u8 {
        var key = std.ArrayList(u8){};
        for (segments, 0..) |segment, i| {
            if (i > 0) try key.append(self.allocator, '/');
            try key.appendSlice(self.allocator, segment);
        }
        return key.toOwnedSlice(self.allocator);
    }

    /// Auto-detect Home root directory
    fn getHomeRoot(allocator: std.mem.Allocator) ![]const u8 {
        // Try environment variable first
        if (std.process.getEnvVarOwned(allocator, "HOME_ROOT")) |home_root| {
            return home_root;
        } else |_| {}

        // Try to find it relative to the current executable
        const self_exe_path = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(self_exe_path);

        // Assume Home executable is in ~/Code/home/zig-out/bin/home
        // So go up to ~/Code/home
        var path_buf = std.ArrayList(u8){};
        try path_buf.appendSlice(allocator, self_exe_path);
        try path_buf.appendSlice(allocator, "/../..");

        const normalized = try std.fs.realpathAlloc(allocator, path_buf.items);
        path_buf.deinit(allocator);

        return normalized;
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
