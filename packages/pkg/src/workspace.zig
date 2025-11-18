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

            // Check for config file (home.toml, couch.toml, etc.)
            const pkg_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir, entry.name });
            const config_names = [_][]const u8{ "home.toml", "couch.toml", "home.json", "couch.json", "couch.jsonc" };
            var found_config = false;

            for (config_names) |config_name| {
                const config_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, pkg_path, config_name });
                defer self.allocator.free(config_path);

                std.fs.cwd().access(config_path, .{}) catch continue;
                found_config = true;
                break;
            }

            if (!found_config) {
                self.allocator.free(pkg_path);
                continue; // No config file, skip
            }

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

        for (self.packages.items) |*pkg| {
            std.debug.print("  Installing {s}...\n", .{pkg.name});

            // Parse config file to extract dependencies
            const toml_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, pkg.path, "home.toml" });
            defer self.allocator.free(toml_path);

            // Read home.toml
            const file = std.fs.cwd().openFile(toml_path, .{}) catch |err| {
                std.debug.print("    ⚠️  Warning: Could not open {s}: {s}\n", .{ toml_path, @errorName(err) });
                continue;
            };
            defer file.close();

            const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
                std.debug.print("    ⚠️  Warning: Could not read {s}: {s}\n", .{ toml_path, @errorName(err) });
                continue;
            };
            defer self.allocator.free(content);

            // Parse dependencies section from TOML
            try self.parseDependencies(pkg, content);

            if (pkg.dependencies.count() > 0) {
                std.debug.print("    → Found {d} dependencies\n", .{pkg.dependencies.count()});

                var dep_iter = pkg.dependencies.iterator();
                while (dep_iter.next()) |entry| {
                    std.debug.print("      • {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            } else {
                std.debug.print("    → No dependencies\n", .{});
            }
        }

        std.debug.print("\n✨ All workspace packages installed!\n", .{});
    }

    /// Parse dependencies from TOML content
    fn parseDependencies(self: *Self, pkg: *WorkspacePackage, content: []const u8) !void {
        // Simple TOML parser for [dependencies] section
        var in_dependencies = false;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for [dependencies] section
            if (std.mem.eql(u8, trimmed, "[dependencies]")) {
                in_dependencies = true;
                continue;
            }

            // Check for other sections (exit dependencies section)
            if (trimmed[0] == '[') {
                in_dependencies = false;
                continue;
            }

            // Parse dependency lines
            if (in_dependencies) {
                // Format: name = "version" or name = { ... }
                const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
                const name = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

                // Remove quotes
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                } else if (value.len > 0 and value[0] == '{') {
                    // Handle inline table: { git = "...", rev = "..." }
                    // For now, just use the whole inline table as the value
                    // A real implementation would parse this properly
                }

                const name_copy = try self.allocator.dupe(u8, name);
                const value_copy = try self.allocator.dupe(u8, value);

                try pkg.dependencies.put(name_copy, value_copy);
            }
        }
    }

    /// Link workspace packages to each other
    pub fn linkPackages(self: *Self) !void {
        std.debug.print("🔗 Linking workspace packages...\n\n", .{});

        // Create a map of package names to paths for quick lookup
        var pkg_map = std.StringHashMap([]const u8).init(self.allocator);
        defer pkg_map.deinit();

        for (self.packages.items) |pkg| {
            try pkg_map.put(pkg.name, pkg.path);
        }

        // Link dependencies
        for (self.packages.items) |pkg| {
            if (pkg.dependencies.count() == 0) continue;

            std.debug.print("  Linking {s}...\n", .{pkg.name});

            // Create node_modules directory if it doesn't exist
            const node_modules_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, pkg.path, "node_modules" });
            defer self.allocator.free(node_modules_path);

            std.fs.cwd().makePath(node_modules_path) catch {};

            var dep_iter = pkg.dependencies.iterator();
            while (dep_iter.next()) |entry| {
                const dep_name = entry.key_ptr.*;
                const dep_version = entry.value_ptr.*;

                // Check if this dependency is a workspace package
                if (pkg_map.get(dep_name)) |dep_path| {
                    // Create symlink to workspace package
                    const link_target = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, dep_path });
                    defer self.allocator.free(link_target);

                    const link_path = try std.fs.path.join(self.allocator, &[_][]const u8{ node_modules_path, dep_name });
                    defer self.allocator.free(link_path);

                    // Remove existing symlink if it exists
                    std.fs.cwd().deleteFile(link_path) catch {};
                    std.fs.cwd().deleteTree(link_path) catch {};

                    // Create symlink
                    std.fs.cwd().symLink(link_target, link_path, .{ .is_directory = true }) catch |err| {
                        std.debug.print("    ⚠️  Warning: Could not link {s}: {s}\n", .{ dep_name, @errorName(err) });
                        continue;
                    };

                    std.debug.print("    ✓ Linked {s} → {s}\n", .{ dep_name, dep_path });
                } else {
                    std.debug.print("    → {s}@{s} (external)\n", .{ dep_name, dep_version });
                }
            }
        }

        std.debug.print("\n✓ Packages linked\n", .{});
    }

    /// Run a script in all workspace packages
    pub fn runAll(self: *Self, script_name: []const u8) !void {
        std.debug.print("🚀 Running '{s}' in all packages...\n\n", .{script_name});

        for (self.packages.items) |pkg| {
            std.debug.print("  {s}:\n", .{pkg.name});

            // Read home.toml to get scripts
            const toml_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, pkg.path, "home.toml" });
            defer self.allocator.free(toml_path);

            const file = std.fs.cwd().openFile(toml_path, .{}) catch |err| {
                std.debug.print("    ⚠️  Warning: Could not open {s}: {s}\n", .{ toml_path, @errorName(err) });
                continue;
            };
            defer file.close();

            const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
                std.debug.print("    ⚠️  Warning: Could not read {s}: {s}\n", .{ toml_path, @errorName(err) });
                continue;
            };
            defer self.allocator.free(content);

            // Parse scripts section
            const script_cmd = try self.parseScript(content, script_name);
            defer if (script_cmd) |cmd| self.allocator.free(cmd);

            if (script_cmd) |cmd| {
                // Execute script in package directory
                const pkg_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ self.root_dir, pkg.path });
                defer self.allocator.free(pkg_dir);

                std.debug.print("    $ {s}\n", .{cmd});

                // Execute using sh -c
                var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, self.allocator);
                child.cwd = pkg_dir;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;

                const term = child.spawnAndWait() catch |err| {
                    std.debug.print("    ❌ Error: {s}\n", .{@errorName(err)});
                    continue;
                };

                switch (term) {
                    .Exited => |code| {
                        if (code == 0) {
                            std.debug.print("    ✓ Success\n", .{});
                        } else {
                            std.debug.print("    ❌ Exited with code {d}\n", .{code});
                        }
                    },
                    else => {
                        std.debug.print("    ❌ Process terminated abnormally\n", .{});
                    },
                }
            } else {
                std.debug.print("    ⚠️  Script '{s}' not found\n", .{script_name});
            }
        }

        std.debug.print("\n✓ Script completed in all packages\n", .{});
    }

    /// Parse a script from TOML content
    fn parseScript(self: *Self, content: []const u8, script_name: []const u8) !?[]const u8 {
        var in_scripts = false;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for [scripts] section
            if (std.mem.eql(u8, trimmed, "[scripts]")) {
                in_scripts = true;
                continue;
            }

            // Check for other sections (exit scripts section)
            if (trimmed[0] == '[') {
                in_scripts = false;
                continue;
            }

            // Parse script lines
            if (in_scripts) {
                // Format: name = "command"
                const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
                const name = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

                // Check if this is the script we're looking for
                if (std.mem.eql(u8, name, script_name)) {
                    // Remove quotes
                    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                        value = value[1 .. value.len - 1];
                    } else if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
                        value = value[1 .. value.len - 1];
                    }

                    return try self.allocator.dupe(u8, value);
                }
            }
        }

        return null;
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
