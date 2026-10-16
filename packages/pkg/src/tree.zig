const std = @import("std");
const pkg_manager = @import("package_manager.zig");

/// Dependency tree visualizer
pub const DependencyTree = struct {
    allocator: std.mem.Allocator,
    root_name: []const u8,
    root_version: []const u8,
    nodes: std.ArrayList(TreeNode),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8) !Self {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        return .{
            .allocator = allocator,
            .root_name = owned_name,
            .root_version = try allocator.dupe(u8, version),
            .nodes = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit(self.allocator);
        self.allocator.free(self.root_name);
        self.allocator.free(self.root_version);
        self.* = undefined;
    }

    /// Add a dependency node
    pub fn addNode(self: *Self, name: []const u8, version: []const u8, depth: usize, is_last: bool) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_version = try self.allocator.dupe(u8, version);
        errdefer self.allocator.free(owned_version);
        const node = TreeNode{
            .allocator = self.allocator,
            .name = owned_name,
            .version = owned_version,
            .depth = depth,
            .is_last = is_last,
            .children = .empty,
        };

        try self.nodes.append(self.allocator, node);
    }

    /// Render the complete dependency tree
    pub fn render(self: *const Self) void {
        std.debug.print("\n📦 Dependency Tree:\n\n", .{});
        std.debug.print("{s}@{s}\n", .{ self.root_name, self.root_version });

        for (self.nodes.items) |*node| {
            renderNode(node);
        }

        std.debug.print("\n", .{});
    }

    /// Render a single node with tree lines
    fn renderNode(node: *const TreeNode) void {
        var d: usize = 0;
        while (d < node.depth) : (d += 1) {
            if (d == node.depth - 1) {
                std.debug.print("{s}", .{if (node.is_last) "└──" else "├──"});
            } else {
                std.debug.print("│  ", .{});
            }
        }
        std.debug.print(" {s}@{s}\n", .{ node.name, node.version });
    }

    /// Render compact tree (single line per dependency)
    pub fn renderCompact(self: *const Self) void {
        std.debug.print("\n📦 Dependencies ({d} total):\n\n", .{self.nodes.items.len});

        for (self.nodes.items) |node| {
            std.debug.print("  • {s}@{s}\n", .{ node.name, node.version });
        }

        std.debug.print("\n", .{});
    }

    /// Show dependency sizes (requires size data)
    pub fn renderWithSizes(self: *const Self, sizes: std.StringHashMap(f64)) !void {
        std.debug.print("\n📦 Dependencies by Size:\n\n", .{});

        // Sort by size (descending)
        var sorted: std.ArrayList(SizeEntry) = .empty;
        defer sorted.deinit(self.allocator);

        for (self.nodes.items) |node| {
            const size = sizes.get(node.name) orelse 0.0;
            try sorted.append(self.allocator, .{
                .name = node.name,
                .version = node.version,
                .size_mb = size,
            });
        }

        // Bubble sort (simple for small lists)
        if (sorted.items.len == 0) return;
        var i: usize = 0;
        while (i < sorted.items.len) : (i += 1) {
            var j: usize = 0;
            while (i + 1 + j < sorted.items.len) : (j += 1) {
                if (sorted.items[j].size_mb < sorted.items[j + 1].size_mb) {
                    const temp = sorted.items[j];
                    sorted.items[j] = sorted.items[j + 1];
                    sorted.items[j + 1] = temp;
                }
            }
        }

        // Render top entries
        const max_show = @min(sorted.items.len, 10);
        var idx: usize = 0;
        while (idx < max_show) : (idx += 1) {
            const entry = sorted.items[idx];
            std.debug.print("  {d}. {s:<30} {d:>6.1} MB\n", .{
                idx + 1,
                entry.name,
                entry.size_mb,
            });
        }

        std.debug.print("\n", .{});
    }
};

/// Tree node representing a dependency
const TreeNode = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    depth: usize,
    is_last: bool,
    children: std.ArrayList(usize),

    pub fn deinit(self: *TreeNode) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.children.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Entry for size-sorted view
const SizeEntry = struct {
    name: []const u8,
    version: []const u8,
    size_mb: f64,
};

/// Build dependency tree from lock file
pub fn buildFromLockFile(allocator: std.mem.Allocator, lock_file: *pkg_manager.LockFile, root_name: []const u8, root_version: []const u8) !DependencyTree {
    var tree = try DependencyTree.init(allocator, root_name, root_version);
    errdefer tree.deinit();

    for (lock_file.packages.items, 0..) |pkg, idx| {
        const is_last = idx == lock_file.packages.items.len - 1;
        try tree.addNode(pkg.name, pkg.version, 1, is_last);
    }

    return tree;
}
