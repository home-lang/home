const std = @import("std");
const auth_mod = @import("auth.zig");
const lockfile_mod = @import("lockfile.zig");
pub const AuthManager = auth_mod.AuthManager;
pub const AuthToken = auth_mod.AuthToken;
pub const Lockfile = lockfile_mod.Lockfile;

/// Package manager for Home
pub const PackageManager = struct {
    allocator: std.mem.Allocator,
    config: *PackageConfig,
    lockfile: ?*Lockfile,
    cache_dir: []const u8,
    registry_url: []const u8,
    auth_manager: ?*AuthManager,

    pub const DEFAULT_REGISTRY = "https://packages.home-lang.org";
    pub const DEFAULT_CACHE_DIR = ".home/cache";
    pub const PACKAGES_DIR = "pantry"; // Where dependencies are installed
    pub const LOCKFILE_NAME = ".freezer"; // Lockfile for reproducible builds

    pub fn init(allocator: std.mem.Allocator) !*PackageManager {
        const pm = try allocator.create(PackageManager);

        // Try config files in priority order:
        // 1. couch.jsonc (preferred - JSON with comments)
        // 2. couch.json
        // 3. home.json
        // 4. package.jsonc (npm-compatible with comments)
        // 5. package.json (npm-compatible)
        // 6. home.toml / couch.toml (fallback)
        const config_files = [_][]const u8{
            "couch.jsonc",
            "couch.json",
            "home.json",
            "package.jsonc",
            "package.json",
            "home.toml",
            "couch.toml",
        };

        var config: ?*PackageConfig = null;
        var last_err: ?anyerror = null;

        for (config_files) |config_file| {
            config = PackageConfig.load(allocator, config_file) catch |err| {
                last_err = err;
                continue;
            };
            break;
        }

        if (config == null) {
            std.debug.print("Error: No configuration file found. Expected one of:\n", .{});
            std.debug.print("  - couch.jsonc (recommended)\n", .{});
            std.debug.print("  - couch.json\n", .{});
            std.debug.print("  - home.json\n", .{});
            std.debug.print("  - package.jsonc\n", .{});
            std.debug.print("  - package.json\n", .{});
            std.debug.print("  - home.toml\n", .{});
            std.debug.print("  - couch.toml\n", .{});
            return last_err orelse error.NoConfigFile;
        }

        // Initialize auth manager
        const auth_manager = try allocator.create(AuthManager);
        auth_manager.* = try AuthManager.init(allocator, DEFAULT_REGISTRY);

        pm.* = .{
            .allocator = allocator,
            .config = config.?,
            .lock_file = null,
            .cache_dir = DEFAULT_CACHE_DIR,
            .registry_url = DEFAULT_REGISTRY,
            .auth_manager = auth_manager,
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
        if (self.auth_manager) |auth| {
            auth.deinit();
            self.allocator.destroy(auth);
        }
        self.allocator.destroy(self);
    }

    /// Login to package registry
    pub fn login(self: *PackageManager, registry: ?[]const u8, username: ?[]const u8, token: ?[]const u8) !void {
        const auth = self.auth_manager orelse return error.AuthNotInitialized;
        try auth.login(registry, username, token);
    }

    /// Logout from package registry
    pub fn logout(self: *PackageManager, registry: ?[]const u8) !void {
        const auth = self.auth_manager orelse return error.AuthNotInitialized;
        try auth.logout(registry);
    }

    /// Check if authenticated to registry
    pub fn isAuthenticated(self: *PackageManager, registry: ?[]const u8) bool {
        const auth = self.auth_manager orelse return false;
        const reg = registry orelse self.registry_url;
        return auth.isAuthenticated(reg);
    }

    /// Get authentication token for registry
    pub fn getAuthToken(self: *PackageManager, registry: ?[]const u8) ?AuthToken {
        const auth = self.auth_manager orelse return null;
        const reg = registry orelse self.registry_url;
        return auth.getToken(reg);
    }

    /// List authenticated registries
    pub fn listAuthenticatedRegistries(self: *PackageManager) ![][]const u8 {
        const auth = self.auth_manager orelse return error.AuthNotInitialized;
        return auth.listAuthenticated();
    }

    /// Add a dependency to home.toml (or couch.toml/couch.json)
    pub fn addDependency(self: *PackageManager, name: []const u8, version: []const u8) !void {
        const dep = Dependency{
            .name = name,
            .version = try self.parseVersion(version),
            .source = .{ .Registry = self.registry_url },
        };

        try self.config.dependencies.append(self.allocator, dep);
        try self.config.save(self.config.config_file);

        // Resolve and download
        try self.resolve();
    }

    /// Add a dependency from Git (supports GitHub shortcuts like "user/repo")
    pub fn addGitDependency(self: *PackageManager, name: []const u8, url: []const u8, rev: ?[]const u8) !void {
        // Expand GitHub shortcuts: "user/repo" -> "https://github.com/user/repo"
        const expanded_url = try self.expandGitUrl(url);
        defer if (!std.mem.eql(u8, expanded_url, url)) self.allocator.free(expanded_url);

        const dep = Dependency{
            .name = name,
            .version = Version{ .git = rev },
            .source = .{ .Git = .{ .url = try self.allocator.dupe(u8, expanded_url), .rev = if (rev) |r| try self.allocator.dupe(u8, r) else null } },
        };

        try self.config.dependencies.append(self.allocator, dep);
        try self.config.save(self.config.config_file);

        try self.resolve();
    }

    /// Add a dependency from a URL (direct HTTP/HTTPS download)
    pub fn addUrlDependency(self: *PackageManager, name: []const u8, url: []const u8) !void {
        const dep = Dependency{
            .name = name,
            .version = Version{ .url = try self.allocator.dupe(u8, url) },
            .source = .{ .Url = try self.allocator.dupe(u8, url) },
        };

        try self.config.dependencies.append(self.allocator, dep);
        try self.config.save(self.config.config_file);

        try self.resolve();
    }

    /// Expand GitHub shortcuts to full URLs
    pub fn expandGitUrl(self: *PackageManager, url: []const u8) ![]const u8 {
        // Check if it's a GitHub shortcut (user/repo or user/repo.git)
        if (std.mem.indexOf(u8, url, "://") == null and std.mem.indexOf(u8, url, "/") != null) {
            // Count slashes - should have exactly 1 for user/repo
            var slash_count: usize = 0;
            for (url) |c| {
                if (c == '/') slash_count += 1;
            }

            if (slash_count == 1) {
                // It's a GitHub shortcut
                const has_git_ext = std.mem.endsWith(u8, url, ".git");
                if (has_git_ext) {
                    return try std.fmt.allocPrint(self.allocator, "https://github.com/{s}", .{url});
                } else {
                    return try std.fmt.allocPrint(self.allocator, "https://github.com/{s}.git", .{url});
                }
            }
        }

        // Already a full URL or local path
        return url;
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

        try self.config.save("home.toml");
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

    /// Download all dependencies (parallel like Bun!)
    fn downloadAll(self: *PackageManager) !void {
        if (self.lock_file) |lock| {
            const num_packages = lock.packages.items.len;
            if (num_packages == 0) return;

            // Use thread pool for parallel downloads (Bun-style speed)
            const num_threads = @min(num_packages, 8); // Max 8 parallel downloads

            std.debug.print("📦 Installing {d} packages ({d} parallel downloads)...\n", .{ num_packages, num_threads });

            // Create a download context for thread synchronization
            var errors = std.ArrayList(DownloadError){};
            defer errors.deinit(self.allocator);

            var download_ctx = DownloadContext{
                .allocator = self.allocator,
                .packages = lock.packages.items,
                .pm = self,
                .current_index = 0,
                .mutex = std.Thread.Mutex{},
                .errors = &errors,
            };

            // Launch worker threads
            var threads = std.ArrayList(std.Thread){};
            defer threads.deinit(self.allocator);

            var i: usize = 0;
            while (i < num_threads) : (i += 1) {
                const thread = try std.Thread.spawn(.{}, downloadWorker, .{&download_ctx});
                try threads.append(self.allocator, thread);
            }

            // Wait for all threads to complete
            for (threads.items) |thread| {
                thread.join();
            }

            // Report any errors
            if (download_ctx.errors.items.len > 0) {
                std.debug.print("\n⚠️  Download errors:\n", .{});
                for (download_ctx.errors.items) |err| {
                    std.debug.print("  • {s}: {s}\n", .{ err.package_name, err.message });
                }
                return error.DownloadsFailed;
            }
        }
    }

    /// Worker thread function for parallel downloads
    fn downloadWorker(ctx: *DownloadContext) void {
        while (true) {
            // Get next package to download (thread-safe)
            ctx.mutex.lock();
            const index = ctx.current_index;
            if (index >= ctx.packages.len) {
                ctx.mutex.unlock();
                break;
            }
            ctx.current_index += 1;
            ctx.mutex.unlock();

            const pkg = ctx.packages[index];

            // Download package
            ctx.pm.downloadPackage(pkg) catch |err| {
                // Record error
                ctx.mutex.lock();
                ctx.errors.append(ctx.allocator, .{
                    .package_name = pkg.name,
                    .message = @errorName(err),
                }) catch {};
                ctx.mutex.unlock();
            };
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
                .Url => |url| try self.downloadFromUrl(url, pkg_dir),
            }

            std.debug.print("    ✓ Downloaded {s}@{s}\n", .{ pkg.name, pkg.version });
            return;
        };

        std.debug.print("  → Using cached {s}@{s}\n", .{ pkg.name, pkg.version });
    }

    fn downloadFromRegistry(self: *PackageManager, pkg: LockedPackage, dest: []const u8) !void {
        _ = self;
        _ = pkg;
        // Would use HTTP client to download from registry
        // For now, simulate download
        try std.fs.cwd().makePath(dest);
    }

    fn downloadFromGit(self: *PackageManager, url: []const u8, rev: ?[]const u8, dest: []const u8) !void {
        // Ensure destination directory doesn't exist
        std.fs.cwd().deleteTree(dest) catch {};

        // Build git clone command
        const rev_args = if (rev) |r| &[_][]const u8{ "--branch", r } else &[_][]const u8{};

        var args = std.ArrayList([]const u8){};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "git");
        try args.append(self.allocator, "clone");
        try args.append(self.allocator, "--depth");
        try args.append(self.allocator, "1");

        for (rev_args) |arg| {
            try args.append(self.allocator, arg);
        }

        try args.append(self.allocator, url);
        try args.append(self.allocator, dest);

        // Execute git clone
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        const term = try child.spawnAndWait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    return error.GitCloneFailed;
                }
            },
            else => return error.GitCloneFailed,
        }

        // Remove .git directory to save space
        const git_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ dest, ".git" });
        defer self.allocator.free(git_dir);
        std.fs.cwd().deleteTree(git_dir) catch {};
    }

    fn downloadFromUrl(self: *PackageManager, url: []const u8, dest: []const u8) !void {
        // Create destination directory
        try std.fs.cwd().makePath(dest);

        // Download using curl or wget
        // Try curl first
        var child = std.process.Child.init(
            &[_][]const u8{ "curl", "-fsSL", "-o", try std.fs.path.join(self.allocator, &[_][]const u8{ dest, "package.tar.gz" }), url },
            self.allocator,
        );
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        const term = child.spawnAndWait() catch |err| {
            // Curl not available, try wget
            if (err == error.FileNotFound) {
                var wget_child = std.process.Child.init(
                    &[_][]const u8{ "wget", "-q", "-O", try std.fs.path.join(self.allocator, &[_][]const u8{ dest, "package.tar.gz" }), url },
                    self.allocator,
                );
                wget_child.stdout_behavior = .Ignore;
                wget_child.stderr_behavior = .Ignore;

                const wget_term = try wget_child.spawnAndWait();
                switch (wget_term) {
                    .Exited => |code| {
                        if (code != 0) {
                            return error.DownloadFailed;
                        }
                    },
                    else => return error.DownloadFailed,
                }
                return;
            }
            return err;
        };

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    return error.DownloadFailed;
                }
            },
            else => return error.DownloadFailed,
        }

        // Extract archive if it's a .tar.gz, .zip, etc.
        const archive_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dest, "package.tar.gz" });
        defer self.allocator.free(archive_path);

        try self.extractArchive(archive_path, dest);
    }

    /// Extract an archive (.tar.gz, .zip, etc.)
    fn extractArchive(self: *PackageManager, archive_path: []const u8, dest_dir: []const u8) !void {
        // Detect archive type from extension
        const is_tar_gz = std.mem.endsWith(u8, archive_path, ".tar.gz") or std.mem.endsWith(u8, archive_path, ".tgz");
        const is_zip = std.mem.endsWith(u8, archive_path, ".zip");

        if (is_tar_gz) {
            // Extract using tar
            var child = std.process.Child.init(
                &[_][]const u8{ "tar", "-xzf", archive_path, "-C", dest_dir },
                self.allocator,
            );
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            const term = child.spawnAndWait() catch |err| {
                return err;
            };

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        return error.ExtractionFailed;
                    }
                },
                else => return error.ExtractionFailed,
            }

            // Remove the archive file to save space
            std.fs.cwd().deleteFile(archive_path) catch {};
        } else if (is_zip) {
            // Extract using unzip
            var child = std.process.Child.init(
                &[_][]const u8{ "unzip", "-q", "-o", archive_path, "-d", dest_dir },
                self.allocator,
            );
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            const term = child.spawnAndWait() catch |err| {
                return err;
            };

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        return error.ExtractionFailed;
                    }
                },
                else => return error.ExtractionFailed,
            }

            // Remove the archive file to save space
            std.fs.cwd().deleteFile(archive_path) catch {};
        } else {
            // Unknown archive format, leave as-is
        }
    }

    fn copyLocal(self: *PackageManager, src: []const u8, dest: []const u8) !void {
        _ = self;
        _ = src;
        // Copy local directory
        try std.fs.cwd().makePath(dest);
    }

    fn parseVersion(self: *PackageManager, version_str: []const u8) !Version {
        _ = self;

        // Handle version range prefixes (^, ~, >=, >, <=, <, =)
        var clean_version = version_str;
        if (version_str.len > 0) {
            if (version_str[0] == '^' or version_str[0] == '~' or version_str[0] == '=') {
                clean_version = version_str[1..];
            } else if (version_str.len >= 2 and (std.mem.startsWith(u8, version_str, ">=") or
                std.mem.startsWith(u8, version_str, "<=") or
                std.mem.startsWith(u8, version_str, "<") or
                std.mem.startsWith(u8, version_str, ">")))
            {
                // Skip comparison operators
                var i: usize = 0;
                while (i < version_str.len and !std.ascii.isDigit(version_str[i])) : (i += 1) {}
                clean_version = std.mem.trim(u8, version_str[i..], " \t");
            }
        }

        // Parse x.y.z format
        var parts = std.mem.splitScalar(u8, clean_version, '.');
        const major_str = parts.next() orelse return error.InvalidVersion;
        const minor_str = parts.next() orelse return error.InvalidVersion;
        const patch_str = parts.next() orelse return error.InvalidVersion;

        // Handle pre-release and build metadata (e.g., 1.0.0-alpha+build)
        // For now, just strip them
        var patch_clean = patch_str;
        if (std.mem.indexOf(u8, patch_str, "-")) |idx| {
            patch_clean = patch_str[0..idx];
        } else if (std.mem.indexOf(u8, patch_str, "+")) |idx| {
            patch_clean = patch_str[0..idx];
        }

        const major = std.fmt.parseInt(u32, major_str, 10) catch return error.InvalidVersion;
        const minor = std.fmt.parseInt(u32, minor_str, 10) catch return error.InvalidVersion;
        const patch = std.fmt.parseInt(u32, patch_clean, 10) catch return error.InvalidVersion;

        return Version{
            .semantic = .{
                .major = major,
                .minor = minor,
                .patch = patch,
            },
        };
    }

    /// Compare two semantic versions
    /// Returns: -1 if a < b, 0 if a == b, 1 if a > b
    fn compareVersions(a: SemanticVersion, b: SemanticVersion) i32 {
        if (a.major != b.major) {
            return if (a.major < b.major) -1 else 1;
        }
        if (a.minor != b.minor) {
            return if (a.minor < b.minor) -1 else 1;
        }
        if (a.patch != b.patch) {
            return if (a.patch < b.patch) -1 else 1;
        }
        return 0;
    }

    /// Check if a version satisfies a version range
    /// Supports: ^1.2.3 (compatible), ~1.2.3 (reasonably close), >=1.2.3, etc.
    fn satisfiesRange(version: SemanticVersion, range: []const u8) bool {
        // Parse range prefix
        if (range.len == 0) return false;

        if (range[0] == '^') {
            // Caret: ^1.2.3 allows changes that don't modify left-most non-zero digit
            // ^0.2.3 → >=0.2.3 <0.3.0
            // ^1.2.3 → >=1.2.3 <2.0.0
            const range_ver = parseVersionString(range[1..]) catch return false;
            if (range_ver.major > 0) {
                return version.major == range_ver.major and
                    (version.minor > range_ver.minor or
                    (version.minor == range_ver.minor and version.patch >= range_ver.patch));
            } else if (range_ver.minor > 0) {
                return version.major == 0 and version.minor == range_ver.minor and version.patch >= range_ver.patch;
            } else {
                return version.major == 0 and version.minor == 0 and version.patch == range_ver.patch;
            }
        } else if (range[0] == '~') {
            // Tilde: ~1.2.3 allows patch-level changes
            // ~1.2.3 → >=1.2.3 <1.3.0
            const range_ver = parseVersionString(range[1..]) catch return false;
            return version.major == range_ver.major and
                version.minor == range_ver.minor and
                version.patch >= range_ver.patch;
        } else if (std.mem.startsWith(u8, range, ">=")) {
            const range_ver = parseVersionString(range[2..]) catch return false;
            return compareVersions(version, range_ver) >= 0;
        } else if (std.mem.startsWith(u8, range, "<=")) {
            const range_ver = parseVersionString(range[2..]) catch return false;
            return compareVersions(version, range_ver) <= 0;
        } else if (range[0] == '>') {
            const range_ver = parseVersionString(range[1..]) catch return false;
            return compareVersions(version, range_ver) > 0;
        } else if (range[0] == '<') {
            const range_ver = parseVersionString(range[1..]) catch return false;
            return compareVersions(version, range_ver) < 0;
        } else {
            // Exact match
            const range_ver = parseVersionString(range) catch return false;
            return compareVersions(version, range_ver) == 0;
        }
    }

    fn parseVersionString(version_str: []const u8) !SemanticVersion {
        const clean = std.mem.trim(u8, version_str, " \t");
        var parts = std.mem.splitScalar(u8, clean, '.');
        const major = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10) catch return error.InvalidVersion;
        const minor = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10) catch return error.InvalidVersion;
        const patch_str = parts.next() orelse return error.InvalidVersion;

        // Strip pre-release/build metadata
        var patch_clean = patch_str;
        if (std.mem.indexOf(u8, patch_str, "-")) |idx| {
            patch_clean = patch_str[0..idx];
        }
        const patch = std.fmt.parseInt(u32, patch_clean, 10) catch return error.InvalidVersion;

        return SemanticVersion{ .major = major, .minor = minor, .patch = patch };
    }
};

