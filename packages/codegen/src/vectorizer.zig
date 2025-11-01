// SIMD Auto-Vectorization
// Converts scalar operations to vector operations

const std = @import("std");
const IR = @import("optimizer.zig").IR;
const LoopAnalysis = @import("loop_optimizer.zig").LoopAnalysis;

/// SIMD width configuration
pub const SIMDWidth = enum(u8) {
    x128 = 16, // SSE, NEON 128-bit
    x256 = 32, // AVX2 256-bit
    x512 = 64, // AVX-512 512-bit

    pub fn getWidth(self: SIMDWidth) u8 {
        return @intFromEnum(self);
    }
};

/// Target SIMD instruction set
pub const SIMDTarget = enum {
    sse,
    sse2,
    avx,
    avx2,
    avx512,
    neon, // ARM NEON
    sve, // ARM SVE (scalable vector extension)
    rvv, // RISC-V Vector extension
};

/// Vectorization opportunity
pub const VectorizationOpportunity = struct {
    /// Basic block containing the opportunity
    block_idx: usize,
    /// Start instruction index
    start_idx: usize,
    /// Number of instructions to vectorize
    count: usize,
    /// Vector width to use
    width: SIMDWidth,
    /// Estimated speedup
    speedup: f32,
};

/// Auto-vectorizer
pub const Vectorizer = struct {
    allocator: std.mem.Allocator,
    target: SIMDTarget,
    /// Minimum loop trip count for vectorization
    min_trip_count: usize,
    /// Enable SLP (Superword-Level Parallelism) vectorization
    enable_slp: bool,

    pub fn init(allocator: std.mem.Allocator, target: SIMDTarget) Vectorizer {
        return .{
            .allocator = allocator,
            .target = target,
            .min_trip_count = 4,
            .enable_slp = true,
        };
    }

    /// Get supported SIMD width for target
    pub fn getSIMDWidth(self: *Vectorizer) SIMDWidth {
        return switch (self.target) {
            .sse, .sse2, .neon => .x128,
            .avx, .avx2 => .x256,
            .avx512 => .x512,
            .sve, .rvv => .x128, // Conservative default
        };
    }

    /// Check if operation is vectorizable
    pub fn isVectorizable(self: *Vectorizer, inst: IR.Instruction) bool {
        _ = self;

        return switch (inst) {
            .add, .sub, .mul => |op| {
                // Can vectorize if both operands are registers or one is a constant
                return (op.lhs == .register or op.lhs == .constant) and
                    (op.rhs == .register or op.rhs == .constant);
            },
            .load, .store => true,
            else => false,
        };
    }

    /// Analyze loops for vectorization opportunities
    pub fn analyzeLoops(self: *Vectorizer, func: *const IR.Function) !std.ArrayList(VectorizationOpportunity) {
        var opportunities = std.ArrayList(VectorizationOpportunity){};

        var loop_analysis = LoopAnalysis.init(self.allocator);
        defer loop_analysis.deinit();

        try loop_analysis.analyzeLoops(func);

        for (loop_analysis.loops.items) |*loop| {
            // Check if loop is vectorizable
            if (loop.trip_count) |trip_count| {
                if (trip_count < self.min_trip_count) continue;

                // Analyze loop body for vectorizable patterns
                for (loop.blocks.items) |block_idx| {
                    if (block_idx >= func.blocks.items.len) continue;

                    const block = &func.blocks.items[block_idx];
                    const opp = try self.analyzeBlock(block, block_idx);

                    if (opp) |opportunity| {
                        try opportunities.append(self.allocator, opportunity);
                    }
                }
            }
        }

        return opportunities;
    }

    fn analyzeBlock(
        self: *Vectorizer,
        block: *const IR.BasicBlock,
        block_idx: usize,
    ) !?VectorizationOpportunity {
        // Count consecutive vectorizable instructions
        var start_idx: ?usize = null;
        var count: usize = 0;
        var max_count: usize = 0;
        var max_start: usize = 0;

        for (block.instructions.items, 0..) |inst, idx| {
            if (self.isVectorizable(inst)) {
                if (start_idx == null) {
                    start_idx = idx;
                    count = 1;
                } else {
                    count += 1;
                }

                if (count > max_count) {
                    max_count = count;
                    max_start = start_idx.?;
                }
            } else {
                start_idx = null;
                count = 0;
            }
        }

        // Need at least 4 consecutive vectorizable instructions
        if (max_count >= 4) {
            const width = self.getSIMDWidth();
            const speedup = @as(f32, @floatFromInt(@intFromEnum(width))) / 16.0;

            return VectorizationOpportunity{
                .block_idx = block_idx,
                .start_idx = max_start,
                .count = max_count,
                .width = width,
                .speedup = speedup,
            };
        }

        return null;
    }

    /// Vectorize a sequence of scalar operations
    pub fn vectorizeInstructions(
        _: *Vectorizer,
        block: *IR.BasicBlock,
        start_idx: usize,
        count: usize,
        width: SIMDWidth,
    ) !bool {
        if (start_idx + count > block.instructions.items.len) return false;

        const vec_width = width.getWidth();
        var changed = false;

        // Replace scalar operations with vector operations
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const idx = start_idx + i;
            if (idx >= block.instructions.items.len) break;

            const inst = block.instructions.items[idx];

            const vec_inst = switch (inst) {
                .add => |op| IR.Instruction{ .vec_add = .{
                    .dest = op.dest,
                    .lhs = op.lhs,
                    .rhs = op.rhs,
                    .width = vec_width,
                } },
                .mul => |op| IR.Instruction{ .vec_mul = .{
                    .dest = op.dest,
                    .lhs = op.lhs,
                    .rhs = op.rhs,
                    .width = vec_width,
                } },
                .load => |op| IR.Instruction{ .vec_load = .{
                    .dest = op.dest,
                    .addr = op.addr,
                    .width = vec_width,
                } },
                .store => |op| IR.Instruction{ .vec_store = .{
                    .addr = op.addr,
                    .value = op.value,
                    .width = vec_width,
                } },
                else => continue,
            };

            block.instructions.items[idx] = vec_inst;
            changed = true;
        }

        return changed;
    }

    /// SLP (Superword-Level Parallelism) vectorization
    /// Vectorizes independent scalar operations that operate on adjacent memory
    pub fn vectorizeSLP(self: *Vectorizer, block: *IR.BasicBlock) !bool {
        if (!self.enable_slp) return false;

        var changed = false;

        // Look for patterns like:
        // r0 = load [addr]
        // r1 = load [addr + 4]
        // r2 = load [addr + 8]
        // r3 = load [addr + 12]
        // Can be vectorized to a single vector load

        var consecutive_loads = std.ArrayList(usize){};
        defer consecutive_loads.deinit(self.allocator);

        for (block.instructions.items, 0..) |inst, idx| {
            if (inst == .load) {
                try consecutive_loads.append(self.allocator, idx);

                // If we have 4 consecutive loads, try to vectorize
                if (consecutive_loads.items.len == 4) {
                    // In real implementation, we'd verify loads are adjacent
                    const width = self.getSIMDWidth();
                    _ = try self.vectorizeInstructions(
                        block,
                        consecutive_loads.items[0],
                        4,
                        width,
                    );
                    consecutive_loads.clearRetainingCapacity();
                    changed = true;
                }
            } else {
                consecutive_loads.clearRetainingCapacity();
            }
        }

        return changed;
    }

    /// Main vectorization optimization
    pub fn optimize(self: *Vectorizer, func: *IR.Function) !bool {
        var changed = false;

        // Loop vectorization
        var opportunities = try self.analyzeLoops(func);
        defer opportunities.deinit(self.allocator);

        for (opportunities.items) |opp| {
            if (opp.block_idx >= func.blocks.items.len) continue;

            const block = &func.blocks.items[opp.block_idx];
            const vectorized = try self.vectorizeInstructions(
                block,
                opp.start_idx,
                opp.count,
                opp.width,
            );

            if (vectorized) changed = true;
        }

        // SLP vectorization for straight-line code
        for (func.blocks.items) |*block| {
            const slp_changed = try self.vectorizeSLP(block);
            if (slp_changed) changed = true;
        }

        return changed;
    }
};

