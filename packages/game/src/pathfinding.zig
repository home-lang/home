// Home Programming Language - A* Pathfinding
// Efficient grid-based and graph-based pathfinding
//
// Features:
// - A* algorithm with configurable heuristics
// - Grid-based pathfinding
// - Weighted graph pathfinding
// - Path smoothing
// - Hierarchical pathfinding for large maps

const std = @import("std");
const game = @import("game.zig");

// ============================================================================
// Grid-Based A* Pathfinding
// ============================================================================

pub const GridNode = struct {
    x: i32,
    y: i32,
    walkable: bool = true,
    cost: f32 = 1.0,
};

pub const PathNode = struct {
    x: i32,
    y: i32,
    g_cost: f32, // Cost from start
    h_cost: f32, // Heuristic cost to end
    f_cost: f32, // Total cost (g + h)
    parent: ?*PathNode,

    pub fn init(x: i32, y: i32, g: f32, h: f32, parent: ?*PathNode) PathNode {
        return .{
            .x = x,
            .y = y,
            .g_cost = g,
            .h_cost = h,
            .f_cost = g + h,
            .parent = parent,
        };
    }
};

pub const Heuristic = enum {
    manhattan,
    euclidean,
    chebyshev,
    octile,
};

pub const PathfindingConfig = struct {
    heuristic: Heuristic = .manhattan,
    allow_diagonal: bool = true,
    diagonal_cost: f32 = 1.414,
    max_iterations: u32 = 10000,
};

// Named struct for neighbor positions (Zig 0.16 compatibility)
pub const NeighborPos = struct {
    x: i32,
    y: i32,
};