/// Package configuration from home.toml (or couch.toml/couch.json)
pub const PackageConfig = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    authors: [][]const u8,
    dependencies: std.ArrayList(Dependency),
    workspaces: ?[][]const u8, // Bun-style workspaces
    scripts: ?std.StringHashMap([]const u8), // Bun-style scripts
    config_file: []const u8, // Track which file was used

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*PackageConfig {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const config = try allocator.create(PackageConfig);

        // Detect format based on file extension
        const is_json = std.mem.endsWith(u8, path, ".json");
        const is_jsonc = std.mem.endsWith(u8, path, ".jsonc");

        if (is_json or is_jsonc) {
            // Strip comments if JSONC
            var json_content = content;
            var owned_content: ?[]u8 = null;

            if (is_jsonc) {
                owned_content = try stripJsonComments(allocator, content);
                json_content = owned_content.?;
            }
            defer if (owned_content) |oc| allocator.free(oc);

            // Parse JSON using std.json
            const parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                json_content,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed.deinit();

            const root = parsed.value.object;

            // Extract fields
            const name = root.get("name") orelse return error.MissingName;
            const version = root.get("version") orelse return error.MissingVersion;

            var deps = std.ArrayList(Dependency){};

            // Parse dependencies if present
            if (root.get("dependencies")) |deps_obj| {
                if (deps_obj == .object) {
                    var iter = deps_obj.object.iterator();
                    while (iter.next()) |entry| {
                        const dep_name = entry.key_ptr.*;
                        const dep_value = entry.value_ptr.*;

                        if (dep_value == .string) {
                            // Simple version string: "^1.0.0"
                            const version_str = dep_value.string;
                            const dep = Dependency{
                                .name = try allocator.dupe(u8, dep_name),
                                .version = try parseVersionString(allocator, version_str),
                                .source = .{ .Registry = PackageManager.DEFAULT_REGISTRY },
                            };
                            try deps.append(allocator, dep);
                        } else if (dep_value == .object) {
                            // Complex dependency with git/url/path
                            const dep_obj = dep_value.object;

                            if (dep_obj.get("git")) |git_url| {
                                const rev = if (dep_obj.get("rev")) |r| r.string else null;
                                const dep = Dependency{
                                    .name = try allocator.dupe(u8, dep_name),
                                    .version = Version{ .git = if (rev) |r| try allocator.dupe(u8, r) else null },
                                    .source = .{ .Git = .{
                                        .url = try allocator.dupe(u8, git_url.string),
                                        .rev = if (rev) |r| try allocator.dupe(u8, r) else null,
                                    } },
                                };
                                try deps.append(allocator, dep);
                            } else if (dep_obj.get("url")) |url| {
                                const dep = Dependency{
                                    .name = try allocator.dupe(u8, dep_name),
                                    .version = Version{ .url = try allocator.dupe(u8, url.string) },
                                    .source = .{ .Url = try allocator.dupe(u8, url.string) },
                                };
                                try deps.append(allocator, dep);
                            }
                        }
                    }
                }
            }

            config.* = .{
                .allocator = allocator,
                .name = try allocator.dupe(u8, name.string),
                .version = try allocator.dupe(u8, version.string),
                .authors = &[_][]const u8{},
                .dependencies = deps,
                .workspaces = null,
                .scripts = null,
                .config_file = try allocator.dupe(u8, path),
            };
        } else {
            // Parse TOML (simplified - would use real TOML parser)
            config.* = .{
                .allocator = allocator,
                .name = try allocator.dupe(u8, "myproject"),
                .version = try allocator.dupe(u8, "0.1.0"),
                .authors = &[_][]const u8{},
                .dependencies = std.ArrayList(Dependency){},
                .workspaces = null,
                .scripts = null,
                .config_file = try allocator.dupe(u8, path),
            };
        }

        return config;
    }

    /// Strip comments from JSONC (JSON with Comments)
    fn stripJsonComments(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
        var result = std.ArrayList(u8){};
        errdefer result.deinit(allocator);

        var i: usize = 0;
        var in_string = false;
        var escape_next = false;

        while (i < content.len) : (i += 1) {
            const c = content[i];

            if (escape_next) {
                try result.append(allocator, c);
                escape_next = false;
                continue;
            }

            if (c == '\\' and in_string) {
                escape_next = true;
                try result.append(allocator, c);
                continue;
            }

            if (c == '"') {
                in_string = !in_string;
                try result.append(allocator, c);
                continue;
            }

            if (in_string) {
                try result.append(allocator, c);
                continue;
            }

            // Handle single-line comments //
            if (c == '/' and i + 1 < content.len and content[i + 1] == '/') {
                // Skip until end of line
                while (i < content.len and content[i] != '\n') : (i += 1) {}
                if (i < content.len) {
                    try result.append(allocator, '\n'); // Preserve newline
                }
                continue;
            }

            // Handle multi-line comments /* */
            if (c == '/' and i + 1 < content.len and content[i + 1] == '*') {
                i += 2;
                // Skip until */
                while (i + 1 < content.len) : (i += 1) {
                    if (content[i] == '*' and content[i + 1] == '/') {
                        i += 1; // Skip the /
                        break;
                    }
                }
                continue;
            }

            try result.append(allocator, c);
        }

        return result.toOwnedSlice(allocator);
    }

    /// Parse version string (^1.0.0, ~1.0.0, 1.0.0, etc.)
    fn parseVersionString(allocator: std.mem.Allocator, version_str: []const u8) !Version {
        _ = allocator;

        // Remove prefixes like ^, ~, >=, etc.
        var clean_version = version_str;
        if (version_str.len > 0) {
            if (version_str[0] == '^' or version_str[0] == '~') {
                clean_version = version_str[1..];
            } else if (std.mem.startsWith(u8, version_str, ">=")) {
                clean_version = version_str[2..];
            }
        }

        // Parse x.y.z
        var parts = std.mem.splitScalar(u8, clean_version, '.');
        const major = if (parts.next()) |p| try std.fmt.parseInt(u32, p, 10) else 0;
        const minor = if (parts.next()) |p| try std.fmt.parseInt(u32, p, 10) else 0;
        const patch = if (parts.next()) |p| try std.fmt.parseInt(u32, p, 10) else 0;

        return Version{
            .semantic = .{
                .major = major,
                .minor = minor,
                .patch = patch,
            },
        };
    }

    pub fn deinit(self: *PackageConfig) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.free(self.config_file);
        self.dependencies.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn save(self: *PackageConfig, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const is_json = std.mem.endsWith(u8, path, ".json");

        if (is_json) {
            // Save as JSON - simplified for now
            var buf = std.ArrayList(u8){};
            defer buf.deinit(self.allocator);

            try buf.appendSlice(self.allocator, "{\n");
            try buf.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "  \"name\": \"{s}\",\n", .{self.name}));
            try buf.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "  \"version\": \"{s}\"\n", .{self.version}));
            // TODO: Add dependencies
            try buf.appendSlice(self.allocator, "}\n");

            try file.writeAll(buf.items);
        } else {
            // Save as TOML
            var content = std.ArrayList(u8){};
            defer content.deinit(self.allocator);

            try content.appendSlice(self.allocator, "[package]\n");
            try content.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "name = \"{s}\"\n", .{self.name}));
            try content.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "version = \"{s}\"\n", .{self.version}));
            try content.appendSlice(self.allocator, "\n[dependencies]\n");

            for (self.dependencies.items) |dep| {
                const dep_line = switch (dep.version) {
                    .semantic => |sem| try std.fmt.allocPrint(
                        self.allocator,
                        "{s} = \"{d}.{d}.{d}\"\n",
                        .{ dep.name, sem.major, sem.minor, sem.patch },
                    ),
                    .git => |rev| switch (dep.source) {
                        .Git => |git| if (rev) |r|
                            try std.fmt.allocPrint(
                                self.allocator,
                                "{s} = {{ git = \"{s}\", rev = \"{s}\" }}\n",
                                .{ dep.name, git.url, r },
                            )
                        else
                            try std.fmt.allocPrint(
                                self.allocator,
                                "{s} = {{ git = \"{s}\" }}\n",
                                .{ dep.name, git.url },
                            ),
                        else => "",
                    },
                    .url => |url| try std.fmt.allocPrint(
                        self.allocator,
                        "{s} = {{ url = \"{s}\" }}\n",
                        .{ dep.name, url },
                    ),
                };
                defer if (dep_line.len > 0) self.allocator.free(dep_line);
                try content.appendSlice(self.allocator, dep_line);
            }

            try file.writeAll(content.items);
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
    url: []const u8, // Direct URL
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
    Url: []const u8, // Direct HTTP/HTTPS download
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
            .packages = std.ArrayList(LockedPackage){},
        };

        for (packages) |pkg| {
            try lock.packages.append(allocator, .{
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
            .packages = std.ArrayList(LockedPackage){},
        };

        return lock;
    }

    pub fn deinit(self: *LockFile) void {
        self.packages.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn save(self: *LockFile, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var content = std.ArrayList(u8){};
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator, "# This file is generated by ion pkg\n");
        try content.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "version = {d}\n\n", .{self.version}));

        for (self.packages.items) |pkg| {
            try content.appendSlice(self.allocator, "[[package]]\n");
            try content.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "name = \"{s}\"\n", .{pkg.name}));
            try content.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "version = \"{s}\"\n", .{pkg.version}));
            try content.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "checksum = \"{s}\"\n", .{pkg.checksum}));
            try content.appendSlice(self.allocator, "\n");
        }

        try file.writeAll(content.items);
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
            .dependencies = std.ArrayList(Dependency){},
            .resolved = std.StringHashMap(ResolvedPackage).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyResolver) void {
        self.dependencies.deinit(self.allocator);
        self.resolved.deinit();
    }

    pub fn addDependency(self: *DependencyResolver, dep: Dependency) !void {
        try self.dependencies.append(self.allocator, dep);
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
                .url => "url-based",
            };

            try self.resolved.put(dep.name, .{
                .name = dep.name,
                .version = version_str,
                .checksum = "abc123", // Would compute actual checksum
                .source = dep.source,
            });
        }

        // Convert to slice
        var result = std.ArrayList(ResolvedPackage){};
        var iter = self.resolved.iterator();
        while (iter.next()) |entry| {
            try result.append(self.allocator, entry.value_ptr.*);
        }

        return result.toOwnedSlice(self.allocator);
    }
};

pub const ResolvedPackage = struct {
    name: []const u8,
    version: []const u8,
    checksum: []const u8,
    source: DependencySource,
};

/// Context for parallel downloads
const DownloadContext = struct {
    allocator: std.mem.Allocator,
    packages: []LockedPackage,
    pm: *PackageManager,
    current_index: usize,
    mutex: std.Thread.Mutex,
    errors: *std.ArrayList(DownloadError),
};

/// Download error info
const DownloadError = struct {
    package_name: []const u8,
    message: []const u8,
};
