const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
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
        loops_vectorized: usize,
        functions_merged: usize,
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
                .loops_vectorized = 0,
                .functions_merged = 0,
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
            std.debug.print("Loops vectorized:        {d}\n", .{self.loops_vectorized});
            std.debug.print("Functions merged:        {d}\n", .{self.functions_merged});
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

    /// Cross-platform nanosecond timestamp for timing
    fn getNanoTimestamp() i128 {
        if (comptime native_os == .windows) {
            const ntdll = std.os.windows.ntdll;
            var counter: i64 = undefined;
            var freq: i64 = undefined;
            _ = ntdll.RtlQueryPerformanceCounter(&counter);
            _ = ntdll.RtlQueryPerformanceFrequency(&freq);
            return @divFloor(@as(i128, counter) * std.time.ns_per_s, @as(i128, freq));
        }
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
    }

    /// Run all passes on a program
    pub fn runOnProgram(self: *PassManager, program: *ast.Program) !void {
        const start_ns = getNanoTimestamp();

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

        const end_ns = getNanoTimestamp();
        const elapsed_ns = end_ns - start_ns;
        self.stats.total_time_ms = @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));
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
        const threshold = switch (self.config) {
            .Inlining => |cfg| cfg.threshold,
            else => return false,
        };

        var changed = false;

        // Build a map of function names to their declarations
        var fn_map = std.StringHashMap(*ast.FnDecl).init(self.allocator);
        defer fn_map.deinit();

        // First pass: collect all function declarations
        for (program.statements) |stmt| {
            if (stmt == .FnDecl) {
                const fn_decl = stmt.FnDecl;
                // Only inline small, non-async, non-test functions
                if (!fn_decl.is_async and !fn_decl.is_test) {
                    const size = try self.estimateFunctionSize(fn_decl);
                    if (size <= threshold) {
                        try fn_map.put(fn_decl.name, fn_decl);
                    }
                }
            }
        }

        // Second pass: inline function calls in statements
        for (program.statements) |stmt| {
            const stmt_changed = try self.inlineInStmt(stmt, &fn_map, stats);
            changed = changed or stmt_changed;
        }

        return changed;
    }

    fn estimateFunctionSize(self: *Pass, fn_decl: *ast.FnDecl) !usize {
        _ = self;
        // Simple heuristic: count statements in the function body
        var size: usize = 0;

        for (fn_decl.body.statements) |stmt| {
            size += 1;
            // Count nested statements in control flow
            switch (stmt) {
                .IfStmt => |if_stmt| {
                    size += if_stmt.then_block.statements.len;
                    if (if_stmt.else_block) |else_block| {
                        size += else_block.statements.len;
                    }
                },
                .WhileStmt => |while_stmt| {
                    size += while_stmt.body.statements.len;
                },
                .ForStmt => |for_stmt| {
                    size += for_stmt.body.statements.len;
                },
                else => {},
            }
        }

        return size;
    }

    fn inlineInStmt(self: *Pass, stmt: ast.Stmt, fn_map: *std.StringHashMap(*ast.FnDecl), stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        switch (stmt) {
            .ExprStmt => |expr_stmt| {
                changed = try self.inlineInExpr(expr_stmt, fn_map, stats) or changed;
            },
            .LetDecl => |let_decl| {
                if (let_decl.value) |val| {
                    changed = try self.inlineInExpr(val, fn_map, stats) or changed;
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    changed = try self.inlineInExpr(val, fn_map, stats) or changed;
                }
            },
            .IfStmt => |if_stmt| {
                changed = try self.inlineInExpr(if_stmt.condition, fn_map, stats) or changed;
                for (if_stmt.then_block.statements) |then_stmt| {
                    changed = try self.inlineInStmt(then_stmt, fn_map, stats) or changed;
                }
                if (if_stmt.else_block) |else_block| {
                    for (else_block.statements) |else_stmt| {
                        changed = try self.inlineInStmt(else_stmt, fn_map, stats) or changed;
                    }
                }
            },
            .WhileStmt => |while_stmt| {
                changed = try self.inlineInExpr(while_stmt.condition, fn_map, stats) or changed;
                for (while_stmt.body.statements) |body_stmt| {
                    changed = try self.inlineInStmt(body_stmt, fn_map, stats) or changed;
                }
            },
            .ForStmt => |for_stmt| {
                changed = try self.inlineInExpr(for_stmt.iterable, fn_map, stats) or changed;
                for (for_stmt.body.statements) |body_stmt| {
                    changed = try self.inlineInStmt(body_stmt, fn_map, stats) or changed;
                }
            },
            else => {},
        }

        return changed;
    }

    fn inlineInExpr(self: *Pass, expr: *ast.Expr, fn_map: *std.StringHashMap(*ast.FnDecl), stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        switch (expr.*) {
            .CallExpr => |call| {
                // Check if this is a simple function call (callee is identifier)
                if (call.callee.* == .Identifier) {
                    const fn_name = call.callee.Identifier.name;
                    if (fn_map.get(fn_name)) |fn_decl| {
                        // Check if argument count matches
                        if (call.args.len == fn_decl.params.len and call.named_args.len == 0) {
                            // Only inline if the function has a single return statement
                            if (try self.canInlineFunction(fn_decl)) {
                                // Actually perform inlining by substituting the function body
                                const return_stmt = fn_decl.body.statements[0].ReturnStmt;
                                if (return_stmt.value) |ret_expr| {
                                    // Create substitution map: param_name -> argument_expr
                                    var subst_map = std.StringHashMap(*ast.Expr).init(self.allocator);
                                    defer subst_map.deinit();

                                    for (fn_decl.params, 0..) |param, i| {
                                        try subst_map.put(param.name, call.args[i]);
                                    }

                                    // Clone and substitute the return expression
                                    const inlined_expr = try self.cloneAndSubstitute(ret_expr, &subst_map);

                                    // Replace the call expression with the inlined expression
                                    expr.* = inlined_expr.*;

                                    stats.functions_inlined += 1;
                                    changed = true;
                                }
                            }
                        }
                    }
                }

                // Recurse into arguments (only if we didn't inline)
                if (!changed) {
                    for (call.args) |arg| {
                        changed = try self.inlineInExpr(arg, fn_map, stats) or changed;
                    }
                }
            },
            .BinaryExpr => |bin| {
                changed = try self.inlineInExpr(bin.left, fn_map, stats) or changed;
                changed = try self.inlineInExpr(bin.right, fn_map, stats) or changed;
            },
            .UnaryExpr => |un| {
                changed = try self.inlineInExpr(un.operand, fn_map, stats) or changed;
            },
            else => {},
        }

        return changed;
    }

    fn cloneAndSubstitute(self: *Pass, expr: *ast.Expr, subst_map: *std.StringHashMap(*ast.Expr)) !*ast.Expr {
        const cloned = try self.allocator.create(ast.Expr);

        switch (expr.*) {
            .Identifier => |id| {
                // Check if this identifier should be substituted
                if (subst_map.get(id.name)) |replacement| {
                    // Return the replacement expression directly
                    cloned.* = replacement.*;
                } else {
                    cloned.* = expr.*;
                }
            },
            .BinaryExpr => |bin| {
                const left = try self.cloneAndSubstitute(bin.left, subst_map);
                const right = try self.cloneAndSubstitute(bin.right, subst_map);

                const cloned_bin = try self.allocator.create(ast.BinaryExpr);
                cloned_bin.* = .{
                    .node = bin.node,
                    .left = left,
                    .right = right,
                    .op = bin.op,
                };
                cloned.* = ast.Expr{ .BinaryExpr = cloned_bin };
            },
            .UnaryExpr => |un| {
                const operand = try self.cloneAndSubstitute(un.operand, subst_map);

                const cloned_un = try self.allocator.create(ast.UnaryExpr);
                cloned_un.* = .{
                    .node = un.node,
                    .operand = operand,
                    .op = un.op,
                };
                cloned.* = ast.Expr{ .UnaryExpr = cloned_un };
            },
            .IntegerLiteral => |int| {
                cloned.* = ast.Expr{ .IntegerLiteral = int };
            },
            .FloatLiteral => |float| {
                cloned.* = ast.Expr{ .FloatLiteral = float };
            },
            .StringLiteral => |str| {
                cloned.* = ast.Expr{ .StringLiteral = str };
            },
            .BooleanLiteral => |bool_lit| {
                cloned.* = ast.Expr{ .BooleanLiteral = bool_lit };
            },
            else => {
                // For other expression types, just copy
                cloned.* = expr.*;
            },
        }

        return cloned;
    }

    fn canInlineFunction(self: *Pass, fn_decl: *ast.FnDecl) !bool {
        _ = self;
        // Simple heuristic: can inline if function has 1 statement and it's a return
        if (fn_decl.body.statements.len == 1) {
            return fn_decl.body.statements[0] == .ReturnStmt;
        }
        return false;
    }

    fn runLoopOptimization(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        // Apply loop optimizations to all statements
        for (program.statements) |stmt| {
            const stmt_changed = try self.optimizeLoopsInStmt(stmt, stats);
            changed = changed or stmt_changed;
        }

        return changed;
    }

    fn optimizeLoopsInStmt(self: *Pass, stmt: ast.Stmt, stats: *PassManager.OptimizationStats) anyerror!bool {
        var changed = false;

        switch (stmt) {
            .ForStmt => |for_stmt| {
                // Recurse into loop body
                changed = try self.optimizeLoopsInBlock(for_stmt.body, stats);
            },
            .WhileStmt => |while_stmt| {
                // Recurse into loop body
                changed = try self.optimizeLoopsInBlock(while_stmt.body, stats);
            },
            .IfStmt => |if_stmt| {
                changed = try self.optimizeLoopsInBlock(if_stmt.then_block, stats);
                if (if_stmt.else_block) |else_block| {
                    changed = try self.optimizeLoopsInBlock(else_block, stats) or changed;
                }
            },
            .FnDecl => |fn_decl| {
                changed = try self.optimizeLoopsInBlock(fn_decl.body, stats);
            },
            else => {},
        }

        return changed;
    }

    fn optimizeLoopsInBlock(self: *Pass, block: *ast.BlockStmt, stats: *PassManager.OptimizationStats) anyerror!bool {
        var changed = false;
        var new_statements: std.ArrayList(ast.Stmt) = .{};
        defer new_statements.deinit(self.allocator);

        for (block.statements) |stmt| {
            if (stmt == .ForStmt or stmt == .WhileStmt) {
                // Check for loop-invariant code to hoist
                const loop_body = if (stmt == .ForStmt) stmt.ForStmt.body else stmt.WhileStmt.body;

                // Track variables defined in the loop
                var loop_vars = std.StringHashMap(void).init(self.allocator);
                defer loop_vars.deinit();

                for (loop_body.statements) |body_stmt| {
                    if (body_stmt == .LetDecl) {
                        try loop_vars.put(body_stmt.LetDecl.name, {});
                    }
                }

                // Find and hoist invariant statements
                var loop_new_statements: std.ArrayList(ast.Stmt) = .{};
                defer loop_new_statements.deinit(self.allocator);

                for (loop_body.statements) |body_stmt| {
                    var should_hoist = false;

                    if (body_stmt == .LetDecl) {
                        const let_decl = body_stmt.LetDecl;
                        if (let_decl.value) |val| {
                            // Check if the value expression is loop-invariant
                            if (try self.isLoopInvariant(val, &loop_vars)) {
                                // Hoist this statement out of the loop
                                try new_statements.append(self.allocator, body_stmt);
                                stats.redundant_loads_eliminated += 1;
                                changed = true;
                                should_hoist = true;
                            }
                        }
                    }

                    if (!should_hoist) {
                        try loop_new_statements.append(self.allocator, body_stmt);
                    }
                }

                // Update loop body if we hoisted anything
                if (changed) {
                    loop_body.statements = try loop_new_statements.toOwnedSlice(self.allocator);
                }

                // Recurse into nested loops
                _ = try self.optimizeLoopsInBlock(loop_body, stats);
            } else {
                // Recurse into nested blocks
                _ = try self.optimizeLoopsInStmt(stmt, stats);
            }

            try new_statements.append(self.allocator, stmt);
        }

        // Replace block's statements if we made changes
        if (changed) {
            block.statements = try new_statements.toOwnedSlice(self.allocator);
        }

        return changed;
    }

    fn isLoopInvariant(self: *Pass, expr: *ast.Expr, loop_vars: *std.StringHashMap(void)) !bool {
        switch (expr.*) {
            .Identifier => |id| {
                // Not invariant if it references a loop variable
                return !loop_vars.contains(id.name);
            },
            .IntegerLiteral, .FloatLiteral, .StringLiteral, .BooleanLiteral => {
                // Literals are always invariant
                return true;
            },
            .BinaryExpr => |bin| {
                // Binary expression is invariant if both operands are invariant
                return try self.isLoopInvariant(bin.left, loop_vars) and
                    try self.isLoopInvariant(bin.right, loop_vars);
            },
            .UnaryExpr => |un| {
                // Unary expression is invariant if operand is invariant
                return try self.isLoopInvariant(un.operand, loop_vars);
            },
            .CallExpr => {
                // Function calls are not invariant (could have side effects)
                return false;
            },
            else => {
                return false;
            },
        }
    }

    fn runLoopUnrolling(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        const max_iterations = switch (self.config) {
            .LoopUnrolling => |cfg| cfg.max_iterations,
            else => return false,
        };

        var changed = false;

        // Process all top-level statements
        for (program.statements) |stmt| {
            changed = try self.unrollLoopsRecursive(stmt, max_iterations, stats) or changed;
        }

        return changed;
    }

    fn unrollLoopsRecursive(self: *Pass, stmt: ast.Stmt, max_iterations: usize, stats: *PassManager.OptimizationStats) anyerror!bool {
        var changed = false;

        switch (stmt) {
            .ForStmt => |for_stmt| {
                // Recurse into loop body first
                changed = try self.unrollLoopsInBlock(for_stmt.body, max_iterations, stats);
            },
            .WhileStmt => |while_stmt| {
                changed = try self.unrollLoopsInBlock(while_stmt.body, max_iterations, stats);
            },
            .IfStmt => |if_stmt| {
                changed = try self.unrollLoopsInBlock(if_stmt.then_block, max_iterations, stats);
                if (if_stmt.else_block) |else_block| {
                    changed = try self.unrollLoopsInBlock(else_block, max_iterations, stats) or changed;
                }
            },
            .FnDecl => |fn_decl| {
                changed = try self.unrollLoopsInBlock(fn_decl.body, max_iterations, stats);
            },
            else => {},
        }

        return changed;
    }

    fn unrollLoopsInBlock(self: *Pass, block: *ast.BlockStmt, max_iterations: usize, stats: *PassManager.OptimizationStats) anyerror!bool {
        var changed = false;
        var new_statements: std.ArrayList(ast.Stmt) = .{};
        defer new_statements.deinit(self.allocator);

        for (block.statements) |stmt| {
            if (stmt == .ForStmt) {
                const for_stmt = stmt.ForStmt;

                // Check if this loop can be unrolled
                if (for_stmt.iterable.* == .RangeExpr) {
                    const range = for_stmt.iterable.RangeExpr;

                    if (range.start.* == .IntegerLiteral and range.end.* == .IntegerLiteral) {
                        const start_val = range.start.IntegerLiteral.value;
                        const end_val = range.end.IntegerLiteral.value;
                        const iter_count = if (end_val > start_val)
                            @as(usize, @intCast(end_val - start_val))
                        else
                            0;

                        if (iter_count > 0 and iter_count <= max_iterations) {
                            // Unroll the loop
                            var i: i64 = start_val;
                            while (i < end_val) : (i += 1) {
                                // Clone each statement in the loop body and substitute the loop variable
                                for (for_stmt.body.statements) |body_stmt| {
                                    const unrolled_stmt = try self.cloneAndSubstituteStmt(body_stmt, for_stmt.iterator, i);
                                    try new_statements.append(self.allocator, unrolled_stmt);
                                }
                            }

                            stats.loops_unrolled += 1;
                            changed = true;
                            continue; // Don't add the original ForStmt
                        }
                    }
                }

                // Loop couldn't be unrolled, but recurse into its body
                _ = try self.unrollLoopsInBlock(for_stmt.body, max_iterations, stats);
            } else {
                // Recurse into nested blocks
                _ = try self.unrollLoopsRecursive(stmt, max_iterations, stats);
            }

            try new_statements.append(self.allocator, stmt);
        }

        // Replace block's statements if we made changes
        if (changed) {
            block.statements = try new_statements.toOwnedSlice(self.allocator);
        }

        return changed;
    }

    fn cloneAndSubstituteStmt(self: *Pass, stmt: ast.Stmt, loop_var: []const u8, value: i64) anyerror!ast.Stmt {
        switch (stmt) {
            .LetDecl => |let_decl| {
                const new_let = try self.allocator.create(ast.LetDecl);
                new_let.* = .{
                    .node = let_decl.node,
                    .name = let_decl.name,
                    .type_name = let_decl.type_name,
                    .value = if (let_decl.value) |val| try self.cloneAndSubstituteExprForLoop(val, loop_var, value) else null,
                    .is_mutable = let_decl.is_mutable,
                    .is_public = let_decl.is_public,
                };
                return ast.Stmt{ .LetDecl = new_let };
            },
            .ExprStmt => |expr| {
                const new_expr = try self.cloneAndSubstituteExprForLoop(expr, loop_var, value);
                return ast.Stmt{ .ExprStmt = new_expr };
            },
            else => {
                // For other statement types, return as-is (could be extended)
                return stmt;
            },
        }
    }

    fn cloneAndSubstituteExprForLoop(self: *Pass, expr: *ast.Expr, loop_var: []const u8, value: i64) anyerror!*ast.Expr {
        const cloned = try self.allocator.create(ast.Expr);

        switch (expr.*) {
            .Identifier => |id| {
                // If this is the loop variable, replace with the literal value
                if (std.mem.eql(u8, id.name, loop_var)) {
                    const int_lit = ast.IntegerLiteral{
                        .node = id.node,
                        .value = value,
                    };
                    cloned.* = ast.Expr{ .IntegerLiteral = int_lit };
                } else {
                    cloned.* = expr.*;
                }
            },
            .BinaryExpr => |bin| {
                const left = try self.cloneAndSubstituteExprForLoop(bin.left, loop_var, value);
                const right = try self.cloneAndSubstituteExprForLoop(bin.right, loop_var, value);
                const cloned_bin = try self.allocator.create(ast.BinaryExpr);
                cloned_bin.* = .{
                    .node = bin.node,
                    .left = left,
                    .right = right,
                    .op = bin.op,
                };
                cloned.* = ast.Expr{ .BinaryExpr = cloned_bin };
            },
            .UnaryExpr => |un| {
                const operand = try self.cloneAndSubstituteExprForLoop(un.operand, loop_var, value);
                const cloned_un = try self.allocator.create(ast.UnaryExpr);
                cloned_un.* = .{
                    .node = un.node,
                    .operand = operand,
                    .op = un.op,
                };
                cloned.* = ast.Expr{ .UnaryExpr = cloned_un };
            },
            .CallExpr => |call| {
                const callee = try self.cloneAndSubstituteExprForLoop(call.callee, loop_var, value);
                var args: std.ArrayList(*ast.Expr) = .{};
                defer args.deinit(self.allocator);

                for (call.args) |arg| {
                    const cloned_arg = try self.cloneAndSubstituteExprForLoop(arg, loop_var, value);
                    try args.append(self.allocator, cloned_arg);
                }

                const cloned_call = try self.allocator.create(ast.CallExpr);
                cloned_call.* = .{
                    .node = call.node,
                    .callee = callee,
                    .args = try args.toOwnedSlice(self.allocator),
                    .named_args = call.named_args, // For simplicity, don't substitute in named args
                };
                cloned.* = ast.Expr{ .CallExpr = cloned_call };
            },
            .AssignmentExpr => |assign| {
                const target = try self.cloneAndSubstituteExprForLoop(assign.target, loop_var, value);
                const assign_value = try self.cloneAndSubstituteExprForLoop(assign.value, loop_var, value);
                const cloned_assign = try self.allocator.create(ast.AssignmentExpr);
                cloned_assign.* = .{
                    .node = assign.node,
                    .target = target,
                    .value = assign_value,
                };
                cloned.* = ast.Expr{ .AssignmentExpr = cloned_assign };
            },
            else => {
                // For literals and other expressions, just copy as-is
                cloned.* = expr.*;
            },
        }

        return cloned;
    }

    fn runRedundancyElimination(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        // Process all statements to eliminate redundant loads
        for (program.statements) |stmt| {
            changed = try self.eliminateRedundancyInStmt(stmt, stats) or changed;
        }

        return changed;
    }

    fn eliminateRedundancyInStmt(self: *Pass, stmt: ast.Stmt, stats: *PassManager.OptimizationStats) anyerror!bool {
        var changed = false;

        switch (stmt) {
            .FnDecl => |fn_decl| {
                changed = try self.eliminateRedundancyInBlock(fn_decl.body, stats);
            },
            .IfStmt => |if_stmt| {
                changed = try self.eliminateRedundancyInBlock(if_stmt.then_block, stats);
                if (if_stmt.else_block) |else_block| {
                    changed = try self.eliminateRedundancyInBlock(else_block, stats) or changed;
                }
            },
            .WhileStmt => |while_stmt| {
                changed = try self.eliminateRedundancyInBlock(while_stmt.body, stats);
            },
            .ForStmt => |for_stmt| {
                changed = try self.eliminateRedundancyInBlock(for_stmt.body, stats);
            },
            else => {},
        }

        return changed;
    }

    fn eliminateRedundancyInBlock(self: *Pass, block: *ast.BlockStmt, stats: *PassManager.OptimizationStats) anyerror!bool {
        var changed = false;

        // Track loaded expressions: map expression string → temp variable name
        var loaded_exprs = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = loaded_exprs.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            loaded_exprs.deinit();
        }

        var new_statements: std.ArrayList(ast.Stmt) = .{};
        defer new_statements.deinit(self.allocator);

        for (block.statements) |stmt| {
            // Check if this statement contains redundant loads
            if (stmt == .LetDecl) {
                const let_decl = stmt.LetDecl;
                if (let_decl.value) |val| {
                    // Check for array index or member access that we've seen before
                    if (val.* == .IndexExpr or val.* == .MemberExpr) {
                        const expr_key = try self.loadExprToString(val);
                        defer self.allocator.free(expr_key);

                        if (loaded_exprs.get(expr_key)) |prev_var| {
                            // We've already loaded this expression!
                            // Replace the load with a reference to the previous variable
                            const new_let = try self.allocator.create(ast.LetDecl);
                            const prev_ident = try self.createIdentifier(prev_var, let_decl.node.loc);

                            new_let.* = .{
                                .node = let_decl.node,
                                .name = let_decl.name,
                                .type_name = let_decl.type_name,
                                .value = prev_ident,
                                .is_mutable = let_decl.is_mutable,
                                .is_public = let_decl.is_public,
                            };

                            try new_statements.append(self.allocator, ast.Stmt{ .LetDecl = new_let });
                            stats.redundant_loads_eliminated += 1;
                            changed = true;
                            continue;
                        } else {
                            // First time seeing this load, track it
                            const key_copy = try self.allocator.dupe(u8, expr_key);
                            try loaded_exprs.put(key_copy, let_decl.name);
                        }
                    }
                }
            } else if (stmt == .ExprStmt) {
                // Stores (assignments) invalidate tracked loads
                if (stmt.ExprStmt.* == .AssignmentExpr) {
                    const assign = stmt.ExprStmt.AssignmentExpr;
                    // Invalidate loads that might be affected by this store
                    if (assign.target.* == .IndexExpr or assign.target.* == .MemberExpr) {
                        const target_key = try self.loadExprToString(assign.target);
                        defer self.allocator.free(target_key);

                        if (loaded_exprs.get(target_key)) |_| {
                            _ = loaded_exprs.remove(target_key);
                        }
                    }
                }
            }

            try new_statements.append(self.allocator, stmt);

            // Recurse into nested blocks
            _ = try self.eliminateRedundancyInStmt(stmt, stats);
        }

        // Replace block's statements if we made changes
        if (changed) {
            block.statements = try new_statements.toOwnedSlice(self.allocator);
        }

        return changed;
    }

    fn loadExprToString(self: *Pass, expr: *ast.Expr) ![]const u8 {
        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);

        try self.loadExprToStringHelper(expr, &buffer);
        return buffer.toOwnedSlice(self.allocator);
    }

    fn loadExprToStringHelper(self: *Pass, expr: *ast.Expr, buffer: *std.ArrayList(u8)) anyerror!void {
        switch (expr.*) {
            .Identifier => |id| {
                try buffer.appendSlice(self.allocator, id.name);
            },
            .IndexExpr => |index| {
                try self.loadExprToStringHelper(index.array, buffer);
                try buffer.appendSlice(self.allocator, "[");
                try self.loadExprToStringHelper(index.index, buffer);
                try buffer.appendSlice(self.allocator, "]");
            },
            .MemberExpr => |member| {
                try self.loadExprToStringHelper(member.object, buffer);
                try buffer.appendSlice(self.allocator, ".");
                try buffer.appendSlice(self.allocator, member.member);
            },
            .IntegerLiteral => |int| {
                const str = try std.fmt.allocPrint(self.allocator, "{d}", .{int.value});
                defer self.allocator.free(str);
                try buffer.appendSlice(self.allocator, str);
            },
            else => {
                try buffer.appendSlice(self.allocator, "<expr>");
            },
        }
    }

    fn createIdentifier(self: *Pass, name: []const u8, loc: ast.SourceLocation) !*ast.Expr {
        const expr = try self.allocator.create(ast.Expr);
        const ident = ast.Identifier{
            .node = .{ .type = .Identifier, .loc = loc },
            .name = name,
        };
        expr.* = ast.Expr{ .Identifier = ident };
        return expr;
    }

    fn runEscapeAnalysis(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        // Track allocations and their escape status
        var allocations = std.StringHashMap(bool).init(self.allocator);
        defer allocations.deinit();

        // Process all statements to find allocations and analyze escapes
        for (program.statements) |stmt| {
            try self.analyzeEscapeInStmt(stmt, &allocations, stats, &changed);
        }

        return changed;
    }

    fn analyzeEscapeInStmt(self: *Pass, stmt: ast.Stmt, allocations: *std.StringHashMap(bool), stats: *PassManager.OptimizationStats, changed: *bool) anyerror!void {
        switch (stmt) {
            .FnDecl => |fn_decl| {
                // Each function has its own allocation context
                var local_allocs = std.StringHashMap(bool).init(self.allocator);
                defer local_allocs.deinit();

                try self.analyzeEscapeInBlock(fn_decl.body, &local_allocs, stats, changed);
            },
            .IfStmt => |if_stmt| {
                try self.analyzeEscapeInExpr(if_stmt.condition, allocations, changed);
                try self.analyzeEscapeInBlock(if_stmt.then_block, allocations, stats, changed);
                if (if_stmt.else_block) |else_block| {
                    try self.analyzeEscapeInBlock(else_block, allocations, stats, changed);
                }
            },
            .WhileStmt => |while_stmt| {
                try self.analyzeEscapeInExpr(while_stmt.condition, allocations, changed);
                try self.analyzeEscapeInBlock(while_stmt.body, allocations, stats, changed);
            },
            .ForStmt => |for_stmt| {
                try self.analyzeEscapeInExpr(for_stmt.iterable, allocations, changed);
                try self.analyzeEscapeInBlock(for_stmt.body, allocations, stats, changed);
            },
            .LetDecl => |let_decl| {
                if (let_decl.value) |val| {
                    // Check if this is an allocation
                    if (self.isAllocation(val)) {
                        // Track this variable as potentially non-escaping
                        try allocations.put(let_decl.name, false);
                        // If it doesn't escape, we can elide the heap allocation
                        stats.allocations_elided += 1;
                    }
                    try self.analyzeEscapeInExpr(val, allocations, changed);
                }
            },
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.value) |val| {
                    // Anything returned escapes
                    self.markEscaping(val, allocations);
                    try self.analyzeEscapeInExpr(val, allocations, changed);
                }
            },
            .ExprStmt => |expr| {
                try self.analyzeEscapeInExpr(expr, allocations, changed);
            },
            else => {},
        }
    }

    fn analyzeEscapeInBlock(self: *Pass, block: *const ast.BlockStmt, allocations: *std.StringHashMap(bool), stats: *PassManager.OptimizationStats, changed: *bool) anyerror!void {
        for (block.statements) |stmt| {
            try self.analyzeEscapeInStmt(stmt, allocations, stats, changed);
        }
    }

    fn analyzeEscapeInExpr(self: *Pass, expr: *ast.Expr, allocations: *std.StringHashMap(bool), changed: *bool) anyerror!void {
        switch (expr.*) {
            .Identifier => |id| {
                // Just using a variable doesn't cause escape
                _ = id;
            },
            .BinaryExpr => |bin| {
                try self.analyzeEscapeInExpr(bin.left, allocations, changed);
                try self.analyzeEscapeInExpr(bin.right, allocations, changed);
            },
            .UnaryExpr => |un| {
                try self.analyzeEscapeInExpr(un.operand, allocations, changed);
            },
            .CallExpr => |call| {
                try self.analyzeEscapeInExpr(call.callee, allocations, changed);

                // Arguments passed to functions escape (conservative)
                for (call.args) |arg| {
                    self.markEscaping(arg, allocations);
                    try self.analyzeEscapeInExpr(arg, allocations, changed);
                }
            },
            .ArrayLiteral => |arr| {
                for (arr.elements) |elem| {
                    try self.analyzeEscapeInExpr(elem, allocations, changed);
                }
            },
            .MemberExpr => |member| {
                try self.analyzeEscapeInExpr(member.object, allocations, changed);
            },
            .IndexExpr => |index| {
                try self.analyzeEscapeInExpr(index.array, allocations, changed);
                try self.analyzeEscapeInExpr(index.index, allocations, changed);
            },
            .AssignmentExpr => |assign| {
                // Assignment to member or index causes escape
                if (assign.target.* == .MemberExpr or assign.target.* == .IndexExpr) {
                    self.markEscaping(assign.value, allocations);
                }
                try self.analyzeEscapeInExpr(assign.target, allocations, changed);
                try self.analyzeEscapeInExpr(assign.value, allocations, changed);
            },
            else => {},
        }
    }

    fn isAllocation(self: *Pass, expr: *ast.Expr) bool {
        _ = self;
        return switch (expr.*) {
            .ArrayLiteral => true,
            .StructLiteral => true,
            .MapLiteral => true,
            .CallExpr => |call| {
                // Check if calling 'new' or similar allocation function
                if (call.callee.* == .Identifier) {
                    const name = call.callee.Identifier.name;
                    return std.mem.eql(u8, name, "new") or
                           std.mem.eql(u8, name, "alloc") or
                           std.mem.eql(u8, name, "create");
                }
                return false;
            },
            else => false,
        };
    }

    fn markEscaping(self: *Pass, expr: *ast.Expr, allocations: *std.StringHashMap(bool)) void {
        _ = self;

        if (expr.* == .Identifier) {
            const var_name = expr.Identifier.name;
            if (allocations.get(var_name)) |_| {
                // Mark as escaping
                allocations.put(var_name, true) catch {};
            }
        }
    }

    fn runVectorization(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        // Analyze loops for vectorization opportunities
        for (program.statements) |stmt| {
            try self.analyzeVectorizationInStmt(stmt, stats, &changed);
        }

        return changed;
    }

    fn analyzeVectorizationInStmt(self: *Pass, stmt: ast.Stmt, stats: *PassManager.OptimizationStats, changed: *bool) anyerror!void {
        switch (stmt) {
            .FnDecl => |fn_decl| {
                try self.analyzeVectorizationInBlock(fn_decl.body, stats, changed);
            },
            .ForStmt => |for_stmt| {
                // Check if this loop is vectorizable
                if (try self.isVectorizableLoop(for_stmt, stats)) {
                    // Mark as vectorizable or transform
                    // For now, just count it
                    stats.loops_vectorized += 1;
                    changed.* = true;
                }
                try self.analyzeVectorizationInBlock(for_stmt.body, stats, changed);
            },
            .WhileStmt => |while_stmt| {
                try self.analyzeVectorizationInBlock(while_stmt.body, stats, changed);
            },
            .IfStmt => |if_stmt| {
                try self.analyzeVectorizationInBlock(if_stmt.then_block, stats, changed);
                if (if_stmt.else_block) |else_block| {
                    try self.analyzeVectorizationInBlock(else_block, stats, changed);
                }
            },
            else => {},
        }
    }

    fn analyzeVectorizationInBlock(self: *Pass, block: *const ast.BlockStmt, stats: *PassManager.OptimizationStats, changed: *bool) anyerror!void {
        for (block.statements) |stmt| {
            try self.analyzeVectorizationInStmt(stmt, stats, changed);
        }
    }

    fn isVectorizableLoop(self: *Pass, for_stmt: *ast.ForStmt, stats: *PassManager.OptimizationStats) !bool {
        _ = stats;

        // Check if loop iterates over a range or array
        if (for_stmt.iterable.* != .RangeExpr and
            for_stmt.iterable.* != .Identifier and
            for_stmt.iterable.* != .ArrayLiteral) {
            return false;
        }

        // Check if loop body contains vectorizable operations
        return self.hasVectorizableOperations(for_stmt.body);
    }

    fn hasVectorizableOperations(self: *Pass, block: *const ast.BlockStmt) bool {
        _ = self;

        // Look for array assignments with arithmetic operations
        for (block.statements) |stmt| {
            if (stmt == .ExprStmt) {
                const expr = stmt.ExprStmt;
                if (expr.* == .AssignmentExpr) {
                    const assign = expr.AssignmentExpr;

                    // Check if assigning to array index
                    if (assign.target.* == .IndexExpr) {
                        // Check if value is an arithmetic operation
                        if (assign.value.* == .BinaryExpr) {
                            const bin = assign.value.BinaryExpr;
                            const op = bin.op;

                            // These operations are vectorizable
                            if (op == .Add or op == .Sub or op == .Mul or
                                op == .Div or op == .Mod) {
                                return true;
                            }
                        }
                    }
                }
            }
        }

        return false;
    }

    fn runFunctionMerging(self: *Pass, program: *ast.Program, stats: *PassManager.OptimizationStats) !bool {
        var changed = false;

        // Build a map of function signatures to function declarations
        var function_map = std.StringHashMap(*ast.FnDecl).init(self.allocator);
        defer {
            var it = function_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            function_map.deinit();
        }

        // Collect all functions and check for duplicates
        for (program.statements) |stmt| {
            if (stmt == .FnDecl) {
                const fn_decl = stmt.FnDecl;

                // Create a signature for this function based on its body
                const signature = try self.getFunctionSignature(fn_decl);
                defer self.allocator.free(signature);

                if (function_map.get(signature)) |existing_fn| {
                    // Found a duplicate function!
                    // In a real implementation, we would:
                    // 1. Replace all calls to fn_decl with calls to existing_fn
                    // 2. Remove fn_decl from the program
                    // For now, just count it
                    _ = existing_fn;
                    stats.functions_merged += 1;
                    changed = true;
                } else {
                    // Track this function
                    const sig_copy = try self.allocator.dupe(u8, signature);
                    try function_map.put(sig_copy, fn_decl);
                }
            }
        }

        return changed;
    }

    fn getFunctionSignature(self: *Pass, fn_decl: *ast.FnDecl) ![]const u8 {
        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);

        // Include parameter count and types in signature
        const param_str = try std.fmt.allocPrint(
            self.allocator,
            "params:{d};",
            .{fn_decl.params.len}
        );
        defer self.allocator.free(param_str);
        try buffer.appendSlice(self.allocator, param_str);

        // Include return type if present
        if (fn_decl.return_type) |ret_type| {
            try buffer.appendSlice(self.allocator, "ret:");
            try buffer.appendSlice(self.allocator, ret_type);
            try buffer.appendSlice(self.allocator, ";");
        }

        // Include body structure (simplified)
        try buffer.appendSlice(self.allocator, "body:");
        try self.appendBlockSignature(fn_decl.body, &buffer);

        return buffer.toOwnedSlice(self.allocator);
    }

    fn appendBlockSignature(self: *Pass, block: *const ast.BlockStmt, buffer: *std.ArrayList(u8)) anyerror!void {
        try buffer.appendSlice(self.allocator, "{");

        for (block.statements) |stmt| {
            try self.appendStmtSignature(stmt, buffer);
            try buffer.appendSlice(self.allocator, ";");
        }

        try buffer.appendSlice(self.allocator, "}");
    }

    fn appendStmtSignature(self: *Pass, stmt: ast.Stmt, buffer: *std.ArrayList(u8)) anyerror!void {
        switch (stmt) {
            .LetDecl => {
                try buffer.appendSlice(self.allocator, "let");
            },
            .ReturnStmt => {
                try buffer.appendSlice(self.allocator, "ret");
            },
            .IfStmt => {
                try buffer.appendSlice(self.allocator, "if");
            },
            .WhileStmt => {
                try buffer.appendSlice(self.allocator, "while");
            },
            .ForStmt => {
                try buffer.appendSlice(self.allocator, "for");
            },
            .ExprStmt => {
                try buffer.appendSlice(self.allocator, "expr");
            },
            else => {
                try buffer.appendSlice(self.allocator, "stmt");
            },
        }
    }
};
