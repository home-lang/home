const std = @import("std");

/// Lockfile format for Home package manager
/// File: .freezer
///
/// The .freezer file ensures deterministic, reproducible builds by
/// locking exact versions and checksums of all dependencies.
pub const Lockfile = struct {
    allocator: std.mem.Allocator,
    version: u32 = 1, // Lockfile format version
    packages: std.StringHashMap(LockedPackage),

    pub const LockedPackage = struct {
        name: []const u8,
        version: []const u8,
        resolved: []const u8, // Full resolution (registry URL, git commit, etc.)
        integrity: []const u8, // Checksum/hash for verification
        dependencies: std.StringHashMap([]const u8), // name -> version
        source: Source,

        pub const Source = union(enum) {
            Registry: []const u8, // registry URL
            Git: struct {
                url: []const u8,
                commit: []const u8, // Exact commit hash
            },
            Path: []const u8,
            Url: []const u8,
        };
    };

    pub fn init(allocator: std.mem.Allocator) Lockfile {
        return .{
            .allocator = allocator,
            .packages = std.StringHashMap(LockedPackage).init(allocator),
        };
    }

    pub fn deinit(self: *Lockfile) void {
        var iter = self.packages.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var pkg = entry.value_ptr.*;
            self.allocator.free(pkg.name);
            self.allocator.free(pkg.version);
            self.allocator.free(pkg.resolved);
            self.allocator.free(pkg.integrity);
            pkg.dependencies.deinit();
        }
        self.packages.deinit();
    }

    /// Load lockfile from .freezer
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Lockfile {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
        defer allocator.free(content);

        var lockfile = Lockfile.init(allocator);

        // Parse JSON lockfile
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            content,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const root = parsed.value.object;

        // Read version
        if (root.get("version")) |v| {
            if (v == .integer) {
                lockfile.version = @intCast(v.integer);
            }
        }

        // Read packages
        if (root.get("packages")) |pkgs_obj| {
            if (pkgs_obj == .object) {
                var iter = pkgs_obj.object.iterator();
                while (iter.next()) |entry| {
                    const pkg_key = entry.key_ptr.*;
                    const pkg_obj = entry.value_ptr.*;

                    if (pkg_obj != .object) continue;

                    const pkg_data = pkg_obj.object;

                    const name = if (pkg_data.get("name")) |n| n.string else continue;
                    const version = if (pkg_data.get("version")) |v| v.string else continue;
                    const resolved = if (pkg_data.get("resolved")) |r| r.string else continue;
                    const integrity = if (pkg_data.get("integrity")) |i| i.string else "";

                    // Parse source
                    var source: LockedPackage.Source = .{ .Registry = "" };
                    if (pkg_data.get("source")) |src_obj| {
                        if (src_obj == .object) {
                            const src_data = src_obj.object;
                            if (src_data.get("type")) |t| {
                                const src_type = t.string;
                                if (std.mem.eql(u8, src_type, "registry")) {
                                    source = .{ .Registry = if (src_data.get("url")) |u| try allocator.dupe(u8, u.string) else "" };
                                } else if (std.mem.eql(u8, src_type, "git")) {
                                    const url = if (src_data.get("url")) |u| u.string else "";
                                    const commit = if (src_data.get("commit")) |c| c.string else "";
                                    source = .{ .Git = .{
                                        .url = try allocator.dupe(u8, url),
                                        .commit = try allocator.dupe(u8, commit),
                                    } };
                                } else if (std.mem.eql(u8, src_type, "path")) {
                                    source = .{ .Path = if (src_data.get("path")) |p| try allocator.dupe(u8, p.string) else "" };
                                } else if (std.mem.eql(u8, src_type, "url")) {
                                    source = .{ .Url = if (src_data.get("url")) |u| try allocator.dupe(u8, u.string) else "" };
                                }
                            }
                        }
                    }

                    // Parse dependencies
                    var deps = std.StringHashMap([]const u8).init(allocator);
                    if (pkg_data.get("dependencies")) |deps_obj| {
                        if (deps_obj == .object) {
                            var deps_iter = deps_obj.object.iterator();
                            while (deps_iter.next()) |dep_entry| {
                                const dep_name = try allocator.dupe(u8, dep_entry.key_ptr.*);
                                const dep_version = try allocator.dupe(u8, dep_entry.value_ptr.*.string);
                                try deps.put(dep_name, dep_version);
                            }
                        }
                    }

                    const locked_pkg = LockedPackage{
                        .name = try allocator.dupe(u8, name),
                        .version = try allocator.dupe(u8, version),
                        .resolved = try allocator.dupe(u8, resolved),
                        .integrity = try allocator.dupe(u8, integrity),
                        .dependencies = deps,
                        .source = source,
                    };

                    try lockfile.packages.put(try allocator.dupe(u8, pkg_key), locked_pkg);
                }
            }
        }

        return lockfile;
    }

    /// Save lockfile to .freezer
    pub fn save(self: *const Lockfile, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.writer();

        // Write header
        try writer.print("{{\n", .{});
        try writer.print("  \"version\": {},\n", .{self.version});
        try writer.print("  \"packages\": {{\n", .{});

        // Write packages
        var iter = self.packages.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try writer.print(",\n", .{});
            first = false;

            const pkg_key = entry.key_ptr.*;
            const pkg = entry.value_ptr.*;

            try writer.print("    \"{s}\": {{\n", .{pkg_key});
            try writer.print("      \"name\": \"{s}\",\n", .{pkg.name});
            try writer.print("      \"version\": \"{s}\",\n", .{pkg.version});
            try writer.print("      \"resolved\": \"{s}\",\n", .{pkg.resolved});
            try writer.print("      \"integrity\": \"{s}\",\n", .{pkg.integrity});

            // Write source
            try writer.print("      \"source\": {{\n", .{});
            switch (pkg.source) {
                .Registry => |url| {
                    try writer.print("        \"type\": \"registry\",\n", .{});
                    try writer.print("        \"url\": \"{s}\"\n", .{url});
                },
                .Git => |git| {
                    try writer.print("        \"type\": \"git\",\n", .{});
                    try writer.print("        \"url\": \"{s}\",\n", .{git.url});
                    try writer.print("        \"commit\": \"{s}\"\n", .{git.commit});
                },
                .Path => |p| {
                    try writer.print("        \"type\": \"path\",\n", .{});
                    try writer.print("        \"path\": \"{s}\"\n", .{p});
                },
                .Url => |url| {
                    try writer.print("        \"type\": \"url\",\n", .{});
                    try writer.print("        \"url\": \"{s}\"\n", .{url});
                },
            }
            try writer.print("      }}", .{});

            // Write dependencies
            if (pkg.dependencies.count() > 0) {
                try writer.print(",\n      \"dependencies\": {{\n", .{});
                var dep_iter = pkg.dependencies.iterator();
                var dep_first = true;
                while (dep_iter.next()) |dep_entry| {
                    if (!dep_first) try writer.print(",\n", .{});
                    dep_first = false;
                    try writer.print("        \"{s}\": \"{s}\"", .{ dep_entry.key_ptr.*, dep_entry.value_ptr.* });
                }
                try writer.print("\n      }}\n", .{});
            } else {
                try writer.print("\n", .{});
            }

            try writer.print("    }}", .{});
        }

        try writer.print("\n  }}\n", .{});
        try writer.print("}}\n", .{});
    }

    /// Add or update a package in the lockfile
    pub fn addPackage(self: *Lockfile, key: []const u8, pkg: LockedPackage) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        try self.packages.put(owned_key, pkg);
    }

    /// Get a locked package
    pub fn getPackage(self: *const Lockfile, key: []const u8) ?LockedPackage {
        return self.packages.get(key);
    }

    /// Check if lockfile exists
    pub fn exists(path: []const u8) bool {
        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        file.close();
        return true;
    }
};
