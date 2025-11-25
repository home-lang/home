const std = @import("std");

/// Flame graph generator for CPU profiling visualization
///
/// Generates interactive flame graphs from profiling data.
/// Output formats:
/// - Folded stack format (for flamegraph.pl)
/// - SVG with embedded JavaScript
/// - JSON for custom visualization
pub const FlameGraph = struct {
    allocator: std.mem.Allocator,
    root: *Node,
    total_samples: usize,

    pub const Node = struct {
        allocator: std.mem.Allocator,
        name: []const u8,
        value: usize,
        children: std.StringHashMap(*Node),

        pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Node {
            const node = try allocator.create(Node);
            node.* = .{
                .allocator = allocator,
                .name = try allocator.dupe(u8, name),
                .value = 0,
                .children = std.StringHashMap(*Node).init(allocator),
            };
            return node;
        }

        pub fn deinit(self: *Node) void {
            var it = self.children.valueIterator();
            while (it.next()) |child| {
                child.*.deinit();
            }
            self.children.deinit();
            self.allocator.free(self.name);
            self.allocator.destroy(self);
        }

        pub fn addChild(self: *Node, name: []const u8) !*Node {
            const entry = try self.children.getOrPut(name);
            if (!entry.found_existing) {
                entry.value_ptr.* = try Node.init(self.allocator, name);
            }
            return entry.value_ptr.*;
        }
    };

    pub fn init(allocator: std.mem.Allocator) !FlameGraph {
        return .{
            .allocator = allocator,
            .root = try Node.init(allocator, "root"),
            .total_samples = 0,
        };
    }

    pub fn deinit(self: *FlameGraph) void {
        self.root.deinit();
    }

    /// Add a stack trace to the flame graph
    pub fn addStack(self: *FlameGraph, stack: []const []const u8) !void {
        var current = self.root;

        // Walk stack from bottom to top
        var i = stack.len;
        while (i > 0) {
            i -= 1;
            const frame = stack[i];
            current = try current.addChild(frame);
            current.value += 1;
        }

        self.total_samples += 1;
    }

    /// Generate folded stack format
    pub fn generateFolded(self: *FlameGraph) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        var stack = std.ArrayList([]const u8).init(self.allocator);
        defer stack.deinit();

        try self.writeFolded(writer, self.root, &stack);

        return try buffer.toOwnedSlice();
    }

    fn writeFolded(
        self: *FlameGraph,
        writer: anytype,
        node: *Node,
        stack: *std.ArrayList([]const u8),
    ) !void {
        if (node != self.root) {
            try stack.append(node.name);
        }

        if (node.children.count() == 0 and stack.items.len > 0) {
            // Leaf node - write stack
            for (stack.items, 0..) |frame, i| {
                if (i > 0) try writer.writeByte(';');
                try writer.writeAll(frame);
            }
            try writer.print(" {d}\n", .{node.value});
        } else {
            // Recurse into children
            var it = node.children.valueIterator();
            while (it.next()) |child| {
                try self.writeFolded(writer, child.*, stack);
            }
        }

        if (node != self.root) {
            _ = stack.pop();
        }
    }

    /// Generate SVG flame graph
    pub fn generateSVG(self: *FlameGraph, width: usize, height: usize) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        // SVG header
        try writer.print(
            \\<?xml version="1.0" standalone="no"?>
            \\<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
            \\<svg version="1.1" width="{d}" height="{d}" xmlns="http://www.w3.org/2000/svg">
            \\<defs>
            \\  <linearGradient id="background" y1="0" y2="1" x1="0" x2="0">
            \\    <stop stop-color="#eeeeee" offset="5%"/>
            \\    <stop stop-color="#eeeeb0" offset="95%"/>
            \\  </linearGradient>
            \\</defs>
            \\<style type="text/css">
            \\  .func_g:hover {{ stroke:black; stroke-width:0.5; cursor:pointer; }}
            \\</style>
            \\<rect x="0" y="0" width="{d}" height="{d}" fill="url(#background)"/>
            \\<text text-anchor="middle" x="{d}" y="24" font-size="17" font-family="Verdana" fill="rgb(0,0,0)">Flame Graph</text>
            \\
        , .{ width, height, width, height, width / 2 });

        // Generate rectangles
        const frame_height = 16;
        try self.generateSVGNode(
            writer,
            self.root,
            0,
            @as(f64, @floatFromInt(width)),
            40,
            frame_height,
        );

        // SVG footer
        try writer.writeAll("</svg>\n");

        return try buffer.toOwnedSlice();
    }

    fn generateSVGNode(
        self: *FlameGraph,
        writer: anytype,
        node: *Node,
        x: f64,
        width: f64,
        y: usize,
        frame_height: usize,
    ) !void {
        if (node == self.root) {
            // Skip root, process children
            var it = node.children.valueIterator();
            while (it.next()) |child| {
                const child_width = @as(f64, @floatFromInt(child.*.value)) /
                    @as(f64, @floatFromInt(self.total_samples)) * width;

                try self.generateSVGNode(
                    writer,
                    child.*,
                    x,
                    child_width,
                    y,
                    frame_height,
                );
            }
            return;
        }

        // Generate rectangle for this node
        const percentage = @as(f64, @floatFromInt(node.value)) /
            @as(f64, @floatFromInt(self.total_samples)) * 100.0;

        const color = self.getColor(node.name);

        try writer.print(
            \\<g class="func_g">
            \\  <title>{s} ({d} samples, {d:.2}%)</title>
            \\  <rect x="{d:.1}" y="{d}" width="{d:.1}" height="{d}" fill="rgb({d},{d},{d})"/>
            \\  <text x="{d:.1}" y="{d}" font-size="12" font-family="Verdana" fill="rgb(0,0,0)">{s}</text>
            \\</g>
            \\
        , .{
            node.name,
            node.value,
            percentage,
            x,
            y,
            width,
            frame_height - 1,
            color[0],
            color[1],
            color[2],
            x + 3,
            y + 12,
            node.name,
        });

        // Process children
        if (node.children.count() > 0) {
            var child_x = x;
            var it = node.children.valueIterator();
            while (it.next()) |child| {
                const child_width = @as(f64, @floatFromInt(child.*.value)) /
                    @as(f64, @floatFromInt(node.value)) * width;

                try self.generateSVGNode(
                    writer,
                    child.*,
                    child_x,
                    child_width,
                    y + frame_height,
                    frame_height,
                );

                child_x += child_width;
            }
        }
    }

    fn getColor(self: *FlameGraph, name: []const u8) [3]u8 {
        _ = self;
        // Simple hash-based color generation
        var hash: u32 = 0;
        for (name) |c| {
            hash = hash *% 31 +% c;
        }

        const r = @as(u8, @intCast((hash % 200) + 55));
        const g = @as(u8, @intCast(((hash >> 8) % 200) + 55));
        const b = @as(u8, @intCast(((hash >> 16) % 200) + 55));

        return .{ r, g, b };
    }

    /// Generate JSON representation
    pub fn generateJSON(self: *FlameGraph) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        try writer.writeAll("{\n");
        try writer.print("  \"total_samples\": {d},\n", .{self.total_samples});
        try writer.writeAll("  \"root\": ");
        try self.writeNodeJSON(writer, self.root, 2);
        try writer.writeAll("\n}\n");

        return try buffer.toOwnedSlice();
    }

    fn writeNodeJSON(self: *FlameGraph, writer: anytype, node: *Node, indent: usize) !void {
        _ = self;
        try writer.writeAll("{\n");

        // Indent
        var i: usize = 0;
        while (i < indent + 2) : (i += 1) {
            try writer.writeByte(' ');
        }

        try writer.print("\"name\": \"{s}\",\n", .{node.name});

        i = 0;
        while (i < indent + 2) : (i += 1) {
            try writer.writeByte(' ');
        }

        try writer.print("\"value\": {d}", .{node.value});

        if (node.children.count() > 0) {
            try writer.writeAll(",\n");

            i = 0;
            while (i < indent + 2) : (i += 1) {
                try writer.writeByte(' ');
            }

            try writer.writeAll("\"children\": [\n");

            var it = node.children.valueIterator();
            var first = true;
            while (it.next()) |child| {
                if (!first) try writer.writeAll(",\n");

                i = 0;
                while (i < indent + 4) : (i += 1) {
                    try writer.writeByte(' ');
                }

                try self.writeNodeJSON(writer, child.*, indent + 4);
                first = false;
            }

            try writer.writeByte('\n');

            i = 0;
            while (i < indent + 2) : (i += 1) {
                try writer.writeByte(' ');
            }

            try writer.writeByte(']');
        }

        try writer.writeByte('\n');

        i = 0;
        while (i < indent) : (i += 1) {
            try writer.writeByte(' ');
        }

        try writer.writeByte('}');
    }
};

