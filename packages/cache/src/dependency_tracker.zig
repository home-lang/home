const std = @import("std");
const ast = @import("ast");

const DependencyList = std.ArrayList([]const u8);
const DependencyGraph = std.StringHashMap(DependencyList);

/// Tracks dependencies between modules for incremental compilation
/// Builds a dependency graph and supports invalidation propagation
pub const DependencyTracker = struct {
    allocator: std.mem.Allocator,
    /// Maps module path -> list of modules it depends on
    dependencies: DependencyGraph,
    /// Maps module path -> list of modules that depend on it (reverse)
    dependents: DependencyGraph,
    /// Track which modules have been invalidated
    invalidated: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) DependencyTracker {
        return .{
            .allocator = allocator,
            .dependencies = DependencyGraph.init(allocator),
            .dependents = DependencyGraph.init(allocator),
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
            entry.value_ptr.deinit(self.allocator);
        }
        self.dependencies.deinit();

        var dep_it = self.dependents.iterator();
        while (dep_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dependent| {
                self.allocator.free(dependent);
            }
            entry.value_ptr.deinit(self.allocator);
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
        const dependency_entry = try self.getOrCreateEntry(&self.dependencies, module);
        errdefer if (dependency_entry.inserted and dependency_entry.list.items.len == 0) {
            self.removeEmptyEntry(&self.dependencies, module);
        };

        const dependent_entry = try self.getOrCreateEntry(&self.dependents, dependency);
        errdefer if (dependent_entry.inserted and dependent_entry.list.items.len == 0) {
            self.removeEmptyEntry(&self.dependents, dependency);
        };

        const add_forward = !contains(dependency_entry.list.items, dependency);
        const add_reverse = !contains(dependent_entry.list.items, module);
        if (!add_forward and !add_reverse) return;

        // Reserve and duplicate both sides before mutating either graph. This
        // keeps the forward and reverse edges coherent on allocation failure.
        if (add_forward) try dependency_entry.list.ensureUnusedCapacity(self.allocator, 1);
        if (add_reverse) try dependent_entry.list.ensureUnusedCapacity(self.allocator, 1);

        const owned_dependency = if (add_forward) try self.allocator.dupe(u8, dependency) else null;
        errdefer if (owned_dependency) |value| self.allocator.free(value);
        const owned_module = if (add_reverse) try self.allocator.dupe(u8, module) else null;
        errdefer if (owned_module) |value| self.allocator.free(value);

        if (owned_dependency) |value| dependency_entry.list.appendAssumeCapacity(value);
        if (owned_module) |value| dependent_entry.list.appendAssumeCapacity(value);
    }

    const Entry = struct {
        list: *DependencyList,
        inserted: bool,
    };

    fn getOrCreateEntry(self: *DependencyTracker, graph: *DependencyGraph, key: []const u8) !Entry {
        if (graph.getPtr(key)) |list| return .{ .list = list, .inserted = false };

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const entry = try graph.getOrPut(owned_key);
        if (entry.found_existing) {
            self.allocator.free(owned_key);
            return .{ .list = entry.value_ptr, .inserted = false };
        }

        entry.key_ptr.* = owned_key;
        entry.value_ptr.* = .empty;
        return .{ .list = entry.value_ptr, .inserted = true };
    }

    fn removeEmptyEntry(self: *DependencyTracker, graph: *DependencyGraph, key: []const u8) void {
        const removed = graph.fetchRemove(key) orelse return;
        std.debug.assert(removed.value.items.len == 0);
        self.allocator.free(removed.key);
        var list = removed.value;
        list.deinit(self.allocator);
    }

    fn contains(items: []const []const u8, needle: []const u8) bool {
        for (items) |item| {
            if (std.mem.eql(u8, item, needle)) return true;
        }
        return false;
    }

    /// Extract dependencies from AST import statements
    pub fn extractFromAST(self: *DependencyTracker, module_path: []const u8, program: *ast.Program) !void {
        for (program.statements) |stmt| {
            switch (stmt) {
                .ImportDecl => |import_decl| {
                    const dep_path = try std.mem.join(self.allocator, "/", import_decl.path);
                    defer self.allocator.free(dep_path);
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
        self.invalidated.put(module_copy, {}) catch |err| {
            self.allocator.free(module_copy);
            return err;
        };

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
    /// The caller owns the returned slice and every string in it.
    pub fn getCompilationOrder(self: *DependencyTracker) ![][]const u8 {
        var order: DependencyList = .empty;
        errdefer {
            for (order.items) |module| self.allocator.free(module);
            order.deinit(self.allocator);
        }
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            try self.visitModule(entry.key_ptr.*, &order, &visited);
        }

        return order.toOwnedSlice(self.allocator);
    }

    fn visitModule(
        self: *DependencyTracker,
        module: []const u8,
        order: *DependencyList,
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
        const owned_module = try self.allocator.dupe(u8, module);
        errdefer self.allocator.free(owned_module);
        try order.append(self.allocator, owned_module);
    }

    /// Detect circular dependencies
    /// The caller owns the returned slice and every string in it.
    pub fn detectCycles(self: *DependencyTracker) !?[][]const u8 {
        var visiting = std.StringHashMap(void).init(self.allocator);
        defer visiting.deinit();

        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var path: DependencyList = .empty;
        defer path.deinit(self.allocator);

        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            if (try self.detectCycleFrom(entry.key_ptr.*, &visiting, &visited, &path)) {
                return try self.cloneCycle(path.items);
            }
        }

        return null;
    }

    fn detectCycleFrom(
        self: *DependencyTracker,
        module: []const u8,
        visiting: *std.StringHashMap(void),
        visited: *std.StringHashMap(void),
        path: *DependencyList,
    ) !bool {
        if (visited.contains(module)) {
            return false;
        }

        if (visiting.contains(module)) {
            try path.append(self.allocator, module);
            return true;
        }

        try visiting.put(module, {});
        errdefer _ = visiting.remove(module);
        try path.append(self.allocator, module);
        errdefer _ = path.pop();

        if (self.dependencies.get(module)) |deps| {
            for (deps.items) |dep| {
                if (try self.detectCycleFrom(dep, visiting, visited, path)) {
                    return true;
                }
            }
        }

        try visited.put(module, {});
        _ = path.pop();
        _ = visiting.remove(module);

        return false;
    }

    fn cloneCycle(self: *DependencyTracker, path: []const []const u8) ![][]const u8 {
        std.debug.assert(path.len >= 2);
        const repeated = path[path.len - 1];
        var start: usize = 0;
        while (!std.mem.eql(u8, path[start], repeated)) : (start += 1) {}

        const result = try self.allocator.alloc([]const u8, path.len - start);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |module| self.allocator.free(module);
            self.allocator.free(result);
        }
        for (path[start..], result) |module, *slot| {
            slot.* = try self.allocator.dupe(u8, module);
            initialized += 1;
        }
        return result;
    }

    /// Get statistics about dependency graph
    pub fn getStats(self: *DependencyTracker) Stats {
        var total_deps: usize = 0;
        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            total_deps += entry.value_ptr.items.len;
        }

        var total_modules = self.dependencies.count();
        var dependent_it = self.dependents.iterator();
        while (dependent_it.next()) |entry| {
            if (!self.dependencies.contains(entry.key_ptr.*)) total_modules += 1;
        }

        return .{
            .total_modules = total_modules,
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
