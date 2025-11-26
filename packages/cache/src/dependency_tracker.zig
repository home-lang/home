const std = @import("std");
const ast = @import("ast");

/// Tracks dependencies between modules for incremental compilation
/// Builds a dependency graph and supports invalidation propagation
pub const DependencyTracker = struct {
    allocator: std.mem.Allocator,
    /// Maps module path -> list of modules it depends on
    dependencies: std.StringHashMap(std.ArrayList([]const u8)),
    /// Maps module path -> list of modules that depend on it (reverse)
    dependents: std.StringHashMap(std.ArrayList([]const u8)),
    /// Track which modules have been invalidated
    invalidated: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) DependencyTracker {
        return .{
            .allocator = allocator,
            .dependencies = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .dependents = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .invalidated = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyTracker) void {
        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| {
                self.allocator.free(dep);
            }
            entry.value_ptr.deinit();
        }
        self.dependencies.deinit();

        var dep_it = self.dependents.iterator();
        while (dep_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dependent| {
                self.allocator.free(dependent);
            }
            entry.value_ptr.deinit();
        }
        self.dependents.deinit();

        var inv_it = self.invalidated.iterator();
        while (inv_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.invalidated.deinit();
    }

    /// Add a dependency relationship: module depends on dependency
    pub fn addDependency(self: *DependencyTracker, module: []const u8, dependency: []const u8) !void {
        // Add to dependencies map
        var deps_entry = try self.dependencies.getOrPut(module);
        if (!deps_entry.found_existing) {
            deps_entry.key_ptr.* = try self.allocator.dupe(u8, module);
            deps_entry.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }

        // Check if dependency already exists
        for (deps_entry.value_ptr.items) |existing_dep| {
            if (std.mem.eql(u8, existing_dep, dependency)) {
                return; // Already exists
            }
        }

        try deps_entry.value_ptr.append(try self.allocator.dupe(u8, dependency));

        // Add to reverse map (dependents)
        var dependents_entry = try self.dependents.getOrPut(dependency);
        if (!dependents_entry.found_existing) {
            dependents_entry.key_ptr.* = try self.allocator.dupe(u8, dependency);
            dependents_entry.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }

        // Check if dependent already exists
        for (dependents_entry.value_ptr.items) |existing_dependent| {
            if (std.mem.eql(u8, existing_dependent, module)) {
                return; // Already exists
            }
        }

        try dependents_entry.value_ptr.append(try self.allocator.dupe(u8, module));
    }

    /// Extract dependencies from AST import statements
    pub fn extractFromAST(self: *DependencyTracker, module_path: []const u8, program: *ast.Program) !void {
        for (program.statements) |stmt| {
            switch (stmt) {
                .ImportStmt => |import_stmt| {
                    // Extract module path from import
                    const dep_path = import_stmt.path;
                    try self.addDependency(module_path, dep_path);
                },
                else => {},
            }
        }
    }

    /// Get direct dependencies of a module
    pub fn getDependencies(self: *DependencyTracker, module: []const u8) []const []const u8 {
        if (self.dependencies.get(module)) |deps| {
            return deps.items;
        }
        return &.{};
    }

    /// Get modules that depend on this module
    pub fn getDependents(self: *DependencyTracker, module: []const u8) []const []const u8 {
        if (self.dependents.get(module)) |deps| {
            return deps.items;
        }
        return &.{};
    }

    /// Mark a module as invalidated and propagate to dependents
    pub fn invalidate(self: *DependencyTracker, module: []const u8) !void {
        // Check if already invalidated
        if (self.invalidated.contains(module)) {
            return;
        }

        // Mark as invalidated
        const module_copy = try self.allocator.dupe(u8, module);
        try self.invalidated.put(module_copy, {});

        // Recursively invalidate all dependents
        if (self.dependents.get(module)) |dependent_list| {
            for (dependent_list.items) |dependent| {
                try self.invalidate(dependent);
            }
        }
    }

    /// Check if a module has been invalidated
    pub fn isInvalidated(self: *DependencyTracker, module: []const u8) bool {
        return self.invalidated.contains(module);
    }

    /// Clear invalidation markers
    pub fn clearInvalidations(self: *DependencyTracker) void {
        var it = self.invalidated.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.invalidated.clearRetainingCapacity();
    }

    /// Perform topological sort to get build order
    pub fn getCompilationOrder(self: *DependencyTracker) ![][]const u8 {
        var order = std.ArrayList([]const u8).init(self.allocator);
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            try self.visitModule(entry.key_ptr.*, &order, &visited);
        }

        return order.toOwnedSlice();
    }

    fn visitModule(
        self: *DependencyTracker,
        module: []const u8,
        order: *std.ArrayList([]const u8),
        visited: *std.StringHashMap(void),
    ) !void {
        // Check if already visited
        if (visited.contains(module)) {
            return;
        }

        // Mark as visited
        try visited.put(module, {});

        // Visit dependencies first (depth-first)
        if (self.dependencies.get(module)) |deps| {
            for (deps.items) |dep| {
                try self.visitModule(dep, order, visited);
            }
        }

        // Add to order after dependencies
        try order.append(try self.allocator.dupe(u8, module));
    }

    /// Detect circular dependencies
    pub fn detectCycles(self: *DependencyTracker) !?[][]const u8 {
        var visiting = std.StringHashMap(void).init(self.allocator);
        defer visiting.deinit();

        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var path = std.ArrayList([]const u8).init(self.allocator);
        defer path.deinit();

        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            if (try self.detectCycleFrom(entry.key_ptr.*, &visiting, &visited, &path)) {
                return try path.toOwnedSlice();
            }
        }

        return null;
    }

    fn detectCycleFrom(
        self: *DependencyTracker,
        module: []const u8,
        visiting: *std.StringHashMap(void),
        visited: *std.StringHashMap(void),
        path: *std.ArrayList([]const u8),
    ) !bool {
        if (visited.contains(module)) {
            return false;
        }

        if (visiting.contains(module)) {
            // Cycle detected!
            try path.append(try self.allocator.dupe(u8, module));
            return true;
        }

        try visiting.put(module, {});
        try path.append(try self.allocator.dupe(u8, module));

        if (self.dependencies.get(module)) |deps| {
            for (deps.items) |dep| {
                if (try self.detectCycleFrom(dep, visiting, visited, path)) {
                    return true;
                }
            }
        }

        _ = visiting.remove(module);
        _ = path.pop();
        try visited.put(module, {});

        return false;
    }

    /// Get statistics about dependency graph
    pub fn getStats(self: *DependencyTracker) Stats {
        var total_deps: usize = 0;
        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            total_deps += entry.value_ptr.items.len;
        }

        return .{
            .total_modules = self.dependencies.count(),
            .total_dependencies = total_deps,
            .invalidated_modules = self.invalidated.count(),
        };
    }

    pub const Stats = struct {
        total_modules: usize,
        total_dependencies: usize,
        invalidated_modules: usize,
    };
};
