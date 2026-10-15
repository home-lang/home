const std = @import("std");
const Io = std.Io;

const max_lockfile_size = 10 * 1024 * 1024;

fn defaultIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

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

        fn clone(self: LockedPackage, allocator: std.mem.Allocator) !LockedPackage {
            const name = try allocator.dupe(u8, self.name);
            errdefer allocator.free(name);
            const version = try allocator.dupe(u8, self.version);
            errdefer allocator.free(version);
            const resolved = try allocator.dupe(u8, self.resolved);
            errdefer allocator.free(resolved);
            const integrity = try allocator.dupe(u8, self.integrity);
            errdefer allocator.free(integrity);

            var dependencies = std.StringHashMap([]const u8).init(allocator);
            errdefer deinitDependencies(allocator, &dependencies);
            var dependency_iter = self.dependencies.iterator();
            while (dependency_iter.next()) |entry| {
                const dependency_name = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(dependency_name);
                const dependency_version = try allocator.dupe(u8, entry.value_ptr.*);
                errdefer allocator.free(dependency_version);
                try dependencies.put(dependency_name, dependency_version);
            }

            const source = try cloneSource(allocator, self.source);

            return .{
                .name = name,
                .version = version,
                .resolved = resolved,
                .integrity = integrity,
                .dependencies = dependencies,
                .source = source,
            };
        }

        fn deinit(self: *LockedPackage, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.version);
            allocator.free(self.resolved);
            allocator.free(self.integrity);
            deinitDependencies(allocator, &self.dependencies);
            deinitSource(allocator, self.source);
        }

        fn cloneSource(allocator: std.mem.Allocator, source: Source) !Source {
            return switch (source) {
                .Registry => |url| .{ .Registry = try allocator.dupe(u8, url) },
                .Git => |git| blk: {
                    const url = try allocator.dupe(u8, git.url);
                    errdefer allocator.free(url);
                    break :blk .{ .Git = .{
                        .url = url,
                        .commit = try allocator.dupe(u8, git.commit),
                    } };
                },
                .Path => |path| .{ .Path = try allocator.dupe(u8, path) },
                .Url => |url| .{ .Url = try allocator.dupe(u8, url) },
            };
        }

        fn deinitSource(allocator: std.mem.Allocator, source: Source) void {
            switch (source) {
                .Registry => |url| allocator.free(url),
                .Git => |git| {
                    allocator.free(git.url);
                    allocator.free(git.commit);
                },
                .Path => |path| allocator.free(path),
                .Url => |url| allocator.free(url),
            }
        }

        fn deinitDependencies(
            allocator: std.mem.Allocator,
            dependencies: *std.StringHashMap([]const u8),
        ) void {
            var iter = dependencies.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            dependencies.deinit();
        }
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
            entry.value_ptr.deinit(self.allocator);
        }
        self.packages.deinit();
    }

    /// Load lockfile from .freezer
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Lockfile {
        return loadWithIo(allocator, defaultIo(), path);
    }

    /// Load a lockfile using an explicit I/O implementation.
    pub fn loadWithIo(allocator: std.mem.Allocator, io: Io, path: []const u8) !Lockfile {
        const content = try Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(max_lockfile_size),
        );
        defer allocator.free(content);

        var lockfile = Lockfile.init(allocator);
        errdefer lockfile.deinit();

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            content,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidLockfile;
        const root = parsed.value.object;

        if (root.get("version")) |v| {
            if (v != .integer) return error.InvalidLockfile;
            lockfile.version = std.math.cast(u32, v.integer) orelse return error.InvalidLockfile;
        }

        if (root.get("packages")) |pkgs_obj| {
            if (pkgs_obj != .object) return error.InvalidLockfile;
            var iter = pkgs_obj.object.iterator();
            while (iter.next()) |entry| {
                const pkg_obj = entry.value_ptr.*;
                if (pkg_obj != .object) return error.InvalidLockfile;
                const pkg_data = pkg_obj.object;

                const name_value = pkg_data.get("name") orelse return error.InvalidLockfile;
                const version_value = pkg_data.get("version") orelse return error.InvalidLockfile;
                const resolved_value = pkg_data.get("resolved") orelse return error.InvalidLockfile;
                if (name_value != .string or version_value != .string or resolved_value != .string) {
                    return error.InvalidLockfile;
                }
                const integrity = if (pkg_data.get("integrity")) |value| blk: {
                    if (value != .string) return error.InvalidLockfile;
                    break :blk value.string;
                } else "";

                var source: LockedPackage.Source = .{ .Registry = "" };
                if (pkg_data.get("source")) |source_value| {
                    if (source_value != .object) return error.InvalidLockfile;
                    const source_data = source_value.object;
                    const type_value = source_data.get("type") orelse return error.InvalidLockfile;
                    if (type_value != .string) return error.InvalidLockfile;
                    const source_type = type_value.string;
                    if (std.mem.eql(u8, source_type, "registry")) {
                        source = .{ .Registry = try optionalJsonString(source_data, "url") };
                    } else if (std.mem.eql(u8, source_type, "git")) {
                        source = .{ .Git = .{
                            .url = try optionalJsonString(source_data, "url"),
                            .commit = try optionalJsonString(source_data, "commit"),
                        } };
                    } else if (std.mem.eql(u8, source_type, "path")) {
                        source = .{ .Path = try optionalJsonString(source_data, "path") };
                    } else if (std.mem.eql(u8, source_type, "url")) {
                        source = .{ .Url = try optionalJsonString(source_data, "url") };
                    } else {
                        return error.InvalidLockfile;
                    }
                }

                var dependencies = std.StringHashMap([]const u8).init(allocator);
                defer dependencies.deinit();
                if (pkg_data.get("dependencies")) |dependencies_value| {
                    if (dependencies_value != .object) return error.InvalidLockfile;
                    var dependency_iter = dependencies_value.object.iterator();
                    while (dependency_iter.next()) |dependency_entry| {
                        if (dependency_entry.value_ptr.* != .string) return error.InvalidLockfile;
                        try dependencies.put(
                            dependency_entry.key_ptr.*,
                            dependency_entry.value_ptr.*.string,
                        );
                    }
                }

                try lockfile.addPackage(entry.key_ptr.*, .{
                    .name = name_value.string,
                    .version = version_value.string,
                    .resolved = resolved_value.string,
                    .integrity = integrity,
                    .dependencies = dependencies,
                    .source = source,
                });
            }
        }

        return lockfile;
    }

    fn optionalJsonString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
        const value = object.get(key) orelse return "";
        if (value != .string) return error.InvalidLockfile;
        return value.string;
    }

    /// Save lockfile to .freezer
    pub fn save(self: *const Lockfile, path: []const u8) !void {
        return self.saveWithIo(defaultIo(), path);
    }

    /// Save a lockfile using an explicit I/O implementation.
    pub fn saveWithIo(self: *const Lockfile, io: Io, path: []const u8) !void {
        var output: Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;

        try writer.writeAll("{\n");
        try writer.print("  \"version\": {},\n", .{self.version});
        try writer.writeAll("  \"packages\": {\n");

        const package_keys = try sortedKeys(self.allocator, self.packages);
        defer self.allocator.free(package_keys);
        var first = true;
        for (package_keys) |pkg_key| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            const pkg = self.packages.get(pkg_key).?;

            try writer.writeAll("    ");
            try writeJsonString(writer, pkg_key);
            try writer.writeAll(": {\n      \"name\": ");
            try writeJsonString(writer, pkg.name);
            try writer.writeAll(",\n      \"version\": ");
            try writeJsonString(writer, pkg.version);
            try writer.writeAll(",\n      \"resolved\": ");
            try writeJsonString(writer, pkg.resolved);
            try writer.writeAll(",\n      \"integrity\": ");
            try writeJsonString(writer, pkg.integrity);
            try writer.writeAll(",\n");

            try writer.writeAll("      \"source\": {\n");
            switch (pkg.source) {
                .Registry => |url| {
                    try writer.writeAll("        \"type\": \"registry\",\n        \"url\": ");
                    try writeJsonString(writer, url);
                    try writer.writeByte('\n');
                },
                .Git => |git| {
                    try writer.writeAll("        \"type\": \"git\",\n        \"url\": ");
                    try writeJsonString(writer, git.url);
                    try writer.writeAll(",\n        \"commit\": ");
                    try writeJsonString(writer, git.commit);
                    try writer.writeByte('\n');
                },
                .Path => |p| {
                    try writer.writeAll("        \"type\": \"path\",\n        \"path\": ");
                    try writeJsonString(writer, p);
                    try writer.writeByte('\n');
                },
                .Url => |url| {
                    try writer.writeAll("        \"type\": \"url\",\n        \"url\": ");
                    try writeJsonString(writer, url);
                    try writer.writeByte('\n');
                },
            }
            try writer.writeAll("      }");

            if (pkg.dependencies.count() > 0) {
                try writer.writeAll(",\n      \"dependencies\": {\n");
                const dependency_keys = try sortedKeys(self.allocator, pkg.dependencies);
                defer self.allocator.free(dependency_keys);
                var dep_first = true;
                for (dependency_keys) |dependency_name| {
                    if (!dep_first) try writer.writeAll(",\n");
                    dep_first = false;
                    try writer.writeAll("        ");
                    try writeJsonString(writer, dependency_name);
                    try writer.writeAll(": ");
                    try writeJsonString(writer, pkg.dependencies.get(dependency_name).?);
                }
                try writer.writeAll("\n      }\n");
            } else {
                try writer.writeByte('\n');
            }

            try writer.writeAll("    }");
        }

        try writer.writeAll("\n  }\n}\n");
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = output.written(),
        });
    }

    fn writeJsonString(writer: *Io.Writer, value: []const u8) !void {
        try std.json.Stringify.value(value, .{}, writer);
    }

    fn sortedKeys(
        allocator: std.mem.Allocator,
        map: anytype,
    ) ![][]const u8 {
        const keys = try allocator.alloc([]const u8, map.count());
        var copied_map = map;
        var iter = copied_map.iterator();
        var index: usize = 0;
        while (iter.next()) |entry| : (index += 1) {
            keys[index] = entry.key_ptr.*;
        }
        std.mem.sort([]const u8, keys, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);
        return keys;
    }

    /// Add or update a package in the lockfile
    pub fn addPackage(self: *Lockfile, key: []const u8, pkg: LockedPackage) !void {
        var owned_package = try pkg.clone(self.allocator);
        errdefer owned_package.deinit(self.allocator);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.packages.ensureUnusedCapacity(1);

        if (self.packages.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            var old_package = old.value;
            old_package.deinit(self.allocator);
        }
        self.packages.putAssumeCapacity(owned_key, owned_package);
    }

    /// Get a locked package
    pub fn getPackage(self: *const Lockfile, key: []const u8) ?LockedPackage {
        return self.packages.get(key);
    }

    /// Check if lockfile exists
    pub fn exists(path: []const u8) bool {
        return existsWithIo(defaultIo(), path);
    }

    pub fn existsWithIo(io: Io, path: []const u8) bool {
        Io.Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }
};
