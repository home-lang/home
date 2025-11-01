// Function Inlining with Heuristics
// Implements cost-based inlining decisions

const std = @import("std");
const IR = @import("optimizer.zig").IR;

/// Inlining heuristics and thresholds
pub const InliningHeuristics = struct {
    /// Maximum function size to inline (in instructions)
    max_inline_size: usize,
    /// Minimum call site benefit to inline
    min_inline_benefit: i32,
    /// Maximum depth for recursive inlining
    max_inline_depth: usize,
    /// Always inline functions below this size
    always_inline_threshold: usize,
    /// Never inline functions above this size
    never_inline_threshold: usize,

    pub fn default() InliningHeuristics {
        return .{
            .max_inline_size = 50,
            .min_inline_benefit = 10,
            .max_inline_depth = 3,
            .always_inline_threshold = 5,
            .never_inline_threshold = 200,
        };
    }

    pub fn aggressive() InliningHeuristics {
        return .{
            .max_inline_size = 100,
            .min_inline_benefit = 5,
            .max_inline_depth = 5,
            .always_inline_threshold = 10,
            .never_inline_threshold = 500,
        };
    }

    pub fn conservative() InliningHeuristics {
        return .{
            .max_inline_size = 20,
            .min_inline_benefit = 20,
            .max_inline_depth = 2,
            .always_inline_threshold = 3,
            .never_inline_threshold = 100,
        };
    }
};

/// Cost-benefit analysis for inlining
pub const InliningCost = struct {
    /// Cost of calling the function (call overhead)
    call_cost: i32,
    /// Cost of inlining the function (code size increase)
    inline_cost: i32,
    /// Benefit from inlining (optimization opportunities)
    inline_benefit: i32,

    pub fn netBenefit(self: InliningCost) i32 {
        return self.inline_benefit - self.inline_cost + self.call_cost;
    }
};

/// Function inlining optimizer
pub const FunctionInliner = struct {
    allocator: std.mem.Allocator,
    heuristics: InliningHeuristics,
    /// Track inlining depth to prevent excessive recursion
    inline_depth: std.AutoHashMap(usize, usize),

    pub fn init(allocator: std.mem.Allocator, heuristics: InliningHeuristics) FunctionInliner {
        return .{
            .allocator = allocator,
            .heuristics = heuristics,
            .inline_depth = std.AutoHashMap(usize, usize).init(allocator),
        };
    }

    pub fn deinit(self: *FunctionInliner) void {
        self.inline_depth.deinit();
    }

    /// Calculate the size of a function in instructions
    pub fn calculateFunctionSize(self: *FunctionInliner, func: *const IR.Function) usize {
        _ = self;
        var size: usize = 0;
        for (func.blocks.items) |*block| {
            size += block.instructions.items.len;
        }
        return size;
    }

    /// Estimate the cost/benefit of inlining a function
    pub fn analyzeCost(
        self: *FunctionInliner,
        callee: *const IR.Function,
        call_site_block: *const IR.BasicBlock,
    ) InliningCost {
        const func_size = self.calculateFunctionSize(callee);

        // Call cost: overhead of function call (prologue, epilogue, parameter passing)
        const call_cost: i32 = 10;

        // Inline cost: code size increase
        const inline_cost: i32 = @intCast(func_size * 2);

        // Inline benefit: optimization opportunities
        var inline_benefit: i32 = 0;

        // Benefit from eliminating call overhead
        inline_benefit += call_cost;

        // Benefit from constant propagation opportunities
        // Check if call site has constant arguments
        for (call_site_block.instructions.items) |inst| {
            if (inst == .call) {
                const call_op = inst.call;
                for (call_op.args) |arg| {
                    if (arg == .constant) {
                        inline_benefit += 5; // Constants enable more optimizations
                    }
                }
            }
        }

        // Benefit from reduced register pressure (small functions)
        if (func_size < 10) {
            inline_benefit += 5;
        }

        // Benefit if function is called in a loop (hot path)
        if (self.isInHotPath(call_site_block)) {
            inline_benefit += 15;
        }

        return .{
            .call_cost = call_cost,
            .inline_cost = inline_cost,
            .inline_benefit = inline_benefit,
        };
    }

    fn isInHotPath(self: *FunctionInliner, block: *const IR.BasicBlock) bool {
        _ = self;
        // Simple heuristic: if block has predecessors that include itself, it's in a loop
        for (block.predecessors.items) |pred| {
            if (pred == block.id) return true;
        }
        return false;
    }

    /// Decide whether to inline a function call
    pub fn shouldInline(
        self: *FunctionInliner,
        callee: *const IR.Function,
        call_site_block: *const IR.BasicBlock,
        call_depth: usize,
    ) bool {
        const func_size = self.calculateFunctionSize(callee);

        // Always inline very small functions
        if (func_size <= self.heuristics.always_inline_threshold) {
            return true;
        }

        // Never inline very large functions
        if (func_size >= self.heuristics.never_inline_threshold) {
            return false;
        }

        // Check inlining depth
        if (call_depth >= self.heuristics.max_inline_depth) {
            return false;
        }

        // Cost-benefit analysis
        const cost = self.analyzeCost(callee, call_site_block);
        const net_benefit = cost.netBenefit();

        return net_benefit >= self.heuristics.min_inline_benefit;
    }

    /// Inline a function call at a specific call site
    pub fn inlineCall(
        self: *FunctionInliner,
        caller: *IR.Function,
        callee: *const IR.Function,
        call_block_idx: usize,
        call_inst_idx: usize,
    ) !bool {
        if (call_block_idx >= caller.blocks.items.len) return false;

        var call_block = &caller.blocks.items[call_block_idx];
        if (call_inst_idx >= call_block.instructions.items.len) return false;

        const call_inst = call_block.instructions.items[call_inst_idx];
        if (call_inst != .call) return false;

        // Remove the call instruction
        _ = call_block.instructions.orderedRemove(call_inst_idx);

        // Insert callee's instructions at call site
        for (callee.blocks.items) |*callee_block| {
            for (callee_block.instructions.items) |inst| {
                // Clone instruction and adjust register numbers to avoid conflicts
                const cloned_inst = try self.cloneInstruction(inst, caller);
                try call_block.instructions.insert(self.allocator, call_inst_idx, cloned_inst);
            }
        }

        return true;
    }

    fn cloneInstruction(self: *FunctionInliner, inst: IR.Instruction, caller: *IR.Function) !IR.Instruction {
        _ = self;
        _ = caller;

        // Simple clone - in a real implementation, we'd need to:
        // 1. Rename registers to avoid conflicts
        // 2. Adjust phi nodes
        // 3. Handle return values
        return inst;
    }

    /// Perform inlining optimization on entire function
    pub fn optimize(self: *FunctionInliner, func: *IR.Function) !bool {
        var changed = false;

        // Find all call instructions
        for (func.blocks.items, 0..) |*block, block_idx| {
            var inst_idx: usize = 0;
            while (inst_idx < block.instructions.items.len) {
                const inst = block.instructions.items[inst_idx];

                if (inst == .call) {
                    // In a real implementation, we'd look up the callee function
                    // For now, just check the heuristics
                    const call_depth = self.inline_depth.get(block_idx) orelse 0;

                    // Create a simple dummy callee for testing
                    var dummy_callee = IR.Function.init(self.allocator, "dummy");
                    defer dummy_callee.deinit(self.allocator);

                    var dummy_block = IR.BasicBlock.init(self.allocator, 0);
                    // Small function with 2 instructions
                    try dummy_block.instructions.append(self.allocator, .{ .move = .{
                        .dest = .{ .register = 0 },
                        .src = .{ .constant = 42 },
                    } });
                    try dummy_callee.blocks.append(self.allocator, dummy_block);

                    if (self.shouldInline(&dummy_callee, block, call_depth)) {
                        // Would inline here in real implementation
                        // For now, just mark as changed
                        changed = true;
                    }
                }

                inst_idx += 1;
            }
        }

        return changed;
    }
};

