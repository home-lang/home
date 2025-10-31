// Register Allocator with Graph Coloring
// Implements live range analysis, interference graph construction, and graph coloring

const std = @import("std");
const IR = @import("optimizer.zig").IR;

/// Register allocation result
pub const RegisterAllocation = struct {
    allocator: std.mem.Allocator,
    /// Maps virtual registers to physical registers (u8 -> u8)
    assignments: std.AutoHashMap(u8, u8),
    /// Spilled registers that need stack slots
    spilled: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) RegisterAllocation {
        return .{
            .allocator = allocator,
            .assignments = std.AutoHashMap(u8, u8).init(allocator),
            .spilled = std.ArrayList(u8){},
        };
    }

    pub fn deinit(self: *RegisterAllocation) void {
        self.assignments.deinit();
        self.spilled.deinit(self.allocator);
    }

    pub fn getPhysicalRegister(self: *const RegisterAllocation, virtual_reg: u8) ?u8 {
        return self.assignments.get(virtual_reg);
    }

    pub fn isSpilled(self: *const RegisterAllocation, virtual_reg: u8) bool {
        for (self.spilled.items) |spill| {
            if (spill == virtual_reg) return true;
        }
        return false;
    }
};

/// Live range for a virtual register
pub const LiveRange = struct {
    start: usize, // First instruction that defines/uses this register
    end: usize, // Last instruction that uses this register
};

/// Interference graph for register allocation
pub const InterferenceGraph = struct {
    allocator: std.mem.Allocator,
    /// Number of virtual registers
    num_registers: usize,
    /// Adjacency matrix for interference
    /// edges[i][j] = true means registers i and j interfere
    edges: [][]bool,

    pub fn init(allocator: std.mem.Allocator, num_registers: usize) !InterferenceGraph {
        const edges = try allocator.alloc([]bool, num_registers);
        for (edges) |*row| {
            row.* = try allocator.alloc(bool, num_registers);
            @memset(row.*, false);
        }

        return .{
            .allocator = allocator,
            .num_registers = num_registers,
            .edges = edges,
        };
    }

    pub fn deinit(self: *InterferenceGraph) void {
        for (self.edges) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.edges);
    }

    pub fn addEdge(self: *InterferenceGraph, reg1: u8, reg2: u8) void {
        if (reg1 >= self.num_registers or reg2 >= self.num_registers) return;
        self.edges[reg1][reg2] = true;
        self.edges[reg2][reg1] = true;
    }

    pub fn interferes(self: *const InterferenceGraph, reg1: u8, reg2: u8) bool {
        if (reg1 >= self.num_registers or reg2 >= self.num_registers) return false;
        return self.edges[reg1][reg2];
    }

    pub fn degree(self: *const InterferenceGraph, reg: u8) usize {
        if (reg >= self.num_registers) return 0;
        var count: usize = 0;
        for (self.edges[reg]) |edge| {
            if (edge) count += 1;
        }
        return count;
    }
};

