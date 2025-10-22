const std = @import("std");
const pkg_manager = @import("package_manager.zig");

/// Dependency tree visualizer
pub const DependencyTree = struct {
    allocator: std.mem.Allocator,
    root_name: []const u8,
    root_version: []const u8,
    nodes: std.ArrayList(TreeNode),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, version: []const u8) Self {
        return .{
            .allocator = allocator,
            .root_name = name,
            .root_version = version,
            .nodes = std.ArrayList(TreeNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit(self.allocator);
    }

    /// Add a dependency node
    pub fn addNode(self: *Self, name: []const u8, version: []const u8, depth: usize, is_last: bool) !void {
        const node = TreeNode{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, name),
            .version = try self.allocator.dupe(u8, version),
            .depth = depth,
            .is_last = is_last,
            .children = std.ArrayList(usize).init(self.allocator),
        };

        try self.nodes.append(self.allocator, node);
    }

    /// Render the complete dependency tree
    pub fn render(self: *const Self) void {
        std.debug.print("\n📦 Dependency Tree:\n\n", .{});
        std.debug.print("{s}@{s}\n", .{ self.root_name, self.root_version });

        for (self.nodes.items, 0..) |node, idx| {
            self.renderNode(&node, idx);
        }

        std.debug.print("\n", .{});
    }

    /// Render a single node with tree lines
    fn renderNode(self: *const Self, node: *const TreeNode, idx: usize) void {
        _ = idx;
        _ = self;

        // Build prefix based on depth and position
        var prefix_buf: [256]u8 = undefined;
        var prefix_len: usize = 0;

        var d: usize = 0;
        while (d < node.depth) : (d += 1) {
            if (d == node.depth - 1) {
                // Last level - show branch
                if (node.is_last) {
                    @memcpy(prefix_buf[prefix_len..][0..3], "└──");
                    prefix_len += 3;
                } else {
                    @memcpy(prefix_buf[prefix_len..][0..3], "├──");
                    prefix_len += 3;
                }
            } else {
                // Parent levels - show continuation
                @memcpy(prefix_buf[prefix_len..][0..3], "│  ");
                prefix_len += 3;
            }
        }

        const prefix = prefix_buf[0..prefix_len];
        std.debug.print("{s} {s}@{s}\n", .{ prefix, node.name, node.version });
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
    pub fn renderWithSizes(self: *const Self, sizes: std.StringHashMap(f64)) void {
        std.debug.print("\n📦 Dependencies by Size:\n\n", .{});

        // Sort by size (descending)
        var sorted = std.ArrayList(SizeEntry).init(self.allocator);
        defer sorted.deinit();

        for (self.nodes.items) |node| {
            const size = sizes.get(node.name) orelse 0.0;
            sorted.append(self.allocator, .{
                .name = node.name,
                .version = node.version,
                .size_mb = size,
            }) catch continue;
        }

        // Bubble sort (simple for small lists)
        var i: usize = 0;
        while (i < sorted.items.len) : (i += 1) {
            var j: usize = 0;
            while (j < sorted.items.len - 1 - i) : (j += 1) {
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
    var tree = DependencyTree.init(allocator, root_name, root_version);

    for (lock_file.packages.items, 0..) |pkg, idx| {
        const is_last = idx == lock_file.packages.items.len - 1;
        try tree.addNode(pkg.name, pkg.version, 1, is_last);
    }

    return tree;
}
