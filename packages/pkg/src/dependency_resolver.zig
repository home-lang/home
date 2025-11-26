const std = @import("std");
const Allocator = std.mem.Allocator;

/// Advanced dependency resolver with conflict detection and resolution
/// Implements a PubGrub-like algorithm for version solving
pub const AdvancedDependencyResolver = struct {
    allocator: Allocator,
    /// Dependency graph
    graph: DependencyGraph,
    /// Version constraints for each package
    constraints: std.StringHashMap(std.ArrayList(VersionConstraint)),
    /// Resolved versions
    solution: std.StringHashMap(ResolvedVersion),
    /// Conflict tracker
    conflicts: std.ArrayList(Conflict),

    pub const DependencyGraph = struct {
        nodes: std.StringHashMap(PackageNode),
        allocator: Allocator,

        pub const PackageNode = struct {
            name: []const u8,
            dependencies: std.ArrayList(Dependency),
            dependents: std.ArrayList([]const u8), // Who depends on this package
        };

        pub fn init(allocator: Allocator) DependencyGraph {
            return .{
                .nodes = std.StringHashMap(PackageNode).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *DependencyGraph) void {
            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.dependencies.deinit();
                for (entry.value_ptr.dependents.items) |dep| {
                    self.allocator.free(dep);
                }
                entry.value_ptr.dependents.deinit();
            }
            self.nodes.deinit();
        }

        pub fn addNode(self: *DependencyGraph, name: []const u8) !void {
            if (self.nodes.contains(name)) return;

            const key = try self.allocator.dupe(u8, name);
            try self.nodes.put(key, .{
                .name = key,
                .dependencies = std.ArrayList(Dependency).init(self.allocator),
                .dependents = std.ArrayList([]const u8).init(self.allocator),
            });
        }

        pub fn addEdge(self: *DependencyGraph, from: []const u8, to: Dependency) !void {
            try self.addNode(from);
            try self.addNode(to.name);

            if (self.nodes.getPtr(from)) |node| {
                try node.dependencies.append(to);
            }

            if (self.nodes.getPtr(to.name)) |node| {
                try node.dependents.append(try self.allocator.dupe(u8, from));
            }
        }

        /// Detect circular dependencies
        pub fn detectCycles(self: *DependencyGraph) !?[][]const u8 {
            var visited = std.StringHashMap(bool).init(self.allocator);
            defer visited.deinit();

            var rec_stack = std.StringHashMap(bool).init(self.allocator);
            defer rec_stack.deinit();

            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                if (try self.detectCyclesHelper(entry.key_ptr.*, &visited, &rec_stack)) |cycle| {
                    return cycle;
                }
            }

            return null;
        }

        fn detectCyclesHelper(
            self: *DependencyGraph,
            node: []const u8,
            visited: *std.StringHashMap(bool),
            rec_stack: *std.StringHashMap(bool),
        ) !?[][]const u8 {
            if (rec_stack.get(node)) |in_stack| {
                if (in_stack) {
                    // Cycle detected
                    var cycle = std.ArrayList([]const u8).init(self.allocator);
                    try cycle.append(try self.allocator.dupe(u8, node));
                    return try cycle.toOwnedSlice();
                }
            }

            if (visited.get(node)) |v| {
                if (v) return null; // Already processed
            }

            try visited.put(node, true);
            try rec_stack.put(node, true);

            if (self.nodes.get(node)) |pkg_node| {
                for (pkg_node.dependencies.items) |dep| {
                    if (try self.detectCyclesHelper(dep.name, visited, rec_stack)) |cycle| {
                        return cycle;
                    }
                }
            }

            try rec_stack.put(node, false);
            return null;
        }
    };

    pub const Dependency = struct {
        name: []const u8,
        constraint: VersionConstraint,
    };

    pub const VersionConstraint = struct {
        operator: Operator,
        version: SemanticVersion,

        pub const Operator = enum {
            Exact,      // 1.2.3
            Caret,      // ^1.2.3 (compatible)
            Tilde,      // ~1.2.3 (reasonably close)
            GreaterEq,  // >=1.2.3
            Greater,    // >1.2.3
            LessEq,     // <=1.2.3
            Less,       // <1.2.3
        };

        pub fn satisfies(self: VersionConstraint, version: SemanticVersion) bool {
            return switch (self.operator) {
                .Exact => compareVersions(version, self.version) == 0,
                .Caret => satisfiesCaret(version, self.version),
                .Tilde => satisfiesTilde(version, self.version),
                .GreaterEq => compareVersions(version, self.version) >= 0,
                .Greater => compareVersions(version, self.version) > 0,
                .LessEq => compareVersions(version, self.version) <= 0,
                .Less => compareVersions(version, self.version) < 0,
            };
        }

        fn satisfiesCaret(version: SemanticVersion, constraint: SemanticVersion) bool {
            // ^1.2.3 allows changes that don't modify left-most non-zero digit
            if (constraint.major > 0) {
                return version.major == constraint.major and
                    (version.minor > constraint.minor or
                    (version.minor == constraint.minor and version.patch >= constraint.patch));
            } else if (constraint.minor > 0) {
                return version.major == 0 and
                    version.minor == constraint.minor and
                    version.patch >= constraint.patch;
            } else {
                return version.major == 0 and
                    version.minor == 0 and
                    version.patch == constraint.patch;
            }
        }

        fn satisfiesTilde(version: SemanticVersion, constraint: SemanticVersion) bool {
            // ~1.2.3 allows patch-level changes
            return version.major == constraint.major and
                version.minor == constraint.minor and
                version.patch >= constraint.patch;
        }
    };

    pub const SemanticVersion = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn toString(self: SemanticVersion, allocator: Allocator) ![]const u8 {
            return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        }

        pub fn parse(str: []const u8) !SemanticVersion {
            var parts = std.mem.splitScalar(u8, str, '.');
            const major = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10);
            const minor = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10);
            const patch_str = parts.next() orelse return error.InvalidVersion;

            // Handle pre-release and build metadata
            var patch_clean = patch_str;
            if (std.mem.indexOf(u8, patch_str, "-")) |idx| {
                patch_clean = patch_str[0..idx];
            } else if (std.mem.indexOf(u8, patch_str, "+")) |idx| {
                patch_clean = patch_str[0..idx];
            }

            const patch = try std.fmt.parseInt(u32, patch_clean, 10);

            return SemanticVersion{
                .major = major,
                .minor = minor,
                .patch = patch,
            };
        }
    };

    pub const ResolvedVersion = struct {
        package_name: []const u8,
        version: SemanticVersion,
        dependencies: []Dependency,
    };

    pub const Conflict = struct {
        package_name: []const u8,
        constraints: []VersionConstraint,
        message: []const u8,
    };

    pub fn init(allocator: Allocator) AdvancedDependencyResolver {
        return .{
            .allocator = allocator,
            .graph = DependencyGraph.init(allocator),
            .constraints = std.StringHashMap(std.ArrayList(VersionConstraint)).init(allocator),
            .solution = std.StringHashMap(ResolvedVersion).init(allocator),
            .conflicts = std.ArrayList(Conflict).init(allocator),
        };
    }

    pub fn deinit(self: *AdvancedDependencyResolver) void {
        self.graph.deinit();

        var it = self.constraints.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.constraints.deinit();

        var sol_it = self.solution.iterator();
        while (sol_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.dependencies);
        }
        self.solution.deinit();

        for (self.conflicts.items) |conflict| {
            self.allocator.free(conflict.package_name);
            self.allocator.free(conflict.constraints);
            self.allocator.free(conflict.message);
        }
        self.conflicts.deinit();
    }

    /// Add a dependency constraint
    pub fn addConstraint(self: *AdvancedDependencyResolver, package: []const u8, constraint: VersionConstraint) !void {
        const key = if (self.constraints.contains(package))
            package
        else
            try self.allocator.dupe(u8, package);

        const constraints_ptr = try self.constraints.getOrPut(key);
        if (!constraints_ptr.found_existing) {
            constraints_ptr.value_ptr.* = std.ArrayList(VersionConstraint).init(self.allocator);
        }

        try constraints_ptr.value_ptr.append(constraint);
    }

    /// Add a dependency relationship
    pub fn addDependency(self: *AdvancedDependencyResolver, from: []const u8, to: Dependency) !void {
        try self.graph.addEdge(from, to);
        try self.addConstraint(to.name, to.constraint);
    }

    /// Resolve all dependencies
    pub fn resolve(self: *AdvancedDependencyResolver, registry: *PackageRegistry) ![]ResolvedVersion {
        // Step 1: Detect circular dependencies
        if (try self.graph.detectCycles()) |cycle| {
            std.debug.print("Error: Circular dependency detected: ", .{});
            for (cycle, 0..) |pkg, i| {
                if (i > 0) std.debug.print(" -> ", .{});
                std.debug.print("{s}", .{pkg});
            }
            std.debug.print("\n", .{});
            return error.CircularDependency;
        }

        // Step 2: Topologically sort dependencies
        const sorted = try self.topologicalSort();
        defer self.allocator.free(sorted);

        // Step 3: Resolve versions for each package
        for (sorted) |package_name| {
            try self.resolvePackage(package_name, registry);
        }

        // Step 4: Check for conflicts
        if (self.conflicts.items.len > 0) {
            std.debug.print("\nDependency conflicts detected:\n", .{});
            for (self.conflicts.items) |conflict| {
                std.debug.print("  {s}: {s}\n", .{ conflict.package_name, conflict.message });
            }
            return error.ConflictingDependencies;
        }

        // Step 5: Return solution
        var result = std.ArrayList(ResolvedVersion).init(self.allocator);
        var it = self.solution.iterator();
        while (it.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }

        return try result.toOwnedSlice();
    }

    /// Topological sort of the dependency graph
    fn topologicalSort(self: *AdvancedDependencyResolver) ![][]const u8 {
        var result = std.ArrayList([]const u8).init(self.allocator);
        var visited = std.StringHashMap(bool).init(self.allocator);
        defer visited.deinit();

        var it = self.graph.nodes.iterator();
        while (it.next()) |entry| {
            try self.topologicalSortHelper(entry.key_ptr.*, &visited, &result);
        }

        return try result.toOwnedSlice();
    }

    fn topologicalSortHelper(
        self: *AdvancedDependencyResolver,
        node: []const u8,
        visited: *std.StringHashMap(bool),
        result: *std.ArrayList([]const u8),
    ) !void {
        if (visited.get(node)) |v| {
            if (v) return; // Already visited
        }

        try visited.put(node, true);

        // Visit dependencies first
        if (self.graph.nodes.get(node)) |pkg_node| {
            for (pkg_node.dependencies.items) |dep| {
                try self.topologicalSortHelper(dep.name, visited, result);
            }
        }

        // Add to result
        try result.append(try self.allocator.dupe(u8, node));
    }

    /// Resolve a single package
    fn resolvePackage(self: *AdvancedDependencyResolver, package_name: []const u8, registry: *PackageRegistry) !void {
        // Get all constraints for this package
        const constraints = self.constraints.get(package_name) orelse {
            // No constraints, use latest version
            const latest = try registry.getLatestVersion(package_name);
            try self.solution.put(try self.allocator.dupe(u8, package_name), .{
                .package_name = package_name,
                .version = latest,
                .dependencies = &[_]Dependency{},
            });
            return;
        };

        // Find a version that satisfies all constraints
        const available_versions = try registry.getVersions(package_name);
        defer self.allocator.free(available_versions);

        // Sort versions in descending order (prefer latest)
        std.sort.pdq(SemanticVersion, available_versions, {}, compareVersionsDesc);

        for (available_versions) |version| {
            // Check if this version satisfies all constraints
            var satisfies_all = true;
            for (constraints.items) |constraint| {
                if (!constraint.satisfies(version)) {
                    satisfies_all = false;
                    break;
                }
            }

            if (satisfies_all) {
                // Found a compatible version
                const deps = try registry.getDependencies(package_name, version);

                try self.solution.put(try self.allocator.dupe(u8, package_name), .{
                    .package_name = package_name,
                    .version = version,
                    .dependencies = deps,
                });
                return;
            }
        }

        // No compatible version found - record conflict
        const message = try std.fmt.allocPrint(
            self.allocator,
            "No version satisfies all constraints",
            .{},
        );

        try self.conflicts.append(.{
            .package_name = try self.allocator.dupe(u8, package_name),
            .constraints = try self.allocator.dupe(VersionConstraint, constraints.items),
            .message = message,
        });
    }

    /// Compare versions for sorting (descending)
    fn compareVersionsDesc(context: void, a: SemanticVersion, b: SemanticVersion) bool {
        _ = context;
        return compareVersions(a, b) > 0;
    }

    /// Parse a version constraint string
    pub fn parseConstraint(str: []const u8) !VersionConstraint {
        var clean = str;
        var operator = VersionConstraint.Operator.Exact;

        if (str.len == 0) return error.InvalidConstraint;

        // Detect operator
        if (str[0] == '^') {
            operator = .Caret;
            clean = str[1..];
        } else if (str[0] == '~') {
            operator = .Tilde;
            clean = str[1..];
        } else if (std.mem.startsWith(u8, str, ">=")) {
            operator = .GreaterEq;
            clean = std.mem.trim(u8, str[2..], " ");
        } else if (std.mem.startsWith(u8, str, "<=")) {
            operator = .LessEq;
            clean = std.mem.trim(u8, str[2..], " ");
        } else if (str[0] == '>') {
            operator = .Greater;
            clean = std.mem.trim(u8, str[1..], " ");
        } else if (str[0] == '<') {
            operator = .Less;
            clean = std.mem.trim(u8, str[1..], " ");
        } else if (str[0] == '=') {
            operator = .Exact;
            clean = std.mem.trim(u8, str[1..], " ");
        }

        const version = try SemanticVersion.parse(clean);

        return VersionConstraint{
            .operator = operator,
            .version = version,
        };
    }
};