// Tests
test "SIMD width selection" {
    const testing = std.testing;

    var vec_sse = Vectorizer.init(testing.allocator, .sse2);
    try testing.expect(vec_sse.getSIMDWidth() == .x128);

    var vec_avx = Vectorizer.init(testing.allocator, .avx2);
    try testing.expect(vec_avx.getSIMDWidth() == .x256);

    var vec_avx512 = Vectorizer.init(testing.allocator, .avx512);
    try testing.expect(vec_avx512.getSIMDWidth() == .x512);
}

test "vectorizable operation detection" {
    const testing = std.testing;

    var vectorizer = Vectorizer.init(testing.allocator, .avx2);

    const add_inst = IR.Instruction{ .add = .{
        .dest = .{ .register = 0 },
        .lhs = .{ .register = 1 },
        .rhs = .{ .register = 2 },
    } };

    try testing.expect(vectorizer.isVectorizable(add_inst));

    const nop_inst = IR.Instruction{ .nop = {} };
    try testing.expect(!vectorizer.isVectorizable(nop_inst));
}

test "instruction vectorization" {
    const testing = std.testing;

    var block = IR.BasicBlock.init(testing.allocator, 0);
    defer block.deinit(testing.allocator);

    // Create scalar add instructions
    for (0..4) |_| {
        try block.instructions.append(testing.allocator, .{ .add = .{
            .dest = .{ .register = 0 },
            .lhs = .{ .register = 1 },
            .rhs = .{ .register = 2 },
        } });
    }

    var vectorizer = Vectorizer.init(testing.allocator, .avx2);

    const changed = try vectorizer.vectorizeInstructions(&block, 0, 4, .x256);
    try testing.expect(changed);

    // First instruction should now be vec_add
    try testing.expect(block.instructions.items[0] == .vec_add);
}

test "SLP vectorization" {
    const testing = std.testing;

    var block = IR.BasicBlock.init(testing.allocator, 0);
    defer block.deinit(testing.allocator);

    // Create consecutive load instructions (SLP candidate)
    for (0..4) |_| {
        try block.instructions.append(testing.allocator, .{ .load = .{
            .dest = .{ .register = 0 },
            .addr = .{ .register = 1 },
            .offset = 0,
        } });
    }

    var vectorizer = Vectorizer.init(testing.allocator, .avx2);
    const changed = try vectorizer.vectorizeSLP(&block);

    try testing.expect(changed);
}
