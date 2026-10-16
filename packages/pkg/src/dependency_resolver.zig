const std = @import("std");
const Allocator = std.mem.Allocator;

/// Dependency resolver with transitive constraint propagation and backtracking.
/// This is a finite search over registry versions, not a PubGrub implementation.
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
                entry.value_ptr.dependencies.deinit(self.allocator);
                entry.value_ptr.dependents.deinit(self.allocator);
            }
            self.nodes.deinit();
        }

        pub fn addNode(self: *DependencyGraph, name: []const u8) !void {
            if (self.nodes.contains(name)) return;

            const key = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(key);
            try self.nodes.put(key, .{
                .name = key,
                .dependencies = .empty,
                .dependents = .empty,
            });
        }

        pub fn addEdge(self: *DependencyGraph, from: []const u8, to: Dependency) !void {
            try self.addNode(from);
            try self.addNode(to.name);

            const from_node = self.nodes.getPtr(from).?;
            const to_node = self.nodes.getPtr(to.name).?;
            try from_node.dependencies.ensureUnusedCapacity(self.allocator, 1);
            try to_node.dependents.ensureUnusedCapacity(self.allocator, 1);
            from_node.dependencies.appendAssumeCapacity(.{ .name = to_node.name, .constraint = to.constraint });
            to_node.dependents.appendAssumeCapacity(from_node.name);
        }

        /// Detect circular dependencies
        pub fn detectCycles(self: *DependencyGraph) !?[][]const u8 {
            var visited = std.StringHashMap(void).init(self.allocator);
            defer visited.deinit();

            var rec_stack = std.StringHashMap(usize).init(self.allocator);
            defer rec_stack.deinit();
            var path: std.ArrayList([]const u8) = .empty;
            defer path.deinit(self.allocator);

            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                if (try self.detectCyclesHelper(entry.key_ptr.*, &visited, &rec_stack, &path)) |cycle| {
                    return cycle;
                }
            }

            return null;
        }

        pub fn freeCycle(self: *DependencyGraph, cycle: [][]const u8) void {
            for (cycle) |name| self.allocator.free(name);
            self.allocator.free(cycle);
        }

        fn detectCyclesHelper(
            self: *DependencyGraph,
            node: []const u8,
            visited: *std.StringHashMap(void),
            rec_stack: *std.StringHashMap(usize),
            path: *std.ArrayList([]const u8),
        ) !?[][]const u8 {
            if (rec_stack.get(node)) |start| {
                var cycle: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (cycle.items) |name| self.allocator.free(name);
                    cycle.deinit(self.allocator);
                }
                for (path.items[start..]) |name| {
                    try self.appendCycleName(&cycle, name);
                }
                try self.appendCycleName(&cycle, node);
                return try cycle.toOwnedSlice(self.allocator);
            }

            if (visited.contains(node)) return null;

            try visited.put(node, {});
            try rec_stack.put(node, path.items.len);
            defer _ = rec_stack.remove(node);
            try path.append(self.allocator, node);
            defer _ = path.pop();

            if (self.nodes.get(node)) |pkg_node| {
                for (pkg_node.dependencies.items) |dep| {
                    if (try self.detectCyclesHelper(dep.name, visited, rec_stack, path)) |cycle| {
                        return cycle;
                    }
                }
            }
            return null;
        }

        fn appendCycleName(self: *DependencyGraph, cycle: *std.ArrayList([]const u8), name: []const u8) !void {
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try cycle.append(self.allocator, owned);
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
            Exact, // 1.2.3
            Caret, // ^1.2.3 (compatible)
            Tilde, // ~1.2.3 (reasonably close)
            GreaterEq, // >=1.2.3
            Greater, // >1.2.3
            LessEq, // <=1.2.3
            Less, // <1.2.3
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
            if (parts.next() != null) return error.InvalidVersion;

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
            .conflicts = .empty,
        };
    }

    pub fn deinit(self: *AdvancedDependencyResolver) void {
        self.clearResolution();
        self.graph.deinit();

        var it = self.constraints.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.constraints.deinit();

        self.solution.deinit();
        self.conflicts.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add a dependency constraint
    pub fn addConstraint(self: *AdvancedDependencyResolver, package: []const u8, constraint: VersionConstraint) !void {
        try self.graph.addNode(package);
        // Look up using the caller's (possibly ephemeral) slice. If we're
        // inserting a new entry we must own the key string, so dupe up-front
        // and free on early exit.
        if (self.constraints.getPtr(package)) |existing| {
            try existing.append(self.allocator, constraint);
            return;
        }

        const key = try self.allocator.dupe(u8, package);
        errdefer self.allocator.free(key);

        var list: std.ArrayList(VersionConstraint) = .empty;
        errdefer list.deinit(self.allocator);
        try list.append(self.allocator, constraint);

        try self.constraints.put(key, list);
    }

    /// Add a dependency relationship
    pub fn addDependency(self: *AdvancedDependencyResolver, from: []const u8, to: Dependency) !void {
        try self.graph.addEdge(from, to);
        try self.addConstraint(to.name, to.constraint);
    }

    /// Resolve all dependencies. The returned slice is owned by the caller;
    /// its entries borrow the resolver's solution until the next `resolve` or
    /// `deinit` call.
    pub fn resolve(self: *AdvancedDependencyResolver, registry: *PackageRegistry) ![]ResolvedVersion {
        self.clearResolution();
        if (try self.graph.detectCycles()) |cycle| {
            defer self.graph.freeCycle(cycle);
            return error.CircularDependency;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var state = SearchState.init(allocator);
        var nodes = self.graph.nodes.iterator();
        while (nodes.next()) |entry| {
            const name = entry.key_ptr.*;
            const node = entry.value_ptr.*;
            // A local project root is an edge source, not a registry package.
            if (!self.constraints.contains(name) and !registry.packages.contains(name) and
                node.dependents.items.len == 0 and node.dependencies.items.len > 0) continue;
            try state.requirements.put(name, .empty);
        }
        var constraints = self.constraints.iterator();
        while (constraints.next()) |entry| {
            for (entry.value_ptr.items) |constraint| {
                try state.addRequirement(entry.key_ptr.*, constraint);
            }
        }
        var failure: SearchFailure = .{};
        defer failure.deinit(self.allocator);
        if (!try self.search(registry, &state, &failure)) {
            if (failure.conflict_name) |name| {
                try self.recordConflict(name, failure.conflict_constraints.?);
                return error.ConflictingDependencies;
            }
            if (failure.missing_name != null) return error.PackageNotFound;
            if (failure.cycle) return error.CircularDependency;
            return error.ConflictingDependencies;
        }
        errdefer self.clearResolution();

        var result: std.ArrayList(ResolvedVersion) = .empty;
        errdefer result.deinit(self.allocator);
        var it = self.solution.iterator();
        while (it.next()) |entry| {
            try result.append(self.allocator, entry.value_ptr.*);
        }
        std.sort.pdq(ResolvedVersion, result.items, {}, lessResolvedName);

        return try result.toOwnedSlice(self.allocator);
    }

    const SearchState = struct {
        allocator: Allocator,
        requirements: std.StringHashMap(std.ArrayList(VersionConstraint)),
        selected: std.StringHashMap(SemanticVersion),

        fn init(allocator: Allocator) SearchState {
            return .{
                .allocator = allocator,
                .requirements = std.StringHashMap(std.ArrayList(VersionConstraint)).init(allocator),
                .selected = std.StringHashMap(SemanticVersion).init(allocator),
            };
        }

        fn clone(self: *const SearchState, allocator: Allocator) !SearchState {
            var copy = SearchState.init(allocator);
            var requirements = self.requirements.iterator();
            while (requirements.next()) |entry| {
                const list = try allocator.dupe(VersionConstraint, entry.value_ptr.items);
                try copy.requirements.put(entry.key_ptr.*, .fromOwnedSlice(list));
            }
            var selected = self.selected.iterator();
            while (selected.next()) |entry| try copy.selected.put(entry.key_ptr.*, entry.value_ptr.*);
            return copy;
        }

        fn addRequirement(self: *SearchState, name: []const u8, constraint: VersionConstraint) !void {
            if (self.requirements.getPtr(name)) |list| {
                try list.append(self.allocator, constraint);
            } else {
                var list: std.ArrayList(VersionConstraint) = .empty;
                try list.append(self.allocator, constraint);
                try self.requirements.put(name, list);
            }
        }
    };

    const SearchFailure = struct {
        conflict_name: ?[]u8 = null,
        conflict_constraints: ?[]VersionConstraint = null,
        missing_name: ?[]const u8 = null,
        cycle: bool = false,

        fn deinit(self: *SearchFailure, allocator: Allocator) void {
            if (self.conflict_name) |name| allocator.free(name);
            if (self.conflict_constraints) |constraints| allocator.free(constraints);
        }

        fn noteConflict(self: *SearchFailure, allocator: Allocator, name: []const u8, constraints: []const VersionConstraint) !void {
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            const owned_constraints = try allocator.dupe(VersionConstraint, constraints);
            if (self.conflict_name) |old| allocator.free(old);
            if (self.conflict_constraints) |old| allocator.free(old);
            self.conflict_name = owned_name;
            self.conflict_constraints = owned_constraints;
        }
    };

    fn search(self: *AdvancedDependencyResolver, registry: *PackageRegistry, state: *SearchState, failure: *SearchFailure) !bool {
        var next: ?[]const u8 = null;
        var requirements = state.requirements.iterator();
        while (requirements.next()) |entry| {
            const name = entry.key_ptr.*;
            if (state.selected.get(name)) |version| {
                for (entry.value_ptr.items) |constraint| {
                    if (!constraint.satisfies(version)) {
                        try failure.noteConflict(self.allocator, name, entry.value_ptr.items);
                        return false;
                    }
                }
            } else if (next == null or std.mem.order(u8, name, next.?) == .lt) {
                next = name;
            }
        }

        if (next == null) {
            if (try self.selectedHasCycle(registry, state)) {
                failure.cycle = true;
                return false;
            }
            try self.commitSolution(registry, state);
            return true;
        }

        const name = next.?;
        const package = registry.packages.get(name) orelse {
            failure.missing_name = name;
            return false;
        };
        const versions = try state.allocator.dupe(SemanticVersion, package.versions);
        std.sort.pdq(SemanticVersion, versions, {}, compareVersionsDesc);
        var had_candidate = false;
        for (versions) |version| {
            var allowed = true;
            for (state.requirements.get(name).?.items) |constraint| {
                if (!constraint.satisfies(version)) {
                    allowed = false;
                    break;
                }
            }
            if (!allowed) continue;
            had_candidate = true;

            // Every candidate owns a separate arena. A failed branch drops its
            // requirements and selections together, including transitive edges.
            var branch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer branch_arena.deinit();
            var branch = try state.clone(branch_arena.allocator());
            try branch.selected.put(name, version);
            const dependencies = package.dependencies_by_version.get(version) orelse &.{};
            for (dependencies) |dependency| {
                try branch.addRequirement(dependency.name, dependency.constraint);
            }
            if (try self.search(registry, &branch, failure)) return true;
        }
        if (!had_candidate) try failure.noteConflict(self.allocator, name, state.requirements.get(name).?.items);
        return false;
    }

    fn selectedHasCycle(self: *AdvancedDependencyResolver, registry: *PackageRegistry, state: *SearchState) !bool {
        var graph = DependencyGraph.init(state.allocator);
        defer graph.deinit();
        var explicit = self.graph.nodes.iterator();
        while (explicit.next()) |entry| {
            try graph.addNode(entry.key_ptr.*);
            for (entry.value_ptr.dependencies.items) |dependency| try graph.addEdge(entry.key_ptr.*, dependency);
        }
        var selected = state.selected.iterator();
        while (selected.next()) |entry| {
            const package = registry.packages.get(entry.key_ptr.*).?;
            const dependencies = package.dependencies_by_version.get(entry.value_ptr.*) orelse &.{};
            for (dependencies) |dependency| try graph.addEdge(entry.key_ptr.*, dependency);
        }
        if (try graph.detectCycles()) |cycle| {
            graph.freeCycle(cycle);
            return true;
        }
        return false;
    }

    fn commitSolution(self: *AdvancedDependencyResolver, registry: *PackageRegistry, state: *SearchState) !void {
        errdefer self.clearResolution();
        var selected = state.selected.iterator();
        while (selected.next()) |entry| {
            try self.commitPackage(registry, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn commitPackage(self: *AdvancedDependencyResolver, registry: *PackageRegistry, name: []const u8, version: SemanticVersion) !void {
        const dependencies = try registry.getDependenciesWithAllocator(self.allocator, name, version);
        errdefer PackageRegistry.freeDependencies(self.allocator, dependencies);
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.solution.put(key, .{ .package_name = key, .version = version, .dependencies = dependencies });
    }

    fn recordConflict(self: *AdvancedDependencyResolver, name: []const u8, incoming: []const VersionConstraint) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const constraints = try self.allocator.dupe(VersionConstraint, incoming);
        errdefer self.allocator.free(constraints);
        const message = try self.allocator.dupe(u8, "No version satisfies all constraints");
        errdefer self.allocator.free(message);
        try self.conflicts.append(self.allocator, .{ .package_name = owned_name, .constraints = constraints, .message = message });
    }

    fn lessResolvedName(_: void, a: ResolvedVersion, b: ResolvedVersion) bool {
        return std.mem.order(u8, a.package_name, b.package_name) == .lt;
    }

    fn clearResolution(self: *AdvancedDependencyResolver) void {
        var solutions = self.solution.iterator();
        while (solutions.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            PackageRegistry.freeDependencies(self.allocator, entry.value_ptr.dependencies);
        }
        self.solution.clearRetainingCapacity();
        for (self.conflicts.items) |conflict| {
            self.allocator.free(conflict.package_name);
            self.allocator.free(conflict.constraints);
            self.allocator.free(conflict.message);
        }
        self.conflicts.clearRetainingCapacity();
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
        versions: []AdvancedDependencyResolver.SemanticVersion,
        /// Dependencies for each version
        dependencies_by_version: std.AutoHashMap(AdvancedDependencyResolver.SemanticVersion, []AdvancedDependencyResolver.Dependency),
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
                freeDependencies(self.allocator, dep_entry.value_ptr.*);
            }
            entry.value_ptr.dependencies_by_version.deinit();
        }
        self.packages.deinit();
    }

    pub fn addPackage(self: *PackageRegistry, name: []const u8, versions: []const AdvancedDependencyResolver.SemanticVersion) !void {
        if (self.packages.contains(name)) return error.PackageAlreadyExists;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_versions = try self.allocator.dupe(AdvancedDependencyResolver.SemanticVersion, versions);
        errdefer self.allocator.free(owned_versions);
        var dependencies_by_version = std.AutoHashMap(AdvancedDependencyResolver.SemanticVersion, []AdvancedDependencyResolver.Dependency).init(self.allocator);
        errdefer dependencies_by_version.deinit();
        try self.packages.put(owned_name, .{
            .name = owned_name,
            .versions = owned_versions,
            .dependencies_by_version = dependencies_by_version,
        });
    }

    pub fn addDependencies(
        self: *PackageRegistry,
        package_name: []const u8,
        version: AdvancedDependencyResolver.SemanticVersion,
        dependencies: []const AdvancedDependencyResolver.Dependency,
    ) !void {
        const package = self.packages.getPtr(package_name) orelse return error.PackageNotFound;
        var known_version = false;
        for (package.versions) |candidate| {
            if (compareVersions(candidate, version) == 0) {
                known_version = true;
                break;
            }
        }
        if (!known_version) return error.VersionNotFound;

        const owned = try cloneDependencies(self.allocator, dependencies);
        errdefer freeDependencies(self.allocator, owned);
        if (package.dependencies_by_version.getPtr(version)) |existing| {
            freeDependencies(self.allocator, existing.*);
            existing.* = owned;
            return;
        }
        try package.dependencies_by_version.put(version, owned);
    }

    pub fn getLatestVersion(self: *PackageRegistry, package_name: []const u8) !AdvancedDependencyResolver.SemanticVersion {
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

    pub fn getVersions(self: *PackageRegistry, package_name: []const u8) ![]AdvancedDependencyResolver.SemanticVersion {
        const pkg = self.packages.get(package_name) orelse return error.PackageNotFound;
        return try self.allocator.dupe(AdvancedDependencyResolver.SemanticVersion, pkg.versions);
    }

    pub fn getDependencies(
        self: *PackageRegistry,
        package_name: []const u8,
        version: AdvancedDependencyResolver.SemanticVersion,
    ) ![]AdvancedDependencyResolver.Dependency {
        return self.getDependenciesWithAllocator(self.allocator, package_name, version);
    }

    pub fn getDependenciesWithAllocator(
        self: *PackageRegistry,
        allocator: Allocator,
        package_name: []const u8,
        version: AdvancedDependencyResolver.SemanticVersion,
    ) ![]AdvancedDependencyResolver.Dependency {
        const pkg = self.packages.get(package_name) orelse return error.PackageNotFound;

        const deps = pkg.dependencies_by_version.get(version) orelse &.{};
        return try cloneDependencies(allocator, deps);
    }

    fn cloneDependencies(allocator: Allocator, dependencies: []const AdvancedDependencyResolver.Dependency) ![]AdvancedDependencyResolver.Dependency {
        const result = try allocator.alloc(AdvancedDependencyResolver.Dependency, dependencies.len);
        errdefer allocator.free(result);
        var completed: usize = 0;
        errdefer for (result[0..completed]) |dep| allocator.free(dep.name);
        for (dependencies, 0..) |dep, index| {
            result[index] = .{ .name = try allocator.dupe(u8, dep.name), .constraint = dep.constraint };
            completed += 1;
        }
        return result;
    }

    pub fn freeDependencies(allocator: Allocator, dependencies: []AdvancedDependencyResolver.Dependency) void {
        for (dependencies) |dep| allocator.free(dep.name);
        allocator.free(dependencies);
    }
};

/// Compare two semantic versions
/// Returns: -1 if a < b, 0 if a == b, 1 if a > b
fn compareVersions(a: AdvancedDependencyResolver.SemanticVersion, b: AdvancedDependencyResolver.SemanticVersion) i32 {
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

    const v1 = try AdvancedDependencyResolver.SemanticVersion.parse("1.2.3");
    try testing.expectEqual(@as(u32, 1), v1.major);
    try testing.expectEqual(@as(u32, 2), v1.minor);
    try testing.expectEqual(@as(u32, 3), v1.patch);

    const v2 = try AdvancedDependencyResolver.SemanticVersion.parse("0.1.0-alpha");
    try testing.expectEqual(@as(u32, 0), v2.major);
    try testing.expectEqual(@as(u32, 1), v2.minor);
    try testing.expectEqual(@as(u32, 0), v2.patch);
}

test "VersionConstraint - caret" {
    const constraint = AdvancedDependencyResolver.VersionConstraint{
        .operator = .Caret,
        .version = .{ .major = 1, .minor = 2, .patch = 3 },
    };

    try std.testing.expect(constraint.satisfies(.{ .major = 1, .minor = 2, .patch = 3 }));
    try std.testing.expect(constraint.satisfies(.{ .major = 1, .minor = 3, .patch = 0 }));
    try std.testing.expect(!constraint.satisfies(.{ .major = 2, .minor = 0, .patch = 0 }));
    try std.testing.expect(!constraint.satisfies(.{ .major = 1, .minor = 1, .patch = 9 }));
}
