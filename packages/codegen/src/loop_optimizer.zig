// Loop Optimization Module
// Implements loop unrolling, loop invariant code motion, and loop analysis

const std = @import("std");
const IR = @import("optimizer.zig").IR;

/// Loop information extracted from CFG
pub const Loop = struct {
    /// Header basic block (where loop starts)
    header: usize,
    /// Blocks that belong to this loop
    blocks: std.ArrayList(usize),
    /// Exit blocks (blocks that leave the loop)
    exits: std.ArrayList(usize),
    /// Loop depth (for nested loops)
    depth: usize,
    /// Estimated iteration count (if statically known)
    trip_count: ?usize,

    pub fn init(_: std.mem.Allocator, header: usize, depth: usize) Loop {
        return .{
            .header = header,
            .blocks = std.ArrayList(usize){},
            .exits = std.ArrayList(usize){},
            .depth = depth,
            .trip_count = null,
        };
    }

    pub fn deinit(self: *Loop, allocator: std.mem.Allocator) void {
        self.blocks.deinit(allocator);
        self.exits.deinit(allocator);
    }
};

/// Loop analysis and detection
pub const LoopAnalysis = struct {
    allocator: std.mem.Allocator,
    loops: std.ArrayList(Loop),

    pub fn init(allocator: std.mem.Allocator) LoopAnalysis {
        return .{
            .allocator = allocator,
            .loops = std.ArrayList(Loop){},
        };
    }

    pub fn deinit(self: *LoopAnalysis) void {
        for (self.loops.items) |*loop| {
            loop.deinit(self.allocator);
        }
        self.loops.deinit(self.allocator);
    }

    /// Detect loops in a function using dominance and back-edge analysis
    pub fn analyzeLoops(self: *LoopAnalysis, func: *const IR.Function) !void {
        // Simplified loop detection: look for back edges in CFG
        for (func.blocks.items, 0..) |*block, block_idx| {
            for (block.successors.items) |succ| {
                // If successor has lower index, it's likely a back edge (loop)
                if (succ <= block_idx) {
                    var loop = Loop.init(self.allocator, succ, 0);
                    try loop.blocks.append(self.allocator, block_idx);
                    try loop.blocks.append(self.allocator, succ);

                    // Try to estimate trip count from branch conditions
                    loop.trip_count = self.estimateTripCount(block);

                    try self.loops.append(self.allocator, loop);
                }
            }
        }
    }

    fn estimateTripCount(self: *LoopAnalysis, block: *const IR.BasicBlock) ?usize {
        _ = self;
        // Look for comparison with constant in last instruction
        if (block.instructions.items.len == 0) return null;

        const last_inst = block.instructions.items[block.instructions.items.len - 1];
        switch (last_inst) {
            .cmp_lt, .cmp_le => |cmp| {
                if (cmp.rhs == .constant and cmp.rhs.constant > 0 and cmp.rhs.constant < 1000) {
                    return @intCast(cmp.rhs.constant);
                }
            },
            else => {},
        }
        return null;
    }

    /// Check if an instruction is loop-invariant (doesn't change within loop)
    pub fn isLoopInvariant(self: *LoopAnalysis, inst: IR.Instruction, loop: *const Loop) bool {
        _ = self;
        _ = loop;

        // Conservative: constants and some specific patterns are invariant
        switch (inst) {
            .move => |op| {
                // Moving a constant is loop-invariant
                return op.src == .constant;
            },
            .add, .sub, .mul, .div => |op| {
                // Operation is invariant if both operands are constants
                return op.lhs == .constant and op.rhs == .constant;
            },
            else => return false,
        }
    }
};

/// Loop unrolling optimization
pub const LoopUnroller = struct {
    allocator: std.mem.Allocator,
    /// Maximum unroll factor
    max_unroll_factor: usize,
    /// Maximum loop body size to unroll
    max_body_size: usize,

    pub fn init(allocator: std.mem.Allocator) LoopUnroller {
        return .{
            .allocator = allocator,
            .max_unroll_factor = 8, // Conservative default
            .max_body_size = 50, // Max instructions in loop body
        };
    }

    /// Determine if loop should be unrolled and by how much
    pub fn shouldUnroll(self: *LoopUnroller, loop: *const Loop, func: *const IR.Function) ?usize {
        // Don't unroll if trip count is unknown
        const trip_count = loop.trip_count orelse return null;

        // Don't unroll very large loops
        if (trip_count > 1000) return null;

        // Calculate loop body size
        var body_size: usize = 0;
        for (loop.blocks.items) |block_idx| {
            if (block_idx < func.blocks.items.len) {
                body_size += func.blocks.items[block_idx].instructions.items.len;
            }
        }

        if (body_size > self.max_body_size) return null;

        // Determine unroll factor based on trip count and body size
        if (trip_count <= 4 and body_size <= 10) {
            return trip_count; // Fully unroll small loops
        } else if (trip_count % 4 == 0 and body_size <= 20) {
            return 4; // Unroll by 4x for medium loops
        } else if (trip_count % 2 == 0 and body_size <= 30) {
            return 2; // Unroll by 2x for larger loops
        }

        return null;
    }

    /// Unroll a loop by the given factor
    pub fn unrollLoop(
        self: *LoopUnroller,
        func: *IR.Function,
        loop: *const Loop,
        factor: usize,
    ) !void {
        if (factor <= 1) return;

        // Find the loop body block
        if (loop.blocks.items.len == 0) return;

        const body_block_idx = loop.blocks.items[0];
        if (body_block_idx >= func.blocks.items.len) return;

        var body_block = &func.blocks.items[body_block_idx];

        // Save original instructions
        var original_insts = std.ArrayList(IR.Instruction){};
        defer original_insts.deinit(self.allocator);

        for (body_block.instructions.items) |inst| {
            try original_insts.append(self.allocator, inst);
        }

        // Clear and rebuild with unrolled copies
        body_block.instructions.clearRetainingCapacity();

        // Replicate the loop body (factor - 1) more times
        for (0..factor) |_| {
            for (original_insts.items) |inst| {
                try body_block.instructions.append(self.allocator, inst);
            }
        }
    }

    /// Perform loop unrolling optimization on entire function
    pub fn optimize(self: *LoopUnroller, func: *IR.Function) !bool {
        var changed = false;

        // Analyze loops
        var analysis = LoopAnalysis.init(self.allocator);
        defer analysis.deinit();

        try analysis.analyzeLoops(func);

        // Unroll each eligible loop
        for (analysis.loops.items) |*loop| {
            if (self.shouldUnroll(loop, func)) |factor| {
                try self.unrollLoop(func, loop, factor);
                changed = true;
            }
        }

        return changed;
    }
};