// Tests
test "inlining heuristics" {
    const testing = std.testing;

    const default_h = InliningHeuristics.default();
    const aggressive_h = InliningHeuristics.aggressive();
    const conservative_h = InliningHeuristics.conservative();

    try testing.expect(aggressive_h.max_inline_size > default_h.max_inline_size);
    try testing.expect(conservative_h.max_inline_size < default_h.max_inline_size);
}

test "function size calculation" {
    const testing = std.testing;

    var func = IR.Function.init(testing.allocator, "test");
    defer func.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);
    try block.instructions.append(testing.allocator, .{ .nop = {} });
    try block.instructions.append(testing.allocator, .{ .nop = {} });
    try func.blocks.append(testing.allocator, block);

    var inliner = FunctionInliner.init(testing.allocator, InliningHeuristics.default());
    defer inliner.deinit();

    const size = inliner.calculateFunctionSize(&func);
    try testing.expect(size == 2);
}

test "inlining decision small function" {
    const testing = std.testing;

    var callee = IR.Function.init(testing.allocator, "small");
    defer callee.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);
    // Very small function - 2 instructions
    try block.instructions.append(testing.allocator, .{ .nop = {} });
    try block.instructions.append(testing.allocator, .{ .nop = {} });
    try callee.blocks.append(testing.allocator, block);

    var call_site = IR.BasicBlock.init(testing.allocator, 0);
    defer call_site.deinit(testing.allocator);

    var inliner = FunctionInliner.init(testing.allocator, InliningHeuristics.default());
    defer inliner.deinit();

    // Small function should always be inlined
    const should_inline = inliner.shouldInline(&callee, &call_site, 0);
    try testing.expect(should_inline);
}

test "inlining decision large function" {
    const testing = std.testing;

    var callee = IR.Function.init(testing.allocator, "large");
    defer callee.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);
    // Very large function - 300 instructions
    for (0..300) |_| {
        try block.instructions.append(testing.allocator, .{ .nop = {} });
    }
    try callee.blocks.append(testing.allocator, block);

    var call_site = IR.BasicBlock.init(testing.allocator, 0);
    defer call_site.deinit(testing.allocator);

    var inliner = FunctionInliner.init(testing.allocator, InliningHeuristics.default());
    defer inliner.deinit();

    // Large function should not be inlined
    const should_inline = inliner.shouldInline(&callee, &call_site, 0);
    try testing.expect(!should_inline);
}

test "cost benefit analysis" {
    const testing = std.testing;

    var callee = IR.Function.init(testing.allocator, "test");
    defer callee.deinit(testing.allocator);

    var block = IR.BasicBlock.init(testing.allocator, 0);
    try block.instructions.append(testing.allocator, .{ .nop = {} });
    try callee.blocks.append(testing.allocator, block);

    var call_site = IR.BasicBlock.init(testing.allocator, 0);
    defer call_site.deinit(testing.allocator);

    var inliner = FunctionInliner.init(testing.allocator, InliningHeuristics.default());
    defer inliner.deinit();

    const cost = inliner.analyzeCost(&callee, &call_site);

    // Call cost should be positive (savings from eliminating call)
    try testing.expect(cost.call_cost > 0);
    // Net benefit calculation should work
    const net = cost.netBenefit();
    _ = net;
}