/// Graph coloring register allocator
pub const GraphColoringAllocator = struct {
    allocator: std.mem.Allocator,
    /// Number of available physical registers
    num_physical_regs: u8,
    /// Target architecture
    arch: Architecture,

    pub const Architecture = enum {
        x64, // 16 general-purpose registers (rax-r15)
        arm64, // 31 general-purpose registers (x0-x30)
        riscv64, // 32 general-purpose registers (x0-x31)
    };

    pub fn init(allocator: std.mem.Allocator, arch: Architecture) GraphColoringAllocator {
        const num_regs: u8 = switch (arch) {
            .x64 => 14, // Reserve rsp and rbp
            .arm64 => 29, // Reserve sp and x30 (link register)
            .riscv64 => 30, // Reserve x0 (zero) and sp
        };

        return .{
            .allocator = allocator,
            .num_physical_regs = num_regs,
            .arch = arch,
        };
    }

    /// Analyze live ranges for all virtual registers in a function
    pub fn analyzeLiveRanges(self: *GraphColoringAllocator, func: *const IR.Function) !std.AutoHashMap(u8, LiveRange) {
        var live_ranges = std.AutoHashMap(u8, LiveRange).init(self.allocator);

        for (func.blocks.items, 0..) |*block, block_idx| {
            for (block.instructions.items, 0..) |inst, inst_idx| {
                const position = block_idx * 1000 + inst_idx; // Approximate position

                // Update live ranges based on instruction
                switch (inst) {
                    .add, .sub, .mul, .div, .and_, .or_, .xor, .shl, .shr => |op| {
                        try self.updateLiveRange(&live_ranges, op.dest, position);
                        try self.updateLiveRange(&live_ranges, op.lhs, position);
                        try self.updateLiveRange(&live_ranges, op.rhs, position);
                    },
                    .load => |op| {
                        try self.updateLiveRange(&live_ranges, op.dest, position);
                        try self.updateLiveRange(&live_ranges, op.addr, position);
                    },
                    .store => |op| {
                        try self.updateLiveRange(&live_ranges, op.addr, position);
                        try self.updateLiveRange(&live_ranges, op.value, position);
                    },
                    .move => |op| {
                        try self.updateLiveRange(&live_ranges, op.dest, position);
                        try self.updateLiveRange(&live_ranges, op.src, position);
                    },
                    .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => |op| {
                        try self.updateLiveRange(&live_ranges, op.dest, position);
                        try self.updateLiveRange(&live_ranges, op.lhs, position);
                        try self.updateLiveRange(&live_ranges, op.rhs, position);
                    },
                    else => {},
                }
            }
        }

        return live_ranges;
    }

    fn updateLiveRange(
        self: *GraphColoringAllocator,
        live_ranges: *std.AutoHashMap(u8, LiveRange),
        value: IR.Value,
        position: usize,
    ) !void {
        _ = self;
        if (value != .register) return;

        const reg = value.register;
        const entry = try live_ranges.getOrPut(reg);

        if (!entry.found_existing) {
            entry.value_ptr.* = LiveRange{
                .start = position,
                .end = position,
            };
        } else {
            if (position < entry.value_ptr.start) {
                entry.value_ptr.start = position;
            }
            if (position > entry.value_ptr.end) {
                entry.value_ptr.end = position;
            }
        }
    }

    /// Build interference graph from live ranges
    pub fn buildInterferenceGraph(
        self: *GraphColoringAllocator,
        live_ranges: *const std.AutoHashMap(u8, LiveRange),
    ) !InterferenceGraph {
        // Find maximum register number
        var max_reg: usize = 0;
        var it = live_ranges.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* > max_reg) {
                max_reg = entry.key_ptr.*;
            }
        }

        var graph = try InterferenceGraph.init(self.allocator, max_reg + 1);

        // Add edges for overlapping live ranges
        var it1 = live_ranges.iterator();
        while (it1.next()) |entry1| {
            const reg1 = entry1.key_ptr.*;
            const range1 = entry1.value_ptr.*;

            var it2 = live_ranges.iterator();
            while (it2.next()) |entry2| {
                const reg2 = entry2.key_ptr.*;
                if (reg1 >= reg2) continue; // Avoid duplicates

                const range2 = entry2.value_ptr.*;

                // Check if ranges overlap
                if (rangesOverlap(range1, range2)) {
                    graph.addEdge(reg1, reg2);
                }
            }
        }

        return graph;
    }

    fn rangesOverlap(r1: LiveRange, r2: LiveRange) bool {
        return !(r1.end < r2.start or r2.end < r1.start);
    }

    /// Perform graph coloring using Chaitin's algorithm
    pub fn colorGraph(
        self: *GraphColoringAllocator,
        graph: *const InterferenceGraph,
    ) !RegisterAllocation {
        var allocation = RegisterAllocation.init(self.allocator);
        errdefer allocation.deinit();

        // Stack for removal order
        var stack = std.ArrayList(u8){};
        defer stack.deinit(self.allocator);

        // Track which nodes have been removed
        var removed = try self.allocator.alloc(bool, graph.num_registers);
        defer self.allocator.free(removed);
        @memset(removed, false);

        // Simplification: remove nodes with degree < num_physical_regs
        var changed = true;
        while (changed) {
            changed = false;

            for (0..graph.num_registers) |reg| {
                if (removed[reg]) continue;

                // Calculate current degree (excluding removed neighbors)
                var deg: usize = 0;
                for (0..graph.num_registers) |neighbor| {
                    if (!removed[neighbor] and graph.interferes(@intCast(reg), @intCast(neighbor))) {
                        deg += 1;
                    }
                }

                if (deg < self.num_physical_regs) {
                    try stack.append(self.allocator, @intCast(reg));
                    removed[reg] = true;
                    changed = true;
                }
            }
        }

        // Mark remaining nodes as potential spills
        for (0..graph.num_registers) |reg| {
            if (!removed[reg]) {
                try allocation.spilled.append(self.allocator, @intCast(reg));
            }
        }

        // Coloring: assign colors in reverse order
        while (stack.items.len > 0) {
            const reg = stack.pop() orelse break;

            // Find available colors (not used by neighbors)
            var used_colors = std.StaticBitSet(32).initEmpty();

            for (0..graph.num_registers) |neighbor| {
                if (graph.interferes(reg, @intCast(neighbor))) {
                    if (allocation.assignments.get(@intCast(neighbor))) |color| {
                        used_colors.set(color);
                    }
                }
            }

            // Assign first available color
            var assigned = false;
            for (0..self.num_physical_regs) |color| {
                if (!used_colors.isSet(color)) {
                    try allocation.assignments.put(reg, @intCast(color));
                    assigned = true;
                    break;
                }
            }

            // If no color available, spill this register
            if (!assigned) {
                try allocation.spilled.append(self.allocator, reg);
            }
        }

        return allocation;
    }

    /// Main allocation function
    pub fn allocate(self: *GraphColoringAllocator, func: *const IR.Function) !RegisterAllocation {
        // Step 1: Analyze live ranges
        var live_ranges = try self.analyzeLiveRanges(func);
        defer live_ranges.deinit();

        // Step 2: Build interference graph
        var graph = try self.buildInterferenceGraph(&live_ranges);
        defer graph.deinit();

        // Step 3: Color the graph
        return try self.colorGraph(&graph);
    }
};

