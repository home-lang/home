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
            .passes = .{},
            .optimization_level = level,
            .stats = OptimizationStats.init(),
        };
    }

    pub fn deinit(self: *PassManager) void {
        for (self.passes.items) |pass| {
            pass.deinit();
            self.allocator.destroy(pass);
        }
        self.passes.deinit(self.allocator);
    }

    /// Add a pass to the manager
    pub fn addPass(self: *PassManager, pass: *Pass) !void {
        try self.passes.append(self.allocator, pass);
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
        const start_time = try std.time.Instant.now();

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

        const end_time = try std.time.Instant.now();
        self.stats.total_time_ms = @intCast(@divFloor(end_time.since(start_time), std.time.ns_per_ms));
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
        switch (stmt.*) {
            .LetDecl => |let_decl| {
                if (let_decl.value) |init_expr| {
                    return try foldExpr(init_expr, stats);
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |expr| {
                    return try foldExpr(expr, stats);
                }
            },
            .FnDecl => |func| {
                var changed = false;
                for (func.body.statements) |*body_stmt| {
                    const stmt_changed = try self.foldStmt(body_stmt, stats);
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
            .BinaryExpr => |bin| {
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
                        switch (bin.op) {
                            .Add, .Sub => {
                                expr.* = bin.left.*;
                                stats.constant_folds += 1;
                                return true;
                            },
                            .Mul => {
                                expr.* = .{ .IntegerLiteral = .{ .value = 0, .node = bin.node } };
                                stats.constant_folds += 1;
                                return true;
                            },
                            else => {},
                        }
                    } else if (bin.right.IntegerLiteral.value == 1) {
                        switch (bin.op) {
                            .Mul, .Div => {
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
            .IntegerLiteral, .FloatLiteral, .BooleanLiteral => true,
            else => false,
        };
    }

    fn evaluateBinaryOp(bin: *const ast.BinaryExpr) !?i64 {
        if (bin.left.* != .IntegerLiteral or bin.right.* != .IntegerLiteral) {
            return null;
        }

        const left = bin.left.IntegerLiteral.value;
        const right = bin.right.IntegerLiteral.value;

        return switch (bin.op) {
            .Add => left + right,
            .Sub => left - right,
            .Mul => left * right,
            .Div => if (right != 0) @divTrunc(left, right) else null,
            .Mod => if (right != 0) @mod(left, right) else null,
            else => null,
        };
    }

    fn runDeadCodeElimination(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        for (program.statements) |*stmt| {
            const stmt_changed = try self.eliminateDeadCodeInStmt(stmt, stats);
            changed = changed or stmt_changed;
        }

        return changed;
    }

    fn eliminateDeadCodeInStmt(self: *Pass, stmt: *ast.Stmt, stats: *PassManager.OptimizationStats) anyerror!bool {
        switch (stmt.*) {
            .FnDecl => |func| {
                return try self.eliminateDeadCodeInBlock(func.body, stats);
            },
            .IfStmt => |if_stmt| {
                var changed = false;

                // Check if condition is a constant boolean
                if (if_stmt.condition.* == .BooleanLiteral) {
                    _ = if_stmt.condition.BooleanLiteral.value;

                    // If condition is always true, replace entire if with then_block
                    // If condition is always false, replace with else_block (or remove)
                    // This is a simplification - full implementation would modify the parent
                    stats.dead_code_removed += 1;
                    changed = true;
                }

                // Recursively process both branches
                changed = try self.eliminateDeadCodeInBlock(if_stmt.then_block, stats) or changed;
                if (if_stmt.else_block) |else_block| {
                    changed = try self.eliminateDeadCodeInBlock(else_block, stats) or changed;
                }

                return changed;
            },
            .WhileStmt => |while_stmt| {
                return try self.eliminateDeadCodeInBlock(while_stmt.body, stats);
            },
            .BlockStmt => |block| {
                return try self.eliminateDeadCodeInBlock(block, stats);
            },
            else => return false,
        }
    }

    fn eliminateDeadCodeInBlock(self: *Pass, block: *ast.BlockStmt, stats: *PassManager.OptimizationStats) anyerror!bool {
        var changed = false;
        var found_terminator = false;
        var dead_code_start: ?usize = null;

        // Find unreachable code after return/break/continue
        for (block.statements, 0..) |*stmt, i| {
            if (found_terminator) {
                if (dead_code_start == null) {
                    dead_code_start = i;
                }
                stats.dead_code_removed += 1;
                changed = true;
            }

            // Check if this statement terminates the block
            switch (stmt.*) {
                .ReturnStmt, .BreakStmt, .ContinueStmt => {
                    found_terminator = true;
                },
                else => {},
            }

            // Recursively process nested blocks
            const nested_changed = try self.eliminateDeadCodeInStmt(stmt, stats);
            changed = changed or nested_changed;
        }

        // If we found dead code, we would need to truncate the statements array
        // For now, we just track that we found it
        // Full implementation would require allocator to create new slice

        return changed;
    }

    fn runCSE(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        // CSE is complex and requires:
        // 1. Expression hashing/equality checking
        // 2. Tracking which expressions are available at each point
        // 3. Creating temporary variables to store results
        // 4. Replacing duplicate expressions with variable references
        //
        // For now, we implement a simple version that tracks expressions
        // within a single basic block (function body)

        var changed = false;

        for (program.statements) |*stmt| {
            const stmt_changed = try self.cseInStmt(stmt, stats);
            changed = changed or stmt_changed;
        }

        return changed;
    }

    fn cseInStmt(self: *Pass, stmt: *ast.Stmt, stats: *PassManager.OptimizationStats) anyerror!bool {
        switch (stmt.*) {
            .FnDecl => |func| {
                return try self.cseInBlock(func.body, stats);
            },
            .IfStmt => |if_stmt| {
                var changed = false;
                changed = try self.cseInBlock(if_stmt.then_block, stats) or changed;
                if (if_stmt.else_block) |else_block| {
                    changed = try self.cseInBlock(else_block, stats) or changed;
                }
                return changed;
            },
            .WhileStmt => |while_stmt| {
                return try self.cseInBlock(while_stmt.body, stats);
            },
            .BlockStmt => |block| {
                return try self.cseInBlock(block, stats);
            },
            else => return false,
        }
    }

    const TempVarInfo = struct {
        temp_name: []const u8,
        first_expr: *ast.Expr,
        count: usize,
    };

    fn cseInBlock(self: *Pass, block: *ast.BlockStmt, stats: *PassManager.OptimizationStats) anyerror!bool {
        // CSE Strategy:
        // 1. Track first occurrence of each pure expression
        // 2. For duplicates, create a temp variable on first occurrence
        // 3. Replace all occurrences (including first) with variable reference
        // 4. Insert temp variable declarations at block start

        var expr_map = std.StringHashMap(TempVarInfo).init(self.allocator);
        defer {
            var iter = expr_map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.temp_name);
            }
            expr_map.deinit();
        }

        var temp_counter: usize = 0;
        var changed = false;

        // Pass 1: Identify duplicate expressions
        for (block.statements) |stmt| {
            try self.findDuplicateExprs(stmt, &expr_map, &temp_counter);
        }

        // Pass 2: Replace expressions with temp variable references
        // Only replace if we found duplicates (count > 1)
        for (block.statements) |*stmt| {
            const stmt_changed = try self.replaceWithTempVars(stmt, &expr_map);
            changed = changed or stmt_changed;
        }

        // Pass 3: Insert temp variable declarations at the beginning
        if (changed) {
            var new_stmts = try std.ArrayList(ast.Stmt).initCapacity(self.allocator, block.statements.len + expr_map.count());
            defer new_stmts.deinit(self.allocator);

            // Add temp variable declarations
            var iter = expr_map.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.count > 1) {
                    // Create: let _cse_N = <expression>
                    // Get location from the expression
                    const loc = switch (entry.value_ptr.first_expr.*) {
                        .BinaryExpr => |bin| bin.node.loc,
                        .IntegerLiteral => |int| int.node.loc,
                        .Identifier => |id| id.node.loc,
                        else => ast.SourceLocation{ .line = 0, .column = 0 },
                    };
                    const let_decl = try ast.LetDecl.init(
                        self.allocator,
                        entry.value_ptr.temp_name,
                        null, // type_name
                        entry.value_ptr.first_expr,
                        false, // is_mutable
                        loc,
                    );
                    try new_stmts.append(self.allocator, ast.Stmt{ .LetDecl = let_decl });
                    stats.dead_code_removed += 1; // Track CSE count
                }
            }

            // Add original statements
            for (block.statements) |stmt| {
                try new_stmts.append(self.allocator, stmt);
            }

            // Replace block's statements
            block.statements = try new_stmts.toOwnedSlice(self.allocator);
        }

        return changed;
    }

    fn findDuplicateExprs(
        self: *Pass,
        stmt: ast.Stmt,
        expr_map: *std.StringHashMap(TempVarInfo),
        temp_counter: *usize,
    ) anyerror!void {
        switch (stmt) {
            .ExprStmt => |expr| {
                try self.trackExpr(expr, expr_map, temp_counter);
            },
            .LetDecl => |let_decl| {
                if (let_decl.value) |val| {
                    try self.trackExpr(val, expr_map, temp_counter);
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    try self.trackExpr(val, expr_map, temp_counter);
                }
            },
            else => {},
        }
    }

    fn trackExpr(
        self: *Pass,
        expr: *ast.Expr,
        expr_map: *std.StringHashMap(TempVarInfo),
        temp_counter: *usize,
    ) anyerror!void {
        // Only track pure binary expressions for now
        if (expr.* != .BinaryExpr) return;

        const bin_expr = expr.BinaryExpr;
        const is_pure = switch (bin_expr.op) {
            .Add, .Sub, .Mul, .Div, .Mod,
            .Equal, .NotEqual, .Less, .LessEq, .Greater, .GreaterEq,
            .BitAnd, .BitOr, .BitXor, .LeftShift, .RightShift => true,
            else => false,
        };

        if (!is_pure) return;

        const expr_str = try self.exprToString(expr.*);
        defer self.allocator.free(expr_str);

        const entry = try expr_map.getOrPut(expr_str);
        if (!entry.found_existing) {
            // First occurrence - create temp var name
            const temp_name = try std.fmt.allocPrint(self.allocator, "_cse_{d}", .{temp_counter.*});
            temp_counter.* += 1;

            const key_copy = try self.allocator.dupe(u8, expr_str);
            entry.key_ptr.* = key_copy;
            entry.value_ptr.* = .{
                .temp_name = temp_name,
                .first_expr = expr,
                .count = 1,
            };
        } else {
            entry.value_ptr.count += 1;
        }

        // Recursively track subexpressions
        try self.trackExpr(bin_expr.left, expr_map, temp_counter);
        try self.trackExpr(bin_expr.right, expr_map, temp_counter);
    }

    fn replaceWithTempVars(
        self: *Pass,
        stmt: *ast.Stmt,
        expr_map: *std.StringHashMap(TempVarInfo),
    ) anyerror!bool {
        switch (stmt.*) {
            .ExprStmt => |expr| {
                return try self.replaceExpr(expr, expr_map);
            },
            .LetDecl => |let_decl| {
                if (let_decl.value) |val| {
                    return try self.replaceExpr(val, expr_map);
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    return try self.replaceExpr(val, expr_map);
                }
            },
            else => {},
        }
        return false;
    }

    fn replaceExpr(
        self: *Pass,
        expr: *ast.Expr,
        expr_map: *std.StringHashMap(TempVarInfo),
    ) anyerror!bool {
        // Check if this expression should be replaced
        const expr_str = try self.exprToString(expr.*);
        defer self.allocator.free(expr_str);

        if (expr_map.get(expr_str)) |info| {
            if (info.count > 1) {
                // Replace with identifier
                // Get location from current expression
                const loc = switch (expr.*) {
                    .BinaryExpr => |bin| bin.node.loc,
                    .IntegerLiteral => |int| int.node.loc,
                    .Identifier => |id| id.node.loc,
                    else => ast.SourceLocation{ .line = 0, .column = 0 },
                };
                expr.* = ast.Expr{
                    .Identifier = ast.Identifier.init(info.temp_name, loc),
                };
                return true;
            }
        }

        // Recursively replace in subexpressions
        var changed = false;
        switch (expr.*) {
            .BinaryExpr => |bin_expr| {
                changed = try self.replaceExpr(bin_expr.left, expr_map) or changed;
                changed = try self.replaceExpr(bin_expr.right, expr_map) or changed;
            },
            .UnaryExpr => |un_expr| {
                changed = try self.replaceExpr(un_expr.operand, expr_map) or changed;
            },
            .CallExpr => |call| {
                for (call.args) |arg| {
                    changed = try self.replaceExpr(arg, expr_map) or changed;
                }
            },
            else => {},
        }
        return changed;
    }

    fn analyzeStmtForCSE(self: *Pass, stmt: ast.Stmt, expr_count: *std.StringHashMap(usize)) anyerror!void {
        switch (stmt) {
            .ExprStmt => |expr| {
                try self.analyzeExprForCSE(expr.*, expr_count);
            },
            .LetDecl => |let_decl| {
                if (let_decl.value) |val| {
                    try self.analyzeExprForCSE(val.*, expr_count);
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    try self.analyzeExprForCSE(val.*, expr_count);
                }
            },
            .IfStmt => |if_stmt| {
                try self.analyzeExprForCSE(if_stmt.condition.*, expr_count);
                // Don't recurse into nested blocks for simplicity
            },
            .WhileStmt => |while_stmt| {
                try self.analyzeExprForCSE(while_stmt.condition.*, expr_count);
            },
            else => {},
        }
    }

    fn analyzeExprForCSE(self: *Pass, expr: ast.Expr, expr_count: *std.StringHashMap(usize)) anyerror!void {
        switch (expr) {
            .BinaryExpr => |bin_expr| {
                // Only consider pure operations (no side effects)
                const is_pure = switch (bin_expr.op) {
                    .Add, .Sub, .Mul, .Div, .Mod,
                    .Equal, .NotEqual, .Less, .LessEq, .Greater, .GreaterEq,
                    .BitAnd, .BitOr, .BitXor, .LeftShift, .RightShift => true,
                    else => false,
                };

                if (is_pure) {
                    // Create a simple string representation of the expression
                    const expr_str = try self.exprToString(expr);
                    defer self.allocator.free(expr_str);

                    const entry = try expr_count.getOrPut(expr_str);
                    if (!entry.found_existing) {
                        // Need to dupe the key for the hashmap to own it
                        const key_copy = try self.allocator.dupe(u8, expr_str);
                        expr_count.put(key_copy, 1) catch {};
                    } else {
                        entry.value_ptr.* += 1;
                    }
                }

                // Recursively analyze operands
                try self.analyzeExprForCSE(bin_expr.left.*, expr_count);
                try self.analyzeExprForCSE(bin_expr.right.*, expr_count);
            },
            .UnaryExpr => |un_expr| {
                try self.analyzeExprForCSE(un_expr.operand.*, expr_count);
            },
            .CallExpr => |call| {
                for (call.args) |arg| {
                    try self.analyzeExprForCSE(arg.*, expr_count);
                }
            },
            else => {},
        }
    }

    fn exprToString(self: *Pass, expr: ast.Expr) ![]const u8 {
        // Simple string representation for expression hashing
        // Format: "op(left,right)" for binary, "op(operand)" for unary
        switch (expr) {
            .BinaryExpr => |bin_expr| {
                const left_str = try self.exprToString(bin_expr.left.*);
                defer self.allocator.free(left_str);
                const right_str = try self.exprToString(bin_expr.right.*);
                defer self.allocator.free(right_str);

                const op_str = switch (bin_expr.op) {
                    .Add => "+",
                    .Sub => "-",
                    .Mul => "*",
                    .Div => "/",
                    .Mod => "%",
                    .Equal => "==",
                    .NotEqual => "!=",
                    .Less => "<",
                    .LessEq => "<=",
                    .Greater => ">",
                    .GreaterEq => ">=",
                    .BitAnd => "&",
                    .BitOr => "|",
                    .BitXor => "^",
                    else => "?",
                };

                return try std.fmt.allocPrint(self.allocator, "({s}{s}{s})", .{left_str, op_str, right_str});
            },
            .Identifier => |id| {
                return try std.fmt.allocPrint(self.allocator, "{s}", .{id.name});
            },
            .IntegerLiteral => |int_lit| {
                return try std.fmt.allocPrint(self.allocator, "{d}", .{int_lit.value});
            },
            else => {
                return try std.fmt.allocPrint(self.allocator, "?", .{});
            },
        }
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