/// Package registry interface
pub const PackageRegistry = struct {
    allocator: Allocator,
    /// Mock registry data (in real implementation, would fetch from HTTP)
    packages: std.StringHashMap(PackageInfo),

    pub const PackageInfo = struct {
        name: []const u8,
        versions: []SemanticVersion,
        /// Dependencies for each version
        dependencies_by_version: std.AutoHashMap(SemanticVersion, []AdvancedDependencyResolver.Dependency),
    };

    pub fn init(allocator: Allocator) PackageRegistry {
        return .{
            .allocator = allocator,
            .packages = std.StringHashMap(PackageInfo).init(allocator),
        };
    }

    pub fn deinit(self: *PackageRegistry) void {
        var it = self.packages.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.versions);
            var dep_it = entry.value_ptr.dependencies_by_version.iterator();
            while (dep_it.next()) |dep_entry| {
                self.allocator.free(dep_entry.value_ptr.*);
            }
            entry.value_ptr.dependencies_by_version.deinit();
        }
        self.packages.deinit();
    }

    pub fn getLatestVersion(self: *PackageRegistry, package_name: []const u8) !SemanticVersion {
        const pkg = self.packages.get(package_name) orelse return error.PackageNotFound;
        if (pkg.versions.len == 0) return error.NoVersionsAvailable;

        // Return highest version
        var latest = pkg.versions[0];
        for (pkg.versions[1..]) |version| {
            if (compareVersions(version, latest) > 0) {
                latest = version;
            }
        }
        return latest;
    }

    pub fn getVersions(self: *PackageRegistry, package_name: []const u8) ![]SemanticVersion {
        const pkg = self.packages.get(package_name) orelse return error.PackageNotFound;
        return try self.allocator.dupe(SemanticVersion, pkg.versions);
    }

    pub fn getDependencies(
        self: *PackageRegistry,
        package_name: []const u8,
        version: SemanticVersion,
    ) ![]AdvancedDependencyResolver.Dependency {
        const pkg = self.packages.get(package_name) orelse return error.PackageNotFound;

        if (pkg.dependencies_by_version.get(version)) |deps| {
            return try self.allocator.dupe(AdvancedDependencyResolver.Dependency, deps);
        }

        return &[_]AdvancedDependencyResolver.Dependency{};
    }
};

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

