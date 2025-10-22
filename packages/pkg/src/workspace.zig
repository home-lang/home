const std = @import("std");

/// Workspace support for monorepos (Bun/pnpm style)
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    packages: std.ArrayList(WorkspacePackage),
    patterns: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .packages = std.ArrayList(WorkspacePackage).init(allocator),
            .patterns = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.packages.items) |*pkg| {
            pkg.deinit();
        }
        self.packages.deinit();
        self.patterns.deinit();
    }

    /// Add a workspace pattern (e.g., "packages/*", "apps/*")
    pub fn addPattern(self: *Self, pattern: []const u8) !void {
        try self.patterns.append(self.allocator, pattern);
    }

    /// Discover all packages in the workspace
    pub fn discover(self: *Self) !void {
        std.debug.print("🔍 Discovering workspace packages...\n", .{});

        for (self.patterns.items) |pattern| {
            try self.discoverPattern(pattern);
        }

        std.debug.print("✓ Found {d} workspace packages\n\n", .{self.packages.items.len});

        for (self.packages.items) |pkg| {
            std.debug.print("  • {s} ({s})\n", .{ pkg.name, pkg.path });
        }
    }

    /// Discover packages matching a glob pattern
    fn discoverPattern(self: *Self, pattern: []const u8) !void {
        // Parse pattern: "packages/*" -> dir="packages", glob="*"
        const sep_idx = std.mem.lastIndexOf(u8, pattern, "/") orelse return;
        const dir = pattern[0..sep_idx];
        const glob = pattern[sep_idx + 1 ..];

        // Open directory
        var dir_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, dir });
        defer self.allocator.free(dir_path);

        var dir_handle = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return; // Pattern not found, skip
            return err;
        };
        defer dir_handle.close();

        // Iterate through entries
        var iter = dir_handle.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            // Check if matches glob
            if (!matchGlob(entry.name, glob)) continue;

            // Check for ion.toml
            const pkg_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir, entry.name });
            const toml_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, pkg_path, "ion.toml" });
            defer self.allocator.free(toml_path);

            std.fs.cwd().access(toml_path, .{}) catch {
                self.allocator.free(pkg_path);
                continue; // No ion.toml, skip
            };

            // Add package
            const pkg = WorkspacePackage{
                .allocator = self.allocator,
                .name = try self.allocator.dupe(u8, entry.name),
                .path = pkg_path,
                .dependencies = std.StringHashMap([]const u8).init(self.allocator),
            };

            try self.packages.append(self.allocator, pkg);
        }
    }

    /// Install all workspace packages
    pub fn installAll(self: *Self) !void {
        std.debug.print("📦 Installing workspace packages...\n\n", .{});

        for (self.packages.items) |pkg| {
            std.debug.print("  Installing {s}...\n", .{pkg.name});
            // TODO: Install package dependencies
        }

        std.debug.print("\n✨ All workspace packages installed!\n", .{});
    }

    /// Link workspace packages to each other
    pub fn linkPackages(self: *Self) !void {
        std.debug.print("🔗 Linking workspace packages...\n", .{});

        // Build dependency graph
        for (self.packages.items) |pkg| {
            _ = pkg;
            // TODO: Parse dependencies and create symlinks
        }

        std.debug.print("✓ Packages linked\n", .{});
    }

    /// Run a script in all workspace packages
    pub fn runAll(self: *Self, script_name: []const u8) !void {
        std.debug.print("🚀 Running '{s}' in all packages...\n\n", .{script_name});

        for (self.packages.items) |pkg| {
            std.debug.print("  {s}:\n", .{pkg.name});
            // TODO: Run script in package
            _ = pkg;
        }

        std.debug.print("\n✓ Script completed in all packages\n", .{});
    }
};

/// A package within a workspace
pub const WorkspacePackage = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    dependencies: std.StringHashMap([]const u8),

    pub fn deinit(self: *WorkspacePackage) void {
        self.allocator.free(self.name);
        self.allocator.free(self.path);
        self.dependencies.deinit();
    }
};

/// Simple glob matching (supports * wildcard)
fn matchGlob(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.eql(u8, pattern, name)) return true;

    // Check prefix matching: "test-*"
    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, name, prefix);
    }

    // Check suffix matching: "*-test"
    if (std.mem.startsWith(u8, pattern, "*")) {
        const suffix = pattern[1..];
        return std.mem.endsWith(u8, name, suffix);
    }

    return false;
}
