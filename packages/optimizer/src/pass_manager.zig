const std = @import("std");
const ast = @import("ast");
const ir = @import("ir");

/// Optimization pass manager
///
/// Manages and executes optimization passes in the correct order.
/// Supports multiple optimization levels (O0, O1, O2, O3) similar to LLVM.
pub const PassManager = struct {
    allocator: std.mem.Allocator,
    passes: std.ArrayList(*Pass),
    optimization_level: OptimizationLevel,
    stats: OptimizationStats,

    pub const OptimizationLevel = enum {
        O0, // No optimization
        O1, // Basic optimizations
        O2, // Moderate optimizations
        O3, // Aggressive optimizations
        Os, // Optimize for size
    };

    pub const OptimizationStats = struct {
        constant_folds: usize,
        dead_code_removed: usize,
        functions_inlined: usize,
        loops_unrolled: usize,
        redundant_loads_eliminated: usize,
        allocations_elided: usize,
        total_passes_run: usize,
        total_time_ms: i64,

        pub fn init() OptimizationStats {
            return .{
                .constant_folds = 0,
                .dead_code_removed = 0,
                .functions_inlined = 0,
                .loops_unrolled = 0,
                .redundant_loads_eliminated = 0,
                .allocations_elided = 0,
                .total_passes_run = 0,
                .total_time_ms = 0,
            };
        }

        pub fn print(self: *const OptimizationStats) void {
            std.debug.print("\n=== Optimization Statistics ===\n", .{});
            std.debug.print("Constant folds:          {d}\n", .{self.constant_folds});
            std.debug.print("Dead code removed:       {d}\n", .{self.dead_code_removed});
            std.debug.print("Functions inlined:       {d}\n", .{self.functions_inlined});
            std.debug.print("Loops unrolled:          {d}\n", .{self.loops_unrolled});
            std.debug.print("Redundant loads elim:    {d}\n", .{self.redundant_loads_eliminated});
            std.debug.print("Allocations elided:      {d}\n", .{self.allocations_elided});
            std.debug.print("Total passes run:        {d}\n", .{self.total_passes_run});
            std.debug.print("Total time:              {d}ms\n", .{self.total_time_ms});
            std.debug.print("===============================\n\n", .{});
        }
    };

    pub fn init(allocator: std.mem.Allocator, level: OptimizationLevel) PassManager {
        return .{
            .allocator = allocator,
            .passes = std.ArrayList(*Pass).init(allocator),
            .optimization_level = level,
            .stats = OptimizationStats.init(),
        };
    }

    pub fn deinit(self: *PassManager) void {
        for (self.passes.items) |pass| {
            pass.deinit();
            self.allocator.destroy(pass);
        }
        self.passes.deinit();
    }

    /// Add a pass to the manager
    pub fn addPass(self: *PassManager, pass: *Pass) !void {
        try self.passes.append(pass);
    }

    /// Configure passes based on optimization level
    pub fn configureForLevel(self: *PassManager) !void {
        switch (self.optimization_level) {
            .O0 => {
                // No optimizations
            },
            .O1 => {
                try self.addBasicPasses();
            },
            .O2 => {
                try self.addBasicPasses();
                try self.addModeratePasses();
            },
            .O3 => {
                try self.addBasicPasses();
                try self.addModeratePasses();
                try self.addAggressivePasses();
            },
            .Os => {
                try self.addBasicPasses();
                try self.addSizeOptimizationPasses();
            },
        }
    }

    fn addBasicPasses(self: *PassManager) !void {
        // Constant folding and propagation
        const const_fold = try self.allocator.create(Pass);
        const_fold.* = Pass.constantFolding(self.allocator);
        try self.addPass(const_fold);

        // Dead code elimination
        const dce = try self.allocator.create(Pass);
        dce.* = Pass.deadCodeElimination(self.allocator);
        try self.addPass(dce);

        // Common subexpression elimination
        const cse = try self.allocator.create(Pass);
        cse.* = Pass.commonSubexpressionElimination(self.allocator);
        try self.addPass(cse);
    }

    fn addModeratePasses(self: *PassManager) !void {
        // Function inlining
        const inline_pass = try self.allocator.create(Pass);
        inline_pass.* = Pass.inlining(self.allocator, 50); // Inline functions < 50 instructions
        try self.addPass(inline_pass);

        // Loop optimization
        const loop_opt = try self.allocator.create(Pass);
        loop_opt.* = Pass.loopOptimization(self.allocator);
        try self.addPass(loop_opt);

        // Redundancy elimination
        const redundancy = try self.allocator.create(Pass);
        redundancy.* = Pass.redundancyElimination(self.allocator);
        try self.addPass(redundancy);
    }

    fn addAggressivePasses(self: *PassManager) !void {
        // Aggressive inlining
        const aggressive_inline = try self.allocator.create(Pass);
        aggressive_inline.* = Pass.inlining(self.allocator, 200);
        try self.addPass(aggressive_inline);

        // Loop unrolling
        const loop_unroll = try self.allocator.create(Pass);
        loop_unroll.* = Pass.loopUnrolling(self.allocator, 8);
        try self.addPass(loop_unroll);

        // Escape analysis
        const escape = try self.allocator.create(Pass);
        escape.* = Pass.escapeAnalysis(self.allocator);
        try self.addPass(escape);

        // Vectorization
        const vector = try self.allocator.create(Pass);
        vector.* = Pass.vectorization(self.allocator);
        try self.addPass(vector);
    }

    fn addSizeOptimizationPasses(self: *PassManager) !void {
        // Focus on code size reduction
        const merge_funcs = try self.allocator.create(Pass);
        merge_funcs.* = Pass.functionMerging(self.allocator);
        try self.addPass(merge_funcs);
    }

    /// Run all passes on a program
    pub fn runOnProgram(self: *PassManager, program: *ast.Program) !void {
        const start_time = std.time.milliTimestamp();

        var changed = true;
        var iteration: usize = 0;

        // Run passes until fixed point (no more changes)
        while (changed and iteration < 10) : (iteration += 1) {
            changed = false;

            for (self.passes.items) |pass| {
                const pass_changed = try pass.run(program, &self.stats);
                changed = changed or pass_changed;
                self.stats.total_passes_run += 1;
            }
        }

        const end_time = std.time.milliTimestamp();
        self.stats.total_time_ms = end_time - start_time;
    }

    /// Print optimization statistics
    pub fn printStats(self: *PassManager) void {
        self.stats.print();
    }
};