pub const Grid = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    nodes: []GridNode,
    config: PathfindingConfig,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, config: PathfindingConfig) !*Grid {
        const grid = try allocator.create(Grid);
        const total = width * height;
        const nodes = try allocator.alloc(GridNode, total);

        // Initialize all nodes as walkable
        for (0..total) |i| {
            const x: i32 = @intCast(i % width);
            const y: i32 = @intCast(i / width);
            nodes[i] = GridNode{ .x = x, .y = y, .walkable = true, .cost = 1.0 };
        }

        grid.* = .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .nodes = nodes,
            .config = config,
        };

        return grid;
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.nodes);
        self.allocator.destroy(self);
    }

    pub fn getNode(self: *Grid, x: i32, y: i32) ?*GridNode {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.width)) or y >= @as(i32, @intCast(self.height))) {
            return null;
        }
        const index = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        return &self.nodes[index];
    }

    pub fn setWalkable(self: *Grid, x: i32, y: i32, walkable: bool) void {
        if (self.getNode(x, y)) |node| {
            node.walkable = walkable;
        }
    }

    pub fn setCost(self: *Grid, x: i32, y: i32, cost: f32) void {
        if (self.getNode(x, y)) |node| {
            node.cost = cost;
        }
    }

    pub fn isWalkable(self: *Grid, x: i32, y: i32) bool {
        if (self.getNode(x, y)) |node| {
            return node.walkable;
        }
        return false;
    }

    fn heuristic(self: *Grid, x1: i32, y1: i32, x2: i32, y2: i32) f32 {
        const dx = @abs(x1 - x2);
        const dy = @abs(y1 - y2);
        const fdx: f32 = @floatFromInt(dx);
        const fdy: f32 = @floatFromInt(dy);

        return switch (self.config.heuristic) {
            .manhattan => fdx + fdy,
            .euclidean => @sqrt(fdx * fdx + fdy * fdy),
            .chebyshev => @max(fdx, fdy),
            .octile => blk: {
                const F: f32 = @sqrt(2.0) - 1.0;
                break :blk if (fdx > fdy) fdx + F * fdy else fdy + F * fdx;
            },
        };
    }

    fn getNeighbors(self: *Grid, x: i32, y: i32) [8]?NeighborPos {
        var neighbors: [8]?NeighborPos = .{null} ** 8;

        // Cardinal directions
        const dirs = [_]struct { dx: i32, dy: i32, diagonal: bool }{
            .{ .dx = 0, .dy = -1, .diagonal = false }, // Up
            .{ .dx = 0, .dy = 1, .diagonal = false },  // Down
            .{ .dx = -1, .dy = 0, .diagonal = false }, // Left
            .{ .dx = 1, .dy = 0, .diagonal = false },  // Right
            .{ .dx = -1, .dy = -1, .diagonal = true }, // Up-Left
            .{ .dx = 1, .dy = -1, .diagonal = true },  // Up-Right
            .{ .dx = -1, .dy = 1, .diagonal = true },  // Down-Left
            .{ .dx = 1, .dy = 1, .diagonal = true },   // Down-Right
        };

        for (dirs, 0..) |dir, i| {
            if (dir.diagonal and !self.config.allow_diagonal) continue;

            const nx = x + dir.dx;
            const ny = y + dir.dy;

            if (self.isWalkable(nx, ny)) {
                neighbors[i] = .{ .x = nx, .y = ny };
            }
        }

        return neighbors;
    }

    /// Find path using A* algorithm
    pub fn findPath(self: *Grid, start_x: i32, start_y: i32, end_x: i32, end_y: i32) !?[]game.Vec2 {
        // Check if start and end are valid
        if (!self.isWalkable(start_x, start_y) or !self.isWalkable(end_x, end_y)) {
            return null;
        }

        // Same position
        if (start_x == end_x and start_y == end_y) {
            const path = try self.allocator.alloc(game.Vec2, 1);
            path[0] = .{ .x = @floatFromInt(start_x), .y = @floatFromInt(start_y) };
            return path;
        }

        var open_list: std.ArrayList(PathNode) = .{};
        defer open_list.deinit(self.allocator);

        var closed_set = std.AutoHashMap(u64, void).init(self.allocator);
        defer closed_set.deinit();

        var all_nodes: std.ArrayList(*PathNode) = .{};
        defer {
            for (all_nodes.items) |node| {
                self.allocator.destroy(node);
            }
            all_nodes.deinit(self.allocator);
        }

        // Add start node
        const start_h = self.heuristic(start_x, start_y, end_x, end_y);
        const start_node = try self.allocator.create(PathNode);
        start_node.* = PathNode.init(start_x, start_y, 0, start_h, null);
        try all_nodes.append(self.allocator, start_node);
        try open_list.append(self.allocator, start_node.*);

        var iterations: u32 = 0;

        while (open_list.items.len > 0 and iterations < self.config.max_iterations) {
            iterations += 1;

            // Find node with lowest f_cost
            var lowest_idx: usize = 0;
            var lowest_f = open_list.items[0].f_cost;
            for (open_list.items[1..], 1..) |node, i| {
                if (node.f_cost < lowest_f or (node.f_cost == lowest_f and node.h_cost < open_list.items[lowest_idx].h_cost)) {
                    lowest_f = node.f_cost;
                    lowest_idx = i;
                }
            }

            const current = open_list.orderedRemove(lowest_idx);
            const current_key = @as(u64, @intCast(@as(u32, @bitCast(current.x)))) << 32 | @as(u64, @intCast(@as(u32, @bitCast(current.y))));
            try closed_set.put(current_key, {});

            // Found the goal
            if (current.x == end_x and current.y == end_y) {
                return try self.reconstructPath(&current);
            }

            // Check neighbors
            const neighbors = self.getNeighbors(current.x, current.y);
            for (neighbors) |maybe_neighbor| {
                if (maybe_neighbor) |neighbor| {
                    const key = @as(u64, @intCast(@as(u32, @bitCast(neighbor.x)))) << 32 | @as(u64, @intCast(@as(u32, @bitCast(neighbor.y))));

                    if (closed_set.contains(key)) continue;

                    const node_cost = if (self.getNode(neighbor.x, neighbor.y)) |n| n.cost else 1.0;
                    const is_diagonal = neighbor.x != current.x and neighbor.y != current.y;
                    const move_cost = if (is_diagonal) self.config.diagonal_cost else 1.0;
                    const new_g = current.g_cost + node_cost * move_cost;

                    // Check if already in open list with better cost
                    var in_open = false;
                    for (open_list.items) |*open_node| {
                        if (open_node.x == neighbor.x and open_node.y == neighbor.y) {
                            in_open = true;
                            if (new_g < open_node.g_cost) {
                                open_node.g_cost = new_g;
                                open_node.f_cost = new_g + open_node.h_cost;
                                // Update parent - find matching stored node
                                for (all_nodes.items) |stored| {
                                    if (stored.x == current.x and stored.y == current.y) {
                                        open_node.parent = stored;
                                        break;
                                    }
                                }
                            }
                            break;
                        }
                    }

                    if (!in_open) {
                        const h = self.heuristic(neighbor.x, neighbor.y, end_x, end_y);
                        const new_node = try self.allocator.create(PathNode);

                        // Find parent node reference
                        var parent_ref: ?*PathNode = null;
                        for (all_nodes.items) |stored| {
                            if (stored.x == current.x and stored.y == current.y) {
                                parent_ref = stored;
                                break;
                            }
                        }

                        new_node.* = PathNode.init(neighbor.x, neighbor.y, new_g, h, parent_ref);
                        try all_nodes.append(self.allocator, new_node);
                        try open_list.append(self.allocator, new_node.*);
                    }
                }
            }
        }

        return null; // No path found
    }

    fn reconstructPath(self: *Grid, end_node: *const PathNode) ![]game.Vec2 {
        var path_length: usize = 0;
        var node: ?*const PathNode = end_node;
        while (node != null) : (node = node.?.parent) {
            path_length += 1;
        }

        const path = try self.allocator.alloc(game.Vec2, path_length);

        node = end_node;
        var i: usize = path_length;
        while (node != null) : (node = node.?.parent) {
            i -= 1;
            path[i] = .{
                .x = @floatFromInt(node.?.x),
                .y = @floatFromInt(node.?.y),
            };
        }

        return path;
    }
};