// Tests
test "live range analysis" {
    const testing = std.testing;

    var func = IR.Function.init(testing.allocator, "test");
    defer func.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);

    // r0 = r1 + r2
    try block.instructions.append(testing.allocator, .{ .add = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .register = 2 },
    } });

    // r3 = r0 + r1
    try block.instructions.append(testing.allocator, .{ .add = .{
        .dest = .{ .register = 3 },
        .lhs = .{ .register = 0 },
        .rhs = .{ .register = 1 },
    } });

    try func.blocks.append(testing.allocator, block);

    var allocator = GraphColoringAllocator.init(testing.allocator, .x64);
    var live_ranges = try allocator.analyzeLiveRanges(&func);
    defer live_ranges.deinit();

    try testing.expect(live_ranges.count() == 4); // r0, r1, r2, r3
}

test "interference graph" {
    const testing = std.testing;

    var graph = try InterferenceGraph.init(testing.allocator, 4);
    defer graph.deinit();

    graph.addEdge(0, 1);
    graph.addEdge(1, 2);
    graph.addEdge(2, 3);

    try testing.expect(graph.interferes(0, 1));
    try testing.expect(graph.interferes(1, 0));
    try testing.expect(!graph.interferes(0, 2));
    try testing.expect(graph.degree(1) == 2);
    try testing.expect(graph.degree(0) == 1);
}

test "graph coloring" {
    const testing = std.testing;

    var func = IR.Function.init(testing.allocator, "test");
    defer func.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);

    // Create a simple program with register conflicts
    // r0 = r1 + r2
    try block.instructions.append(testing.allocator, .{ .add = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .register = 2 },
    } });

    try func.blocks.append(testing.allocator, block);

    var allocator = GraphColoringAllocator.init(testing.allocator, .x64);
    var allocation = try allocator.allocate(&func);
    defer allocation.deinit();

    // Verify that registers were allocated
    try testing.expect(allocation.assignments.count() >= 1);
}