/// Differential flame graph for comparing two profiles
pub const DiffFlameGraph = struct {
    allocator: std.mem.Allocator,
    before: *FlameGraph,
    after: *FlameGraph,

    pub fn init(allocator: std.mem.Allocator, before: *FlameGraph, after: *FlameGraph) DiffFlameGraph {
        return .{
            .allocator = allocator,
            .before = before,
            .after = after,
        };
    }

    /// Generate differential flame graph showing changes
    pub fn generate(self: *DiffFlameGraph) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        try writer.writeAll("# Differential Flame Graph\n");
        try writer.writeAll("# Positive values = increase, Negative values = decrease\n\n");

        try self.compareTrees(writer, self.before.root, self.after.root, &.{});

        return try buffer.toOwnedSlice();
    }

    fn compareTrees(
        self: *DiffFlameGraph,
        writer: anytype,
        before_node: *FlameGraph.Node,
        after_node: *FlameGraph.Node,
        stack: []const []const u8,
    ) !void {
        _ = self;

        const before_total = @as(f64, @floatFromInt(before_node.value));
        const after_total = @as(f64, @floatFromInt(after_node.value));

        const diff = after_total - before_total;
        const pct_change = if (before_total > 0)
            (diff / before_total) * 100.0
        else if (after_total > 0)
            100.0
        else
            0.0;

        // Write stack with diff
        if (stack.len > 0) {
            for (stack, 0..) |frame, i| {
                if (i > 0) try writer.writeByte(';');
                try writer.writeAll(frame);
            }
            try writer.print(" {d:.0} ({d:.1}%)\n", .{ diff, pct_change });
        }

        // Recurse into children
        var it = after_node.children.iterator();
        while (it.next()) |entry| {
            const child_name = entry.key_ptr.*;
            const after_child = entry.value_ptr.*;

            if (before_node.children.get(child_name)) |before_child| {
                var new_stack = std.ArrayList([]const u8).init(self.allocator);
                defer new_stack.deinit();

                try new_stack.appendSlice(stack);
                try new_stack.append(child_name);

                try self.compareTrees(writer, before_child, after_child, new_stack.items);
            }
        }
    }
};

/// Interactive HTML flame graph generator
pub fn generateHTMLFlameGraph(allocator: std.mem.Allocator, flame_graph: *FlameGraph) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    try writer.writeAll(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\  <meta charset="utf-8">
        \\  <title>Flame Graph</title>
        \\  <style>
        \\    body { margin: 0; padding: 20px; font-family: sans-serif; }
        \\    #flamegraph { border: 1px solid #ddd; }
        \\    .info { padding: 10px; background: #f5f5f5; margin-top: 10px; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <h1>Flame Graph</h1>
        \\  <div id="flamegraph"></div>
        \\  <div class="info">
        \\    <p>Total samples:
    );

    try writer.print("{d}</p>\n", .{flame_graph.total_samples});

    try writer.writeAll(
        \\    <p>Hover over boxes to see details. Click to zoom.</p>
        \\  </div>
        \\  <script>
        \\  // Flame graph data and rendering code would go here
        \\  const data =
    );

    const json = try flame_graph.generateJSON();
    defer allocator.free(json);
    try writer.writeAll(json);

    try writer.writeAll(
        \\;
        \\  // Rendering logic here
        \\  </script>
        \\</body>
        \\</html>
        \\
    );

    return try buffer.toOwnedSlice();
}