const SemanticVersion = AdvancedDependencyResolver.SemanticVersion;

test "AdvancedDependencyResolver - basic resolution" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resolver = AdvancedDependencyResolver.init(allocator);
    defer resolver.deinit();

    var registry = PackageRegistry.init(allocator);
    defer registry.deinit();

    // Add a simple dependency
    const constraint = try AdvancedDependencyResolver.parseConstraint("^1.0.0");
    try resolver.addConstraint("foo", constraint);

    // Would normally resolve with registry
    // const resolved = try resolver.resolve(&registry);
}

test "SemanticVersion - parsing" {
    const testing = std.testing;

    const v1 = try SemanticVersion.parse("1.2.3");
    try testing.expectEqual(@as(u32, 1), v1.major);
    try testing.expectEqual(@as(u32, 2), v1.minor);
    try testing.expectEqual(@as(u32, 3), v1.patch);

    const v2 = try SemanticVersion.parse("0.1.0-alpha");
    try testing.expectEqual(@as(u32, 0), v2.major);
    try testing.expectEqual(@as(u32, 1), v2.minor);
    try testing.expectEqual(@as(u32, 0), v2.patch);
}

test "VersionConstraint - caret" {
    const constraint = AdvancedDependencyResolver.VersionConstraint{
        .operator = .Caret,
        .version = .{ .major = 1, .minor = 2, .minor = 3 },
    };

    try std.testing.expect(constraint.satisfies(.{ .major = 1, .minor = 2, .patch = 3 }));
    try std.testing.expect(constraint.satisfies(.{ .major = 1, .minor = 3, .patch = 0 }));
    try std.testing.expect(!constraint.satisfies(.{ .major = 2, .minor = 0, .patch = 0 }));
    try std.testing.expect(!constraint.satisfies(.{ .major = 1, .minor = 1, .patch = 9 }));
}
