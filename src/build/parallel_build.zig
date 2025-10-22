const std = @import("std");
const ast = @import("../ast/ast.zig");
const ModuleLoader = @import("../modules/module_system.zig").ModuleLoader;
const IRCache = @import("../cache/ir_cache.zig").IRCache;

/// Build task representing a single compilation unit
pub const BuildTask = struct {
    module_name: []const u8,
    file_path: []const u8,
    dependencies: []const []const u8,
    status: TaskStatus,

    pub const TaskStatus = enum {
        Pending,
        InProgress,
        Completed,
        Failed,
    };
};

/// Parallel build system for compiling multiple modules
pub const ParallelBuilder = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(*BuildTask),
    module_loader: *ModuleLoader,
    ir_cache: *IRCache,
    num_threads: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        module_loader: *ModuleLoader,
        ir_cache: *IRCache,
        num_threads: ?usize,
    ) ParallelBuilder {
        const threads = num_threads orelse std.Thread.getCpuCount() catch 4;
        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(*BuildTask){},
            .module_loader = module_loader,
            .ir_cache = ir_cache,
            .num_threads = threads,
        };
    }

    pub fn deinit(self: *ParallelBuilder) void {
        for (self.tasks.items) |task| {
            self.allocator.free(task.module_name);
            self.allocator.free(task.file_path);
            for (task.dependencies) |dep| {
                self.allocator.free(dep);
            }
            self.allocator.free(task.dependencies);
            self.allocator.destroy(task);
        }
        self.tasks.deinit(self.allocator);
    }

    /// Add a build task
    pub fn addTask(
        self: *ParallelBuilder,
        module_name: []const u8,
        file_path: []const u8,
        dependencies: []const []const u8,
    ) !void {
        const task = try self.allocator.create(BuildTask);

        const deps_copy = try self.allocator.alloc([]const u8, dependencies.len);
        for (dependencies, 0..) |dep, i| {
            deps_copy[i] = try self.allocator.dupe(u8, dep);
        }

        task.* = .{
            .module_name = try self.allocator.dupe(u8, module_name),
            .file_path = try self.allocator.dupe(u8, file_path),
            .dependencies = deps_copy,
            .status = .Pending,
        };

        try self.tasks.append(self.allocator, task);
    }

    /// Build all tasks in parallel
    pub fn build(self: *ParallelBuilder) !void {
        if (self.tasks.items.len == 0) return;

        std.debug.print("[1mBuilding {d} modules with {d} threads...[0m\n", .{
            self.tasks.items.len,
            self.num_threads,
        });

        // Simple parallel build: process tasks that have no pending dependencies
        while (self.hasPendingTasks()) {
            const ready_tasks = try self.getReadyTasks();
            defer self.allocator.free(ready_tasks);

            if (ready_tasks.len == 0) {
                // Circular dependency detected
                return error.CircularDependency;
            }

            // Build ready tasks in parallel (simplified: sequential for now)
            for (ready_tasks) |task| {
                try self.buildTask(task);
            }
        }

        // Check for failures
        for (self.tasks.items) |task| {
            if (task.status == .Failed) {
                return error.BuildFailed;
            }
        }

        std.debug.print("[32mSuccess:[0m Built {d} modules\n", .{self.tasks.items.len});
    }

    fn hasPendingTasks(self: *ParallelBuilder) bool {
        for (self.tasks.items) |task| {
            if (task.status == .Pending or task.status == .InProgress) {
                return true;
            }
        }
        return false;
    }

    fn getReadyTasks(self: *ParallelBuilder) ![]const *BuildTask {
        var ready = std.ArrayList(*BuildTask){};
        defer ready.deinit(self.allocator);

        for (self.tasks.items) |task| {
            if (task.status != .Pending) continue;

            var dependencies_met = true;
            for (task.dependencies) |dep| {
                if (!self.isDependencyCompleted(dep)) {
                    dependencies_met = false;
                    break;
                }
            }

            if (dependencies_met) {
                try ready.append(self.allocator, task);
            }
        }

        return ready.toOwnedSlice(self.allocator);
    }

    fn isDependencyCompleted(self: *ParallelBuilder, dep_name: []const u8) bool {
        for (self.tasks.items) |task| {
            if (std.mem.eql(u8, task.module_name, dep_name)) {
                return task.status == .Completed;
            }
        }
        return true; // Not in task list, assume external/completed
    }

    fn buildTask(self: *ParallelBuilder, task: *BuildTask) !void {
        task.status = .InProgress;

        std.debug.print("  [34m→[0m Compiling {s}...\n", .{task.module_name});

        // Check cache first
        const file = try std.fs.cwd().openFile(task.file_path, .{});
        defer file.close();
        const source = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 10);
        defer self.allocator.free(source);

        const cached = self.ir_cache.isCacheValid(task.file_path, source) catch false;
        if (cached) {
            std.debug.print("    [2m✓ Using cached IR[0m\n", .{});
            task.status = .Completed;
            return;
        }

        // Load and compile module
        _ = self.module_loader.loadModule(task.module_name) catch {
            std.debug.print("    [31m✗ Failed to compile[0m\n", .{});
            task.status = .Failed;
            return;
        };

        // Cache the result (simplified: just mark as cached)
        self.ir_cache.put(task.file_path, source, &[_]u8{}, &[_]u8{}) catch {};

        std.debug.print("    [32m✓ Compiled successfully[0m\n", .{});
        task.status = .Completed;
    }

    /// Analyze dependencies across all tasks
    pub fn analyzeDependencies(self: *ParallelBuilder) !void {
        std.debug.print("[1mDependency graph:[0m\n", .{});
        for (self.tasks.items) |task| {
            std.debug.print("  {s}", .{task.module_name});
            if (task.dependencies.len > 0) {
                std.debug.print(" -> ", .{});
                for (task.dependencies, 0..) |dep, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{dep});
                }
            }
            std.debug.print("\n", .{});
        }
    }
};