/// Base optimization pass
pub const Pass = struct {
    name: []const u8,
    kind: PassKind,
    allocator: std.mem.Allocator,
    config: PassConfig,

    pub const PassKind = enum {
        ConstantFolding,
        DeadCodeElimination,
        CommonSubexpressionElimination,
        Inlining,
        LoopOptimization,
        LoopUnrolling,
        RedundancyElimination,
        EscapeAnalysis,
        Vectorization,
        FunctionMerging,
    };

    pub const PassConfig = union(PassKind) {
        ConstantFolding: void,
        DeadCodeElimination: void,
        CommonSubexpressionElimination: void,
        Inlining: struct { threshold: usize },
        LoopOptimization: void,
        LoopUnrolling: struct { max_iterations: usize },
        RedundancyElimination: void,
        EscapeAnalysis: void,
        Vectorization: void,
        FunctionMerging: void,
    };

    pub fn constantFolding(allocator: std.mem.Allocator) Pass {
        return .{
            .name = "Constant Folding",
            .kind = .ConstantFolding,
            .allocator = allocator,
            .config = .{ .ConstantFolding = {} },
        };
    }

    pub fn deadCodeElimination(allocator: std.mem.Allocator) Pass {
        return .{
            .name = "Dead Code Elimination",
            .kind = .DeadCodeElimination,
            .allocator = allocator,
            .config = .{ .DeadCodeElimination = {} },
        };
    }

    pub fn commonSubexpressionElimination(allocator: std.mem.Allocator) Pass {
        return .{
            .name = "Common Subexpression Elimination",
            .kind = .CommonSubexpressionElimination,
            .allocator = allocator,
            .config = .{ .CommonSubexpressionElimination = {} },
        };
    }

    pub fn inlining(allocator: std.mem.Allocator, threshold: usize) Pass {
        return .{
            .name = "Function Inlining",
            .kind = .Inlining,
            .allocator = allocator,
            .config = .{ .Inlining = .{ .threshold = threshold } },
        };
    }

    pub fn loopOptimization(allocator: std.mem.Allocator) Pass {
        return .{
            .name = "Loop Optimization",
            .kind = .LoopOptimization,
            .allocator = allocator,
            .config = .{ .LoopOptimization = {} },
        };
    }

    pub fn loopUnrolling(allocator: std.mem.Allocator, max_iterations: usize) Pass {
        return .{
            .name = "Loop Unrolling",
            .kind = .LoopUnrolling,
            .allocator = allocator,
            .config = .{ .LoopUnrolling = .{ .max_iterations = max_iterations } },
        };
    }

    pub fn redundancyElimination(allocator: std.mem.Allocator) Pass {
        return .{
            .name = "Redundancy Elimination",
            .kind = .RedundancyElimination,
            .allocator = allocator,
            .config = .{ .RedundancyElimination = {} },
        };
    }

    pub fn escapeAnalysis(allocator: std.mem.Allocator) Pass {
        return .{
            .name = "Escape Analysis",
            .kind = .EscapeAnalysis,
            .allocator = allocator,
            .config = .{ .EscapeAnalysis = {} },
        };
    }

    pub fn vectorization(allocator: std.mem.Allocator) Pass {
        return .{
            .name = "Vectorization",
            .kind = .Vectorization,
            .allocator = allocator,
            .config = .{ .Vectorization = {} },
        };
    }

    pub fn functionMerging(allocator: std.mem.Allocator) Pass {
        return .{
            .name = "Function Merging",
            .kind = .FunctionMerging,
            .allocator = allocator,
            .config = .{ .FunctionMerging = {} },
        };
    }

    pub fn deinit(self: *Pass) void {
        _ = self;
    }

    /// Run the pass on a program
    pub fn run(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        return switch (self.kind) {
            .ConstantFolding => try self.runConstantFolding(program, stats),
            .DeadCodeElimination => try self.runDeadCodeElimination(program, stats),
            .CommonSubexpressionElimination => try self.runCSE(program, stats),
            .Inlining => try self.runInlining(program, stats),
            .LoopOptimization => try self.runLoopOptimization(program, stats),
            .LoopUnrolling => try self.runLoopUnrolling(program, stats),
            .RedundancyElimination => try self.runRedundancyElimination(program, stats),
            .EscapeAnalysis => try self.runEscapeAnalysis(program, stats),
            .Vectorization => try self.runVectorization(program, stats),
            .FunctionMerging => try self.runFunctionMerging(program, stats),
        };
    }

    fn runConstantFolding(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        for (program.statements) |*stmt| {
            const stmt_changed = try self.foldStmt(stmt, stats);
            changed = changed or stmt_changed;
        }

        return changed;
    }

    fn foldStmt(self: *Pass, stmt: *ast.Stmt, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = stats;

        switch (stmt.*) {
            .LetDecl => |*let_decl| {
                if (let_decl.initializer) |init_expr| {
                    return try foldExpr(init_expr, stats);
                }
            },
            .ReturnStmt => |*ret_stmt| {
                if (ret_stmt.expression) |expr| {
                    return try foldExpr(expr, stats);
                }
            },
            .FunctionDecl => |*func| {
                var changed = false;
                for (func.body.statements) |*body_stmt| {
                    const stmt_changed = try foldStmt(body_stmt, stats);
                    changed = changed or stmt_changed;
                }
                return changed;
            },
            else => {},
        }

        return false;
    }

    fn foldExpr(expr: *ast.Expr, stats: *PassManager.OptimizationStats) !bool {
        switch (expr.*) {
            .BinaryExpr => |*bin| {
                // Try to fold binary operations with constant operands
                const left_is_const = isConstant(bin.left);
                const right_is_const = isConstant(bin.right);

                if (left_is_const and right_is_const) {
                    const folded = try evaluateBinaryOp(bin);
                    if (folded) |value| {
                        expr.* = .{ .IntegerLiteral = .{ .value = value, .node = bin.node } };
                        stats.constant_folds += 1;
                        return true;
                    }
                }

                // Algebraic simplifications
                // x + 0 = x, x * 1 = x, x * 0 = 0, etc.
                if (right_is_const) {
                    if (bin.right.IntegerLiteral.value == 0) {
                        switch (bin.operator) {
                            .Add, .Subtract => {
                                expr.* = bin.left.*;
                                stats.constant_folds += 1;
                                return true;
                            },
                            .Multiply => {
                                expr.* = .{ .IntegerLiteral = .{ .value = 0, .node = bin.node } };
                                stats.constant_folds += 1;
                                return true;
                            },
                            else => {},
                        }
                    } else if (bin.right.IntegerLiteral.value == 1) {
                        switch (bin.operator) {
                            .Multiply, .Divide => {
                                expr.* = bin.left.*;
                                stats.constant_folds += 1;
                                return true;
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }

        return false;
    }

    fn isConstant(expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .IntegerLiteral, .FloatLiteral, .BoolLiteral => true,
            else => false,
        };
    }

    fn evaluateBinaryOp(bin: *const ast.BinaryExpr) !?i64 {
        if (bin.left.* != .IntegerLiteral or bin.right.* != .IntegerLiteral) {
            return null;
        }

        const left = bin.left.IntegerLiteral.value;
        const right = bin.right.IntegerLiteral.value;

        return switch (bin.operator) {
            .Add => left + right,
            .Subtract => left - right,
            .Multiply => left * right,
            .Divide => if (right != 0) @divTrunc(left, right) else null,
            .Modulo => if (right != 0) @mod(left, right) else null,
            else => null,
        };
    }

    fn runDeadCodeElimination(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Would analyze control flow and remove unreachable code
        return false;
    }

    fn runCSE(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Would find and eliminate common subexpressions
        return false;
    }

    fn runInlining(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Would inline small functions at call sites
        return false;
    }

    fn runLoopOptimization(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Loop invariant code motion, strength reduction
        return false;
    }

    fn runLoopUnrolling(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Unroll loops with known iteration counts
        return false;
    }

    fn runRedundancyElimination(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Eliminate redundant loads/stores
        return false;
    }

    fn runEscapeAnalysis(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Analyze if allocations can be moved to stack
        return false;
    }

    fn runVectorization(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Convert scalar operations to SIMD
        return false;
    }

    fn runFunctionMerging(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        _ = self;
        _ = program;
        _ = stats;
        // Merge identical functions to reduce code size
        return false;
    }
};