// ============================================================================
// Path Smoothing
// ============================================================================

pub fn smoothPath(allocator: std.mem.Allocator, path: []const game.Vec2, grid: *Grid) ![]game.Vec2 {
    if (path.len <= 2) {
        const result = try allocator.alloc(game.Vec2, path.len);
        @memcpy(result, path);
        return result;
    }

    var smoothed = std.ArrayList(game.Vec2).init(allocator);
    defer smoothed.deinit();

    try smoothed.append(path[0]);

    var current_idx: usize = 0;
    while (current_idx < path.len - 1) {
        var furthest = current_idx + 1;

        // Find furthest visible point
        for (current_idx + 2..path.len) |i| {
            if (hasLineOfSight(grid, path[current_idx], path[i])) {
                furthest = i;
            }
        }

        try smoothed.append(path[furthest]);
        current_idx = furthest;
    }

    return try smoothed.toOwnedSlice();
}

fn hasLineOfSight(grid: *Grid, start: game.Vec2, end: game.Vec2) bool {
    // Bresenham's line algorithm
    var x0: i32 = @intFromFloat(start.x);
    var y0: i32 = @intFromFloat(start.y);
    const x1: i32 = @intFromFloat(end.x);
    const y1: i32 = @intFromFloat(end.y);

    const dx = @abs(x1 - x0);
    const dy = @abs(y1 - y0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx - dy;

    while (true) {
        if (!grid.isWalkable(x0, y0)) {
            return false;
        }

        if (x0 == x1 and y0 == y1) break;

        const e2 = 2 * err;
        if (e2 > -dy) {
            err -= dy;
            x0 += sx;
        }
        if (e2 < dx) {
            err += dx;
            y0 += sy;
        }
    }

    return true;
}

// ============================================================================
// Graph-Based Pathfinding
// ============================================================================

pub const GraphNode = struct {
    pub const Edge = struct {
        to: u32,
        cost: f32,
    };

    id: u32,
    position: game.Vec2,
    edges: std.ArrayList(Edge),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u32, pos: game.Vec2) GraphNode {
        return .{
            .id = id,
            .position = pos,
            .edges = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GraphNode) void {
        self.edges.deinit(self.allocator);
    }

    pub fn addEdge(self: *GraphNode, to: u32, cost: f32) !void {
        try self.edges.append(self.allocator, .{ .to = to, .cost = cost });
    }
};

// Named struct for priority queue entries (Zig 0.16 compatibility)
pub const PQEntry = struct {
    id: u32,
    f: f32,

    pub fn lessThan(_: void, a: PQEntry, b: PQEntry) std.math.Order {
        return std.math.order(a.f, b.f);
    }
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u32, GraphNode),

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u32, GraphNode).init(allocator),
        };
    }

    pub fn deinit(self: *Graph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            node.deinit();
        }
        self.nodes.deinit();
    }

    pub fn addNode(self: *Graph, id: u32, pos: game.Vec2) !void {
        try self.nodes.put(id, GraphNode.init(self.allocator, id, pos));
    }

    pub fn addEdge(self: *Graph, from: u32, to: u32, cost: f32) !void {
        if (self.nodes.getPtr(from)) |node| {
            try node.addEdge(to, cost);
        }
    }

    pub fn findPath(self: *Graph, start: u32, end: u32) !?[]u32 {
        const start_node = self.nodes.get(start) orelse return null;
        const end_node = self.nodes.get(end) orelse return null;

        var open = std.PriorityQueue(PQEntry, void, PQEntry.lessThan).init(self.allocator, {});
        defer open.deinit();

        var g_scores = std.AutoHashMap(u32, f32).init(self.allocator);
        defer g_scores.deinit();

        var came_from = std.AutoHashMap(u32, u32).init(self.allocator);
        defer came_from.deinit();

        try g_scores.put(start, 0);
        const h = start_node.position.distance(end_node.position);
        try open.add(PQEntry{ .id = start, .f = h });

        while (open.removeOrNull()) |current| {
            if (current.id == end) {
                // Reconstruct path
                var path: std.ArrayList(u32) = .{};
                var node_id = end;
                while (came_from.get(node_id)) |prev| {
                    try path.append(self.allocator, node_id);
                    node_id = prev;
                }
                try path.append(self.allocator, start);
                std.mem.reverse(u32, path.items);
                return try path.toOwnedSlice(self.allocator);
            }

            const current_node = self.nodes.get(current.id) orelse continue;
            const current_g = g_scores.get(current.id) orelse std.math.inf(f32);

            for (current_node.edges.items) |edge| {
                const tentative_g = current_g + edge.cost;
                const neighbor_g = g_scores.get(edge.to) orelse std.math.inf(f32);

                if (tentative_g < neighbor_g) {
                    try came_from.put(edge.to, current.id);
                    try g_scores.put(edge.to, tentative_g);

                    if (self.nodes.get(edge.to)) |neighbor_node| {
                        const h_cost = neighbor_node.position.distance(end_node.position);
                        try open.add(PQEntry{ .id = edge.to, .f = tentative_g + h_cost });
                    }
                }
            }
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Grid A* pathfinding" {
    const allocator = std.testing.allocator;

    var grid = try Grid.init(allocator, 10, 10, .{});
    defer grid.deinit();

    // Create obstacle
    grid.setWalkable(5, 3, false);
    grid.setWalkable(5, 4, false);
    grid.setWalkable(5, 5, false);

    const path = try grid.findPath(0, 4, 9, 4);
    defer if (path) |p| allocator.free(p);

    try std.testing.expect(path != null);
    if (path) |p| {
        try std.testing.expect(p.len > 0);
        try std.testing.expectEqual(@as(f32, 0), p[0].x);
        try std.testing.expectEqual(@as(f32, 4), p[0].y);
        try std.testing.expectEqual(@as(f32, 9), p[p.len - 1].x);
        try std.testing.expectEqual(@as(f32, 4), p[p.len - 1].y);
    }
}

test "Graph pathfinding" {
    const allocator = std.testing.allocator;

    var graph = Graph.init(allocator);
    defer graph.deinit();

    try graph.addNode(0, .{ .x = 0, .y = 0 });
    try graph.addNode(1, .{ .x = 1, .y = 0 });
    try graph.addNode(2, .{ .x = 2, .y = 0 });

    try graph.addEdge(0, 1, 1.0);
    try graph.addEdge(1, 2, 1.0);

    const path = try graph.findPath(0, 2);
    defer if (path) |p| allocator.free(p);

    try std.testing.expect(path != null);
    if (path) |p| {
        try std.testing.expectEqual(@as(usize, 3), p.len);
        try std.testing.expectEqual(@as(u32, 0), p[0]);
        try std.testing.expectEqual(@as(u32, 1), p[1]);
        try std.testing.expectEqual(@as(u32, 2), p[2]);
    }
}