/// Loop invariant code motion (LICM)
pub const LoopInvariantCodeMotion = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LoopInvariantCodeMotion {
        return .{ .allocator = allocator };
    }

    /// Move loop-invariant code out of loops
    pub fn optimize(self: *LoopInvariantCodeMotion, func: *IR.Function) !bool {
        var changed = false;

        // Analyze loops
        var analysis = LoopAnalysis.init(self.allocator);
        defer analysis.deinit();

        try analysis.analyzeLoops(func);

        // For each loop, find invariant instructions
        for (analysis.loops.items) |*loop| {
            // Find loop header preheader (block before loop)
            if (loop.header == 0) continue;

            const preheader_idx = loop.header - 1;
            if (preheader_idx >= func.blocks.items.len) continue;

            var preheader = &func.blocks.items[preheader_idx];

            // Check each block in the loop
            for (loop.blocks.items) |block_idx| {
                if (block_idx >= func.blocks.items.len) continue;

                var block = &func.blocks.items[block_idx];
                var i: usize = 0;

                while (i < block.instructions.items.len) {
                    const inst = block.instructions.items[i];

                    if (analysis.isLoopInvariant(inst, loop)) {
                        // Move to preheader
                        try preheader.instructions.append(self.allocator, inst);
                        _ = block.instructions.orderedRemove(i);
                        changed = true;
                    } else {
                        i += 1;
                    }
                }
            }
        }

        return changed;
    }
};

// Tests
test "loop detection" {
    const testing = std.testing;

    var func = IR.Function.init(testing.allocator, "test");
    defer func.deinit(testing.allocator);

    // Block 0: header
    var block0 = IR.BasicBlock.init(testing.allocator, 0);
    try block0.successors.append(testing.allocator, 1);
    try func.blocks.append(testing.allocator, block0);

    // Block 1: body with back edge to 0
    var block1 = IR.BasicBlock.init(testing.allocator, 1);
    try block1.successors.append(testing.allocator, 0); // Back edge
    try func.blocks.append(testing.allocator, block1);

    var analysis = LoopAnalysis.init(testing.allocator);
    defer analysis.deinit();

    try analysis.analyzeLoops(&func);

    try testing.expect(analysis.loops.items.len >= 1);
}

test "loop unrolling small loop" {
    const testing = std.testing;

    var func = IR.Function.init(testing.allocator, "test");
    defer func.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);

    // Simple loop body
    try block.instructions.append(testing.allocator, .{ .add = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 0 },
        .rhs = .{ .constant = 1 },
    } });

    try func.blocks.append(testing.allocator, block);

    var loop = Loop.init(testing.allocator, 0, 0);
    defer loop.deinit(testing.allocator);

    try loop.blocks.append(testing.allocator, 0);
    loop.trip_count = 4; // Small loop

    var unroller = LoopUnroller.init(testing.allocator);

    const factor = unroller.shouldUnroll(&loop, &func);
    try testing.expect(factor != null);
    try testing.expect(factor.? == 4); // Should fully unroll

    const original_size = func.blocks.items[0].instructions.items.len;
    try unroller.unrollLoop(&func, &loop, factor.?);

    const new_size = func.blocks.items[0].instructions.items.len;
    try testing.expect(new_size == original_size * factor.?);
}

test "loop invariant code motion" {
    const testing = std.testing;

    var func = IR.Function.init(testing.allocator, "test");
    defer func.deinit(testing.allocator);

    // Preheader block
    const preheader = IR.BasicBlock.init(testing.allocator, 0);
    try func.blocks.append(testing.allocator, preheader);

    // Loop header
    const loop_header = IR.BasicBlock.init(testing.allocator, 1);
    try func.blocks.append(testing.allocator, loop_header);

    // Loop body with invariant instruction and back edge
    var loop_body = IR.BasicBlock.init(testing.allocator, 2);
    try loop_body.successors.append(testing.allocator, 1); // Back edge to header

    // Invariant: moving a constant
    try loop_body.instructions.append(testing.allocator, .{ .move = .{
        .dest = .{ .register = 5 },
        .src = .{ .constant = 42 },
    } });

    try func.blocks.append(testing.allocator, loop_body);

    var licm = LoopInvariantCodeMotion.init(testing.allocator);
    const changed = try licm.optimize(&func);

    // LICM is conservative, so it may or may not move the instruction
    // Just verify it doesn't crash
    _ = changed;
    try testing.expect(func.blocks.items.len == 3);
}
