const std = @import("std");

/// Package manager for Ion
pub const PackageManager = struct {
    allocator: std.mem.Allocator,
    config: *PackageConfig,
    lock_file: ?*LockFile,
    cache_dir: []const u8,
    registry_url: []const u8,

    pub const DEFAULT_REGISTRY = "https://packages.ion-lang.org";
    pub const DEFAULT_CACHE_DIR = ".ion/cache";

    pub fn init(allocator: std.mem.Allocator) !*PackageManager {
        const pm = try allocator.create(PackageManager);

        // Load ion.toml
        const config = try PackageConfig.load(allocator, "ion.toml");

        pm.* = .{
            .allocator = allocator,
            .config = config,
            .lock_file = null,
            .cache_dir = DEFAULT_CACHE_DIR,
            .registry_url = DEFAULT_REGISTRY,
        };

        // Try to load lockfile
        pm.lock_file = LockFile.load(allocator, "ion.lock") catch null;

        return pm;
    }

    pub fn deinit(self: *PackageManager) void {
        self.config.deinit();
        if (self.lock_file) |lock| {
            lock.deinit();
        }
        self.allocator.destroy(self);
    }

    /// Add a dependency to ion.toml
    pub fn addDependency(self: *PackageManager, name: []const u8, version: []const u8) !void {
        const dep = Dependency{
            .name = name,
            .version = try self.parseVersion(version),
            .source = .{ .Registry = self.registry_url },
        };

        try self.config.dependencies.append(dep);
        try self.config.save("ion.toml");

        // Resolve and download
        try self.resolve();
    }

    /// Add a dependency from Git
    pub fn addGitDependency(self: *PackageManager, name: []const u8, url: []const u8, rev: ?[]const u8) !void {
        const dep = Dependency{
            .name = name,
            .version = Version{ .git = rev },
            .source = .{ .Git = .{ .url = url, .rev = rev } },
        };

        try self.config.dependencies.append(dep);
        try self.config.save("ion.toml");

        try self.resolve();
    }

    /// Remove a dependency
    pub fn removeDependency(self: *PackageManager, name: []const u8) !void {
        var i: usize = 0;
        while (i < self.config.dependencies.items.len) {
            if (std.mem.eql(u8, self.config.dependencies.items[i].name, name)) {
                _ = self.config.dependencies.orderedRemove(i);
                break;
            }
            i += 1;
        }

        try self.config.save("ion.toml");
        try self.resolve();
    }

    /// Resolve all dependencies
    pub fn resolve(self: *PackageManager) !void {
        std.debug.print("Resolving dependencies...\n", .{});

        var resolver = DependencyResolver.init(self.allocator);
        defer resolver.deinit();

        // Build dependency graph
        for (self.config.dependencies.items) |dep| {
            try resolver.addDependency(dep);
        }

        // Resolve transitive dependencies
        const resolved = try resolver.resolve();
        defer self.allocator.free(resolved);

        // Create new lockfile
        if (self.lock_file) |old_lock| {
            old_lock.deinit();
        }

        self.lock_file = try LockFile.create(self.allocator, resolved);
        try self.lock_file.?.save("ion.lock");

        // Download packages
        try self.downloadAll();

        std.debug.print("✓ Resolved {} dependencies\n", .{resolved.len});
    }

    /// Update dependencies to latest versions
    pub fn update(self: *PackageManager) !void {
        std.debug.print("Updating dependencies...\n", .{});

        // Clear lockfile to force re-resolution
        if (self.lock_file) |lock| {
            lock.deinit();
            self.lock_file = null;
        }

        try self.resolve();
    }

    /// Download all dependencies
    fn downloadAll(self: *PackageManager) !void {
        if (self.lock_file) |lock| {
            for (lock.packages.items) |pkg| {
                try self.downloadPackage(pkg);
            }
        }
    }

    /// Download a single package
    fn downloadPackage(self: *PackageManager, pkg: LockedPackage) !void {
        const pkg_dir = try std.fs.path.join(self.allocator, &[_][]const u8{
            self.cache_dir,
            pkg.name,
            pkg.version,
        });
        defer self.allocator.free(pkg_dir);

        // Check if already cached
        std.fs.cwd().access(pkg_dir, .{}) catch {
            std.debug.print("  → Downloading {s}@{s}...\n", .{ pkg.name, pkg.version });

            switch (pkg.source) {
                .Registry => try self.downloadFromRegistry(pkg, pkg_dir),
                .Git => |git| try self.downloadFromGit(git.url, git.rev, pkg_dir),
                .Local => |path| try self.copyLocal(path, pkg_dir),
            }

            std.debug.print("    ✓ Downloaded {s}@{s}\n", .{ pkg.name, pkg.version });
            return;
        };

        std.debug.print("  → Using cached {s}@{s}\n", .{ pkg.name, pkg.version });
    }

    fn downloadFromRegistry(self: *PackageManager, pkg: LockedPackage, dest: []const u8) !void {
        _ = self;
        _ = pkg;
        _ = dest;
        // Would use HTTP client to download from registry
        // For now, simulate download
        try std.fs.cwd().makePath(dest);
    }

    fn downloadFromGit(self: *PackageManager, url: []const u8, rev: ?[]const u8, dest: []const u8) !void {
        _ = self;

        // Clone git repository
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append("git");
        try args.append("clone");
        try args.append("--depth");
        try args.append("1");

        if (rev) |r| {
            try args.append("--branch");
            try args.append(r);
        }

        try args.append(url);
        try args.append(dest);

        // Execute git command (simplified)
        try std.fs.cwd().makePath(dest);
    }

    fn copyLocal(self: *PackageManager, src: []const u8, dest: []const u8) !void {
        _ = self;
        _ = src;
        _ = dest;
        // Copy local directory
        try std.fs.cwd().makePath(dest);
    }

    fn parseVersion(self: *PackageManager, version_str: []const u8) !Version {
        _ = self;
        // Parse semantic version
        return Version{ .semantic = .{ .major = 0, .minor = 1, .patch = 0 } };
    }
};

/// Package configuration from ion.toml
pub const PackageConfig = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    authors: [][]const u8,
    dependencies: std.ArrayList(Dependency),

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*PackageConfig {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Parse TOML (simplified - would use real TOML parser)
        const config = try allocator.create(PackageConfig);
        config.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, "myproject"),
            .version = try allocator.dupe(u8, "0.1.0"),
            .authors = &[_][]const u8{},
            .dependencies = std.ArrayList(Dependency).init(allocator),
        };

        return config;
    }

    pub fn deinit(self: *PackageConfig) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.dependencies.deinit();
        self.allocator.destroy(self);
    }

    pub fn save(self: *PackageConfig, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.print("[package]\n", .{});
        try writer.print("name = \"{s}\"\n", .{self.name});
        try writer.print("version = \"{s}\"\n", .{self.version});
        try writer.print("\n[dependencies]\n", .{});

        for (self.dependencies.items) |dep| {
            switch (dep.version) {
                .semantic => |sem| {
                    try writer.print("{s} = \"{d}.{d}.{d}\"\n", .{
                        dep.name,
                        sem.major,
                        sem.minor,
                        sem.patch,
                    });
                },
                .git => |rev| {
                    if (rev) |r| {
                        try writer.print("{s} = {{ git = \"{s}\", rev = \"{s}\" }}\n", .{
                            dep.name,
                            r,
                            r,
                        });
                    }
                },
            }
        }
    }
};

/// Dependency specification
pub const Dependency = struct {
    name: []const u8,
    version: Version,
    source: DependencySource,
};

pub const Version = union(enum) {
    semantic: SemanticVersion,
    git: ?[]const u8, // Git commit/tag/branch
};

pub const SemanticVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub const DependencySource = union(enum) {
    Registry: []const u8,
    Git: struct {
        url: []const u8,
        rev: ?[]const u8,
    },
    Local: []const u8,
};

/// Lock file (ion.lock) for reproducible builds
pub const LockFile = struct {
    allocator: std.mem.Allocator,
    version: u32,
    packages: std.ArrayList(LockedPackage),

    pub fn create(allocator: std.mem.Allocator, packages: []ResolvedPackage) !*LockFile {
        const lock = try allocator.create(LockFile);
        lock.* = .{
            .allocator = allocator,
            .version = 1,
            .packages = std.ArrayList(LockedPackage).init(allocator),
        };

        for (packages) |pkg| {
            try lock.packages.append(.{
                .name = pkg.name,
                .version = pkg.version,
                .checksum = pkg.checksum,
                .source = pkg.source,
            });
        }

        return lock;
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*LockFile {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(content);

        // Parse lockfile (simplified)
        const lock = try allocator.create(LockFile);
        lock.* = .{
            .allocator = allocator,
            .version = 1,
            .packages = std.ArrayList(LockedPackage).init(allocator),
        };

        return lock;
    }

    pub fn deinit(self: *LockFile) void {
        self.packages.deinit();
        self.allocator.destroy(self);
    }

    pub fn save(self: *LockFile, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.print("# This file is generated by ion pkg\n", .{});
        try writer.print("version = {d}\n\n", .{self.version});

        for (self.packages.items) |pkg| {
            try writer.print("[[package]]\n", .{});
            try writer.print("name = \"{s}\"\n", .{pkg.name});
            try writer.print("version = \"{s}\"\n", .{pkg.version});
            try writer.print("checksum = \"{s}\"\n", .{pkg.checksum});
            try writer.print("\n", .{});
        }
    }
};

pub const LockedPackage = struct {
    name: []const u8,
    version: []const u8,
    checksum: []const u8,
    source: DependencySource,
};

/// Dependency resolver
pub const DependencyResolver = struct {
    allocator: std.mem.Allocator,
    dependencies: std.ArrayList(Dependency),
    resolved: std.StringHashMap(ResolvedPackage),

    pub fn init(allocator: std.mem.Allocator) DependencyResolver {
        return .{
            .allocator = allocator,
            .dependencies = std.ArrayList(Dependency).init(allocator),
            .resolved = std.StringHashMap(ResolvedPackage).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyResolver) void {
        self.dependencies.deinit();
        self.resolved.deinit();
    }

    pub fn addDependency(self: *DependencyResolver, dep: Dependency) !void {
        try self.dependencies.append(dep);
    }

    pub fn resolve(self: *DependencyResolver) ![]ResolvedPackage {
        // Simple resolution (would implement proper algorithm)
        for (self.dependencies.items) |dep| {
            const version_str = switch (dep.version) {
                .semantic => |sem| try std.fmt.allocPrint(
                    self.allocator,
                    "{d}.{d}.{d}",
                    .{ sem.major, sem.minor, sem.patch },
                ),
                .git => |rev| rev orelse "HEAD",
            };

            try self.resolved.put(dep.name, .{
                .name = dep.name,
                .version = version_str,
                .checksum = "abc123", // Would compute actual checksum
                .source = dep.source,
            });
        }

        // Convert to slice
        var result = std.ArrayList(ResolvedPackage).init(self.allocator);
        var iter = self.resolved.iterator();
        while (iter.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }

        return result.toOwnedSlice();
    }
};

pub const ResolvedPackage = struct {
    name: []const u8,
    version: []const u8,
    checksum: []const u8,
    source: DependencySource,
};
